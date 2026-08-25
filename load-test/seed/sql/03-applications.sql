-- ===========================================================================
-- 참가 신청 시딩 — :applications 건.
--
-- 왜 필요한가: PostDto.pendingCount 가 0 인 상태로만 테스트하면, 목록/상세
-- 조회가 실제보다 가벼워진다. 신청이 붙어 있어야 조회 경로의 부하가 현실적이다.
--
-- ⚠️ applications 에는 UNIQUE(post_id, applicant_id) 가 걸려 있다.
--    같은 쌍을 두 번 넣으면 시딩 자체가 실패한다. 그래서 쌍을 무작위로
--    만들지 않고 결정론적으로 계산한다.
--
--      n         = 0 .. (:applications - 1)
--      post 순번 = n % :posts
--      user 순번 = ((n % :posts) * 2 + n / :posts) % :accounts
--
--    같은 글에 걸리는 n 은 :posts 간격이므로 n / :posts 값이 매번 다르고,
--    따라서 user 순번도 매번 다르다 → 중복 쌍이 나올 수 없다.
--    (전제: 글당 신청 수 = ceil(:applications / :posts) 가 :accounts 이하)
--
-- status 는 전부 PENDING 이다.
-- ⚠️ ApplicationService.PENDING_TTL = 1시간. 시딩 후 1시간이 지나면 PENDING
--    신청이 만료 처리되어 /api/my/applications 응답이 비고 pendingCount 가
--    달라진다. 시딩과 회차 사이를 1시간 안에 둔다.
-- ===========================================================================

BEGIN;

INSERT INTO applications (post_id, applicant_id, status, created_at)
SELECT p.id, u.id, 'PENDING', now()
FROM generate_series(0, :applications - 1) AS n
JOIN (
  SELECT id, (row_number() OVER (ORDER BY id) - 1) AS rn
    FROM posts WHERE title LIKE '[SEED]%'
) p ON p.rn = n % :posts
JOIN (
  SELECT id, (row_number() OVER (ORDER BY id) - 1) AS rn
    FROM users WHERE email LIKE 'lt%@test.local'
) u ON u.rn = ((n % :posts) * 2 + n / :posts) % :accounts;

COMMIT;
