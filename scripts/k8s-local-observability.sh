#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 관측 스택을 kind 클러스터(gamehouse-local)에 설치한다.
#
# 전제: ./scripts/k8s-local-up.sh 가 먼저 돌아 클러스터가 떠 있어야 한다.
#       (이 스크립트는 클러스터를 만들지 않는다)
#
# 명명 규칙은 기존 스크립트를 따랐다:
#   k8s-local-up.sh  /  k8s-local-secrets.sh  /  k8s-local-observability.sh
#
# 키만 다시 넣을 때 secrets 스크립트만 돌리듯, 관측 스택만 다시 깔 때
# 이것만 돌리면 된다. 클러스터를 다시 만들 필요가 없다.
# ---------------------------------------------------------------------------
set -euo pipefail

NS=observability
CLUSTER=gamehouse-local
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="$HERE/../k8s/platform/values"

# ---------------------------------------------------------------------------
# Docker Desktop 메모리가 8GiB 미만이면 LOWMEM=1 로 돌린다.
#   LOWMEM=1 ./scripts/k8s-local-observability.sh
#
# 관측 스택이 약 2.5GiB → 1.3GiB 로 줄어든다. Alertmanager 를 끄고
# 보관 기간을 12h 로 줄이는 것이라, 지금 단계에서 잃는 것은 없다.
# ---------------------------------------------------------------------------
LOWMEM="${LOWMEM:-0}"
KPS_EXTRA=(); LOKI_EXTRA=(); ALLOY_EXTRA=()

# ⚠️ 아래 helm 호출에서 배열을 그냥 확장하면 안 된다. macOS 기본 bash 3.2 는
#    **빈 배열의 확장을 set -u 위반으로 본다** — "unbound variable" 로 죽는다.
#    bash 4.4 에서 고쳐졌지만 macOS 는 라이선스 때문에 3.2 에 묶여 있다.
#    그래서 arr[@]+... 형태로 "비어 있으면 아무 인자도 안 넘긴다" 를 명시한다.
#    LOWMEM=1 일 때만 값이 차므로, 기본 경로(LOWMEM=0)가 바로 이 경우다.
if [ "$LOWMEM" = "1" ]; then
  echo "▶ 저메모리 모드"
  KPS_EXTRA=(-f "$VALUES/lowmem.local.yaml")
  LOKI_EXTRA=(-f "$VALUES/loki.lowmem.local.yaml")
  ALLOY_EXTRA=(-f "$VALUES/alloy.lowmem.local.yaml")
fi

# --- 클러스터 확인 ---------------------------------------------------------
CTX="kind-$CLUSTER"
if ! kubectl config get-contexts -o name | grep -qx "$CTX"; then
  echo "❌ kind 컨텍스트 '$CTX' 가 없다. 먼저 ./scripts/k8s-local-up.sh 를 돌린다."
  exit 1
fi
kubectl config use-context "$CTX" >/dev/null
echo "▶ 컨텍스트: $CTX"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# --- Helm ------------------------------------------------------------------
echo "▶ Helm 저장소"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "▶ 1/3 kube-prometheus-stack"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n "$NS" -f "$VALUES/kube-prometheus-stack.local.yaml" "${KPS_EXTRA[@]+"${KPS_EXTRA[@]}"}" \
  --wait --timeout 10m

echo "▶ 2/3 Loki"
helm upgrade --install loki grafana/loki \
  -n "$NS" -f "$VALUES/loki.local.yaml" "${LOKI_EXTRA[@]+"${LOKI_EXTRA[@]}"}" \
  --wait --timeout 10m

# Alloy 는 Loki 가 준비된 뒤에. 먼저 올리면 push 실패 재시도 로그만 쌓인다.
echo "▶ 3/3 Alloy"
helm upgrade --install alloy grafana/alloy \
  -n "$NS" -f "$VALUES/alloy.local.yaml" "${ALLOY_EXTRA[@]+"${ALLOY_EXTRA[@]}"}" \
  --wait --timeout 5m

echo
echo "✅ 설치 완료"
echo
echo "   확인:   ./scripts/k8s-local-observability-verify.sh"
echo "   Grafana: kubectl -n $NS port-forward svc/kps-grafana 3000:80"
echo "            http://localhost:3000  (admin / admin)"
