#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Argo CD 를 kind 클러스터(gamehouse-local)에 설치한다.
#
# 전제: ./scripts/k8s-local-up.sh 가 먼저 돌아 클러스터가 떠 있어야 한다.
#       (이 스크립트는 클러스터를 만들지 않는다)
#
# k8s-local-up.sh 와 일부러 분리했다. 클러스터 층과 워크로드 층을 나누는 것과
# 같은 이유로, Argo CD 는 워크로드가 아니라 그 둘 사이의 애드온 층이다.
# 클러스터를 다시 만들지 않고 Argo CD 만 다시 깔 수 있어야 한다.
#
# ---------------------------------------------------------------------------
# ⚠️ EKS 용을 만들 때 이 파일을 복사하지 말 것
#
# 환경마다 Argo CD 를 그 클러스터 안에 하나씩 두므로 dev/prod 에도 설치가 필요해진다.
# 그때 이 파일을 복사해 k8s-dev-argocd.sh 를 만들면 아래 CHART_VERSION 이 갈라진다.
# 하나만 올리고 나머지를 잊는 순간, CI 의 KUSTOMIZE_VERSION 은 한 환경하고만 맞게 되고
# 나머지는 "CI 는 통과했는데 클러스터에는 다른 결과" 상태가 된다. 조용히 어긋나므로
# 알아채기 어렵다.
#
# 복사 대신 이 스크립트를 환경 인자를 받도록 일반화한다:
#   ./scripts/k8s-argocd-install.sh local|dev|prod
#
# 단 컨텍스트 처리는 환경마다 반대로 가야 한다. 아래 use-context 처럼 자동 전환하는 것은
# 로컬에서만 안전하다. dev/prod 는 현재 컨텍스트를 쓰되 이름을 보여주고 확인을 받는다 —
# 스크립트가 알아서 컨텍스트를 바꾸면 그 뒤에 치는 모든 kubectl 이 prod 를 향하게 된다.
#
# values 파일도 환경마다 필요하다(도메인·ALB·TLS·SSO). 다만 첫 설치는 values 없이
# 기본값 + `kubectl port-forward` 로도 동작한다 — 동기화 기능은 values 와 무관하다.
# ---------------------------------------------------------------------------
set -euo pipefail

NS=argocd
CLUSTER=gamehouse-local
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="$HERE/../k8s/platform/values"

# ---------------------------------------------------------------------------
# 차트 버전을 고정한다.
#
# 고정하지 않으면 helm repo update 시점의 최신 차트가 깔려서, 같은 명령이
# 시점마다 다른 결과를 낸다. "클러스터를 지우고 다시 만들어도 같은 명령 하나로
# 복원된다"가 성립하지 않는다.
#
# 차트 10.5.0 = Argo CD v3.5.2 = 번들 kustomize 5.8.1
#   ⚠️ 그 kustomize 버전이 .github/workflows/k8s-ci.yml 의 KUSTOMIZE_VERSION 과
#      같아야 한다. 어긋나면 CI 는 통과했는데 클러스터에는 다른 결과가 적용된다.
#      설치 후 아래로 확인:
#        kubectl -n argocd exec deploy/argocd-repo-server -- kustomize version
# ---------------------------------------------------------------------------
CHART_VERSION=10.5.0

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
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

echo "▶ Argo CD (차트 $CHART_VERSION)"
helm upgrade --install argocd argo/argo-cd \
  --version "$CHART_VERSION" \
  -n "$NS" -f "$VALUES/argocd.local.yaml" \
  --wait --timeout 10m

echo
echo "✅ 설치 완료"
echo
echo "   /etc/hosts 에 아래 한 줄이 필요하다 (gamehouse.local 과 같은 방식):"
echo "     127.0.0.1 argocd.local"
echo
echo "   UI:       http://argocd.local"
echo "   ID:       admin"
echo "   비밀번호: kubectl -n $NS get secret argocd-initial-admin-secret \\"
echo "               -o jsonpath='{.data.password}' | base64 -d; echo"
echo
echo "   kustomize 버전 대조:"
echo "     kubectl -n $NS exec deploy/argocd-repo-server -- kustomize version"
