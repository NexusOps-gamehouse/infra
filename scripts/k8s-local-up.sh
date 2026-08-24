#!/usr/bin/env bash
# 로컬 kind 클러스터에 GameHouse MSA 전체를 띄운다.
# 전제: docker, kind, kubectl, kustomize(또는 kubectl >=1.14 내장 -k) 설치되어 있음.
#
# 이 스크립트는 인프라(클러스터+ingress-nginx)만 준비한다. 6개 서비스 이미지는
# CI 가 nexusops0713/gamehouse-<service>:develop 로 push 해 둔 걸 그대로 당겨 쓴다.
# 로컬에서 직접 빌드한 이미지로 테스트하려면 각 backend/<service> 에서
# `docker build` 후 `kind load docker-image ... --name gamehouse-dev` 로 클러스터에 넣는다.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="gamehouse-dev"

echo "[1/4] kind 클러스터 생성/확인..."
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config "${INFRA_DIR}/kind-config.yaml"
else
  echo "  이미 존재 — 재사용"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

echo "[2/4] ingress-nginx 설치..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "[3/4] GameHouse MSA 매니페스트 적용 (overlays/dev)..."
kubectl apply -k "${INFRA_DIR}/k8s/overlays/dev"

echo "[4/4] 롤아웃 대기..."
# match / crew 는 base/kustomization.yaml 에서 빠져 있다 — 여기 두면 없는
# Deployment 를 180초씩 기다리다 만다. match / crew 는 추후 추가한다.
for svc in user post chat riot; do
  kubectl -n gamehouse rollout status deployment/"${svc}" --timeout=180s || true
done

cat <<'EOF'

완료.
  - /etc/hosts 에 `127.0.0.1 gamehouse.local` 추가했는지 확인
  - http://gamehouse.local 로 접속
  - kubectl -n gamehouse get pods 로 상태 확인
  - riot 는 dummy_key 로 떠 있음 — 실제 Riot API 연동을 테스트하려면
    `kubectl -n gamehouse create secret generic riot-secret \
       --from-literal=RIOT_API_KEY=<실제키> --dry-run=client -o yaml | kubectl apply -f -`
EOF
