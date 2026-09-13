#!/usr/bin/env bash
# ===========================================================================
# RabbitMQ 회차 — 장애 주입과 상태 확인
#
#   ./inject.sh baseline              기준선 (context · Pod · 큐)
#   ./inject.sh rabbitmq-queues       큐 상태
#   ./inject.sh rabbitmq-consumed     채팅방 수 (발행 계정 기준)
#   ./inject.sh roundtrip             이벤트 왕복 확인 (글 = 방 = chatRoomId)
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
RABBIT_STS_SVC="${RABBIT_STS_SVC:-rabbitmq}"
CHAT_DEPLOYMENT="${CHAT_DEPLOYMENT:-chat}"
BASE_URL="${BASE_URL:-http://gamehouse.local}"
ROOMS_URL="${ROOMS_URL:-$BASE_URL/api/chat/rooms}"

mkdir -p "$RESULT_DIR"

note() { "$SCRIPT_DIR/timeline.sh" -t "$1" "${@:2}"; }

# EKS 회차는 current-context가 우연히 맞는지에 의존하지 않는다. 두 스위치가 모두
# 주어진 경우, 조회와 주입을 포함한 모든 kubectl 호출에 그 context를 강제한다.
KUBECTL=(kubectl)
EKS_REQUESTED=0
if [[ "${ALLOW_EKS_FAULT:-0}" == "1" || -n "${EKS_CONTEXT:-}" ]]; then
  EKS_REQUESTED=1
  if [[ "${ALLOW_EKS_FAULT:-0}" != "1" || -z "${EKS_CONTEXT:-}" ]]; then
    echo "중단: EKS 실행에는 ALLOW_EKS_FAULT=1 과 EKS_CONTEXT를 함께 준다." >&2
    exit 2
  fi
  KUBECTL+=(--context "$EKS_CONTEXT")
fi

kube() { "${KUBECTL[@]}" "$@"; }

current_context() {
  if (( EKS_REQUESTED )); then
    printf '%s\n' "$EKS_CONTEXT"
  else
    kubectl config current-context
  fi
}

require_safe_context() {
  local ctx
  ctx="$(current_context)"
  [[ "$ctx" == kind-* ]] && return 0

  # 운영(EKS)은 두 겹을 **모두** 만족해야 통과한다.
  #   ① ALLOW_EKS_FAULT=1   — 의도했다는 표시
  #   ② EKS_CONTEXT 와 일치 — 어느 클러스터인지 한 번 더 적게 한다
  #
  # 오늘만 세 번, 다른 작업 때문에 current-context 가 EKS 로 넘어가 있었다.
  # 스위치 하나만으로는 그 상태에서 그대로 통과해 버린다. 그래서 중복시킨다.
  if [[ "${ALLOW_EKS_FAULT:-0}" == "1" && -n "${EKS_CONTEXT:-}" \
        && "$ctx" == "$EKS_CONTEXT" ]]; then
    echo "⚠️ 운영 클러스터에 장애를 주입한다: $ctx" >&2
    return 0
  fi

  echo "중단: kind 가 아닌 context 에서는 장애를 주입하지 않는다: $ctx" >&2
  echo "  로컬로 돌아가려면: kubectl config use-context kind-gamehouse-local" >&2
  echo "  운영 회차라면:     ALLOW_FAULT=1 ALLOW_EKS_FAULT=1 EKS_CONTEXT=$ctx $0 ..." >&2
  exit 2
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
  kube -n "$NAMESPACE" exec "$RABBIT_POD" -- \
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

# 이벤트 왕복 확인.
#
# 이 흐름은 두 번 오간다. 채팅방 수만 세면 앞의 절반만 검증한 것이다.
#
#   ① post  발행: PostCreatedEvent
#   ② chat  소비 → 채팅방 생성
#   ③ chat  발행: ChatRoomCreatedEvent   ← 여기부터 안 보고 있었다
#   ④ post  소비 → posts.chat_room_id 채움
#
# 세 숫자가 같아야 왕복 전체가 무사한 것이다.
#   [RMQ-TEST] 글 수 == 채팅방 수 == chatRoomId 가 채워진 글 수
#
# ⚠️ PostDto 의 chatRoomId 는 "내가 멤버인 경우에만" 실린다. 발행자가 방장이라
#    발행 계정 토큰으로 조회하면 채워져 나온다. 다른 계정으로 보면 전부 null 이다.
roundtrip() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    [[ -f "$DATA_DIR/tokens.json" ]] || {
      echo "중단: 토큰이 없다. ./seed/prepare.sh 를 먼저 실행한다." >&2; exit 2; }
    token="$(jq -r '.[0].token' "$DATA_DIR/tokens.json")"
  fi

  local prefix="[RMQ-TEST]"
  [[ -f "$DATA_DIR/meta.json" ]] &&     prefix="$(jq -r '.titlePrefix // "[RMQ-TEST]"' "$DATA_DIR/meta.json")"

  local base="$BASE_URL"
  local posts=0 filled=0 page=0

  while [ "$page" -lt 50 ]; do
    local body items n
    body="$(curl -s --max-time 30 "$base/api/posts?page=${page}&size=100" \
      -H "Authorization: Bearer $token" || echo '[]')"
    items="$(jq -c 'if type=="object" then (.content // .items // []) else . end' \
      <<<"$body" 2>/dev/null || echo '[]')"
    n="$(jq 'length' <<<"$items" 2>/dev/null || echo 0)"
    [ "$n" -eq 0 ] && break

    posts=$(( posts + $(jq --arg p "$prefix" \
      '[.[] | select((.title // "") | startswith($p))] | length' <<<"$items") ))
    filled=$(( filled + $(jq --arg p "$prefix" \
      '[.[] | select((.title // "") | startswith($p)) | select(.chatRoomId != null)] | length' \
      <<<"$items") ))

    [ "$n" -lt 100 ] && break
    page=$(( page + 1 ))
  done

  # ⚠️ head 로 자르면 안 된다. rabbitmq_consumed 는 수치를 찍은 뒤 timeline 에도
  #    기록하는데, head 가 파이프를 닫으면 그 쓰기가 SIGPIPE 로 죽고 pipefail
  #    이 실패로 잡아 set -e 가 스크립트를 통째로 끝낸다(출력 한 줄 없이).
  local rooms rooms_raw
  rooms_raw="$(rabbitmq_consumed "$token" 2>/dev/null || true)"
  rooms="$(printf '%s' "$rooms_raw" | sed -n '1p')"

  printf '  %-26s %s\n' "[RMQ-TEST] 글 수" "$posts"
  printf '  %-26s %s\n' "채팅방 수" "${rooms:-?}"
  printf '  %-26s %s\n' "chatRoomId 채워진 글" "$filled"
  if [ "$posts" = "$filled" ]; then
    echo "  → 왕복 정상 (③④ 까지 완료)"
  else
    echo "  → ⚠️ 왕복 미완: $(( posts - filled ))건이 chatRoomId 없음"
  fi
  note SNAPSHOT "roundtrip posts=$posts rooms=${rooms:-?} filled=$filled"
}

baseline() {
  echo "===== CONTEXT ====="; current_context
  echo; echo "===== PODS ====="
  kube -n "$NAMESPACE" get pods -o wide
  echo; echo "===== RABBITMQ STS ====="
  kube -n "$NAMESPACE" get sts rabbitmq
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
  before="$(kube -n "$NAMESPACE" get deploy "$CHAT_DEPLOYMENT" \
    -o jsonpath='{.spec.replicas}')"
  : "${before:=1}"
  echo "$before" > "$RESULT_DIR/chat-replicas.before"
  echo "복구할 replica 수를 저장했다: $before"

  kube -n "$NAMESPACE" scale deployment "$CHAT_DEPLOYMENT" --replicas=0
  # resource 종류를 명시한다. 예전 버전은 종류가 빠져 있어 대기가 성립하지
  # 않았고, 오류를 || true 로 삼켜서 Pod 가 살아 있어도 다음 단계로 갔다.
  kube -n "$NAMESPACE" wait --for=delete pod \
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

  kube -n "$NAMESPACE" scale deployment "$CHAT_DEPLOYMENT" --replicas="$before"
  kube -n "$NAMESPACE" rollout status "deployment/$CHAT_DEPLOYMENT" \
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

  # ⚠️ 삭제 직후 곧바로 wait 를 걸면 안 된다. StatefulSet 이라 Pod 이름이
  #    같아서, 삭제가 전파되기 전의 **옛 Pod** 를 보고 즉시 통과한다.
  #    실제로 그렇게 해서 다운타임이 36초인데 0초로 기록된 적이 있다.
  #
  #    Pod UID 를 먼저 기억했다가 **바뀐 뒤에** Ready 를 기다린다. UID 는
  #    Pod 마다 새로 발급되므로 같은 이름이어도 새 Pod 인지 구분된다.
  local old_uid
  old_uid="$(kube -n "$NAMESPACE" get pod "$RABBIT_POD" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"

  note INJECT "rabbitmq-kill pod=$RABBIT_POD uid=${old_uid:0:8} delete 직전"
  kube -n "$NAMESPACE" delete pod "$RABBIT_POD" --wait=false

  echo "새 Pod 대기..."
  local n=0 new_uid=""
  while [ "$n" -lt "${RABBIT_REPLACE_TIMEOUT:-120}" ]; do
    new_uid="$(kube -n "$NAMESPACE" get pod "$RABBIT_POD" \
      -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ] && break
    sleep 1; n=$((n + 1))
  done
  if [ -z "$new_uid" ] || [ "$new_uid" = "$old_uid" ]; then
    echo "중단: 새 Pod 가 ${RABBIT_REPLACE_TIMEOUT:-120}초 안에 생기지 않았다." >&2
    note NOTE "rabbitmq-kill 새 Pod 대기 실패"
    exit 1
  fi

  echo "Ready 대기..."
  kube -n "$NAMESPACE" wait --for=condition=Ready "pod/$RABBIT_POD" \
    --timeout="${RABBIT_READY_TIMEOUT:-300s}"

  # Endpoints 까지 봐야 실제로 트래픽을 받는다. Ready 와 몇 초 차이가 난다.
  n=0
  while [ "$n" -lt 60 ]; do
    [ "$(kube -n "$NAMESPACE" get endpoints "$RABBIT_STS_SVC" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')" != "0" ] && break
    sleep 1; n=$((n + 1))
  done

  note RECOVER "rabbitmq Ready pod=$RABBIT_POD uid=${new_uid:0:8}"
}

case "${1:-}" in
  baseline)          baseline ;;
  rabbitmq-queues)   rabbitmq_queues; note SNAPSHOT "queues 조회" ;;
  rabbitmq-consumed) rabbitmq_consumed "${2:-}" ;;
  roundtrip)         roundtrip "${2:-}" ;;
  rabbitmq-kill)     rabbitmq_kill ;;
  chat-down)         chat_down ;;
  chat-up)           chat_up ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
