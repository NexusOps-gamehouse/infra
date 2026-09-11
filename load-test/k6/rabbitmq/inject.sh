#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-gamehouse}"
RABBIT_POD="${RABBIT_POD:-rabbitmq-0}"
CHAT_DEPLOYMENT="${CHAT_DEPLOYMENT:-chat}"
RESULT_DIR="${RESULT_DIR:-results}"

mkdir -p "$RESULT_DIR"

current_context() {
  kubectl config current-context
}

require_safe_context() {
  local ctx
  ctx="$(current_context)"
  if [[ "${ALLOW_NON_KIND:-0}" != "1" && "$ctx" != kind-* ]]; then
    echo "Refusing fault injection outside a kind-* context: $ctx"
    echo "Set ALLOW_NON_KIND=1 only if you intentionally want to test another environment."
    exit 2
  fi
}

require_fault_opt_in() {
  if [[ "${ALLOW_FAULT:-0}" != "1" ]]; then
    echo "Fault injection is disabled."
    echo "Re-run with ALLOW_FAULT=1 after confirming the namespace/context."
    exit 2
  fi
}

rabbitmq_queues() {
  kubectl -n "$NAMESPACE" exec "$RABBIT_POD" -- \
    rabbitmqctl list_queues \
      name messages_ready messages_unacknowledged consumers durable
}

rabbitmq_consumed() {
  local token="${1:-}"
  local rooms_url="${ROOMS_URL:-}"

  if [[ -z "$token" || -z "$rooms_url" ]]; then
    echo "Usage: ROOMS_URL='http://gamehouse.local/api/...' $0 rabbitmq-consumed <TOKEN>"
    echo "ROOMS_URL must be the real endpoint that returns the user's chat-room list."
    exit 2
  fi

  curl -fsS \
    -H "Authorization: Bearer $token" \
    "$rooms_url" | jq 'length'
}

rabbitmq_kill() {
  require_safe_context
  require_fault_opt_in

  echo "Context: $(current_context)"
  echo "Namespace: $NAMESPACE"
  echo "Deleting pod: $RABBIT_POD"
  kubectl -n "$NAMESPACE" delete pod "$RABBIT_POD"

  echo "Waiting for recreated RabbitMQ pod..."
  kubectl -n "$NAMESPACE" wait \
    --for=condition=Ready \
    "pod/$RABBIT_POD" \
    --timeout="${RABBIT_READY_TIMEOUT:-300s}"
}

chat_down() {
  require_safe_context
  require_fault_opt_in

  echo "Scaling $CHAT_DEPLOYMENT to 0 replicas"
  kubectl -n "$NAMESPACE" scale deployment "$CHAT_DEPLOYMENT" --replicas=0
  kubectl -n "$NAMESPACE" wait \
    --for=delete \
    -l "app.kubernetes.io/name=$CHAT_DEPLOYMENT" \
    --timeout="${CHAT_DELETE_TIMEOUT:-180s}" || true
}

chat_up() {
  require_safe_context
  require_fault_opt_in

  echo "Scaling $CHAT_DEPLOYMENT to 1 replica"
  kubectl -n "$NAMESPACE" scale deployment "$CHAT_DEPLOYMENT" --replicas=1
  kubectl -n "$NAMESPACE" rollout status \
    "deployment/$CHAT_DEPLOYMENT" \
    --timeout="${CHAT_READY_TIMEOUT:-300s}"
}

baseline() {
  echo "===== CONTEXT ====="
  current_context
  echo
  echo "===== PODS ====="
  kubectl -n "$NAMESPACE" get pods -o wide
  echo
  echo "===== RABBITMQ STS ====="
  kubectl -n "$NAMESPACE" get sts rabbitmq
  echo
  echo "===== QUEUES ====="
  rabbitmq_queues
}

case "${1:-}" in
  baseline)
    baseline
    ;;
  rabbitmq-queues)
    rabbitmq_queues
    ;;
  rabbitmq-consumed)
    rabbitmq_consumed "${2:-}"
    ;;
  rabbitmq-kill)
    rabbitmq_kill
    ;;
  chat-down)
    chat_down
    ;;
  chat-up)
    chat_up
    ;;
  *)
    cat <<'EOF'
Usage:
  ./inject.sh baseline
  ./inject.sh rabbitmq-queues
  ROOMS_URL='...' ./inject.sh rabbitmq-consumed "$TOKEN"

Fault injection (kind context by default):
  ALLOW_FAULT=1 ./inject.sh chat-down
  ALLOW_FAULT=1 ./inject.sh chat-up
  ALLOW_FAULT=1 ./inject.sh rabbitmq-kill

Safety:
  Fault injection is refused unless ALLOW_FAULT=1.
  Non-kind contexts are refused unless ALLOW_NON_KIND=1.
EOF
    exit 2
    ;;
esac
