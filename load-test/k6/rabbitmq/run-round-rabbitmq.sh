#!/usr/bin/env bash
# ===========================================================================
# RabbitMQ 단독 장애 회차 — 브로커를 90초 내리고 post 발행 경로를 본다
#
#   ALLOW_FAULT=1 ALLOW_EKS_FAULT=1 EKS_CONTEXT=gamehouse-main \
#   BASE_URL=https://api.game-duo.com ./run-round-rabbitmq.sh
#
# [chat 단계를 뺀 이유]
# 전체 회차는 chat Pod 삭제 → 복구 gate → RabbitMQ 순이었는데, 그 gate 가
# chat API 200 을 기다린다. 그런데 GET /api/chat/rooms 는 방 하나당 user 로
# HTTP 를 한 번씩 부른다(ChatService.toRoomDto). 방이 900개면 900번이다.
# 그래서 회차가 길어질수록 그 API 가 안 열리고, RabbitMQ 단계까지 못 갔다.
#
# chat 쪽 발견(적체 → Drain → consumer 복귀)은 1차-2 에서 이미 확보했다.
# 이 스크립트는 남은 것 — **브로커가 없을 때 글쓰기가 어떻게 되는가** — 만 본다.
#
# [판정은 k6 와 actuator 로 한다]
# 응답 분포·실패율·처리량은 k6 요약과 원본에서, 커넥션 풀은 actuator 를 2초
# 간격으로 직접 긁어서 본다. /api/chat/rooms 는 대조 구간에서 딱 한 번만
# 부른다(2홉 역참조율 확보용). 그 시점에는 방이 900개 수준이라 아직 열린다.
# ===========================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

: "${BASE_URL:?BASE_URL 을 준다. 예: https://api.game-duo.com}"
: "${EKS_CONTEXT:?EKS_CONTEXT 를 준다. 예: gamehouse-main}"
[[ "${ALLOW_FAULT:-0}" == "1" && "${ALLOW_EKS_FAULT:-0}" == "1" ]] || {
  echo "중단: ALLOW_FAULT=1 ALLOW_EKS_FAULT=1 을 함께 준다." >&2; exit 2; }

CTX="$EKS_CONTEXT"
NS="${NAMESPACE:-gamehouse}"
POD="${RABBIT_POD:-rabbitmq-0}"
SVC="${RABBIT_STS_SVC:-rabbitmq}"
RATE="${RATE:-5}"
DOWN_SECONDS="${DOWN_SECONDS:-90}"

STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT="results/EKS-RMQ-$STAMP"
mkdir -p "$OUT"

kube() { kubectl --context "$CTX" -n "$NS" "$@"; }

# [RMQ-TEST] 글 수와 chatRoomId 채워진 수만 센다.
#
# ⚠️ /api/chat/rooms 는 부르지 않는다. 그쪽은 방 하나당 user 로 HTTP 를 한 번씩
#    부르므로(ChatService.toRoomDto) 방이 쌓일수록 판정이 대상을 흔든다.
#    /api/posts 는 authorsOf 가 distinct 로 묶어 페이지당 user 호출이 1회다.
count_posts() {
  local token page=0 posts=0 filled=0 body items n
  token="$(jq -r '.[0].token' seed/data/tokens.json)"
  while [ "$page" -lt 60 ]; do
    body="$(curl -s --max-time 30 "$BASE_URL/api/posts?page=${page}&size=100" \
      -H "Authorization: Bearer $token" || echo '{}')"
    items="$(jq -c '(.items // .content // [])' <<<"$body" 2>/dev/null || echo '[]')"
    n="$(jq 'length' <<<"$items" 2>/dev/null || echo 0)"
    [ "$n" -eq 0 ] && break
    posts=$(( posts + $(jq '[.[]|select((.title//"")|startswith("[RMQ-TEST]"))]|length' <<<"$items") ))
    filled=$(( filled + $(jq '[.[]|select((.title//"")|startswith("[RMQ-TEST]"))|select(.chatRoomId!=null)]|length' <<<"$items") ))
    [ "$n" -lt 100 ] && break
    page=$(( page + 1 ))
  done
  printf '%s %s\n' "$posts" "$filled"
}
mark() { ./timeline.sh -t "$1" "${@:2}"; }
say()  { printf '\n\033[1m▶ [%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"; }

# 신호를 즉시 받으려면 전경 자식을 만들면 안 된다. bash 는 전경 자식이 끝날
# 때까지 trap 실행을 미룬다 — 90초 sleep 중에 터미널을 닫으면 브로커가 내려간
# 채로 그 시간을 다 기다린다.
nap()  { sleep "$1" & wait $!; }
irun() { "$@" & wait $!; }

# ---------------------------------------------------------------------------
# 1. 사전 확인
# ---------------------------------------------------------------------------
say "사전 확인"
kube get pod "$POD" -o wide | tee "$OUT/pre-pod.txt"
kube get deploy post -o custom-columns='NAME:.metadata.name,SPEC:.spec.replicas,READY:.status.readyReplicas' --no-headers | tee "$OUT/pre-deploy.txt"
kube exec "$POD" -- rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers \
  | tee "$OUT/pre-queues.txt"

ready="$(kube get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}')"
[ "$ready" = "true" ] || { echo "중단: $POD 가 Ready 가 아니다." >&2; exit 2; }

# ---------------------------------------------------------------------------
# 2. 커넥션 풀 샘플러 (2초 간격)
# ---------------------------------------------------------------------------
pkill -f "port-forward.*18182" 2>/dev/null || true
kube port-forward svc/post 18182:8180 >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do
  curl -sf --max-time 2 "http://localhost:18182/actuator/prometheus?includedNames=hikaricp_connections_active" >/dev/null 2>&1 && break
  sleep 0.5
done
./sample-pool.sh "$OUT/pool.csv" >/dev/null 2>&1 &
POOL_PID=$!

# ---------------------------------------------------------------------------
# 3. 큐 샘플러 (5초 간격 — exec 이라 더 자주 하면 브로커에 부담)
# ---------------------------------------------------------------------------
QUEUE_LOG="$OUT/queue.tsv"
printf 'time\tready\tunacked\tconsumers\n' > "$QUEUE_LOG"
sample_queue() {
  while :; do
    row="$(kube exec "$POD" -- rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers 2>/dev/null \
      | awk '$1=="gamehouse.events.gamehouse-chat"{print $2"\t"$3"\t"$4; exit}')"
    printf '%s\t%s\n' "$(date '+%H:%M:%S')" "${row:-?$'\t'?$'\t'?}" >> "$QUEUE_LOG"
    sleep 5
  done
}
sample_queue & QUEUE_PID=$!

# ---------------------------------------------------------------------------
# 4. 안전장치 — 어떤 종료 경로에서도 브로커를 되올린다
#
#    scale 0 과 scale 1 **사이**에서 죽으면 운영 브로커가 0 replica 로 방치된다.
#    이 회차에서 가장 위험한 실패 방식이다.
# ---------------------------------------------------------------------------
RABBIT_DOWN=0
cleanup_on_exit() {
  if [ "$RABBIT_DOWN" = "1" ]; then
    echo "⚠️ 종료 중이다. RabbitMQ 를 1 replica 로 되올린다." >&2
    kube scale statefulset "$SVC" --replicas=1 || true
  fi
  kill "$POOL_PID" "$QUEUE_PID" "$PF_PID" 2>/dev/null || true
  wait "$POOL_PID" "$QUEUE_PID" "$PF_PID" 2>/dev/null || true
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------------------
# 5. 부하 시작
# ---------------------------------------------------------------------------
DURATION="${DURATION:-8m}"
say "부하 시작 — ${RATE} req/s · $DURATION"
mark MARK "RMQ 단독 회차 시작 rate=${RATE}/s duration=$DURATION out=$OUT"
RESULT_DIR="$OUT" BASE_URL="$BASE_URL" RATE="$RATE" DURATION="$DURATION" \
  ./run-load.sh smoke > "$OUT/k6.log" 2>&1 &
LOAD_PID=$!

# ---------------------------------------------------------------------------
# 6. 대조 구간 3분 → 2홉 역참조율 1회 측정
#
#    여기서만 /api/chat/rooms 를 부른다. 이 시점 방이 900개 수준이라 아직
#    응답이 온다. 회차 끝에 다시 부르면 2,400개라 timeout 된다.
# ---------------------------------------------------------------------------
nap 180
say "대조 구간 종료 — 2홉 역참조율 측정"
mark MARK "대조 구간 종료, roundtrip 측정"
( BASE_URL="$BASE_URL" ALLOW_EKS_FAULT=1 EKS_CONTEXT="$CTX" \
    timeout 120 ./inject.sh roundtrip || echo "roundtrip 실패 — 판정에는 영향 없음" ) \
  2>&1 | tee "$OUT/roundtrip-baseline.log"

# ---------------------------------------------------------------------------
# 7. 브로커 중단
# ---------------------------------------------------------------------------
say "브로커 중단 — ${DOWN_SECONDS}초"
mark INJECT "rabbitmq scale 0 requested"
RABBIT_DOWN=1                       # ← 요청 **앞에** 세운다
kube scale statefulset "$SVC" --replicas=0
irun kube wait --for=delete "pod/$POD" --timeout=120s || true

for _ in $(seq 1 60); do
  EP="$(kube get endpoints "$SVC" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')"
  [ "$EP" = "0" ] && break
  sleep 1
done
mark INJECT "rabbitmq unavailable endpoint=$EP"
say "브로커 서비스에서 제거됨 (endpoint=$EP)"

# 장애 한가운데서 스레드 덤프 — 무엇이 요청 스레드를 붙잡는지 확정한다.
# 로컬 R4 에서 CachingConnectionFactory 의 ReentrantLock 으로 확인했던 그 지점이
# 운영에서도 같은지 본다. kill -3 은 stdout 으로 덤프를 뱉는다.
nap 20
say "스레드 덤프"
PPOD="$(kube get pod -l 'app.kubernetes.io/name=post' -o jsonpath='{.items[0].metadata.name}')"
kube exec "$PPOD" -- sh -c 'kill -3 1' 2>/dev/null || echo "덤프 전송 실패"
sleep 5
kube logs "$PPOD" --tail=3000 > "$OUT/threaddump.txt" 2>/dev/null || true
echo "  덤프 $(wc -l < "$OUT/threaddump.txt") 줄"

nap "$(( DOWN_SECONDS - 25 ))"

# ---------------------------------------------------------------------------
# 8. 복구 — 각 구간을 따로 잰다
# ---------------------------------------------------------------------------
say "브로커 복구"
T0=$(date +%s)
mark RECOVER "rabbitmq scale 1 requested"
kube scale statefulset "$SVC" --replicas=1
RABBIT_DOWN=0                       # ← 되올렸으므로 trap 의 책임 해제

# ⚠️ UID 는 bash 읽기 전용 변수다. POD_UID 를 쓴다.
for _ in $(seq 1 120); do
  POD_UID="$(kube get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  [ -n "${POD_UID:-}" ] && break
  sleep 1
done
mark RECOVER "rabbitmq new pod uid=${POD_UID:0:8} +$(( $(date +%s) - T0 ))s"

irun kube wait --for=condition=Ready "pod/$POD" --timeout=300s
mark RECOVER "rabbitmq Ready +$(( $(date +%s) - T0 ))s"

for _ in $(seq 1 60); do
  EP="$(kube get endpoints "$SVC" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')"
  [ "${EP:-0}" -gt 0 ] && break
  sleep 1
done
mark RECOVER "rabbitmq endpoint=$EP +$(( $(date +%s) - T0 ))s"
say "복구 완료 — $(( $(date +%s) - T0 ))초"

# ---------------------------------------------------------------------------
# 9. 부하 종료 대기
# ---------------------------------------------------------------------------
say "부하 종료 대기"
wait "$LOAD_PID" || true
mark MARK "RMQ 단독 회차 종료"

kube exec "$POD" -- rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers \
  > "$OUT/post-queues.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# 10. 집계 — 방 없는 글을 뺄셈으로 구한다
#
# 글은 커밋 시점에 확정되고, 채팅방은 그 뒤 비동기로 생긴다. 그래서 두 수를
# 비교하면 "커밋은 됐는데 발행이 안 된 글" 이 나온다. 이벤트가 안 나갔으니
# 방도 없다.
#
#   조치 전  발행 실패 → 트랜잭션 롤백 → 글이 안 남음 → 차이 0
#   조치 후  커밋 뒤 발행 → 글은 남음               → 차이 = 방 없는 글
#
# 로컬 4회차에서 이 뺄셈과 DB 조인 실측이 정확히 일치했다(0/0/36/38).
# ---------------------------------------------------------------------------
say "집계"
read -r POSTS FILLED <<<"$(count_posts)"
SUMMARY="$(ls -1 "$OUT"/*-summary.json 2>/dev/null | tail -1)"
PUBLISHED=0; REQS=0; FAILED=0
if [ -n "$SUMMARY" ]; then
  PUBLISHED="$(jq -r '.metrics.rmq_published.count // 0' "$SUMMARY")"
  REQS="$(jq -r '.metrics.http_reqs.count // 0' "$SUMMARY")"
  FAILED="$(jq -r '.metrics.rmq_publish_failed.count // 0' "$SUMMARY")"
fi
ORPHAN=$(( POSTS - PUBLISHED ))

{
  printf 'k6 발행 성공\t%s\n' "$PUBLISHED"
  printf 'k6 발행 실패\t%s\n' "$FAILED"
  printf 'k6 총 요청\t%s\n'   "$REQS"
  printf '실제 글 수\t%s\n'   "$POSTS"
  printf 'chatRoomId 채움\t%s\n' "$FILLED"
  printf '방 없는 글(뺄셈)\t%s\n' "$ORPHAN"
} | tee "$OUT/tally.tsv"

if [ "$POSTS" -gt 0 ]; then
  printf '  2홉 역참조 성공률  %.1f%%\n' "$(echo "scale=3; 100*$FILLED/$POSTS" | bc)"
fi
[ "$ORPHAN" -gt 0 ] && echo "  ⚠️ 방 없는 글 ${ORPHAN}건 — 커밋 뒤 발행이 실패했다" \
                    || echo "  방 없는 글 없음 — 발행 실패가 롤백으로 처리됐다"

# ---------------------------------------------------------------------------
# 11. chat 소비 실패 확인
#
# 뺄셈이 못 잡는 경우가 하나 있다 — 발행은 성공했는데 chat 이 소비에 실패한
# 경우다. RabbitEventBridge 가 예외를 삼키고 메시지를 버리므로 큐도 0 이 되고
# 글 수도 정상이다. 그때는 chat 로그에만 흔적이 남는다.
# ---------------------------------------------------------------------------
say "chat 소비 실패 확인 (Loki)"
pkill -f "port-forward.*13100" 2>/dev/null || true
kubectl --context "$CTX" -n observability port-forward svc/loki 13100:3100 >/dev/null 2>&1 &
LOKI_PID=$!
sleep 3
now=$(date +%s); start=$(( now - 1800 ))
curl -s --max-time 30 -G 'http://localhost:13100/loki/api/v1/query_range' \
  --data-urlencode '{namespace="gamehouse", app="chat"} |~ "이벤트 처리 실패|이벤트가 아닌 메시지"' \
  --data-urlencode "start=${start}000000000" --data-urlencode "end=${now}000000000" \
  --data-urlencode 'limit=200' 2>/dev/null \
  | jq -r '.data.result[]? | .values[] | [(.[0]|tonumber/1e9|todate), (.[1]|gsub("\\s+";" ")|.[0:140])] | @tsv' \
  | sort > "$OUT/chat-consume-errors.tsv" || true
kill "$LOKI_PID" 2>/dev/null || true
cnt="$(wc -l < "$OUT/chat-consume-errors.tsv" | tr -d ' ')"
if [ "$cnt" -gt 0 ]; then
  echo "  ⚠️ chat 소비 실패 ${cnt}건 — 뺄셈으로 안 잡히는 유실이 있다"
  head -3 "$OUT/chat-consume-errors.tsv" | sed 's/^/     /'
else
  echo "  chat 소비 실패 없음 — 뺄셈 결과를 그대로 믿어도 된다"
fi

say "완료 — $OUT"
echo
echo "  k6 요약   : $OUT/*-summary.json"
echo "  커넥션 풀 : $OUT/pool.csv"
echo "  큐        : $OUT/queue.tsv"
echo "  스레드 덤프: $OUT/threaddump.txt"
echo "  집계      : $OUT/tally.tsv"
echo "  chat 오류 : $OUT/chat-consume-errors.tsv"
echo "  시각      : results/timeline.log"
