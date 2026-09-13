#!/usr/bin/env bash
# ===========================================================================
# RabbitMQ 회차가 만든 글만 정리
#
# 공용 load-test/seed/reset.sh 를 쓰지 않는다. 그쪽은 전체를 초기화하므로
# 다른 팀의 시딩까지 날아간다. 여기서는 **이 회차가 만든 글만** 지운다.
#
# 판정 기준은 제목 접두사다(기본 "[RMQ-TEST]"). rabbit.js 가 그 접두사로
# 글을 만들고, 여기서 같은 접두사를 찾아 지운다.
#
#   ./seed/cleanup.sh --dry-run     # 지울 목록만 보여준다 (기본)
#   ./seed/cleanup.sh --delete      # 실제로 지운다
#
# ⚠️ 기본이 dry-run 이다. 삭제는 되돌릴 수 없으므로 --delete 를 명시해야만
#    지운다.
#
# ⚠️ 글 삭제는 작성자만 할 수 있다. 그래서 seed/data/tokens.json 의 토큰으로
#    지운다. 다른 계정이 만든 글은 접두사가 같아도 403 이 나고 건너뛴다.
# ===========================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
RESULT_DIR="${RESULT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/results}"

MODE="dry-run"
case "${1:-}" in
  --delete)  MODE="delete" ;;
  --dry-run|"") MODE="dry-run" ;;
  *) echo "Usage: $0 [--dry-run|--delete]" >&2; exit 2 ;;
esac

for c in curl jq; do
  command -v "$c" >/dev/null || { echo "$c 가 필요하다" >&2; exit 2; }
done

[ -f "$DATA_DIR/meta.json" ] || {
  echo "중단: $DATA_DIR/meta.json 이 없다. ./seed/prepare.sh 를 먼저 실행한다." >&2
  exit 2
}
[ -f "$DATA_DIR/tokens.json" ] || {
  echo "중단: $DATA_DIR/tokens.json 이 없다." >&2
  exit 2
}

BASE_URL="${BASE_URL:-$(jq -r '.baseUrl' "$DATA_DIR/meta.json")}"
TITLE_PREFIX="${RMQ_TITLE_PREFIX:-$(jq -r '.titlePrefix' "$DATA_DIR/meta.json")}"
ROUND_ID="$(jq -r '.roundId' "$DATA_DIR/meta.json")"

case "$BASE_URL" in
  http://gamehouse.local|http://gamehouse.local:*|http://localhost:*|http://127.0.0.1:*) ;;
  *)
    # 로컬이 아니면 기본은 중단이다. 운영(EKS)은 두 겹을 **모두** 만족해야 통과한다.
    #   ① ALLOW_EKS_CLEANUP=1        — 의도했다는 표시
    #   ② EKS_BASE_URL 과 일치    — 어느 운영인지 한 번 더 적게 한다
    # 환경변수 하나를 잘못 넣어 운영에 쏘는 일을 막기 위해 일부러 중복시킨다.
    if [[ "${ALLOW_EKS_CLEANUP:-0}" == "1" && -n "${EKS_BASE_URL:-}" \
          && "$BASE_URL" == "$EKS_BASE_URL" ]]; then
      echo "⚠️ 운영 환경이다: $BASE_URL" >&2
    else
      echo "중단: BASE_URL 이 로컬이 아니다 ($BASE_URL)" >&2
      echo "  운영에서 쓰려면 두 가지를 모두 준다:" >&2
      echo "    ALLOW_EKS_CLEANUP=1 EKS_BASE_URL=$BASE_URL BASE_URL=$BASE_URL $0" >&2
      exit 2
    fi
    ;;
esac

http() { curl -s --max-time 30 "$@" || true; }

first_token="$(jq -r '.[0].token' "$DATA_DIR/tokens.json")"
[ -n "$first_token" ] && [ "$first_token" != "null" ] || {
  echo "중단: 토큰을 읽지 못했다." >&2; exit 2; }

echo "대상        : $BASE_URL"
echo "회차 ID     : $ROUND_ID"
echo "제목 접두사 : $TITLE_PREFIX"
echo "모드        : $MODE"
echo

# --- 1. 접두사가 붙은 글을 모은다 -----------------------------------------
# 서버가 page size 를 100 으로 제한하므로 페이지를 넘겨 가며 읽는다.
ids='[]'
page=0
while [ "$page" -lt 50 ]; do
  body=$(http "$BASE_URL/api/posts?page=${page}&size=100" \
    -H "Authorization: Bearer $first_token")
  items=$(jq -c 'if type=="object" then (.content // .items // []) else . end' \
    <<<"$body" 2>/dev/null || echo '[]')
  n=$(jq 'length' <<<"$items" 2>/dev/null || echo 0)
  [ "$n" -eq 0 ] && break

  hit=$(jq -c --arg p "$TITLE_PREFIX" \
    '[ .[] | select((.title // "") | startswith($p)) | .id ]' <<<"$items")
  ids=$(jq -c -n --argjson a "$ids" --argjson b "$hit" '($a + $b) | unique')

  [ "$n" -lt 100 ] && break
  page=$((page + 1))
done

total=$(jq 'length' <<<"$ids")
echo "찾은 글     : ${total}건"

if [ "$total" -eq 0 ]; then
  echo "지울 것이 없다."
  exit 0
fi

# 기록으로 남긴다. 회차 결과와 대조할 때 쓴다.
mkdir -p "$DATA_DIR"
jq -n --arg roundId "$ROUND_ID" \
      --arg collectedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --argjson postIds "$ids" \
      '{roundId:$roundId, collectedAt:$collectedAt, postIds:$postIds}' \
  > "$DATA_DIR/created-posts.json"
echo "목록 저장   : $DATA_DIR/created-posts.json"

if [ "$MODE" = "dry-run" ]; then
  echo
  echo "dry-run 이라 지우지 않았다. 실제로 지우려면:"
  echo "  $0 --delete"
  exit 0
fi

# --- 2. 삭제 --------------------------------------------------------------
# 작성자만 지울 수 있으므로 토큰을 돌아가며 시도한다.
# mapfile 은 bash 4+ 전용이다. macOS 기본 bash 는 3.2 라 쓸 수 없다.
TOKENS=()
while IFS= read -r line; do
  [ -n "$line" ] && TOKENS+=("$line")
done < <(jq -r '.[].token' "$DATA_DIR/tokens.json")

[ "${#TOKENS[@]}" -gt 0 ] || { echo "중단: 토큰이 없다." >&2; exit 2; }
deleted=0; skipped=0

for id in $(jq -r '.[]' <<<"$ids"); do
  ok=0
  for t in "${TOKENS[@]}"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
      -X DELETE "$BASE_URL/api/posts/${id}" \
      -H "Authorization: Bearer $t" || echo "000")
    case "$code" in
      200|204) ok=1; break ;;
      403|401) continue ;;      # 다른 계정의 글 — 다음 토큰으로
      404)     ok=1; break ;;   # 이미 없다
      *)       continue ;;
    esac
  done
  if [ "$ok" -eq 1 ]; then deleted=$((deleted + 1)); else skipped=$((skipped + 1)); fi
done

echo
echo "삭제        : ${deleted}건"
echo "건너뜀      : ${skipped}건 (다른 계정이 만든 글이거나 실패)"

mkdir -p "$RESULT_DIR"
printf '%s\tcleanup deleted=%s skipped=%s round=%s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$deleted" "$skipped" "$ROUND_ID" \
  >> "$RESULT_DIR/cleanup.log"
