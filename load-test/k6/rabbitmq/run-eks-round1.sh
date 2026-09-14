#!/usr/bin/env bash
# EKS RabbitMQ 1차: 5 RPS 유지 중 chat 전체 consumer 공백과 RabbitMQ 90초 중단.
# 실행 전: ALLOW_EKS_FAULT=1 EKS_CONTEXT=gamehouse-main BASE_URL=https://api.game-duo.com ./preflight.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${EKS_CONTEXT:?EKS_CONTEXT가 필요하다}"
NS="${NAMESPACE:-gamehouse}"
BASE_URL="${BASE_URL:?BASE_URL이 필요하다}"
[[ "${ALLOW_EKS_FAULT:-0}" == 1 ]] || { echo "ALLOW_EKS_FAULT=1 이 필요하다" >&2; exit 2; }
[[ "$CTX" == gamehouse-main ]] || { echo "대상 context가 다르다: $CTX" >&2; exit 2; }

ROUND_LABEL="${ROUND_LABEL:-EKS-R1}"
RUN_DIR="${RESULT_DIR:-$SCRIPT_DIR/results/${ROUND_LABEL}-$(date '+%Y%m%d-%H%M%S')}"
mkdir -p "$RUN_DIR"
K=(kubectl --context "$CTX" -n "$NS")
SEL='app.kubernetes.io/name=chat'
RABBIT_DOWN=0
LOAD_PID=""
QUEUE_PID=""

note() { RESULT_DIR="$RUN_DIR" "$SCRIPT_DIR/timeline.sh" -t "$1" "${@:2}"; }
nap() { sleep "$1" & wait $!; }
chat_replicas() { "${K[@]}" get deploy chat -o jsonpath='{.spec.replicas}'; }
chat_uids() { "${K[@]}" get pod -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | sort | tr '\n' ' '; }
chat_ready() { "${K[@]}" get pod -l "$SEL" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true || true; }
chat_consumers() { "${K[@]}" exec rabbitmq-0 -- rabbitmqctl list_queues name consumers 2>/dev/null | awk '$1=="gamehouse.events.gamehouse-chat"{print $2}'; }
chat_endpoints() { "${K[@]}" get endpoints chat -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' '; }
chat_queue_ready() { "${K[@]}" exec rabbitmq-0 -- rabbitmqctl list_queues name messages_ready 2>/dev/null | awk '$1=="gamehouse.events.gamehouse-chat"{print $2}'; }
chat_queue_unacked() { "${K[@]}" exec rabbitmq-0 -- rabbitmqctl list_queues name messages_unacknowledged 2>/dev/null | awk '$1=="gamehouse.events.gamehouse-chat"{print $2}'; }
CHAT_TOKEN="$(jq -r '.[0].token' "$SCRIPT_DIR/seed/data/tokens.json")"
chat_api_code() {
  # curl은 timeout 때도 -w로 000을 출력한다. || printf를 붙이면 000000이 되어
  # 판독이 흐려진다. 빈 출력만 000으로 정규화한다.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "$BASE_URL/api/chat/rooms" -H "Authorization: Bearer $CHAT_TOKEN" || true)"
  printf '%s' "${code:-000}"
}

cleanup() {
  if [[ "$RABBIT_DOWN" == 1 ]]; then
    echo "⚠️ 종료 중 RabbitMQ를 복구한다" >&2
    "${K[@]}" scale sts rabbitmq --replicas=1 || true
  fi
  # checkpoint 실패로 본문이 일찍 끝나도 k6만 고아로 남겨 부하를 계속 주지 않는다.
  if [[ -n "$LOAD_PID" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    echo "⚠️ 종료 중 k6 부하를 중지한다" >&2
    # run-load.sh가 k6의 부모다. 부모만 끊으면 자식 k6가 남을 수 있으므로 둘 다 중단한다.
    pkill -INT -P "$LOAD_PID" 2>/dev/null || true
    kill -INT "$LOAD_PID" 2>/dev/null || true
    wait "$LOAD_PID" 2>/dev/null || true
  fi
  [[ -n "$QUEUE_PID" ]] && kill "$QUEUE_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

wait_chat_stable() {
  local before="$1" t0="$2" now desired ready consumers endpoints queued unacked code consecutive=0
  # HTTP timeout도 한 번에 최대 10초라 반복 횟수만 60으로 제한하면 실제 대기 시간이
  # 300초를 크게 넘는다. 장애 주입 보류 판단은 반드시 벽시계 300초 안에 끝낸다.
  while (( $(date +%s) - t0 < 300 )); do
    now="$(chat_uids)"; desired="$(chat_replicas)"; ready="$(chat_ready)"
    consumers="$(chat_consumers)"; endpoints="$(chat_endpoints)"
    queued="$(chat_queue_ready)"; unacked="$(chat_queue_unacked)"; code="$(chat_api_code)"
    printf '%s +%ss desired=%s ready=%s endpoint=%s consumer=%s queue_ready=%s queue_unacked=%s api=%s\n' \
      "$(date '+%H:%M:%S')" "$(( $(date +%s)-t0 ))" "$desired" "$ready" \
      "${endpoints:-?}" "${consumers:-?}" "${queued:-?}" "${unacked:-?}" "$code" | tee -a "$RUN_DIR/chat-recovery.log"
    if [[ "$now" != "$before" && "$ready" -ge "$desired" && "${endpoints:-0}" -ge "$desired" \
       && "${consumers:-0}" -ge "$desired" && "${queued:-1}" -eq 0 && "${unacked:-1}" -eq 0 \
       && "$code" == 200 ]]; then
      consecutive=$((consecutive + 1))
      [[ "$consecutive" -ge 2 ]] && return 0
    else
      consecutive=0
    fi
    nap 5
  done
  echo "chat은 Pod/Endpoint/consumer/queue/API 조건을 300초 안에 동시에 만족하지 못했다" >&2
  return 1
}
checkpoint() {
  local name="$1"
  note SNAPSHOT "checkpoint=$name"
  if ! RESULT_DIR="$RUN_DIR" ALLOW_EKS_FAULT=1 EKS_CONTEXT="$CTX" BASE_URL="$BASE_URL" \
    "$SCRIPT_DIR/inject.sh" roundtrip | tee "$RUN_DIR/roundtrip-$name.log"; then
    note ABORT "checkpoint=$name failed; fault injection skipped"
    return 1
  fi
}

"${K[@]}" get hpa post chat -o wide > "$RUN_DIR/pre-hpa.txt"
"${K[@]}" get pods -o wide > "$RUN_DIR/pre-pods.txt"
"${K[@]}" exec rabbitmq-0 -- rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers > "$RUN_DIR/pre-queues.txt"

RESULT_DIR="$RUN_DIR" BASE_URL="$BASE_URL" RATE=5 DURATION=13m "$SCRIPT_DIR/run-load.sh" smoke > "$RUN_DIR/run-load.log" 2>&1 &
LOAD_PID=$!
note MARK "round1 load start rate=5/s duration=13m"

# ① 정상 대조 구간
nap 180
checkpoint baseline

# ② chat 전체 consumer 공백: N→0→N. Ready만으로 복구를 선언하지 않는다.
CHAT_N="$(chat_replicas)"; BEFORE="$(chat_uids)"; T0=$(date +%s)
[[ "$CHAT_N" -ge 2 ]] || { echo "chat replicas < 2" >&2; exit 1; }
note INJECT "chat all delete replicas=$CHAT_N"
"${K[@]}" delete pod -l "$SEL" --wait=false
wait_chat_stable "$BEFORE" "$T0"
note RECOVER "chat ${CHAT_N}->0->$(chat_replicas) stable seconds=$(( $(date +%s)-T0 ))"
checkpoint chat-drained
nap 120

# ③ RabbitMQ 90초 완전 중단 및 복구
note INJECT "rabbitmq scale=0"
RABBIT_DOWN=1
"${K[@]}" scale sts rabbitmq --replicas=0
"${K[@]}" wait --for=delete pod/rabbitmq-0 --timeout=120s
note INJECT "rabbitmq unavailable"
nap 90
T0=$(date +%s); note RECOVER "rabbitmq scale=1"
"${K[@]}" scale sts rabbitmq --replicas=1
RABBIT_DOWN=0
"${K[@]}" wait --for=condition=Ready pod/rabbitmq-0 --timeout=300s
for _ in $(seq 1 60); do
  EP=$("${K[@]}" get endpoints rabbitmq -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')
  [[ "${EP:-0}" -gt 0 ]] && break
  nap 1
done
note RECOVER "rabbitmq ready endpoint=${EP:-0} seconds=$(( $(date +%s)-T0 ))"
checkpoint rabbit-recovered

wait "$LOAD_PID"
"${K[@]}" get hpa post chat -o wide > "$RUN_DIR/post-hpa.txt"
"${K[@]}" get pods -o wide > "$RUN_DIR/post-pods.txt"
"${K[@]}" get events --sort-by=.lastTimestamp > "$RUN_DIR/post-events.txt"
"${K[@]}" exec rabbitmq-0 -- rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers > "$RUN_DIR/post-queues.txt"
note MARK "round1 complete"
echo "결과: $RUN_DIR"
