#!/usr/bin/env bash
# ===========================================================================
# 회차 실행 래퍼.
#
#   ./load-test/run.sh smoke
#   ./load-test/run.sh round-a
#   ./load-test/run.sh round-b --raw      # 원시 데이터까지 (수백 MB)
#
# k6 를 직접 불러도 돌아간다. 이 래퍼가 추가로 하는 일은 네 가지다.
#
#   1. testid 를 만들어 결과 디렉토리 이름과 k6 태그에 '같은 값'으로 넣는다.
#      대시보드에서 $testid 로 고른 그래프와 results/ 의 폴더가 이어져야
#      나중에 "이 그래프가 어느 파일인가"를 찾을 수 있다.
#   2. 시딩 상태를 회차 시작 전에 확인한다. k6 의 setup() 도 확인하지만,
#      그건 이미 k6 가 뜬 뒤라 러너 EC2 가동 시간이 소모된 다음이다.
#   3. exit code 를 기록한다. 회차 A 는 abortOnFail 을 쓰지 않으므로 threshold
#      를 어겨도 끝까지 돈다. 99 를 안 잡으면 '완주했지만 기준은 벗어났다'가
#      결과에 안 남는다.
#   4. manifest.json 에 시딩 meta 사본과 실행 조건을 남긴다. 회차 D 는
#      "게시글 몇 건일 때인가"가 결과의 전부라, 이게 없으면 파일이 무의미하다.
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_DIR="${SCRIPT_DIR}/k6"
RESULTS_ROOT="${SCRIPT_DIR}/results"

# ---------------------------------------------------------------------------
# 회차 이름 → 스크립트 경로
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
사용법: ./run.sh <회차> [--raw] [-- k6 에 그대로 넘길 인자...]

  smoke      경로 검증. 성능 측정 아님
  round-a    Load    — 유일한 판정 근거
  round-b    Stress  — Break Point 탐색
  round-c    Spike   — 순간 폭증
  round-d    Data Growth — 페이징 시점 + OOM 시점

  --raw      요청 단위 원시 데이터도 남긴다 (raw.json.gz)
             회차 A 기준 압축 전 400MB 대. 회차 B·C 를 파고들 때만 쓴다.

예)
  ./run.sh smoke
  SCALE=smoke ./run.sh smoke
  ./run.sh round-a
  ./run.sh round-d --raw
  ./run.sh round-a -- --http-debug=full
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
ROUND="$1"; shift

case "${ROUND}" in
  smoke)   SCRIPT="rounds/smoke.js" ;;
  round-a) SCRIPT="rounds/round-a-load.js" ;;
  round-b) SCRIPT="rounds/round-b-stress.js" ;;
  round-c) SCRIPT="rounds/round-c-spike.js" ;;
  round-d) SCRIPT="rounds/round-d-data-growth.js" ;;
  -h|--help) usage ;;
  *) echo "모르는 회차: ${ROUND}" >&2; usage ;;
esac

RAW=0
K6_EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) RAW=1; shift ;;
    --) shift; K6_EXTRA=("$@"); break ;;
    *) echo "모르는 인자: $1" >&2; usage ;;
  esac
done

command -v k6 >/dev/null 2>&1 || { echo "k6 가 없다. brew install k6" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq 가 없다." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 시딩 확인 — 회차를 띄우기 전에 멈춘다.
#
# k6 의 assertSeed() 와 중복이지만 위치가 다르다. 여기서 막으면 러너가 아직
# 아무것도 안 한 상태이고, 거기서 막히면 이미 VU 를 할당한 뒤다.
# ---------------------------------------------------------------------------
SEED_DIR="${SEED_DATA_DIR:-${SCRIPT_DIR}/seed/data}"
META="${SEED_DIR}/meta.json"

if [[ ! -f "${META}" ]]; then
  echo "시딩이 없다: ${META}" >&2
  echo "  ./load-test/seed/generate.sh 를 먼저 돌린다." >&2
  exit 1
fi

SCALE_SUFFIX="${SCALE:+.${SCALE}}"
SCALE_FILE="${SCRIPT_DIR}/scale${SCALE_SUFFIX}.json"
[[ -f "${SCALE_FILE}" ]] || { echo "규모 파일이 없다: ${SCALE_FILE}" >&2; exit 1; }

WANT_PROFILE=$(jq -r '.profile' "${SCALE_FILE}")
HAVE_PROFILE=$(jq -r '.profile' "${META}")
if [[ "${WANT_PROFILE}" != "${HAVE_PROFILE}" ]]; then
  # 안내는 그대로 복붙할 수 있어야 한다. SCALE 이 비어 있을 때 'SCALE=<none>'
  # 같은 문자열을 찍으면 읽는 사람이 무엇을 입력해야 할지 모른다.
  SEED_HINT="./load-test/seed/generate.sh"
  [[ -n "${SCALE:-}" ]] && SEED_HINT="SCALE=${SCALE} ${SEED_HINT}"

  {
    echo "시딩 프로파일이 다르다: 지금 데이터='${HAVE_PROFILE}' / 이 회차가 기대='${WANT_PROFILE}'"
    echo ""
    echo "  '${WANT_PROFILE}' 규모로 다시 시딩한다 (backend 가 떠 있어야 한다):"
    echo "      ${SEED_HINT}"
    echo ""
    echo "  스모크 데이터로 회차를 돌리지 않는다 — 계정이 부족하면 여러 VU 가 같은"
    echo "  계정을 잡아 500 이 나고, 서버 결함과 구분되지 않는다."
  } >&2
  exit 1
fi

# 토큰 신선도. JWT 기본 만료가 24시간이라 그 전에 발급된 것이면 회차 중에
# 전부 401 이 된다. 4xx 는 실패로 세지 않으므로 회차는 끝까지 정상으로 돌고
# 결과만 무의미해진다 — 가장 알아채기 어려운 실패 방식이라 먼저 막는다.
GENERATED_AT=$(jq -r '.generatedAt' "${META}")
if command -v python3 >/dev/null 2>&1; then
  AGE_H=$(python3 -c "
import datetime,sys
t=datetime.datetime.strptime('${GENERATED_AT}','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()//3600))
" 2>/dev/null || echo 0)
  if [[ "${AGE_H}" -ge 20 ]]; then
    echo "⚠ 시딩이 ${AGE_H}시간 전이다. JWT 만료(24h)가 가깝다." >&2
    echo "  generate.sh 를 다시 돌리는 것을 권한다. 계속하려면 Enter, 중단은 Ctrl-C." >&2
    read -r
  fi
fi

# ---------------------------------------------------------------------------
# testid — 디렉토리 이름이자 k6 태그. 둘이 같아야 그래프와 파일이 이어진다.
# ---------------------------------------------------------------------------
TESTID="${TESTID:-$(date +%Y%m%d-%H%M%S)-${ROUND}}"
RESULT_DIR="${RESULTS_ROOT}/${TESTID}"
mkdir -p "${RESULT_DIR}"

BASE_URL="${BASE_URL:-http://localhost:8080}"

# 로컬이면 요약 하단에 경고를 붙인다. 로컬 수치가 보고서로 새는 것을 막는다.
LOCAL=0
case "${BASE_URL}" in
  *localhost*|*127.0.0.1*) LOCAL=1 ;;
esac

echo "회차   ${ROUND}   (${SCRIPT})"
echo "testid ${TESTID}"
echo "대상   ${BASE_URL}"
echo "규모   ${HAVE_PROFILE}  계정 $(jq -r '.accounts' "${META}") · 게시글 $(jq -r '.posts' "${META}")"
echo "결과   ${RESULT_DIR}"
[[ "${LOCAL}" -eq 1 ]] && echo "⚠ 로컬 — 성능 판정에 쓰지 않는다"
echo ""

# ---------------------------------------------------------------------------
# 실행
#
# --summary-trend-stats: p(99) 는 k6 기본 요약에 없다. threshold 판정은
#   되지만 summary.txt 의 p99 칸이 비어 보인다.
# --tag testid: remote write 로 나가는 모든 시계열에 붙는다. 대시보드의
#   $testid 변수가 이 값을 고른다.
# ---------------------------------------------------------------------------
K6_ARGS=(
  run
  --summary-trend-stats "avg,min,med,p(95),p(99),max"
  --tag "testid=${TESTID}"
  --tag "round=${ROUND}"
)

if [[ "${RAW}" -eq 1 ]]; then
  # .gz 로 끝나면 k6 가 압축해서 쓴다. 회차 A 는 압축 전 400MB 대라
  # 확장자를 빠뜨리면 디스크가 먼저 찬다.
  K6_ARGS+=(--out "json=${RESULT_DIR}/raw.json.gz")
  echo "원시 데이터도 남긴다 → raw.json.gz"
fi

[[ ${#K6_EXTRA[@]} -gt 0 ]] && K6_ARGS+=("${K6_EXTRA[@]}")

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_EPOCH=$(date +%s)

# set -e 를 잠깐 끈다. threshold 위반은 exit 99 인데, 그건 '실패한 실행'이
# 아니라 '기록해야 할 결과'다. 여기서 죽으면 manifest 를 못 남긴다.
set +e
RESULT_DIR="${RESULT_DIR}" TESTID="${TESTID}" ROUND="${ROUND}" \
BASE_URL="${BASE_URL}" LOCAL="${LOCAL}" SEED_DATA_DIR="${SEED_DIR}" \
  k6 "${K6_ARGS[@]}" "${K6_DIR}/${SCRIPT}"
EXIT_CODE=$?
set -e

FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ELAPSED=$(( $(date +%s) - START_EPOCH ))

# 연결 오류가 있었으면 '대상이 죽은 것' 이고, threshold 위반과 성격이 다르다.
# summary.json 을 되읽어 구분한다.
CONN_ERRORS=0
if [[ -f "${RESULT_DIR}/summary.json" ]]; then
  CONN_ERRORS=$(jq -r '.metrics.lt_conn_errors.values.count // 0' "${RESULT_DIR}/summary.json")
fi

case "${EXIT_CODE}" in
  0)  VERDICT="threshold 전부 통과" ;;
  99)
    if [[ "${CONN_ERRORS%.*}" -gt 0 ]]; then
      CONN_AT=$(jq -r '.metrics.lt_conn_error_at.values.min // 0 | floor' "${RESULT_DIR}/summary.json" 2>/dev/null || echo 0)
      VERDICT="대상에 연결되지 않아 중단 — 회차 시작 ${CONN_AT}초 지점. 이 회차는 폐기한다"
    else
      VERDICT="threshold 위반 (회차는 완주). summary.txt 의 위반 목록을 볼 것"
    fi
    ;;
  *)  VERDICT="실행 오류 — 결과를 쓰지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# manifest.json — 이 회차가 '무엇이었는지'를 파일 하나로 설명한다.
# ---------------------------------------------------------------------------
GIT_COMMIT=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")

jq -n \
  --arg testid "${TESTID}" \
  --arg round "${ROUND}" \
  --arg script "${SCRIPT}" \
  --arg startedAt "${STARTED_AT}" \
  --arg finishedAt "${FINISHED_AT}" \
  --argjson elapsedSec "${ELAPSED}" \
  --argjson exitCode "${EXIT_CODE}" \
  --arg verdict "${VERDICT}" \
  --argjson connErrors "${CONN_ERRORS%.*}" \
  --arg baseUrl "${BASE_URL}" \
  --argjson local "${LOCAL}" \
  --argjson raw "${RAW}" \
  --arg scaleFile "$(basename "${SCALE_FILE}")" \
  --arg gitCommit "${GIT_COMMIT}" \
  --arg k6Version "$(k6 version 2>/dev/null | head -1)" \
  --arg host "$(uname -srm)" \
  --slurpfile seed "${META}" \
  '{
     testid: $testid, round: $round, script: $script,
     startedAt: $startedAt, finishedAt: $finishedAt, elapsedSec: $elapsedSec,
     exitCode: $exitCode, verdict: $verdict, connErrors: $connErrors,
     target: { baseUrl: $baseUrl, local: ($local == 1) },
     seed: $seed[0], scaleFile: $scaleFile,
     raw: ($raw == 1),
     runner: { k6: $k6Version, host: $host, gitCommit: $gitCommit }
   }' > "${RESULT_DIR}/manifest.json"

echo ""
echo "exit ${EXIT_CODE} — ${VERDICT}"
echo "결과 ${RESULT_DIR}"
ls -1 "${RESULT_DIR}"

# 회차 A 는 완주가 목적이므로 99 를 실패로 전파하지 않는다. CI 에 물릴 때는
# manifest.json 의 exitCode 를 읽어 판단한다.
exit 0
