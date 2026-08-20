#!/usr/bin/env bash
# ===========================================================================
# 회차 D 전용 — [SEED] 글을 목표 건수까지 늘린다.
#
#   ./load-test/seed/grow.sh 1000
#
# generate.sh 와 달리 아무것도 지우지 않는다. 이미 있는 [SEED] 글 다음
# 번호부터 목표까지 채우기만 한다. 계정·신청·토큰은 그대로 둔다.
#
# ⚠️ meta.json 의 posts 를 함께 갱신한다.
#    회차 D 는 "게시글 몇 건일 때인가"가 결과의 전부다. run.sh 가 meta.json 을
#    manifest.json 에 복사하는데, 여기서 갱신하지 않으면 10,000건 구간의
#    결과에 "posts: 300" 이 적힌다. 나중에 그 파일만 보면 어느 구간인지
#    알 수 없게 되고, 회차 D 전체가 무의미해진다.
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"
DATA_DIR="${SCRIPT_DIR}/data"
META="${DATA_DIR}/meta.json"

# shellcheck source=../db.sh
source "${SCRIPT_DIR}/../db.sh"
lt_guard_target

command -v jq >/dev/null 2>&1 || { echo "jq 가 없다." >&2; exit 1; }

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  cat >&2 <<EOF
사용법: ./load-test/seed/grow.sh <목표 건수>

  준비된 증분: $(ls "${SQL_DIR}"/d-growth-*.sql | sed 's/.*d-growth-//;s/\.sql//' | sort -n | tr '\n' ' ')

회차 D 진행:
  ./load-test/seed/generate.sh          # 300건에서 시작
  ./load-test/run.sh round-d
  ./load-test/seed/grow.sh 1000
  ./load-test/run.sh round-d
  ./load-test/seed/grow.sh 3000
  ./load-test/run.sh round-d
  ./load-test/seed/grow.sh 10000
  ./load-test/run.sh round-d
EOF
  exit 1
fi

SQL="${SQL_DIR}/d-growth-${TARGET}.sql"
if [[ ! -f "${SQL}" ]]; then
  echo "증분 파일이 없다: ${SQL}" >&2
  echo "  준비된 값: $(ls "${SQL_DIR}"/d-growth-*.sql | sed 's/.*d-growth-//;s/\.sql//' | sort -n | tr '\n' ' ')" >&2
  exit 1
fi

if [[ ! -f "${META}" ]]; then
  echo "시딩이 없다: ${META}" >&2
  echo "  ./load-test/seed/generate.sh 를 먼저 돌린다. grow.sh 는 채우기만 한다." >&2
  exit 1
fi

BEFORE=$(psql_exec -c "SELECT count(*) FROM posts WHERE title LIKE '[SEED]%';")

if [[ "${BEFORE}" -ge "${TARGET}" ]]; then
  echo "이미 ${BEFORE}건이다 (목표 ${TARGET}). 줄이려면 generate.sh 로 되돌린다." >&2
  exit 1
fi

echo "대상: $(lt_db_label)"
echo "게시글 ${BEFORE} → ${TARGET} 건"

# \ir 은 SQL 파일 위치 기준으로 _post-rows.sql 을 찾는다. -f 로 넘기면 된다.
psql_exec -f "${SQL}" >/dev/null

AFTER=$(psql_exec -c "SELECT count(*) FROM posts WHERE title LIKE '[SEED]%';")
if [[ "${AFTER}" -ne "${TARGET}" ]]; then
  echo "실제 ${AFTER}건 ≠ 목표 ${TARGET}. SQL 을 확인할 것." >&2
  exit 1
fi

# meta.json 갱신 — manifest.json 이 어느 구간인지 말할 수 있어야 한다.
TMP=$(mktemp)
jq --argjson posts "${AFTER}" \
   --arg grownAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.posts = $posts | .grownAt = $grownAt' "${META}" > "${TMP}"
mv "${TMP}" "${META}"

echo "완료 — ${AFTER}건. meta.json 갱신됨"
echo ""
echo "⚠️ post-ids.json 은 갱신하지 않는다. 회차 D 는 시나리오 1(목록) 단독이라"
echo "   개별 글 ID 를 쓰지 않는다. 다른 회차를 돌리려면 generate.sh 로 되돌린다."
