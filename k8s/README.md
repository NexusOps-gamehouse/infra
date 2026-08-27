# GameHouse Kubernetes

GameHouse MSA의 Kubernetes 매니페스트와 local/dev/prod 환경별 overlay를 관리한다.

## 환경

| 환경 | 클러스터 | 인프라 | 이미지 |
|---|---|---|---|
| `local` | kind | ingress-nginx, in-cluster PostgreSQL | 로컬 build + `kind load` |
| `dev` | EKS | ALB, RDS, External Secrets | CI SHA tag |
| `prod` | EKS | ALB, RDS, External Secrets | CI SHA tag |

`crew`는 매니페스트만 준비되어 있고 현재 배포 대상에서 제외되어 있다 (backend 모듈 없음).
`prod`에는 frontend Deployment가 없으며 S3/CloudFront 배포를 전제로 한다.

## local 실행

사전 요구사항:

```bash
brew install kind kubectl kustomize
echo "127.0.0.1 gamehouse.local" | sudo tee -a /etc/hosts
```

### 이미지 build

backend 서비스는 `backend/` 루트가 build context다.

```bash
cd backend
for svc in user post chat riot match; do
  docker build -t gamehouse:$svc-develop -f $svc/Dockerfile .
done

cd ../frontend
docker build -t gamehouse:frontend-develop .

cd ../infra/rabbitmq
docker build -t gamehouse:rabbitmq-develop .
```

### kind 기동 및 배포

```bash
cd infra
./scripts/k8s-local-up.sh
```

스크립트가 kind 클러스터 생성, ingress-nginx 설치, metrics-server 설치, 로컬 이미지
적재, `overlays/local` 적용, 롤아웃 대기를 수행한다.

수동으로 이미지를 적재해야 하는 경우:

```bash
for svc in user post chat riot match frontend rabbitmq; do
  kind load docker-image gamehouse:$svc-develop --name gamehouse-local
done
```

### 외부 API 키

`overlays/local`의 Secret은 전부 더미다 — 이 저장소는 public이라 실제 키를 커밋할 수 없다.
실제 키는 **`infra/.env.k8s.local`** 에 둔다(`.gitignore` 대상).

```bash
cp infra/.env.k8s.local.example infra/.env.k8s.local
# RIOT_API_KEY, LLM_API_KEY 를 채운다
```

compose용 `.env`와 분리한 이유: compose는 구 모놀리스 `backend` 하나만 띄운다 —
`match` 자체가 없어서 `LLM_API_KEY`가 거기선 의미가 없다. 반대로 `.env`의
`DB_HOST`/`FRONTEND_*`는 kind에서 의미가 없다.

`RIOT_API_KEY`처럼 양쪽이 같은 키를 쓰는 경우 두 번 적을 필요는 없다 —
`.env.k8s.local`에 없으면 `.env`로 폴백하고, 어느 파일에서 읽었는지 출력한다.

`k8s-local-up.sh`가 apply 직후 `k8s-local-secrets.sh`를 호출해 클러스터에 밀어 넣는다.
키만 바꿀 때는 이것만 다시 돌리면 된다 — 클러스터를 다시 만들 필요가 없다.

```bash
./scripts/k8s-local-secrets.sh
```

| 키 | 없으면 |
|---|---|
| `RIOT_API_KEY` | riot 연동만 빠진다 |
| `LLM_API_KEY` | match의 AI 설명이 규칙 기반 문구로 대체된다 |

둘 다 없어도 클러스터는 정상 기동한다. **파드는 뜨는데 기능만 조용히 빠지는 형태**라
연동을 테스트할 때는 값이 실제로 들어갔는지 먼저 확인한다.

DB·JWT·RabbitMQ는 일부러 동기화하지 않는다. kind의 in-cluster postgres는
`overlays/local/postgres.yaml`의 계정으로 부트스트랩되므로, compose용 `.env` 값으로
덮어쓰면 오히려 연결이 깨진다.

## 확인

```bash
kubectl -n gamehouse get pods
kubectl -n gamehouse get svc
kubectl -n gamehouse get ingress
kubectl -n gamehouse get hpa
open http://gamehouse.local
```

모든 활성 서비스 Pod가 `Running`이고 HPA의 `TARGETS`가 `<unknown>`이 아니어야 한다.

코드 변경 후에는 클러스터를 다시 만들 필요 없이 해당 이미지만 build/load하고 롤아웃을
재시작한다.

```bash
cd backend
docker build -t gamehouse:user-develop -f user/Dockerfile .
kind load docker-image gamehouse:user-develop --name gamehouse-local
kubectl -n gamehouse rollout restart deployment/user
kubectl -n gamehouse rollout status deployment/user
```

## 매니페스트 검증

```bash
kubectl kustomize k8s/overlays/local >/tmp/gamehouse-local.yaml
kubectl kustomize k8s/overlays/dev >/tmp/gamehouse-dev.yaml
kubectl kustomize k8s/overlays/prod >/tmp/gamehouse-prod.yaml
```

local 클러스터에 서버 검증만 수행:

```bash
kubectl apply -k k8s/overlays/local --dry-run=server
```

## dev/prod 이미지 주입

prod의 `REPLACE_AT_DEPLOY`는 실제 tag가 아니라 의도적인 placeholder다. CI가 배포 전에
서비스별 SHA tag를 주입해야 한다.

```bash
cd k8s/overlays/prod
kustomize edit set image \
  gamehouse-user=nexusops0713/gamehouse:user-$GIT_SHA
kubectl apply -k .
```

private Docker Hub pull 인증은 `components/aws`의 ExternalSecret과
`imagePullSecrets`가 담당한다. AWS Secrets Manager에 환경별 read-only Docker Hub
토큰이 먼저 등록되어 있어야 한다.

## 스크립트 구분

- `scripts/k8s-local-up.sh`: local kind 클러스터 준비 및 local overlay 배포
- `scripts/deploy.sh`: 기존 EC2 Docker Compose 배포용

## 정리

```bash
kind delete cluster --name gamehouse-local
```
