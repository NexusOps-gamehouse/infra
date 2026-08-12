-- ===========================================================================
-- 계정 시딩.
--
-- :accounts 개의 부하용 계정 + 시딩 글 작성자 1개.
-- 변수는 generate.sh 가 scale.json 에서 읽어 psql -v 로 넘긴다.
--
-- ⚠️ 작성자 계정을 분리하는 이유
--    시나리오 4(참가 신청)는 "본인 글에는 참가 신청할 수 없습니다" 로 400 이
--    난다. 시딩 글을 부하용 계정이 쓰면 600 명 중 1 명이 자기 글을 만나
--    4xx 가 섞이고, 그 비율이 부하 단계마다 달라진다.
--    작성자를 따로 두면 부하용 계정은 어떤 시딩 글에도 신청할 수 있다.
--
--    generate.sh 의 users.json 조회 조건이 'lt%@test.local' 이라
--    seedauthor@test.local 은 자동으로 빠진다. 이 이메일 규칙을 바꾸면
--    작성자가 users.json 에 섞여 들어간다.
--
-- 비밀번호는 600 계정이 공유한다(:pwhash). 계정마다 salt 를 다르게 할 이유가
-- 없고, 다르게 하면 시딩에만 BCrypt 600 회 = 90 초 이상이 든다. 로그인 검증은
-- 매번 해시를 새로 계산하므로 시나리오 8 의 CPU 부하는 실사용과 같다.
-- ===========================================================================

BEGIN;

INSERT INTO users (email, password, nickname, mic, created_at)
SELECT
  'lt' || lpad(i::text, 4, '0') || '@test.local',
  :'pwhash',
  'lt' || lpad(i::text, 4, '0'),
  false,
  now()
FROM generate_series(1, :accounts) AS i;

-- 시딩 글 전용 작성자. 부하 계정이 아니므로 users.json 에 들어가지 않는다.
INSERT INTO users (email, password, nickname, mic, created_at)
VALUES ('seedauthor@test.local', :'pwhash', 'seedauthor', false, now());

COMMIT;
