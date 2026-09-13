#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-gamehouse}"
RABBIT_POD="${RABBIT_POD:-rabbitmq-0}"
RABBIT_STS="${RABBIT_STS:-rabbitmq}"
POST_DEPLOYMENT="${POST_DEPLOYMENT:-post}"
CHAT_DEPLOYMENT="${CHAT_DEPLOYMENT:-chat}"

CHAT_QUEUE="${CHAT_QUEUE:-gamehouse.events.gamehouse-chat}"

TOKEN_FILE="${TOKEN_FILE:-$SCRIPT_DIR/seed/data/tokens.json}"
BASE_URL="${BASE_URL:-http://gamehouse.local}"
ROOMS_URL="${ROOMS_URL:-$BASE_URL/api/chat/rooms}"

FAILURES=0

pass() {
  printf '[PASS] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

info() {
  printf '[INFO] %s\n' "$*"
}

retry() {
  local attempts="${1}"
  local delay="${2}"
  shift 2

  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi

    if (( i < attempts )); then
      sleep "$delay"
    fi
  done

  return 1
}

check_context() {
  local ctx

  if ! ctx="$(kubectl config current-context 2>/dev/null)"; then
    fail "Kubernetes context를 읽을 수 없음"
    return
  fi

  if [[ "$ctx" == kind-* ]]; then
    pass "Kubernetes context: $ctx"
  elif [[ "${ALLOW_EKS_FAULT:-0}" == "1" && -n "${EKS_CONTEXT:-}" && "$ctx" == "$EKS_CONTEXT" ]]; then
    # inject.sh 와 같은 두 겹 조건이다. 여기만 느슨하면 사전 점검을 통과하고
    # 정작 주입에서 막히거나, 반대로 점검이 막아 회차를 못 연다.
    pass "Kubernetes context (운영 명시): $ctx"
  else
    fail "kind-* context가 아님: $ctx"
  fi
}

check_cluster_access() {
  if retry 3 2 kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    pass "Kubernetes API / namespace 접근: $NAMESPACE"
  else
    fail "Kubernetes API 또는 namespace 접근 실패: $NAMESPACE"
  fi
}

check_statefulset() {
  local desired ready

  if ! desired="$(
    kubectl -n "$NAMESPACE" get sts "$RABBIT_STS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null
  )"; then
    fail "RabbitMQ StatefulSet 조회 실패: $RABBIT_STS"
    return
  fi

  ready="$(
    kubectl -n "$NAMESPACE" get sts "$RABBIT_STS" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
  )"
  ready="${ready:-0}"

  if [[ "$desired" == "1" && "$ready" == "1" ]]; then
    pass "RabbitMQ StatefulSet: 1/1 Ready"
  else
    fail "RabbitMQ StatefulSet Ready 불일치: ${ready}/${desired}"
  fi
}

check_rabbit_pod() {
  local ready

  ready="$(
    kubectl -n "$NAMESPACE" get pod "$RABBIT_POD" \
      -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true
  )"

  if [[ "$ready" == "true" ]]; then
    pass "RabbitMQ Pod Ready: $RABBIT_POD"
  else
    fail "RabbitMQ Pod가 Ready가 아님: $RABBIT_POD"
  fi
}

check_deployment() {
  local deployment="$1"
  local desired ready available

  desired="$(
    kubectl -n "$NAMESPACE" get deployment "$deployment" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || true
  )"

  ready="$(
    kubectl -n "$NAMESPACE" get deployment "$deployment" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
  )"

  available="$(
    kubectl -n "$NAMESPACE" get deployment "$deployment" \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true
  )"

  desired="${desired:-0}"
  ready="${ready:-0}"
  available="${available:-0}"

  if [[ "$desired" -gt 0 && "$ready" == "$desired" && "$available" == "$desired" ]]; then
    pass "$deployment Deployment: ${ready}/${desired} Ready"
  else
    fail "$deployment Deployment: desired=$desired ready=$ready available=$available"
  fi
}

check_token_file() {
  if [[ ! -e "$TOKEN_FILE" ]]; then
    fail "RabbitMQ 전용 token 파일 없음: $TOKEN_FILE"
    return
  fi

  if [[ ! -r "$TOKEN_FILE" ]]; then
    fail "RabbitMQ 전용 token 파일 읽기 불가: $TOKEN_FILE"
    return
  fi

  if ! jq empty "$TOKEN_FILE" >/dev/null 2>&1; then
    fail "token 파일이 유효한 JSON이 아님: $TOKEN_FILE"
    return
  fi

  pass "RabbitMQ 전용 token 파일 확인"
}

check_queue() {
  local output
  local line
  local consumers

  if ! output="$(
    kubectl -n "$NAMESPACE" exec "$RABBIT_POD" -- \
      rabbitmqctl list_queues \
      name messages_ready messages_unacknowledged consumers durable \
      2>/dev/null
  )"; then
    fail "RabbitMQ Queue 조회 실패"
    return
  fi

  pass "RabbitMQ Queue 조회 가능"

  line="$(
    printf '%s\n' "$output" |
      awk -v queue="$CHAT_QUEUE" '$1 == queue { print; exit }'
  )"

  if [[ -z "$line" ]]; then
    fail "Chat Queue를 찾을 수 없음: $CHAT_QUEUE"
    return
  fi

  consumers="$(printf '%s\n' "$line" | awk '{print $4}')"

  if [[ "$consumers" =~ ^[0-9]+$ ]] && (( consumers > 0 )); then
    pass "Chat Consumer 연결: queue=$CHAT_QUEUE consumers=$consumers"
  else
    fail "Chat Consumer 없음: queue=$CHAT_QUEUE consumers=${consumers:-unknown}"
  fi
}

get_publisher_token() {
  if [[ -n "${PUBLISHER_TOKEN:-}" ]]; then
    printf '%s' "$PUBLISHER_TOKEN"
    return 0
  fi

  if [[ ! -r "$TOKEN_FILE" ]]; then
    return 1
  fi

  # tokens.json 은 공용 시드(load-test/seed/data.example/tokens.json)와 같은
  # **배열** 형식이다: [{email, token}, ...]
  #
  # ⚠️ 배열에 .publisher 를 바로 태우면 jq 가 "Cannot index array with string"
  #    으로 죽는다. // 는 오류를 넘기지 못하므로 type 을 먼저 가른다.
  #
  # 발행자는 prepare.sh 가 만든 첫 계정이다. rabbit.js 도 기본값으로 [0] 만
  # 쓰므로(채팅방 대조가 로그인 사용자 기준이라) 여기서도 [0] 을 본다.
  jq -r '
    if type == "array" then
      (.[0].token // empty)
    else
      (.publisher.token // .publisherToken // .token // empty)
    end
  ' "$TOKEN_FILE" 2>/dev/null | head -n 1
}

check_chat_rooms() {
  local token
  local body_file
  local status
  local count

  if ! token="$(get_publisher_token)" || [[ -z "$token" || "$token" == "null" ]]; then
    fail "Publisher token을 확인할 수 없음"
    info "seed/data/tokens.json 형식이 확정되면 token 경로를 맞춰야 함"
    info "임시 확인은 PUBLISHER_TOKEN 환경변수로 가능"
    return
  fi

  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' RETURN

  status="$(
    curl -sS \
      -o "$body_file" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $token" \
      "$ROOMS_URL" 2>/dev/null || true
  )"

  if [[ "$status" != "200" ]]; then
    fail "Chat room 조회 HTTP 실패: status=${status:-unknown} url=$ROOMS_URL"
    return
  fi

  if ! count="$(
    jq -er '
      if type == "array" then
        length
      elif (.data? | type) == "array" then
        .data | length
      elif (.content? | type) == "array" then
        .content | length
      else
        error("unsupported response")
      end
    ' "$body_file" 2>/dev/null
  )"; then
    fail "Chat room 응답에서 숫자 count를 계산할 수 없음"
    return
  fi

  pass "Chat room 조회: HTTP 200 / count=$count"
}

main() {
  echo "===== RabbitMQ Test Preflight ====="
  echo

  check_context
  check_cluster_access

  echo
  check_statefulset
  check_rabbit_pod
  check_deployment "$POST_DEPLOYMENT"
  check_deployment "$CHAT_DEPLOYMENT"

  echo
  check_token_file

  echo
  check_queue

  echo
  check_chat_rooms

  echo

  if (( FAILURES == 0 )); then
    echo "===== PREFLIGHT PASSED ====="
    echo "RabbitMQ 테스트를 시작할 수 있습니다."
    exit 0
  fi

  echo "===== PREFLIGHT FAILED ====="
  echo "실패 항목: $FAILURES"
  echo "실패 원인을 해결한 뒤 다시 실행하세요."
  exit 1
}

main "$@"
