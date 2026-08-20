-- ===========================================================================
-- 게시글 INSERT 본문 — 이 파일 하나만 존재한다.
--
-- 직접 실행하지 않는다. :target 을 정한 뒤 \ir 로 부른다.
--   02-posts.sql        \set target :posts   → 시딩 300건
--   d-growth-1000.sql   \set target 1000     → 회차 D 증분
--
-- ⚠️ 왜 합쳤나
--    02-posts.sql 과 d-growth.sql 에 같은 INSERT 를 복사해 두었더니, 게임
--    모드 값을 프론트 상수에 맞추면서 02 만 고쳐지고 d-growth 는 옛날 값
--    ('솔로랭크','자유랭크','칼바람나락')으로 남았다. 회차 D 에서만 다른
--    데이터가 들어가는 상태였고, 목록 조회 결과가 회차마다 달라진다.
--    복사본이 둘이면 언젠가 갈라진다.
--
-- 이미 있는 [SEED] 글 다음 번호부터 :target 까지 채운다. 그래서 같은 본문이
-- 최초 시딩(0 → 300)과 증분(300 → 1,000)에 모두 쓰인다.
--
-- ---------------------------------------------------------------------------
-- 값은 frontend/src/constants.js 와 맞춘다
--
--   GAMES         = ['리그오브레전드', '발로란트', '기타']
--   GAME_MODES    = ['일반', '랭크', '칼바람', '기타']
--   POSITIONS     = ['탑','정글','미드','원딜','서폿','상관없음']   ← 복수 선택, CSV 로 저장
--   MEMBER_COUNTS = [2, 3, 4, 5]
--
-- play_time 은 상수가 아니다. 글 작성 폼(PostFormPage)에서 자유 입력이고
-- placeholder 가 "예: 오늘 21시, 주말 저녁, 상시" 다.
-- constants.js 의 PLAY_TIMES / PLAY_DAYS 는 회원가입 설문(SurveyPage)용이라
-- 게시글과 무관하다 — 여기에 끌어다 쓰면 안 된다.
--
-- content 길이는 응답 크기의 근거다. 실측 PostDto = 1,014 B (문서 가정 600 B).
-- 여기를 바꾸면 preflight/response-size.sh 로 다시 재고 비용 추정을 갱신한다.
-- ===========================================================================

BEGIN;

INSERT INTO posts (
  author_id, title, content,
  game, game_mode, play_time, mic_required, positions,
  target_members, status, created_at
)
SELECT
  (SELECT id FROM users WHERE email = 'seedauthor@test.local'),
  '[SEED] 같이 게임하실 분 구합니다 #' || i,
  '오늘 저녁에 같이 게임 하실 분 찾습니다. 티어는 크게 상관없고 소통만 잘 되면 좋겠습니다. '
    || '초보자도 환영이고 편하게 즐기실 분이면 좋겠습니다. 마이크는 없어도 괜찮습니다. '
    || '연락 주시면 바로 답장 드리겠습니다. 모집글 번호 ' || i || ' 번입니다.',

  -- GAMES
  CASE i % 3 WHEN 0 THEN '리그오브레전드' WHEN 1 THEN '발로란트' ELSE '기타' END,

  -- GAME_MODES
  CASE i % 4 WHEN 0 THEN '일반' WHEN 1 THEN '랭크' WHEN 2 THEN '칼바람' ELSE '기타' END,

  -- 자유 입력. 폼 placeholder 와 같은 결로 둔다.
  CASE i % 4 WHEN 0 THEN '오늘 21시' WHEN 1 THEN '주말 저녁' WHEN 2 THEN '평일 밤' ELSE '상시' END,

  (i % 2 = 0),

  -- POSITIONS 는 복수 선택이라 CSV 로 저장된다(utils.csv 가 프론트에서 쪼갠다).
  -- 전부 단일 값으로 넣으면 실제보다 짧아져 응답 크기가 과소평가된다.
  CASE i % 6
    WHEN 0 THEN '탑'
    WHEN 1 THEN '정글,서폿'
    WHEN 2 THEN '미드'
    WHEN 3 THEN '원딜,서폿'
    WHEN 4 THEN '탑,정글,미드'
    ELSE '상관없음'
  END,

  -- MEMBER_COUNTS = [2,3,4,5]
  2 + (i % 4),

  -- 전부 RECRUITING 이어야 한다. CLOSED 글에 신청하면 400 이 나고,
  -- 시나리오 4 는 시딩 글 중에서 무작위로 고르기 때문이다.
  'RECRUITING',

  -- i 분씩 어긋나게 준다. GET /api/posts 가 findAllByOrderByCreatedAtDesc 로
  -- 정렬하므로 같은 시각이면 순서가 실행마다 달라져 회차 간 비교가 흔들린다.
  now() - (i || ' minutes')::interval

FROM generate_series(
  (SELECT count(*) + 1 FROM posts WHERE title LIKE '[SEED]%'),
  :target
) AS i;

COMMIT;
