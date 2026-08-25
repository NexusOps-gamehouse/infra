-- ===========================================================================
-- 회차 간 초기 상태 복원.
--
-- ⚠️ 전체 테이블을 비우지 않는다. @test.local 계정에 딸린 것만 지운다.
--    TRUNCATE 로 밀면 편하지만, 이 스크립트가 실수로 공용 DB 를 향했을 때
--    돌이킬 수 없다. 삭제 범위를 데이터로 한정해 두면 최악의 경우에도
--    지워지는 것은 우리가 만든 테스트 데이터뿐이다.
--
-- 지우는 대상
--   · users        email LIKE '%@test.local'   (부하용 600 + 시딩 작성자 1)
--   · posts        그 계정이 쓴 글 — [SEED] 시딩분과 [LT] 런타임 생성분 모두
--   · applications / notifications / chat_* / friends  위에 딸린 것
--
-- 순서는 FK 역방향이다. 자식부터 지우지 않으면 참조 위반이 난다.
-- ===========================================================================

BEGIN;

-- 대상 계정과 글을 한 번만 계산해 임시 테이블에 담는다.
-- 매 DELETE 마다 서브쿼리를 반복하면 큰 테이블에서 느리다.
CREATE TEMP TABLE lt_users ON COMMIT DROP AS
  SELECT id FROM users WHERE email LIKE '%@test.local';

CREATE TEMP TABLE lt_posts ON COMMIT DROP AS
  SELECT id FROM posts WHERE author_id IN (SELECT id FROM lt_users);

CREATE TEMP TABLE lt_rooms ON COMMIT DROP AS
  SELECT id FROM chat_rooms
   WHERE post_id IN (SELECT id FROM lt_posts)
      OR owner_id IN (SELECT id FROM lt_users);

DELETE FROM chat_messages
 WHERE room_id IN (SELECT id FROM lt_rooms)
    OR sender_id IN (SELECT id FROM lt_users);

DELETE FROM chat_room_members
 WHERE room_id IN (SELECT id FROM lt_rooms)
    OR user_id IN (SELECT id FROM lt_users);

DELETE FROM chat_rooms WHERE id IN (SELECT id FROM lt_rooms);

DELETE FROM friends
 WHERE requester_id IN (SELECT id FROM lt_users)
    OR receiver_id IN (SELECT id FROM lt_users);

DELETE FROM user_champion_masteries
 WHERE user_id IN (SELECT id FROM lt_users);

-- 시나리오 4 는 신청 1건마다 글쓴이에게 알림을 1건 만든다.
-- 회차마다 여기가 가장 많이 불어나는 테이블이다.
DELETE FROM notifications
 WHERE user_id IN (SELECT id FROM lt_users);

DELETE FROM applications
 WHERE post_id IN (SELECT id FROM lt_posts)
    OR applicant_id IN (SELECT id FROM lt_users);

DELETE FROM posts WHERE id IN (SELECT id FROM lt_posts);

DELETE FROM users WHERE id IN (SELECT id FROM lt_users);

COMMIT;
