#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 통과 기준 자동 확인
#
# "설치가 됐다" 와 "동작한다" 는 다르다.
# Alloy 는 대상을 못 찾아도, 권한이 없어도, Loki 주소가 틀려도 Running 이다.
# 그래서 데이터가 실제로 흐르는지까지 본다.
#
# [2026-09-01 개정]
#   - port-forward 실패를 무시하지 않는다. 실패하면 그 구간을 통째로 건너뛴다.
#     예전에는 실패해도 계속 진행해서 curl 이 옛 compose 스택의 Prometheus 에
#     붙어 성공했고, 진단이 통째로 틀어진 적이 있다.
#   - 포트를 29090 / 23100 / 29093 으로 옮겼다. 옛 compose 스택이 쓰던
#     19090 / 19100 / 18086 과 겹치지 않게 한다.
#   - 붙은 Prometheus 가 정말 이 클러스터의 것인지 확인한다(kubelet 타겟 존재).
#   - HPA 검사가 HPA 존재 여부를 먼저 확인한다. 예전에는 HPA 가 하나도 없어도
#     "정상" 으로 통과했다.
#   - 알람 파이프라인(규칙 로드 · Alertmanager 연결)을 확인 항목에 넣었다.
# ---------------------------------------------------------------------------
set -uo pipefail
NS=observability
APP_NS=gamehouse
PROM_PORT=29090
LOKI_PORT=23100
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
ng()   { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "  ·  $1"; }

# --- port-forward 헬퍼 ------------------------------------------------------
# 실패를 조용히 넘기지 않는 것이 이 헬퍼의 존재 이유다.
PF_PID=""; PF_LOG=""

pf_start() {   # $1=대상  $2=로컬포트  $3=원격포트  $4=표시이름
  local target="$1" lport="$2" rport="$3" name="$4" i
  PF_LOG=$(mktemp)

  # 이미 누가 그 포트를 쥐고 있으면 새 터널이 안 뜬다. 그런데도 curl 은 성공할 수
  # 있다 — 옛 port-forward 가 살아 있거나 다른 프로세스가 응답하기 때문이다.
  # 그 상태로 진행하면 엉뚱한 대상을 읽는다.
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$lport" -sTCP:LISTEN >/dev/null 2>&1; then
      ng "$name: 로컬 포트 $lport 가 이미 사용 중"
      info "누가 쥐고 있는지: lsof -nP -iTCP:$lport -sTCP:LISTEN"
      info "파드가 재시작되면 옛 port-forward 가 죽은 파드를 가리킨 채 남는다"
      rm -f "$PF_LOG"; PF_LOG=""
      return 1
    fi
  fi

  kubectl port-forward -n "$NS" "$target" "$lport:$rport" >"$PF_LOG" 2>&1 &
  PF_PID=$!

  for i in $(seq 1 20); do
    if grep -q "Forwarding from" "$PF_LOG" 2>/dev/null; then return 0; fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      ng "$name: port-forward 가 즉시 종료됐다"
      sed 's/^/       /' "$PF_LOG"
      PF_PID=""; rm -f "$PF_LOG"; PF_LOG=""
      return 1
    fi
    sleep 0.5
  done

  ng "$name: port-forward 가 10초 안에 준비되지 않았다"
  sed 's/^/       /' "$PF_LOG"
  pf_stop
  return 1
}

pf_stop() {
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; fi
  if [ -n "$PF_LOG" ]; then rm -f "$PF_LOG"; fi
  PF_PID=""; PF_LOG=""
}
trap pf_stop EXIT

echo "═══ 1. 파드 상태 ═══"
NOTREADY=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
  | awk '$3!="Running" && $3!="Completed" {print $1" ("$3")"}')
if [ -z "$NOTREADY" ]; then ok "observability 파드 전부 Running"
else ng "Running 아닌 파드:"; echo "$NOTREADY" | sed 's/^/       /'; fi

echo
echo "═══ 2. Loki 서비스 이름 ═══"
# values 에 하드코딩한 주소가 실제와 맞는지. 틀리면 Alloy 는 뜨는데 로그가 0건이다.
if kubectl get svc -n "$NS" loki >/dev/null 2>&1; then
  ok "svc/loki 존재 — values 의 loki.write URL 과 일치"
else
  ng "'loki' 서비스가 없음 — alloy/grafana values 의 URL 을 고쳐야 함"
  kubectl get svc -n "$NS" 2>/dev/null | grep -i loki | sed 's/^/       /'
fi

echo
echo "═══ 3. Prometheus — 수집 대상 · 규칙 · 알림 경로 ═══"
if pf_start svc/kps-prometheus "$PROM_PORT" 9090 "Prometheus"; then
  P="http://127.0.0.1:$PROM_PORT"

  # ⚠️ 붙은 Prometheus 가 정말 이 클러스터의 것인지 먼저 확인한다.
  #    옛 compose 스택의 Prometheus 에는 kubelet 타겟이 없다.
  KUBELET=$(curl -s --max-time 5 "$P/api/v1/query?query=up%7Bjob%3D%22kubelet%22%7D" 2>/dev/null | grep -c '"metric"')
  if [ "${KUBELET:-0}" -eq 0 ]; then
    ng "kubelet 타겟이 없다 — 이 Prometheus 가 kind 클러스터의 것이 아닐 수 있다"
    info "옛 compose 스택이 떠 있지 않은지 확인: docker ps | grep prometheus"
  else
    ok "kind 클러스터의 Prometheus 가 맞다 (kubelet 타겟 확인)"

    T=$(curl -s --max-time 5 "$P/api/v1/targets" 2>/dev/null)
    if [ -n "$T" ]; then
      UP=$(printf '%s' "$T" | grep -o '"health":"up"' | wc -l | tr -d ' ')
      DN=$(printf '%s' "$T" | grep -o '"health":"down"' | wc -l | tr -d ' ')
      [ "$UP" -gt 0 ] && ok "UP 타겟 $UP 개" || ng "UP 타겟 없음"
      if [ "$DN" -gt 0 ]; then
        ng "DOWN 타겟 $DN 개 — etcd/scheduler 계열이면 values 에서 껐는지 확인"
      else ok "DOWN 타겟 없음"; fi
    else ng "Prometheus targets API 응답 없음"; fi

    KSM=$(curl -s --max-time 5 "$P/api/v1/query?query=kube_deployment_status_replicas_available" 2>/dev/null | grep -c '"metric"')
    if [ "${KSM:-0}" -gt 0 ]; then
      ok "kube-state-metrics 동작 — EC2 때 없던 '선언 대 실제' 지표"
    else info "kube-state-metrics 지표 없음 (Deployment 가 아직 없으면 정상)"; fi

    # 알람 규칙이 실제로 로드됐는가. 평가 오류가 있으면 health 가 ok 가 아니다.
    R=$(curl -s --max-time 5 "$P/api/v1/rules" 2>/dev/null)
    GH=$(printf '%s' "$R" | grep -o '"name":"gamehouse-[a-z]*"' | wc -l | tr -d ' ')
    BAD=$(printf '%s' "$R" | grep -o '"health":"err"' | wc -l | tr -d ' ')
    if [ "${GH:-0}" -gt 0 ]; then
      ok "gamehouse 알람 규칙 그룹 $GH 개 로드됨"
      [ "${BAD:-0}" -eq 0 ] && ok "규칙 평가 오류 없음" || ng "평가 오류 규칙 $BAD 개"
    else
      info "gamehouse 알람 규칙이 없음 (PrometheusRule 미배포면 정상)"
    fi

    # 규칙이 firing 돼도 보낼 곳을 모르면 소용이 없다.
    AMC=$(curl -s --max-time 5 "$P/api/v1/alertmanagers" 2>/dev/null | grep -o '"url"' | wc -l | tr -d ' ')
    ACTIVE=$(curl -s --max-time 5 "$P/api/v1/alertmanagers" 2>/dev/null \
      | sed 's/"droppedAlertmanagers".*//' | grep -o '"url"' | wc -l | tr -d ' ')
    if [ "${ACTIVE:-0}" -gt 0 ]; then
      ok "Alertmanager 연결됨 (active $ACTIVE)"
    else
      info "Alertmanager 없음 — LOWMEM 으로 껐다면 정상. 규칙 평가는 계속된다"
    fi
  fi
  pf_stop
fi

echo
echo "═══ 4. Loki 에 로그가 실제로 들어오는가 ═══"
if pf_start svc/loki "$LOKI_PORT" 3100 "Loki"; then
  L=$(curl -s --max-time 5 "http://127.0.0.1:$LOKI_PORT/loki/api/v1/labels" 2>/dev/null)
  if printf '%s' "$L" | grep -q '"namespace"'; then
    ok "namespace 라벨 존재 → Alloy 가 밀어넣고 있음"
    NSV=$(curl -s --max-time 5 "http://127.0.0.1:$LOKI_PORT/loki/api/v1/label/namespace/values" 2>/dev/null)
    info "수집 중: $(printf '%s' "$NSV" | tr -d '{}"' | sed 's/.*data://')"
    if printf '%s' "$L" | grep -q '"app"'; then
      ok "app 라벨 존재 → 메트릭의 job 라벨과 짝이 맞음"
    else
      info "app 라벨 없음"
      info "→ 매니페스트가 app.kubernetes.io/name 을 쓰는지 확인:"
      info "   kubectl get deploy -n $APP_NS --show-labels"
    fi
  else
    ng "Loki 에 라벨 없음 → 로그가 하나도 안 들어옴"
    info "확인: kubectl logs -n $NS ds/alloy --tail=50"
  fi
  pf_stop
fi

echo
echo "═══ 5. 기존 앱과의 공존 ═══"
if kubectl get ns "$APP_NS" >/dev/null 2>&1; then
  # ⚠️ HPA 가 하나도 없으면 <unknown> 도 0 개다. 예전에는 그 상태가 "정상" 으로
  #    통과했다. 대상이 있는지를 먼저 센다.
  HPA_ALL=$(kubectl get hpa -n "$APP_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${HPA_ALL:-0}" -eq 0 ]; then
    info "HPA 가 없음 (앱 배포 전이면 정상) — metrics-server 검사를 건너뛴다"
  else
    HPA_UNK=$(kubectl get hpa -n "$APP_NS" --no-headers 2>/dev/null | grep -c "<unknown>")
    if [ "${HPA_UNK:-0}" -eq 0 ]; then ok "HPA $HPA_ALL 개 TARGETS 정상 — metrics-server 영향 없음"
    else ng "HPA TARGETS 가 <unknown> ($HPA_UNK/$HPA_ALL 개) — metrics-server 확인"; fi
  fi
else info "$APP_NS 네임스페이스 없음 (앱 배포 전이면 정상)"; fi

echo
echo "═══ 결과 ═══"
echo "  통과 $PASS · 실패 $FAIL"
echo
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 관측 스택 정상."
  echo "   Grafana:      kubectl -n $NS port-forward svc/kps-grafana 23000:80"
  echo "   Prometheus:   kubectl -n $NS port-forward svc/kps-prometheus $PROM_PORT:9090"
  echo "   Explore 에서 {namespace=\"gamehouse\"} 을 쳐본다."
else
  echo "❌ 아래 출력을 그대로 붙여서 물어보면 된다:"
  echo "   kubectl get pods -n $NS"
  echo "   kubectl logs -n $NS ds/alloy --tail=50"
fi
