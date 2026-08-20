#!/usr/bin/env bash
# ===========================================================================
# PostDto 실제 응답 크기 측정.
#
# 설계 문서는 PostDto 를 약 600B 로 잡고 거기서 대역폭과 AWS 송신 비용을
# 추정했다. 그 숫자가 맞는지 재는 것이 이 스크립트다. 회차 전에 한 번만
# 돌리면 되고, 결과가 다르면 비용 추정을 갱신한다.
#
# 왜 중요한가
#   GET /api/posts 에는 페이징이 없다. 목록 응답 = PostDto × 전체 글 수 다.
#   글 1건당 크기가 2 배면 54 RPS 구간의 송신량도 2 배가 된다. AWS 는
#   송신량이 곧 요금이므로, 이 값이 틀리면 비용 추정 전체가 틀린다.
#
# 실행 전제: 시딩이 끝나 있어야 한다(seed/generate.sh).
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-http://localhost:8080}"
DATA_DIR="${DATA_DIR:-${SCRIPT_DIR}/../seed/data}"

command -v jq >/dev/null || { echo "jq 가 필요하다" >&2; exit 1; }

# ⚠️ 이 확인을 먼저 한다.
#    set -e 가 걸려 있어서, backend 가 없으면 아래 curl 이 exit 7 로 죽고
#    스크립트가 아무 메시지 없이 끝난다. 실패는 조용하면 안 된다.
if ! curl -sf -o /dev/null --max-time 5 "${BASE_URL}/api/posts" \
     && ! curl -s -o /dev/null --max-time 5 "${BASE_URL}/api/posts"; then
  cat >&2 <<EOF
backend 에 연결할 수 없다: ${BASE_URL}

  docker compose --env-file .env.local \\
    -f docker-compose.yml -f docker-compose.local.yml up -d backend
EOF
  exit 1
fi

[[ -f "${DATA_DIR}/tokens.json" ]] || {
  echo "토큰이 없다: ${DATA_DIR}/tokens.json — seed/generate.sh 를 먼저 돌린다" >&2
  exit 1
}

TOKEN=$(jq -r '.[0].token' "${DATA_DIR}/tokens.json")
AUTH=(-H "Authorization: Bearer ${TOKEN}")

echo "대상: ${BASE_URL}"
echo ""

# ---------------------------------------------------------------------------
# 1. 목록 — 한 페이지의 바이트와 건당 평균
#
# Content-Length 가 아니라 실제 수신 바이트를 센다. 압축이 켜져 있으면
# 둘이 다르고, 대역폭에 잡히는 것은 압축된 쪽이다.
#
# ⚠️ 응답이 배열이 아니라 { items, page, size, totalElements, hasNext } 다.
#    jq 의 length 를 그대로 쓰면 '키 개수 5' 가 나와서 건당 평균이 4배로
#    뻥튀기된다. 에러는 안 나므로 숫자만 보면 알아채기 어렵다.
# ---------------------------------------------------------------------------
LIST_BODY=$(mktemp)
LIST_BYTES=$(curl -s "${AUTH[@]}" -o "${LIST_BODY}" -w '%{size_download}' "${BASE_URL}/api/posts")
LIST_COUNT=$(jq '.items | length' "${LIST_BODY}" 2>/dev/null || echo 0)
TOTAL_COUNT=$(jq -r '.totalElements // "-"' "${LIST_BODY}" 2>/dev/null || echo "-")
ENCODING=$(curl -s -I "${AUTH[@]}" "${BASE_URL}/api/posts" | grep -i '^content-encoding' || echo "  (압축 없음)")

echo "GET /api/posts   (파라미터 없음 = 첫 페이지)"
echo "  응답 크기   : ${LIST_BYTES} B"
echo "  한 페이지   : ${LIST_COUNT} 건   ← 부하 회차가 실제로 받는 양"
echo "  전체 글 수  : ${TOTAL_COUNT} 건   ← totalElements. 응답 크기와 무관하다"
if [[ "${LIST_COUNT}" -gt 0 ]]; then
  echo "  건당 평균   : $(( LIST_BYTES / LIST_COUNT )) B   ← 문서 가정 600B 와 비교"
fi
echo "  압축        : ${ENCODING}"
echo ""

# ---------------------------------------------------------------------------
# 2. 상세 — PostDto 1 건의 순수 크기
#
# 목록의 건당 평균에는 JSON 배열의 구분자와 대괄호가 섞인다. 상세 응답이
# PostDto 한 건의 실제 크기다.
# ---------------------------------------------------------------------------
FIRST_ID=$(jq -r '.[0]' "${DATA_DIR}/post-ids.json")
DETAIL_BYTES=$(curl -s "${AUTH[@]}" -o /dev/null -w '%{size_download}' "${BASE_URL}/api/posts/${FIRST_ID}")

echo "GET /api/posts/${FIRST_ID}"
echo "  PostDto 1건 : ${DETAIL_BYTES} B"
echo ""

# ---------------------------------------------------------------------------
# 3. Peak 구간 송신량 추정
#
# 시나리오 1 = 54 RPS(Peak).
#
# ⚠️ 페이징이 들어가기 전에는 목록이 통째로 나가서 이 시나리오 하나가 전체
#    송신량을 지배했고, 글이 늘면 송신량도 그대로 늘었다. 지금은 한 페이지
#    고정이라 그 비례가 끊겼다 — 글이 10,000건이 되어도 아래 값은 그대로다.
#    회차 D 의 관전 포인트가 '얼마나 커지나' 에서 '정말 고정인가' 로 바뀐 것도
#    같은 이유다.
# ---------------------------------------------------------------------------
S1_RPS=54
BPS=$(( LIST_BYTES * S1_RPS ))
echo "Peak 추정 (시나리오 1 = ${S1_RPS} RPS, 한 페이지 ${LIST_COUNT}건 기준)"
echo "  송신 대역폭 : $(( BPS / 1024 / 1024 )) MB/s  ($(( BPS * 8 / 1000000 )) Mbps)"
echo "  15분 회차   : $(( BPS * 900 / 1024 / 1024 / 1024 )) GB"
echo ""
echo "⚠️ 이 값은 전체 글 수(${TOTAL_COUNT}건)와 무관하다. 페이지 크기만 따라간다."
echo "   회차 D 에서 글을 10,000건까지 늘려도 응답 크기가 그대로여야 정상이고,"
echo "   커진다면 페이징이 안 걸린 경로가 남아 있다는 뜻이다."

rm -f "${LIST_BODY}"
