-- ===========================================================================
-- 프로브용 데이터 — N+1 을 '잴 수 있게' 만든다.
--
-- ⚠️ 왜 필요한가
--    회차용 시딩(seed/generate.sh)은 계정·글·신청만 만든다. 채팅방·친구·알림은
--    한 건도 없다. 그 상태로 /api/chat/rooms 를 재면 응답이 빈 배열이라
--    "쿼리 0개" 가 나오는데, 그건 N+1 이 없다는 뜻이 아니라 잰 적이 없다는 뜻이다.
--    분모가 0 이면 '건당' 을 계산할 수 없다.
--
--    신청도 마찬가지다. 시딩은 계정당 평균 1.25건뿐이고, 게다가 전부 PENDING
--    이라 ApplicationService.PENDING_TTL(1시간) 이 지나면 응답에서 사라진다.
--    시딩한 지 한 시간이 넘었다면 /api/my/applications 는 이미 빈 배열이다.
--
-- 그래서 계정 하나(:probe_id)에만 측정 가능한 양을 몰아준다.
--   친구 30 · 알림 30 · 채팅방 10(방마다 멤버 5) · 신청 30
--
-- 30 인 이유: 분모가 한 자리면 '건당 1회'(N+1)와 '상수 1회'(정상)가 안 갈린다.
-- 30 이면 30배 차이로 벌어져서 표에서 바로 보인다.
--
-- ⚠️ 이 파일은 회차용 시딩 상태를 바꾼다. 프로브를 돌린 뒤 부하 회차를 돌릴
--    거라면 seed/generate.sh 를 다시 돌려 원상복구한다. reset.sql 은 여기서
--    만든 것만 지우므로 그것만으로도 충분하지만, 회차 전 재시딩이 원칙이다.
--
-- 넘어오는 변수 (probe.sh 가 psql -v 로 준다)
--   :probe_id   측정 대상 계정의 users.id
-- ===========================================================================

BEGIN;

-- 재실행 가능하게 — 이 파일이 만드는 것을 먼저 지운다.
-- (reset.sql 과 같은 내용이다. 두 번 돌려도 30건이 60건이 되지 않아야 한다)
--
-- ⚠️ 순서는 FK 역방향이다. 자식부터 지운다.
--    chat_messages 를 빠뜨리면, 그 방에 메시지가 하나라도 있을 때
--    chat_rooms 삭제가 참조 위반으로 죽는다. 부하 시나리오는 메시지를 안
--    보내지만 UI 로 한 번이라도 채팅을 해 봤으면 남아 있다.
--    (00-reset.sql 이 같은 순서를 지키는 이유와 같다)
DELETE FROM chat_messages WHERE room_id IN (
  SELECT r.id FROM chat_rooms r JOIN posts p ON p.id = r.post_id
  WHERE p.title LIKE '[SEED]%');
DELETE FROM chat_room_members WHERE room_id IN (
  SELECT r.id FROM chat_rooms r JOIN posts p ON p.id = r.post_id
  WHERE p.title LIKE '[SEED]%');
DELETE FROM chat_rooms WHERE post_id IN (SELECT id FROM posts WHERE title LIKE '[SEED]%');
DELETE FROM friends       WHERE requester_id = :probe_id OR receiver_id = :probe_id;
DELETE FROM notifications WHERE user_id = :probe_id;
DELETE FROM applications  WHERE applicant_id = :probe_id;

-- ---------------------------------------------------------------------------
-- 친구 30명 — FriendDto.from() 이 requester/receiver 를 둘 다 만진다.
--
-- 절반은 내가 신청하고 절반은 내가 받은 것으로 만든다. from() 은 '내가 아닌
-- 쪽' 을 고르느라 어느 경우든 두 연관을 다 건드리는데, 한 방향으로만 만들면
-- 그중 하나가 항상 나 자신이라 1차 캐시에 걸려 쿼리가 안 나간다.
-- 실제 사용에서는 양쪽이 섞이므로 섞어서 만든다.
-- ---------------------------------------------------------------------------
INSERT INTO friends (requester_id, receiver_id, status, created_at, accepted_at)
SELECT
  CASE WHEN u.rn % 2 = 0 THEN :probe_id ELSE u.id END,
  CASE WHEN u.rn % 2 = 0 THEN u.id ELSE :probe_id END,
  'ACCEPTED', now(), now()
FROM (
  SELECT id, row_number() OVER (ORDER BY id) AS rn
  FROM users
  WHERE email LIKE 'lt%@test.local' AND id <> :probe_id
  ORDER BY id LIMIT 30
) u;

-- ---------------------------------------------------------------------------
-- 알림 30건 — NotificationDto.from() 은 지연 연관을 안 만진다.
--
-- 즉 이 엔드포인트는 '깨끗할 것으로 예상되는' 대조군이다. 대조군이 없으면
-- 다른 API 의 숫자가 큰 것인지 원래 그런 것인지 말할 수 없다.
-- 조회는 findTop30 이라 30건을 넣으면 상한까지 채워진다.
-- ---------------------------------------------------------------------------
INSERT INTO notifications (user_id, message, link, is_read, created_at)
SELECT :probe_id, '[PROBE] 알림 ' || n, NULL, false, now() - (n || ' minutes')::interval
FROM generate_series(1, 30) AS n;

-- ---------------------------------------------------------------------------
-- 채팅방 10개 × 멤버 5명 — ChatService.toRoomDto() 가 중첩으로 돈다.
--
-- 방마다: 멤버 목록 조회 1 + 방 1 + 글 1 + 방장 1
-- 멤버마다: applicationRepository.findByPostIdAndApplicantId 1 (방장 제외)
-- → 방 수 × 멤버 수의 곱으로 늘어나는 유일한 자리다.
--
-- 방장은 글 작성자(seedauthor)로 둔다. 실제 흐름(승인 → 방 생성)과 같다.
-- ---------------------------------------------------------------------------
-- ⚠️ UNION ALL 로 '방장 + 나 + 3명' 을 한 번에 만들지 않는다. UNION 뒤의
--    ORDER BY / LIMIT 은 마지막 가지가 아니라 합쳐진 결과 전체에 걸려서,
--    "다른 계정 3명" 을 고르려던 OFFSET 이 5행짜리 결과에 적용된다.
--    문장을 나누는 편이 짧고 틀릴 여지가 없다.
INSERT INTO chat_rooms (post_id, owner_id, created_at)
SELECT id, author_id, now()
FROM (SELECT id, author_id FROM posts WHERE title LIKE '[SEED]%' ORDER BY id LIMIT 10) p;

-- 방장 — 글 작성자다. toRoomDto 가 owner 를 따로 조회한다.
INSERT INTO chat_room_members (room_id, user_id, confirmed, joined_at)
SELECT r.id, p.author_id, true, now()
FROM chat_rooms r JOIN posts p ON p.id = r.post_id
WHERE p.title LIKE '[SEED]%';

-- 프로브 계정 — 이 계정이 /api/chat/rooms 를 부른다.
INSERT INTO chat_room_members (room_id, user_id, confirmed, joined_at)
SELECT r.id, :probe_id, true, now()
FROM chat_rooms r JOIN posts p ON p.id = r.post_id
WHERE p.title LIKE '[SEED]%';

-- 나머지 3명씩 — 방마다 다른 계정을 넣는다. 같은 3명을 모든 방에 넣으면
-- 1차 캐시가 User 조회를 접어버려서, 멤버마다 나가는 쿼리가 과소평가된다.
INSERT INTO chat_room_members (room_id, user_id, confirmed, joined_at)
SELECT r.room_id, u.id, false, now()
FROM (
  SELECT r.id AS room_id, row_number() OVER (ORDER BY r.id) AS rn
  FROM chat_rooms r JOIN posts p ON p.id = r.post_id
  WHERE p.title LIKE '[SEED]%'
) r
CROSS JOIN LATERAL (
  SELECT id FROM users
  WHERE email LIKE 'lt%@test.local' AND id <> :probe_id
  ORDER BY id OFFSET 100 + (r.rn - 1) * 3 LIMIT 3
) u;

-- ---------------------------------------------------------------------------
-- 신청 30건 — ApplicationService.toDto() 가 글마다 채팅방을 다시 찾는다.
--
-- ⚠️ created_at 을 now() 로 둔다. PENDING_TTL 이 1시간이라 시딩 시각을 그대로
--    쓰면 프로브를 돌리는 시점에 이미 만료돼 응답이 빈다.
-- ⚠️ status 를 APPROVED 로 둔다. toDto 의 chatRoomRepository.findByPostId 는
--    APPROVED/CONFIRMED 일 때만 돌아서, PENDING 으로 넣으면 정작 재려던 그
--    쿼리가 안 나간다.
-- UNIQUE(post_id, applicant_id) 가 있으므로 위에서 이 계정의 신청을 먼저 지웠다.
-- ---------------------------------------------------------------------------
INSERT INTO applications (post_id, applicant_id, status, created_at)
SELECT p.id, :probe_id, 'APPROVED', now()
FROM (
  SELECT id FROM posts
  WHERE title LIKE '[SEED]%' AND author_id <> :probe_id
  ORDER BY id LIMIT 30
) p;

COMMIT;
