-- ===========================================================================
-- 프로브용 데이터 제거.
--
-- fixture.sql 이 만든 것만 지운다. 회차용 시딩(계정·글·다른 계정의 신청)은
-- 건드리지 않는다.
--
-- ⚠️ 그래도 부하 회차 전에는 seed/generate.sh 를 다시 돌린다. 이 파일은
--    "프로브 흔적을 지운다" 이지 "시딩을 원상복구한다" 가 아니다 — 예를 들어
--    :probe_id 계정이 원래 갖고 있던 시딩 신청 1~2건은 fixture 가 지웠고
--    여기서 되살리지 못한다.
--
--   :probe_id   측정 대상 계정의 users.id
-- ===========================================================================

BEGIN;

-- ⚠️ FK 역방향. chat_messages 를 먼저 지우지 않으면 chat_rooms 삭제가 참조
--    위반으로 죽는다 (00-reset.sql 과 같은 순서).
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

COMMIT;
