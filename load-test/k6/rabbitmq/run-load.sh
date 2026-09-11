#!/usr/bin/env bash
# ===========================================================================
# RabbitMQ 회차 부하 실행
#
#   ./run-load.sh              # smoke (5 req/s · 2분)
#   ./run-load.sh low
#   RATE=10 DURATION=5m ./run-load.sh smoke
#
# 어느 경로에서 불러도 같게 동작하도록 스크립트 자기 위치를 기준으로 삼는다
# (설계 4-1절). 예전 버전은 ./timeline.sh · rabbit.js 처럼 터미널 위치에
# 의존해서, 다른 폴더에서 부르면 timeline.log 가 두 군데 생겼다.
#
# 토큰은 인자로 받지 않는다. rabbit.js 가 seed/data/tokens.json 에서 전용
# JWT 를 직접 읽는다 — 회차마다 손으로 export 하면 언젠가 공용 토큰이
# 섞여 들어간다.
# ===========================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${RESULT_DIR:-$SCRIPT_DIR/results}"
DATA_DIR="$SCRIPT_DIR/seed/data"

STAGE="${1:-smoke}"

case "$STAGE" in
  smoke)  RATE="${RATE:-5}";   DURATION="${DURATION:-2m}" ;;
  low)    RATE="${RATE:-20}";  DURATION="${DURATION:-3m}" ;;
  medium) RATE="${RATE:-50}";  DURATION="${DURATION:-5m}" ;;
  high)   RATE="${RATE:-100}"; DURATION="${DURATION:-5m}" ;;
  burst)  RATE="${RATE:-200}"; DURATION="${DURATION:-1m}" ;;
  *)
    echo "Unknown stage: $STAGE" >&2
    echo "Allowed: smoke | low | medium | high | burst" >&2
    exit 2
    ;;
esac

command -v k6 >/dev/null || { echo "k6 가 필요하다: brew install k6" >&2; exit 2; }

# 시드가 없으면 회차 전체가 401 이 되어, 장애 때문에 실패한 것과 구분되지
# 않는다. 시작 전에 끊는다.
for f in tokens.json meta.json; do
  [ -f "$DATA_DIR/$f" ] || {
    echo "중단: $DATA_DIR/$f 가 없다." >&2
    echo "  ./seed/prepare.sh 를 먼저 실행한다." >&2
    exit 2
  }
done

BASE_URL="${BASE_URL:-$(jq -r '.baseUrl // "http://gamehouse.local"' "$DATA_DIR/meta.json")}"
ROUND_ID="$(jq -r '.roundId // "RMQ-UNKNOWN"' "$DATA_DIR/meta.json")"

mkdir -p "$RESULT_DIR"
ts="$(date '+%Y%m%d-%H%M%S')"
summary="$RESULT_DIR/${ts}-${STAGE}-summary.json"
raw="$RESULT_DIR/${ts}-${STAGE}-raw.json"

echo "회차 ID : $ROUND_ID"
echo "대상    : $BASE_URL"
echo "단계    : $STAGE  (${RATE} req/s · $DURATION)"
echo

"$SCRIPT_DIR/timeline.sh" -t MARK "load stage=$STAGE rate=${RATE}/s duration=$DURATION start"

# rabbit.js 의 open() 은 스크립트 파일 기준으로 상대경로를 푼다. k6 를 어느
# 위치에서 실행하든 seed/data 를 찾도록 절대경로로 넘긴다.
set +e
BASE_URL="$BASE_URL" \
RATE="$RATE" \
DURATION="$DURATION" \
RMQ_TOKENS_FILE="$DATA_DIR/tokens.json" \
RMQ_META_FILE="$DATA_DIR/meta.json" \
k6 run \
  --summary-export="$summary" \
  --out "json=$raw" \
  "$SCRIPT_DIR/rabbit.js"
rc=$?
set -e

"$SCRIPT_DIR/timeline.sh" -t MARK "load stage=$STAGE end rc=$rc summary=$(basename "$summary")"

echo
echo "요약    : $summary"
echo "원본    : $raw"
[ "$rc" -ne 0 ] && echo "⚠️ k6 종료 코드 $rc — threshold 미달이거나 실행 오류다." >&2
exit "$rc"
