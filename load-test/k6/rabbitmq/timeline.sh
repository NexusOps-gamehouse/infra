#!/usr/bin/env bash
# ===========================================================================
# 시각 기록 — 공동 파일
#
# 회차가 끝난 뒤 남는 가장 중요한 증거는 "언제 무엇을 했는가" 다. 시각만
# 정확하면 k6 결과든 Grafana 든 kubectl 이벤트든 나중에 그 구간을 다시
# 꺼내 볼 수 있다. 반대로 시각이 어긋나면 나머지 증거가 전부 쓸모없어진다.
#
# 그래서 시간 형식과 결과 경로 두 가지를 여기서 고정한다. 두 사람이 쓰는
# 스크립트가 서로 다른 형식·경로를 쓰면 대조가 안 되기 때문이다.
#
#   ./timeline.sh "rabbitmq-kill"
#   ./timeline.sh -t INJECT "rabbitmq-kill pod=rabbitmq-0"
#
# ---------------------------------------------------------------------------
# 1. 시간 형식 — UTC 와 로컬을 **둘 다** 적는다
# ---------------------------------------------------------------------------
#
#   2026-09-11T01:19:43Z<TAB>2026-09-11T10:19:43+09:00<TAB>INJECT<TAB>rabbitmq-kill
#
# 왜 둘 다 적나. 증거마다 쓰는 기준이 다르다.
#
#   kubectl get events   → UTC          2026-09-11T00:52:01Z
#   Grafana / Loki       → UTC 기준 질의
#   k6 --out json        → 로컬 + 오프셋 2026-09-11T10:17:37.360884+09:00
#
# 하나만 적어 두면 나중에 반드시 한쪽과 어긋난다. 실제로 이전 회차에서
# UTC 만 적었다가 k6 원본과 구간을 맞추지 못해 다시 계산해야 했다.
#
# 초 단위까지만 적는다. 밀리초는 사람이 손으로 치는 기록에서는 의미가 없고,
# k6 쪽 밀리초와 비교할 때는 어차피 앞 19자(초 단위)로 자른다.
#
# ⚠️ macOS 의 date 는 %z 를 +0900 으로 낸다. k6 는 +09:00 을 쓰므로 콜론을
#    넣어 맞춘다. 형식이 다르면 문자열 비교가 어긋난다.
#
# ---------------------------------------------------------------------------
# 2. 결과 경로 — **스크립트가 있는 곳의 results/**
# ---------------------------------------------------------------------------
#
# 실행 위치(CWD)를 기준으로 하면 run-load.sh 를 다른 폴더에서 부르는 순간
# 로그가 흩어진다. 그러면 timeline.log 가 두 군데에 생기고 어느 쪽이
# 이번 회차인지 알 수 없게 된다.
#
# RESULT_DIR 로 덮어쓸 수 있다. 회차마다 폴더를 나누고 싶을 때 쓴다.
#   RESULT_DIR=results/2026-09-11-round1 ./timeline.sh "..."
#
# run-load.sh 와 inject.sh 도 같은 기본값을 써야 한다(설계 문서 4-1절).
#   RESULT_DIR="${RESULT_DIR:-$(cd "$(dirname "$0")" && pwd)/results}"
# ===========================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${RESULT_DIR:-$SCRIPT_DIR/results}"
LOG="$RESULT_DIR/timeline.log"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./timeline.sh <message>
  ./timeline.sh -t <TAG> <message>

TAG 는 나중에 grep 으로 골라내기 위한 분류다. 쓰는 값을 맞춰 둔다.
  MARK     구간 표시 (기준선 시작, 회차 종료 등)
  INJECT   장애 주입
  RECOVER  장애 해제 · 복구 확인
  SNAPSHOT 큐 · 채팅방 수 등 수치 기록
  NOTE     그 밖의 메모
EOF
  exit 2
}

TAG=""
if [[ "${1:-}" == "-t" ]]; then
  # -t 만 주고 값을 빠뜨린 경우를 여기서 잡는다. shift 2 를 먼저 하면
  # 인자가 모자라 shift 가 실패하고, usage 없이 끝나 버린다.
  [[ $# -ge 3 ]] || usage
  TAG="$2"
  shift 2
fi

message="${*:-}"
if [[ -z "$message" ]]; then
  usage
fi

# 탭·줄바꿈이 섞이면 4열 TSV 가 깨진다. 한 줄로 눌러서 넣는다.
message="$(printf '%s' "$message" | tr '\t\n\r' '   ')"

mkdir -p "$RESULT_DIR"

# ⚠️ date 를 두 번 부르면 안 된다. 초 경계에 걸치면 UTC 와 로컬이 서로 다른
#    순간을 가리켜, 같은 사건인데 대조 기준이 1초 어긋난다.
#    epoch 을 한 번만 읽고 그 값으로 두 형식을 만든다.
epoch="$(date '+%s')"

# epoch 을 형식화하는 옵션이 BSD(macOS)와 GNU(리눅스)가 다르다.
#   BSD : date -r <epoch>
#   GNU : date -d @<epoch>
# 팀원 환경이 섞일 수 있으니 한 번 확인하고 고른다.
if date -r "$epoch" '+%s' >/dev/null 2>&1; then
  AT=(-r "$epoch")        # BSD (macOS)
else
  AT=(-d "@$epoch")       # GNU (리눅스)
fi

utc="$(date -u "${AT[@]}" '+%Y-%m-%dT%H:%M:%SZ')"
# macOS 는 +0900, k6 는 +09:00 → 콜론을 넣어 맞춘다
off="$(date "${AT[@]}" '+%z')"
local_ts="$(date "${AT[@]}" '+%Y-%m-%dT%H:%M:%S')${off:0:3}:${off:3:2}"

printf '%s\t%s\t%s\t%s\n' "$utc" "$local_ts" "${TAG:-NOTE}" "$message" \
  | tee -a "$LOG"
