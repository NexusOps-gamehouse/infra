#!/usr/bin/env bash
# 로컬 kind 클러스터에 GameHouse MSA 전체를 띄운다.
# 전제: docker, kind, kubectl, kustomize(또는 kubectl >=1.14 내장 -k) 설치되어 있음.
#
# 이 스크립트는 인프라(클러스터+ingress-nginx)만 준비한다. 서비스 이미지는 backend/
# 에서 직접 빌드해 `kind load docker-image <이미지> --name gamehouse-local` 로 노드에
# 적재한다 — overlays/local 은 레지스트리를 타지 않는다(이유는 그 kustomization.yaml 참고).
#
# 환경 3단 중 첫 단계다: local(kind) → dev(EKS) → prod(EKS).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="gamehouse-local"

echo "[1/6] kind 클러스터 생성/확인..."
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config "${INFRA_DIR}/kind-config.yaml"
else
  echo "  이미 존재 — 재사용"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

echo "[2/6] ingress-nginx 설치..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
# `kubectl wait --for=condition=ready pod --selector=...` 를 쓰면 안 된다.
# apply 직후에는 파드가 아직 생성되지 않았는데, kubectl wait 는 셀렉터에 걸리는
# 오브젝트가 0개면 기다리지 않고 즉시 "no matching resources found" 로 죽는다
# (set -e 라 스크립트 전체가 여기서 멈춘다). Deployment 오브젝트는 apply 직후
# 바로 존재하므로 rollout status 에는 그 경쟁 상태가 없다.
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

echo "[3/6] metrics-server 설치..."
# HPA 는 스스로 사용량을 재지 않는다. metrics-server 가 각 노드의 kubelet 에서
# 긁어 Metrics API 로 노출해야 HPA 가 requests 대비 비율을 계산할 수 있다.
# 없으면 HPA 가 TARGETS 에 <unknown> 을 띄운 채 영원히 멈춘다 — 파드도 HPA
# 오브젝트도 정상이라 에러가 안 나서 알아채기 어렵다.
#
# ⚠️ --kubelet-insecure-tls 는 kind 전용 우회다. kind 노드의 kubelet 은 자체
#    서명 인증서를 쓰는데 metrics-server 가 그걸 검증하지 못해
#    "x509: certificate signed by unknown authority" 로 계속 실패한다.
#    EKS 는 정상 인증서 체인이 있으므로 이 플래그를 절대 쓰지 않는다.
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

echo "[4/6] 로컬 이미지 적재..."
# overlays/local 은 레지스트리를 타지 않는다 — 호스트에서 빌드한 이미지를 노드에
# 직접 넣어야 파드가 뜬다. 여기서 안 넣고 apply 하면 [6/6] 이 ErrImageNeverPull 인
# 파드를 서비스마다 180초씩 기다리다 만다.
MISSING=()
for img in user post chat riot frontend rabbitmq; do
  if docker image inspect "gamehouse:${img}-develop" >/dev/null 2>&1; then
    kind load docker-image "gamehouse:${img}-develop" --name "${CLUSTER_NAME}"
  else
    MISSING+=("gamehouse:${img}-develop")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo
  echo "  ⚠️  아래 이미지가 호스트에 없다 — 해당 파드는 ErrImageNeverPull 로 남는다:"
  printf '       %s\n' "${MISSING[@]}"
  echo "     backend/ 루트에서: docker build -t gamehouse:<svc>-develop -f <svc>/Dockerfile ."
  echo
fi

echo "[5/6] GameHouse MSA 매니페스트 적용 (overlays/local)..."
kubectl apply -k "${INFRA_DIR}/k8s/overlays/local"

echo "[6/6] 롤아웃 대기..."
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
