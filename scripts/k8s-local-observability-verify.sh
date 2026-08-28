#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 통과 기준 자동 확인
#
# "설치가 됐다" 와 "동작한다" 는 다르다.
# Alloy 는 대상을 못 찾아도, 권한이 없어도, Loki 주소가 틀려도 Running 이다.
# 그래서 데이터가 실제로 흐르는지까지 본다.
# ---------------------------------------------------------------------------
set -uo pipefail
NS=observability
APP_NS=gamehouse
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
ng()   { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "  ·  $1"; }

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
echo "═══ 3. Prometheus 수집 대상 ═══"
kubectl port-forward -n "$NS" svc/kps-prometheus 19090:9090 >/dev/null 2>&1 &
PF=$!; sleep 4
T=$(curl -s --max-time 5 http://127.0.0.1:19090/api/v1/targets 2>/dev/null)
if [ -n "$T" ]; then
  UP=$(printf '%s' "$T" | grep -o '"health":"up"' | wc -l | tr -d ' ')
  DN=$(printf '%s' "$T" | grep -o '"health":"down"' | wc -l | tr -d ' ')
  [ "$UP" -gt 0 ] && ok "UP 타겟 $UP 개" || ng "UP 타겟 없음"
  if [ "$DN" -gt 0 ]; then
    ng "DOWN 타겟 $DN 개 — etcd/scheduler 계열이면 values 에서 껐는지 확인"
  else ok "DOWN 타겟 없음"; fi
  KSM=$(curl -s --max-time 5 "http://127.0.0.1:19090/api/v1/query?query=kube_deployment_status_replicas_available" 2>/dev/null | grep -c '"metric"')
  if [ "${KSM:-0}" -gt 0 ]; then
    ok "kube-state-metrics 동작 — EC2 때 없던 '선언 대 실제' 지표"
    info "이제 frontend 생존을 absent(container_last_seen) 편법 없이 볼 수 있다"
  else info "kube-state-metrics 지표 없음 (Deployment 가 아직 없으면 정상)"; fi
else ng "Prometheus API 응답 없음"; fi
kill $PF 2>/dev/null; wait $PF 2>/dev/null

echo
echo "═══ 4. Loki 에 로그가 실제로 들어오는가 ═══"
kubectl port-forward -n "$NS" svc/loki 13100:3100 >/dev/null 2>&1 &
PF=$!; sleep 4
L=$(curl -s --max-time 5 http://127.0.0.1:13100/loki/api/v1/labels 2>/dev/null)
if printf '%s' "$L" | grep -q '"namespace"'; then
  ok "namespace 라벨 존재 → Alloy 가 밀어넣고 있음"
  NSV=$(curl -s --max-time 5 http://127.0.0.1:13100/loki/api/v1/label/namespace/values 2>/dev/null)
  info "수집 중: $(printf '%s' "$NSV" | tr -d '{}"' | sed 's/.*data://')"
  if printf '%s' "$L" | grep -q '"app"'; then
    ok "app 라벨 존재 → 메트릭의 application 태그와 짝이 맞음"
  else
    info "app 라벨 없음"
    info "→ 기존 매니페스트가 app.kubernetes.io/name 을 안 쓰는지 확인:"
    info "   kubectl get deploy -n $APP_NS --show-labels"
    info "   다르면 alloy values 의 relabel rule 을 그 라벨로 바꾼다"
  fi
else
  ng "Loki 에 라벨 없음 → 로그가 하나도 안 들어옴"
  info "확인: kubectl logs -n $NS ds/alloy --tail=50"
fi
kill $PF 2>/dev/null; wait $PF 2>/dev/null

echo
echo "═══ 5. 기존 앱과의 공존 ═══"
if kubectl get ns "$APP_NS" >/dev/null 2>&1; then
  HPA=$(kubectl get hpa -n "$APP_NS" --no-headers 2>/dev/null | grep -c "<unknown>")
  if [ "${HPA:-0}" -eq 0 ]; then ok "HPA TARGETS 정상 — metrics-server 영향 없음"
  else ng "HPA TARGETS 가 <unknown> ($HPA 개) — metrics-server 확인"; fi
else info "$APP_NS 네임스페이스 없음 (앱 배포 전이면 정상)"; fi

echo
echo "═══ 결과 ═══"
echo "  통과 $PASS · 실패 $FAIL"
echo
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 플랫폼 준비 완료. 이제 서비스를 하나씩 붙인다."
  echo "   Grafana: kubectl -n $NS port-forward svc/kps-grafana 3000:80"
  echo "   Explore 에서 {namespace=\"kube-system\"} 을 쳐본다."
else
  echo "❌ 아래 출력을 그대로 붙여서 물어보면 된다:"
  echo "   kubectl get pods -n $NS"
  echo "   kubectl logs -n $NS ds/alloy --tail=50"
fi
