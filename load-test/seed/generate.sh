#!/usr/bin/env bash
# ===========================================================================
# 계약 ① — 생산자 쪽(B).
#
# SQL 시딩을 돌리고, 그 결과를 A 가 읽을 JSON 네 개로 떨군다.
#
#   data/users.json      부하용 계정 (시딩 글 작성자는 제외)
#   data/post-ids.json   시딩 게시글 PK 만
#   data/tokens.json     계정별 JWT — 여기서 미리 발급한다
#   data/meta.json       실제 생성 건수. A 가 assertSeed() 로 대조한다
#
# ⚠️ 토큰을 k6 setup() 에서 발급하지 않는 이유
#    setup() 은 단일 VU 에서 순차 실행된다. BCrypt strength 10 이라 로그인
#    1회가 약 150ms 이고, 600개면 순차로 90초를 넘는다. 로컬은 Rosetta
#    에뮬레이션이라 훨씬 길어져 스모크를 돌릴 때마다 그만큼 기다리게 된다.
#    JWT_EXPIRATION_MS 기본값이 24시간이므로 미리 받아 두면 회차 내내 유효하다.
#
# 필요한 것: psql, curl, jq, htpasswd
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"
DATA_DIR="${SCRIPT_DIR}/data"

# ---------------------------------------------------------------------------
# 설정.
#
# ⚠️ infra/.env 를 source 하지 않는다. 그 파일의 DB_HOST 는 공용 dev RDS 를
#    가리키고, 이 스크립트는 00-reset.sql 로 테이블을 비운다. 접속 정보는
#    db.sh 가 LT_DB_* 만 보고 결정하며, 로컬이 아니면 확인을 요구한다.
# ---------------------------------------------------------------------------
# shellcheck source=../db.sh
source "${SCRIPT_DIR}/../db.sh"
lt_guard_target

BASE_URL="${BASE_URL:-http://localhost:8080}"
LT_PASSWORD="${LT_PASSWORD:-LoadTest!2026}"   # 부하용 계정 공통 비밀번호
LOGIN_CONCURRENCY="${LOGIN_CONCURRENCY:-4}"   # 토큰 발급 병렬도. BCrypt 는 CPU 바운드다

# 기대 규모. 숫자를 여기에 적지 않는다 — load-test/scale*.json 이 유일한 출처이고
# k6/lib/config.js 의 SEED 도 같은 파일을 읽는다. 한쪽만 고치는 사고를 막는다.
#
# 작게 돌릴 때는 값을 고치지 말고 프로파일을 바꾼다.
#   ./generate.sh              → scale.json        (계정 600 · 글 300 · 신청 1,000)
#   SCALE=smoke ./generate.sh  → scale.smoke.json  (5 · 10 · 30)
#
# ⚠️ 경로가 아니라 '이름'을 받는다.
#    상대경로를 받으면 bash 는 실행 위치(CWD) 기준으로 풀고 k6 의 open() 은
#    파일 위치 기준으로 풀어서, 같은 문자열이 양쪽에서 다른 파일을 가리킨다.
#    이름으로 받으면 어디서 실행하든 같은 파일이 된다.
SCALE_FILE="${SCALE_FILE:-${SCRIPT_DIR}/../scale${SCALE:+.${SCALE}}.json}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "필요한 명령이 없다: $1" >&2; exit 1; }
}
require curl
require jq

[[ -f "${SCALE_FILE}" ]] || { echo "규모 파일이 없다: ${SCALE_FILE}" >&2; exit 1; }
PROFILE=$(jq -r '.profile' "${SCALE_FILE}")
EXPECT_ACCOUNTS=$(jq -r '.accounts' "${SCALE_FILE}")
EXPECT_POSTS=$(jq -r '.posts' "${SCALE_FILE}")
EXPECT_APPLICATIONS=$(jq -r '.applications' "${SCALE_FILE}")
echo "규모: ${PROFILE} — 계정 ${EXPECT_ACCOUNTS} · 게시글 ${EXPECT_POSTS} · 신청 ${EXPECT_APPLICATIONS}"
echo "     (${SCALE_FILE})"
echo "대상: $(lt_db_label)"

# ---------------------------------------------------------------------------
# BCrypt 해시 — 600 계정이 같은 비밀번호를 쓰므로 한 번만 만든다.
#
# 계정마다 다른 해시를 만들 이유가 없다. salt 가 달라도 부하 특성은 같고,
# 시딩 시간만 600 배가 된다(BCrypt strength 10 = 약 150ms).
#
# 로그인 검증은 매번 해시를 새로 계산하므로, 해시를 공유해도 시나리오 8 의
# CPU 부하는 실사용과 동일하다.
# ---------------------------------------------------------------------------
require htpasswd
LT_PASSWORD_HASH="${LT_PASSWORD_HASH:-$(
  htpasswd -bnBC 10 "" "${LT_PASSWORD}" | tr -d ':\n'
)}"
# Spring Security 의 BCryptPasswordEncoder 는 $2a/$2b/$2y 를 모두 읽는다.
# htpasswd 는 $2y 로 만든다.

# SQL 이 규모와 해시를 알아야 한다. psql 변수로 넘긴다.
PSQL_VARS=(
  -v "accounts=${EXPECT_ACCOUNTS}"
  -v "posts=${EXPECT_POSTS}"
  -v "applications=${EXPECT_APPLICATIONS}"
  -v "pwhash=${LT_PASSWORD_HASH}"
)

# ---------------------------------------------------------------------------
# 1. 시딩
#
# 00-reset 을 먼저 돌린다. 회차 간 시딩 상태를 동일하게 복원하지 않으면
# 회차별 비교 자체가 불가능해진다.
# ---------------------------------------------------------------------------
echo "==> 1/4 시딩 (reset → users → posts → applications)"
for f in 00-reset.sql 01-users.sql 02-posts.sql 03-applications.sql; do
  echo "    - ${f}"
  psql_exec "${PSQL_VARS[@]}" -f "${SQL_DIR}/${f}" >/dev/null
done

mkdir -p "${DATA_DIR}"

# ---------------------------------------------------------------------------
# 2. users.json / post-ids.json
#
# 조회 조건이 곧 계약이다.
#   · users  : 부하용 계정만. 시딩 글 작성자 계정이 섞이면 "본인 글" 400 이 난다
#   · posts  : 시딩 300건만. 시나리오 5 가 런타임에 만든 [LT] 글은 제외한다
# ---------------------------------------------------------------------------
echo "==> 2/4 users.json / post-ids.json"

psql_exec -c "
  SELECT json_agg(json_build_object('id', id, 'email', email, 'password', '${LT_PASSWORD}')
                  ORDER BY id)
    FROM users
   WHERE email LIKE 'lt%@test.local';
" > "${DATA_DIR}/users.json"

psql_exec -c "
  SELECT COALESCE(json_agg(id ORDER BY id), '[]'::json)
    FROM posts
   WHERE title LIKE '[SEED]%';
" > "${DATA_DIR}/post-ids.json"

ACCOUNTS=$(jq 'length' "${DATA_DIR}/users.json")
POSTS=$(jq 'length' "${DATA_DIR}/post-ids.json")
APPLICATIONS=$(psql_exec -c "SELECT count(*) FROM applications;")

echo "    계정 ${ACCOUNTS} · 게시글 ${POSTS} · 신청 ${APPLICATIONS}"

# ---------------------------------------------------------------------------
# 3. tokens.json — 계정별 JWT 사전 발급
#
# 병렬로 돌리되 과하게 올리지 않는다. BCrypt 는 CPU 를 독점하므로 동시에
# 수십 개를 던지면 대상 서버가 그것만으로 포화된다.
# ---------------------------------------------------------------------------
echo "==> 3/4 tokens.json (${ACCOUNTS}개, 동시 ${LOGIN_CONCURRENCY})"

login_one() {
  local email="$1"
  local id="$2"
  local token
  # -s 만 쓴다. 병렬 실행이라 curl 자신의 에러 메시지가 서로 섞여 읽을 수
  # 없게 되므로, 실패는 토큰이 비었는지로 판정하고 한 줄로 직접 찍는다.
  token=$(curl -s -X POST "${BASE_URL}/api/auth/login" \
            -H 'Content-Type: application/json' \
            -d "{\"email\":\"${email}\",\"password\":\"${LT_PASSWORD}\"}" \
          | jq -r '.token // .accessToken // empty')

  if [[ -z "${token}" ]]; then
    echo "로그인 실패: ${email}" >&2
    return 1
  fi
  jq -nc --argjson userId "${id}" --arg token "${token}" \
     '{userId: $userId, token: $token}'
}
export -f login_one
export BASE_URL LT_PASSWORD

# ⚠️ xargs -I{} 를 쓰지 않는다.
#    macOS(BSD) xargs 는 -I 치환에서 탭을 공백으로 바꾼다. 그래서
#    "lt0001@test.local\t1" 이 한 덩어리가 되어 이메일이 "lt0001@test.local 1"
#    로 넘어가고, 전 계정이 400 으로 실패한다. GNU xargs 에서는 재현되지 않아
#    리눅스 러너에서만 통과하는 종류의 버그다.
#
#    -n 2 로 두 단어씩 끊어 bash 인자로 넘긴다. xargs 가 붙인 첫 인자는
#    bash -c 에서 $0 이 되므로 $0/$1 로 받는다. 이메일에 공백이 없어 안전하다.
jq -r '.[] | "\(.email) \(.id)"' "${DATA_DIR}/users.json" \
  | xargs -P "${LOGIN_CONCURRENCY}" -n 2 bash -c 'login_one "$0" "$1"' \
  | jq -s 'sort_by(.userId)' > "${DATA_DIR}/tokens.json"

TOKENS=$(jq 'length' "${DATA_DIR}/tokens.json")
if [[ "${TOKENS}" -ne "${ACCOUNTS}" ]]; then
  echo "토큰 ${TOKENS} ≠ 계정 ${ACCOUNTS}. 일부 로그인이 실패했다." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. meta.json — A 가 assertSeed() 로 대조하는 파일
#
# 여기서 기대값과 다르면 회차를 시작하기 전에 멈춘다. 어긋난 채로 돌면
# 15분을 다 쓰고 나서야 알게 되고, AWS 에서는 그게 곧 비용이다.
# ---------------------------------------------------------------------------
echo "==> 4/4 meta.json"

jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg baseUrl "${BASE_URL}" \
  --arg profile "${PROFILE}" \
  --argjson accounts "${ACCOUNTS}" \
  --argjson posts "${POSTS}" \
  --argjson applications "${APPLICATIONS}" \
  '{generatedAt: $generatedAt, baseUrl: $baseUrl, profile: $profile,
    accounts: $accounts, posts: $posts, applications: $applications}' \
  > "${DATA_DIR}/meta.json"

FAILED=0
[[ "${ACCOUNTS}"     -eq "${EXPECT_ACCOUNTS}"     ]] || { echo "계정 ${ACCOUNTS} ≠ 기대 ${EXPECT_ACCOUNTS}" >&2; FAILED=1; }
[[ "${POSTS}"        -eq "${EXPECT_POSTS}"        ]] || { echo "게시글 ${POSTS} ≠ 기대 ${EXPECT_POSTS}" >&2; FAILED=1; }
[[ "${APPLICATIONS}" -eq "${EXPECT_APPLICATIONS}" ]] || { echo "신청 ${APPLICATIONS} ≠ 기대 ${EXPECT_APPLICATIONS}" >&2; FAILED=1; }

if [[ "${FAILED}" -ne 0 ]]; then
  echo "" >&2
  echo "실제 시딩 결과가 ${SCALE_FILE} 과 다르다. 회차를 시작하지 말 것." >&2
  echo "(SQL 이 기대만큼 안 넣었다는 뜻이다. 규모를 바꾸려면 scale.json 을 고친다 —" >&2
  echo " k6 의 SEED 도 같은 파일을 읽으므로 양쪽이 함께 움직인다)" >&2
  exit 1
fi

echo ""
echo "완료 — ${DATA_DIR}"
jq -c . "${DATA_DIR}/meta.json"
