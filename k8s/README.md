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

### 이미지 build — 모노레포(`backend/`)

backend 서비스는 `backend/` 루트가 build context다. 각 서비스가 `:common` 을
소스로 의존하므로 모듈 디렉터리만 넘기면 `settings.gradle` 도 `common/` 도 안 보인다.

```bash
cd backend
for svc in user post chat riot match; do
  docker build -t gamehouse:$svc-develop -f $svc/Dockerfile .
done

cd ../frontend
docker build -t gamehouse:frontend-develop .

cd ../infra/rabbitmq
docker build -t gamehouse:rabbitmq-3-1 .
```

### 이미지 build — 서비스별 레포

MSA 레포 분리 후에는 **각 레포 루트가 곧 build context**다. `common` 은 함께
빌드되지 않고 **GitHub Packages 에서 받아온다**(`gg.duo:common`).

| 레포 | 포트 |
|---|---|
| `gamehouse-user` | 8081 |
| `gamehouse-post` | 8082 |
| `gamehouse-chat` | 8083 |
| `gamehouse-riot` | 8084 |
| `gamehouse-match` | 8085 |
| `gamehouse-common` | — (라이브러리, 이미지 없음) |

**사전 준비 — GPR 자격증명.** GitHub Packages 는 public 패키지도 읽기에 토큰이
필요하다. 없으면 `common` 을 못 받아 빌드가 실패한다.

토큰은 GitHub → Settings → Developer settings → **Personal access tokens (classic)**
에서 `read:packages` 만 체크해 만든다. fine-grained 토큰은 GitHub Packages 의 Maven
레지스트리를 아직 제대로 지원하지 않는다.

아래를 **통째로** 붙여넣는다. `아이디` 에는 GitHub 로그인 아이디(**이메일 아님**),
`PAT` 에는 토큰을 붙여넣고 엔터. **토큰은 화면에 안 보이는 게 정상이다.**

```bash
mkdir -p ~/.gradle && touch ~/.gradle/gradle.properties
printf 'GitHub 아이디: '; read GPR_USER
printf 'PAT (read:packages): '; read -s GPR_KEY; echo
{ grep -v '^gpr\.' ~/.gradle/gradle.properties || true; \
  echo "gpr.user=$GPR_USER"; echo "gpr.key=$GPR_KEY"; } > ~/.gradle/gp.new \
  && mv ~/.gradle/gp.new ~/.gradle/gradle.properties
unset GPR_USER GPR_KEY
```

기존 `gpr.*` 항목만 걷어내고 다시 넣으므로 여러 번 돌려도 중복되지 않고, 같은 파일의
다른 설정(`org.gradle.jvmargs` 등)은 그대로 남는다. `read -s` 라 토큰이 화면에도 셸
히스토리에도 남지 않는다. 이 파일은 레포가 아니라 홈 디렉터리에 있고, 머신당 한 번만
하면 서비스 레포 전체에 적용된다.

> ⚠️ **붙여넣는 블록에 `#` 주석을 넣지 않았다.** zsh 대화형 셸은 기본적으로 `#` 을 주석으로
> 보지 않아(`interactive_comments` 미설정), 주석이 명령으로 실행된다. 특히 `gpr.*` 같은
> 문자열은 glob 으로 해석되어 `zsh: no matches found: gpr.*` 가 뜬다 — 실제 명령은 그 뒤에
> 정상 실행되지만 실패한 것처럼 보인다.

확인 — 아이디가 찍히고 마지막 줄이 `1` 이면 된다:

```bash
grep '^gpr\.user' ~/.gradle/gradle.properties
grep -c '^gpr\.key=.\+' ~/.gradle/gradle.properties
```

빌드는 레포마다 돌린다. 모노레포와 달리 `-f` 로 Dockerfile 을 지정하지 않는다.

레포들이 같은 부모 디렉터리에 체크아웃되어 있다고 가정한다.

```bash
for svc in user post chat riot match; do
  ( cd gamehouse-$svc \
    && DOCKER_BUILDKIT=1 docker build \
         --secret id=gpr,src=$HOME/.gradle/gradle.properties \
         -t gamehouse:$svc-develop . )
done
```

> ⚠️ **토큰을 `--build-arg` 로 넘기지 말 것.** 이미지 레이어 히스토리에 평문으로 남는다.
> `--secret` 은 해당 `RUN` 동안만 마운트되고 레이어에 남지 않는다. 그래서
> `DOCKER_BUILDKIT=1` 이 필요하다 — 구형 빌더는 `--secret` 을 모른다.

이미지 태그(`gamehouse:<svc>-develop`)는 모노레포 때와 같다. **k8s 매니페스트는
레포 구조를 모르므로 `overlays/local` 은 그대로 쓴다** — `kind load` 이후 절차도 동일하다.

> `gamehouse-crew` 는 아직 비어 있다(`.git` 만 있음). 코드가 생기면 위 루프에 추가하고
> `base/kustomization.yaml` 의 `- crew` 도 함께 푼다.

### kind 기동 및 배포

```bash
cd infra
./scripts/k8s-local-up.sh
```

스크립트가 kind 클러스터 생성, ingress-nginx 설치, metrics-server 설치, 로컬 이미지
적재, `overlays/local` 적용, 롤아웃 대기를 수행한다.

수동으로 이미지를 적재해야 하는 경우:

```bash
for svc in user post chat riot match frontend; do
  kind load docker-image gamehouse:$svc-develop --name gamehouse-local
done

# rabbitmq 만 태그 형태가 다르다 — 브랜치가 아니라 리비전으로 굴린다
kind load docker-image gamehouse:rabbitmq-3-1 --name gamehouse-local
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
