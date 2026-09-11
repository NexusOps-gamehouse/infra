#!/usr/bin/env bash
# ===========================================================================
# RabbitMQ 회차 — 장애 주입과 상태 확인
#
#   ./inject.sh baseline              기준선 (context · Pod · 큐)
#   ./inject.sh rabbitmq-queues       큐 상태
#   ./inject.sh rabbitmq-consumed     채팅방 수 (발행 계정 기준)
#
#   ALLOW_FAULT=1 ./inject.sh chat-down       Chat consumer 중단 → 큐 적체
#   ALLOW_FAULT=1 ./inject.sh chat-up         원래 replica 로 복구
#   ALLOW_FAULT=1 ./inject.sh rabbitmq-kill   브로커 재시작
#
# 안전장치
#   · ALLOW_FAULT=1 없이는 장애 주입을 거부한다
#   · kind-* 가 아닌 context 에서는 거부한다 (우회 수단 없음)
#
# ⚠️ 예전 버전에는 ALLOW_NON_KIND=1 우회가 있었다. 없앴다. 이 도구는 로컬
#    전용이고, 실수로 운영에 Pod 삭제를 날리는 것보다 불편한 편이 낫다.
#    다른 환경에서 정말 필요하면 그때 별도 절차를 만든다.
# ===========================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${RESULT_DIR:-$SCRIPT_DIR/results}"
DATA_DIR="$SCRIPT_DIR/seed/data"

NAMESPACE="${NAMESPACE:-gamehouse}"
RABBIT_POD="${RABBIT_POD:-rabbitmq-0}"
CHAT_DEPLOYMENT="${CHAT_DEPLOYMENT:-chat}"
ROOMS_URL="${ROOMS_URL:-http://gamehouse.local/api/chat/rooms}"

mkdir -p "$RESULT_DIR"

note() { "$SCRIPT_DIR/timeline.sh" -t "$1" "${@:2}"; }

current_context() { kubectl config current-context; }

require_safe_context() {
  local ctx
  ctx="$(current_context)"
  if [[ "$ctx" != kind-* ]]; then
    echo "중단: kind 가 아닌 context 에서는 장애를 주입하지 않는다: $ctx" >&2
    echo "  kubectl config use-context kind-gamehouse-local" >&2
    exit 2
  fi
}

require_fault_opt_in() {
  if [[ "${ALLOW_FAULT:-0}" != "1" ]]; then
    echo "중단: 장애 주입이 꺼져 있다." >&2
    echo "  context 와 namespace 를 확인한 뒤 ALLOW_FAULT=1 을 붙여 다시 실행한다." >&2
    exit 2
  fi
}

# --- 조회 -----------------------------------------------------------------

rabbitmq_queues() {
  kubectl -n "$NAMESPACE" exec "$RABBIT_POD" -- \
    rabbitmqctl list_queues \
      name messages_ready messages_unacknowledged consumers durable
}

# Chat consumer 수. chat-down 이 실제로 먹었는지 확인하는 값이다.
chat_consumers() {
  rabbitmq_queues 2>/dev/null \
    | awk '$1 ~ /gamehouse-chat$/ { sum += $4 } END { print sum + 0 }'
}

# 채팅방 수 — 소비 결과를 세는 값.
#
# ⚠️ 큐 길이만 보면 안 된다. consumer 가 곧바로 비우면 큐는 늘 0 이라
#    "소비됐다" 와 "애초에 안 들어왔다" 가 구분되지 않는다. PostCreatedEvent
#    를 chat 이 받으면 그 글의 채팅방이 생기므로, 그 수를 직접 센다.
#
# ⚠️ GET /api/chat/rooms 는 로그인 사용자 소속 방만 돌려준다. 그래서 반드시
#    **발행 계정과 같은 토큰**이어야 한다. 기본은 tokens.json 의 첫 계정이고,
#    rabbit.js 도 기본값으로 그 계정만 쓴다.
rabbitmq_consumed() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    [[ -f "$DATA_DIR/tokens.json" ]] || {
      echo "중단: 토큰이 없다. ./seed/prepare.sh 를 먼저 실행하거나 인자로 넘긴다." >&2
      exit 2
    }
    token="$(jq -r '.[0].token' "$DATA_DIR/tokens.json")"
  fi

  local body code rooms
  body="$(curl -s -w $'\n%{http_code}' --max-time 20 \
    -H "Authorization: Bearer $token" "$ROOMS_URL" || printf '\n000')"
  code="$(tail -n1 <<<"$body")"

  if [[ "$code" != "200" ]]; then
    echo "채팅방 조회 실패: HTTP $code ($ROOMS_URL)" >&2
    note SNAPSHOT "chat-rooms 조회 실패 http=$code"
    exit 1
  fi

  rooms="$(sed '$d' <<<"$body" \
    | jq 'if type=="object" then (.content // .items // []) else . end | length')"
  echo "$rooms"
  note SNAPSHOT "chat-rooms=$rooms"
}

baseline() {
  echo "===== CONTEXT ====="; current_context
  echo; echo "===== PODS ====="
  kubectl -n "$NAMESPACE" get pods -o wide
  echo; echo "===== RABBITMQ STS ====="
  kubectl -n "$NAMESPACE" get sts rabbitmq
  echo; echo "===== QUEUES ====="
  rabbitmq_queues
  echo; echo "===== CHAT ROOMS ====="
  rabbitmq_consumed || true
}

# --- 장애 주입 -------------------------------------------------------------

# Chat 을 내려 큐를 쌓는다.
#
# ⚠️ 복구할 replica 수를 먼저 저장한다. 예전 버전은 chat-up 이 항상 1 로
#    되돌려서, 테스트 전에 HPA 가 2 로 올려 둔 상태였다면 원상복구가 아니었다.
chat_down() {
  require_safe_context
  require_fault_opt_in

  local before
  before="$(kubectl -n "$NAMESPACE" get deploy "$CHAT_DEPLOYMENT" \
    -o jsonpath='{.spec.replicas}')"
  : "${before:=1}"
  echo "$before" > "$RESULT_DIR/chat-replicas.before"
  echo "복구할 replica 수를 저장했다: $before"

  kubectl -n "$NAMESPACE" scale deployment "$CHAT_DEPLOYMENT" --replicas=0
  # resource 종류를 명시한다. 예전 버전은 종류가 빠져 있어 대기가 성립하지
  # 않았고, 오류를 || true 로 삼켜서 Pod 가 살아 있어도 다음 단계로 갔다.
  kubectl -n "$NAMESPACE" wait --for=delete pod \
    -l "app.kubernetes.io/name=$CHAT_DEPLOYMENT" \
    --timeout="${CHAT_DELETE_TIMEOUT:-180s}"

  # Pod 가 사라져도 broker 쪽 consumer 등록이 남아 있을 수 있다. 실제로
  # 0 이 됐는지 확인해야 큐 적체 결과를 믿을 수 있다.
  local n=0 c
  while [ "$n" -lt 12 ]; do
    c="$(chat_consumers)"
    [ "$c" = "0" ] && break
    sleep 5; n=$((n + 1))
  done
  c="$(chat_consumers)"
  if [ "$c" != "0" ]; then
    echo "경고: Chat consumer 가 아직 ${c} 개다. 큐 적체 결과를 신뢰할 수 없다." >&2
  fi

  note INJECT "chat-down replicas 0 (before=$before) consumers=$c"
}

chat_up() {
  require_safe_context
  require_fault_opt_in

  local before=1
  [ -f "$RESULT_DIR/chat-replicas.before" ] && \
    before="$(cat "$RESULT_DIR/chat-replicas.before")"

  kubectl -n "$NAMESPACE" scale deployment "$CHAT_DEPLOYMENT" --replicas="$before"
  kubectl -n "$NAMESPACE" rollout status "deployment/$CHAT_DEPLOYMENT" \
    --timeout="${CHAT_READY_TIMEOUT:-300s}"

  # consumer 가 다시 붙었는지 확인한다. Pod 가 Ready 라도 AMQP 재연결까지는
  # 시간이 걸린다.
  local n=0 c
  while [ "$n" -lt 24 ]; do
    c="$(chat_consumers)"
    [ "$c" != "0" ] && break
    sleep 5; n=$((n + 1))
  done
  c="$(chat_consumers)"

  note RECOVER "chat-up replicas $before consumers=$c"
  [ "$c" = "0" ] && echo "경고: consumer 가 아직 0 이다. 큐가 안 비워진다." >&2
  rm -f "$RESULT_DIR/chat-replicas.before"
}

# 브로커 재시작. 삭제 직전과 Ready 직후 시각을 자동으로 남긴다 —
# 손으로 적으면 반드시 한 번은 빠진다.
rabbitmq_kill() {
  require_safe_context
  require_fault_opt_in

  echo "Context   : $(current_context)"
  echo "Namespace : $NAMESPACE"
  echo "Pod       : $RABBIT_POD"

  note INJECT "rabbitmq-kill pod=$RABBIT_POD delete 직전"
  kubectl -n "$NAMESPACE" delete pod "$RABBIT_POD" --wait=false

  echo "재생성 대기..."
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$RABBIT_POD" \
    --timeout="${RABBIT_READY_TIMEOUT:-300s}"
  note RECOVER "rabbitmq Ready pod=$RABBIT_POD"
}

case "${1:-}" in
  baseline)          baseline ;;
  rabbitmq-queues)   rabbitmq_queues; note SNAPSHOT "queues 조회" ;;
  rabbitmq-consumed) rabbitmq_consumed "${2:-}" ;;
  rabbitmq-kill)     rabbitmq_kill ;;
  chat-down)         chat_down ;;
  chat-up)           chat_up ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
