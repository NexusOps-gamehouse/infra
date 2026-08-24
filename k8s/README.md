# GameHouse MSA — k8s 매니페스트

설계 문서("GameHouse MSA 디렉터리 구조") 섹션 10~13을 기준으로 생성했다.
백엔드가 아직 Gradle 멀티모듈로 쪼개지지 않았어도(섹션 13의 1~2단계 전) 이 트리 자체는
독립적으로 검증 가능하다 — `kustomize build` 로 세 트리 모두 확인했다.

```
infra/
├── kind-config.yaml          local 클러스터(kind) 정의
├── rabbitmq/Dockerfile       기존 그대로(stomp+prometheus 플러그인)
├── scripts/
│   ├── deploy.sh             기존 EC2 docker-compose 배포 스크립트(그대로 둠 — 섹션13
│   │                         3~5단계까지는 모놀리스가 여전히 compose 로 돈다)
│   └── k8s-local-up.sh       ★ kind 클러스터 생성 + ingress-nginx + overlays/local 적용
└── k8s/
    ├── base/                 서비스(현재 4개) + rabbitmq + redis + 네임스페이스 전역 정책
    ├── components/
    │   └── aws/              EKS 공통 구성 — ALB Ingress, External Secrets, PDB,
    │                         base placeholder Secret 삭제. dev/prod 가 함께 쓴다.
    └── overlays/
        ├── local/            kind + ingress-nginx + in-cluster postgres + frontend Pod
        ├── dev/              EKS + ALB + RDS + External Secrets. prod 리허설.
        └── prod/             EKS + ALB + RDS + External Secrets (frontend 없음)
```

## 환경 3단 — local → dev → prod

| | local | dev | prod |
|---|---|---|---|
| 클러스터 | kind (개발자 노트북) | EKS (전용) | EKS (전용) |
| 인그레스 | ingress-nginx | ALB | ALB |
| DB | in-cluster postgres | 전용 RDS | 전용 RDS |
| 시크릿 | 평문 더미 patch | ESO ← `gamehouse/dev/*` | ESO ← `gamehouse/prod/*` |
| 이미지 | 로컬 빌드 + `kind load` | `<svc>-<sha>` (CI가 지정) | `<svc>-<sha>` (CI가 지정) |
| replicas | 1 | 2 | 3 |

**왜 dev 가 따로 필요한가.** local(kind) 이 검증하는 범위는 `base/` 뿐이다 — 프로브,
NetworkPolicy, 서비스 디스커버리, 컨테이너 env 조립, 롤아웃. ALB 애노테이션, IRSA,
External Secrets, RDS 계정·권한은 kind 에서 **원리적으로** 한 줄도 밟히지 않는다.

**왜 component 인가 (dev 가 prod 를 상속하지 않는 이유).** `overlays/dev` 가
`resources: ../prod` 로 prod 를 상속하면 prod 의 `images:` 트랜스포머가 먼저 돌아
`gamehouse-user`·`gamehouse-post` 가 전부 `nexusops0713/gamehouse` 로 바뀐 뒤에 dev 가
매칭을 시도하게 된다 — 아래 "이미지 참조" 항목의 그 충돌이 그대로 재현된다.
component 는 트랜스포머를 상속하지 않으므로 각 오버레이가 base 의 논리 이름에 직접
매칭할 수 있다. 공유 목적(dev/prod 드리프트 방지)은 `components/aws` 가 그대로 맡는다.

**dev 와 prod 가 달라도 되는 것은 값뿐이다** — AWS 리소스 좌표(ACM/IAM ARN, ALB
`group.name`, Secrets Manager 경로), 규모(replicas/HPA/PDB), 도메인. 구조가 갈리기
시작하면 리허설의 의미가 없어지므로, 새 리소스나 애노테이션은 `components/aws` 에
넣는 것이 원칙이다.

## 로컬(kind)에서 띄우기

### 0. 사전 준비

```bash
brew install kind kubectl        # docker 는 이미 떠 있어야 한다
echo "127.0.0.1 gamehouse.local" | sudo tee -a /etc/hosts
```

`kustomize` 는 따로 설치하지 않아도 된다 — `kubectl` 에 내장돼 있고(`kubectl kustomize`,
`kubectl apply -k`), 이 트리는 kustomize v5 기능(`components`, `replacements`)을 쓰므로
**kubectl 1.27 이상**이 필요하다. `kubectl version --client` 로 확인한다.

### 1. 이미지 빌드 — 클러스터를 만들기 전에 한다

`overlays/local` 은 **레지스트리를 타지 않는다.** 로컬에서 빌드한 이미지를 kind 노드에
직접 적재하는 방식이라, 이미지가 없으면 파드가 `ErrImageNeverPull`/`ImagePullBackOff` 로
멈춘다. 이유는 두 가지다.

1. 도커허브 레포가 비공개라 `imagePullSecrets` 가 필요한데 아직 없다.
2. CI 가 `platforms: linux/amd64` 단일 빌드라, Apple Silicon 의 arm64 kind 노드에서는
   `no matching manifest for linux/arm64` 로 pull 이 실패한다.

백엔드 4개는 **컨텍스트가 `backend/` 루트**다(`common` 모듈을 참조하므로 서비스
디렉터리에서 빌드하면 깨진다).

```bash
cd backend
for svc in user post chat riot; do
  docker build -t gamehouse:$svc-develop -f $svc/Dockerfile .
done

cd frontend
docker build -t gamehouse:frontend-develop .

cd infra/rabbitmq
docker build -t gamehouse:rabbitmq-develop .
```

`postgres:16` 과 `redis:7-alpine` 은 공개 이미지라 kind 가 알아서 당겨 온다.

### 2. 클러스터 생성 + 이미지 적재 + 배포

```bash
cd infra
./scripts/k8s-local-up.sh
```

스크립트가 하는 일: kind 클러스터 생성 → ingress-nginx 설치 → metrics-server 설치 →
**1단계에서 빌드한 이미지를 노드에 적재** → `overlays/local` 적용 → 롤아웃 대기. 이미지 적재를 apply
전에 하는 이유는, 순서가 뒤집히면 `ErrImageNeverPull` 인 파드를 서비스마다 180초씩
기다리게 되기 때문이다. 빠진 이미지가 있으면 목록을 찍어 주고 계속 진행한다.

수동으로 하려면:

```bash
kind create cluster --name gamehouse-local --config kind-config.yaml
for img in user post chat riot frontend rabbitmq; do
  kind load docker-image gamehouse:$img-develop --name gamehouse-local
done
kubectl apply -k k8s/overlays/local
```

### 3. 확인

```bash
kubectl -n gamehouse get pods            # 전부 Running 이어야 한다
kubectl -n gamehouse get ingress
open http://gamehouse.local
```

### 4. 코드 고친 뒤 다시 돌리는 루프

클러스터를 다시 만들 필요 없다. 바꾼 서비스만:

```bash
cd backend
docker build -t gamehouse:user-develop -f user/Dockerfile .
kind load docker-image gamehouse:user-develop --name gamehouse-local
kubectl -n gamehouse rollout restart deployment/user
kubectl -n gamehouse rollout status deployment/user
```

`kind load` 만으로는 파드가 안 바뀐다 — 태그가 `:develop` 로 같아서 쿠버네티스 입장에선
"이미 그 이미지로 돌고 있는" 상태다. `rollout restart` 가 필요한 이유다.

### 5. 매니페스트만 검증하기 (클러스터 불필요)

렌더 결과만 보면 되는 경우 — 오버레이 패치가 먹었는지, placeholder 가 남았는지 등:

```bash
cd infra
kubectl kustomize k8s/overlays/local        # 렌더 결과 출력
kubectl kustomize k8s/overlays/dev  | grep -c REPLACE_IN_OVERLAY   # 0 이어야 함
kubectl kustomize k8s/overlays/prod | grep -c REPLACE_IN_OVERLAY   # 0 이어야 함
```

클러스터가 있다면 서버 사이드 검증까지:

```bash
kubectl apply -k k8s/overlays/local --dry-run=server
```

### 정리

```bash
kind delete cluster --name gamehouse-local
```

### 잘 안 될 때

| 증상 | 원인 |
|---|---|
| `ErrImageNeverPull` / `ImagePullBackOff` | 1단계 빌드나 `kind load` 를 빠뜨렸다. `docker exec -it gamehouse-local-control-plane crictl images \| grep gamehouse` 로 노드에 실제로 들어갔는지 본다 |
| `no matching manifest for linux/arm64` | 도커허브 CI 이미지를 당기고 있다. `overlays/local` 은 로컬 빌드만 써야 한다 |
| 파드는 Running 인데 `gamehouse.local` 이 안 열림 | `/etc/hosts` 항목 누락, 또는 호스트 80 포트를 다른 프로세스가 점유 |
| 파드가 `CrashLoopBackOff`, 로그에 DB 연결 실패 | postgres 파드가 아직 initdb 중일 수 있다. `kubectl -n gamehouse logs -l app.kubernetes.io/name=postgres` 확인 |
| 서비스 간 호출이 전부 timeout | NetworkPolicy 가 default-deny 다. 새 서비스를 추가했다면 자기 `networkpolicy.yaml` 이 있는지 본다 |
| `kubectl get hpa` 의 TARGETS 가 `<unknown>` | metrics-server 가 없거나 아직 수집 전이다. HPA 컨트롤러는 15초 주기라 `kubectl top` 이 먼저 되고 HPA 는 조금 늦게 채워진다 |
| `apply` 시 `field is immutable` (selector) | `environment` 라벨이 selector 에 박혀 있다. 오버레이를 바꿔 끼운 경우 클러스터를 지우고 다시 만든다 |

## dev / prod 배포

CI 파이프라인에서 (아래는 prod 기준, dev 는 디렉터리만 바꾼다):
```bash
cd k8s/overlays/prod
kustomize edit set image gamehouse-user=nexusops0713/gamehouse:user-$GIT_SHA
kustomize edit set image gamehouse-post=nexusops0713/gamehouse:post-$GIT_SHA
# ... 나머지(chat/riot/rabbitmq)도 동일하게. match/crew 는 아직 대상이 아니다.
kubectl apply -k .
```
왼쪽 `gamehouse-user` 는 도커허브 주소가 아니라 **base 가 쓰는 매칭 키**다(아래
"이미지 참조" 항목 참고). 오른쪽이 CI가 실제로 푸시하는 좌표다.

`images:` 의 기본 태그를 일부러 존재하지 않는 `<service>-REPLACE_AT_DEPLOY` 로 박아
뒀다 — CI가 이 단계를 빼먹으면 `ImagePullBackOff` 로 바로 드러나게 하기 위해서다
(조용히 dev 이미지가 prod 에 깔리는 사고 방지).

## 설계 결정과 그 이유

**이미지 참조 — base 는 논리 이름, 오버레이가 실제 레포로 매핑한다.**
CI(`backend`·`frontend` 의 `ci-cd.yml`)는 레포 하나에 서비스를 태그 접두사로 구분해
푸시한다 — `nexusops0713/gamehouse:user-develop`, `:user-<sha>` 형태다.

이 좌표를 base 에 그대로 쓰면 안 된다. kustomize 의 `images:` 트랜스포머는 레포
이름으로만 매칭하고 태그 접두사는 구분하지 못하므로, 서비스가 전부 같은 레포를
쓰면 항목 하나가 전부를 덮어쓴다. `user` 파드에 `chat` 이미지가 깔리는데 에러도
경고도 없이 조용히 일어난다.

그래서 base 는 서비스별 **논리 이름**(`gamehouse-user:develop`)을 쓰고, 오버레이가
실제 좌표를 만든다.

```yaml
# overlays/prod/kustomization.yaml
- name: gamehouse-user                 # base 의 매칭 키 (출력에 안 나옴)
  newName: nexusops0713/gamehouse      # 실제 레포
  newTag: user-REPLACE_AT_DEPLOY       # 실제 태그
```

덤으로 로컬 kind 개발이 단순해진다. base 의 이름이 그대로 로컬 빌드 태그가 되므로
레지스트리·인증이 필요 없다. Apple Silicon 에서는 이 경로가 사실상 유일하다 —
CI 이미지는 `platforms: linux/amd64` 단일 빌드라 arm64 노드에서 pull 이 실패한다.

```bash
cd backend
docker build -t gamehouse:user-develop -f user/Dockerfile .   # 컨텍스트는 backend/ 루트
kind load docker-image gamehouse:user-develop --name gamehouse-local
```

자세한 근거와 재현은 `task/k8s/kustomize-images-트랜스포머.md` 참고.

**네임스페이스는 세 환경 모두 `gamehouse` 하나.** 클러스터 자체가 전부 다르므로(kind /
dev EKS / prod EKS) 이름이 겹칠 일이 없다. 이름을 환경별로 나누면(`gamehouse-dev` 등)
매니페스트 안의 모든 `namespace:` 참조를 patch 해야 해서 오히려 복잡해진다.

**NetworkPolicy는 default-deny + 화이트리스트.** `base/networkpolicy-baseline.yaml`
이 네임스페이스 전체를 일단 다 막고, 서비스별 `networkpolicy.yaml` 이 필요한 통로만
연다. 새 서비스를 추가했는데 자기 NetworkPolicy 를 안 만들면 "아무 통신도 못 하는"
파드가 되도록 일부러 fail-closed 로 설계했다. 다만 ALB(prod)/ingress-nginx(dev) 에서
들어오는 트래픽은 소스 IP 로 좁히기 어려워 8080 포트를 사실상 열어 둔다 — 실제 경계는
인그레스 자체의 경로 라우팅과 (prod) AWS 보안그룹이 담당한다는 전제다.

**시크릿은 이 저장소에 실제 값이 없다.**
- `base/**/*-secret.yaml`, `base/jwt-secret.yaml` 은 전부 `CHANGE_ME` placeholder다.
- local: `overlays/local/patches/secret-*.yaml` 이 kind 전용 더미값으로 덮어쓴다
  (클러스터 밖으로 안 나가므로 커밋해도 안전).
- dev/prod: `components/aws` 가 그 placeholder Secret 을 통째로 지우고(`$patch: delete`),
  대신 `components/aws/external-secrets/` 의 `ExternalSecret` 이 AWS Secrets Manager 값을
  15분마다 동기화한다. 경로의 `ENV` 세그먼트는 각 오버레이의 `replacements` 가
  `env-configmap.yaml` 값을 읽어 `dev`/`prod` 로 치환한다. **External Secrets Operator 를 클러스터에 먼저 Helm 설치해야
  동작한다** — 이 kustomize 트리 범위 밖.

**`refreshInterval: 15m` 의 근거 — 비용이 아니라 파드 반영 방식이 기준이다.**

먼저 비용부터. Secrets Manager 요금은 저장이 시크릿당 **월 $0.40**, API 호출이
**10,000건당 $0.05** 다. 현재 활성 `ExternalSecret` 은 환경당 6개이고 `data:` 항목은
합쳐서 13개(jwt 1, rabbitmq 2, riot 1, db 3×3)다. 15분 주기면 환경당

```
13 항목 × 4회/시 × 24시 × 30일 = 37,440 호출/월  →  $0.19
```

dev + prod 둘이면 월 **$0.37**. 반면 저장 비용은 6개 × $0.40 × 2환경 = **월 $4.80** 이다.
즉 **호출이 아니라 시크릿 개수가 비용을 지배한다.** 주기를 1분으로 줄여도 호출 비용은
월 $2.8 수준이라 여전히 무시할 만하다 — 주기는 비용으로 정할 문제가 아니다.

진짜 제약은 따로 있다. 각 서비스 Deployment 는 Secret 을 `secretKeyRef` 로 **환경변수에
주입**한다(볼륨 마운트가 아니다). 환경변수는 **컨테이너 시작 시점에 고정**되므로,
ESO 가 k8s Secret 을 새로 써도 **돌고 있는 파드에는 반영되지 않는다.** 따라서
`refreshInterval` 을 아무리 줄여도 전파가 빨라지지 않는다. 이 값이 실제로 정하는 것은
"다음에 파드가 뜰 때 최신 값을 쓸 것을 얼마나 보장하느냐" 하나다.

그래서 15분이 하는 일은 셋이다.
- 값이 회전(rotate)된 뒤, 다음 롤아웃에서 확실히 새 값을 집도록 보장한다.
- 누가 `kubectl edit` 로 k8s Secret 을 손댔을 때 15분 안에 원래 값으로 되돌린다.
- Secret 이 삭제되면 15분 안에 다시 만들어진다.

**회전된 비밀번호를 즉시 반영해야 한다면** `refreshInterval` 을 줄이는 게 아니라
파드를 다시 띄워야 한다 — `kubectl -n gamehouse rollout restart deployment/<svc>`,
또는 Stakater Reloader 같은 걸 붙여 Secret 변경 시 자동 롤아웃되게 한다.

**호출 수를 굳이 더 줄이려면** `data:` 항목을 나열하는 대신 `dataFrom.extract` 로 JSON
전체를 한 번에 받으면 된다 — db 시크릿이 3회에서 1회로 준다(13 → 6). 다만 지금은
절감액이 월 $0.2 수준이라 키 매핑이 명시적으로 보이는 현재 형태를 유지한다.

**이미지 pull 자격증명은 CI 가 아니라 클러스터 쪽 일이다.**
CI 가 레지스트리에 넣는 건 **push** 권한이고(GitHub Actions secrets), 파드를 띄울 때
이미지를 당기는 건 노드의 kubelet 이라 **pull** 권한이 따로 필요하다. kubelet 은
GitHub Actions secrets 를 볼 수 없다.

`nexusops0713/gamehouse` 가 비공개 레포이므로 dev/prod 는 `imagePullSecrets` 가 있어야
한다 — 없으면 EKS 첫 배포에서 전 서비스가 `ImagePullBackOff` 로 뜬다. local(kind) 은
`kind load` 로 노드에 이미지를 직접 넣으므로 대상이 아니다.

- 자격증명 자체는 `components/aws/external-secrets/external-secret-dockerhub.yaml` 이
  Secrets Manager 에서 받아 온다. 다른 ExternalSecret 과 달리 `template` 을 쓰는데,
  `imagePullSecrets` 는 평범한 key/value 가 아니라 `kubernetes.io/dockerconfigjson`
  타입이어야 하기 때문이다. Secrets Manager 에는 `USERNAME`/`PASSWORD` 두 키만 두고
  JSON 조립은 매니페스트에서 한다.
- **Deployment 가 아니라 ServiceAccount 에 붙인다**
  (`components/aws/patches/imagepullsecret-*.yaml`). 그 SA 를 쓰는 파드가 자동으로
  상속하므로 워크로드 종류(Deployment/StatefulSet/Job)가 늘어도 한 곳만 보면 된다.
  `automountServiceAccountToken: false` 와는 무관하다 — 그건 파드 안에 API 토큰을
  마운트할지 여부고, `imagePullSecrets` 는 kubelet 이 별도로 읽는다.
- 대상은 user·post·chat·riot·rabbitmq 5개다. redis 는 공개 이미지(`redis:7-alpine`)라
  빠져 있다.
- ⚠️ CI 의 push 토큰을 그대로 쓰지 말 것. 도커허브에서 **read-only** 액세스 토큰을 따로
  발급해 넣는다. 클러스터가 유출돼도 레지스트리에 쓰기는 못 하게.

**ECR 로 옮기면 이 항목 전체가 없어진다.** 노드 IAM 역할에
`AmazonEC2ContainerRegistryReadOnly` 만 붙으면 kubelet 이 IAM 으로 인증하므로
`imagePullSecrets` 도, 토큰 회전도 필요 없다. 덤으로 도커허브 pull rate limit 에서
벗어나고(노드가 스케일아웃될 때마다 당기므로 실제로 물릴 수 있다), ECR 은 레포를
서비스별로 만드는 게 자연스러워 아래 "이미지 참조" 의 논리 이름 우회도 사라진다.
지금은 CI(backend/frontend 레포) 변경이 필요해 보류했다.

**JWT_SECRET 은 네임스페이스에 하나만.** user 가 발급하고 나머지 5개 서비스가
`common/security`(JwtAuthFilter)로 검증하므로 서비스별로 쪼개면 안 된다.

**Redis/RabbitMQ 는 지금 in-cluster StatefulSet.** 섹션10 메모대로 `base/redis/` 는
ElastiCache 로 대체하면 통째로 지우고 각 서비스 ConfigMap 의 `REDIS_HOST` 만
엔드포인트로 바꾸면 되는 구조로 짰다. RabbitMQ 는 관리형 대안(Amazon MQ)이
STOMP 플러그인을 지원하지 않아 지금은 이관 계획이 없다 — 단일 인스턴스라 HA 가
필요해지면 RabbitMQ Cluster Operator 도입을 검토한다.

**DB 접속 — 한 RDS, 서비스별 스키마(섹션11).** 각 서비스 Deployment 의 `DB_URL` 은
`jdbc:postgresql://$(DB_HOST):$(DB_PORT)/$(DB_NAME)?currentSchema=<service>_` 형태로
스키마를 고정한다. local 은 `overlays/local/postgres.yaml` 의 initdb 스크립트가 5개
스키마를 미리 만들어 두고 전 서비스가 같은 계정(`duo`)을 공유한다. dev/prod 는 각자의 RDS 에
**서비스별 계정을 최소 권한(자기 스키마만)으로 직접 만들어야 한다** — Kubernetes 가
RDS 계정을 만들어 주지는 않는다.

## local 접속 정보

이 저장소는 **공개**다. `overlays/local/patches/secret-*.yaml` 의 값은 kind 클러스터
전용 더미이며, 팀의 `application-secret.yml` 값과 **일부러 다르다**.
backend 가 같은 이유로 그 파일을 `.gitignore` 에 넣어 뒀다.

| 계정 | 비밀번호 | 용도 |
|---|---|---|
| `duo` | `kind-dev-only-duo` | DB 소유자. initdb·마이그레이션용 |
| `duo_user` | `kind-dev-only-user` | user 서비스 (`user_svc` 스키마 소유) |
| `duo_post` | `kind-dev-only-post` | post 서비스 (`post_svc`) |
| `duo_chat` | `kind-dev-only-chat` | chat 서비스 (`chat_svc`) |

DB GUI 로 붙으려면 포트 포워딩이 필요하다. 클러스터 안 `postgres` 는 ClusterIP 라
호스트에서 바로 닿지 않는다.

```bash
kubectl -n gamehouse port-forward svc/postgres 5432:5432
# Host localhost / Port 5432 / Database duo / User duo / PW kind-dev-only-duo
```

## 배포 전 반드시 채워야 하는 것 (`CHANGE_ME` grep 하면 다 나옴)

dev / prod 각각 따로 채워야 한다 — 같은 값을 쓰면 안 된다.

```bash
grep -rn "CHANGE_ME" k8s/overlays/dev
grep -rn "CHANGE_ME" k8s/overlays/prod
```

렌더 결과에 placeholder 가 남지 않았는지도 확인한다. `components/aws` 는
오버레이가 반드시 덮어써야 하는 자리를 `REPLACE_IN_OVERLAY` 로 두었으므로,
아래가 0 이 아니면 오버레이 패치가 빠진 것이다.

```bash
kubectl kustomize k8s/overlays/dev | grep -c REPLACE_IN_OVERLAY   # 0 이어야 함
```

- ACM 인증서 ARN + ALB `group.name` (`overlays/<env>/patches/ingress.yaml`).
  `group.name` 은 dev/prod 가 반드시 달라야 한다 — 같은 AWS 계정에서 겹치면 두 클러스터의
  LB 컨트롤러가 ALB 하나를 서로 덮어쓴다.
- IAM 계정 ID / 역할 ARN 4종 — user, post, external-secrets, (ALB 컨트롤러는 트리 밖).
  dev 역할은 `gamehouse/dev/*` 만, prod 역할은 `gamehouse/prod/*` 만 읽도록 IAM 정책을 좁힌다.
- RDS 엔드포인트 — 저장소에 두지 않는다. AWS Secrets Manager 의
  `gamehouse/prod/db/<service>` JSON 에 `DB_HOST` 키로 넣으면
  `ExternalSecret` 이 받아 온다. 호스트명 자체는 자격증명이 아니지만 AWS 계정
  식별자·리전·인스턴스명이 드러나므로 커밋하지 않는다.
- AWS Secrets Manager 에 시크릿 등록. `<env>` 는 문서 표기이고 실제로는 `dev`/`prod`
  두 벌을 만든다 — `gamehouse/<env>/jwt`, `gamehouse/<env>/rabbitmq`,
  `gamehouse/<env>/riot`, `gamehouse/<env>/db/<service>`, `gamehouse/<env>/dockerhub`.
  매니페스트의 `key: gamehouse/ENV/...` 에 있는 `ENV` 는 파일에 실제로 들어 있는
  글자이고 빌드 때 `replacements` 가 치환한다. 헷갈리면 렌더 결과로 확인한다:

  ```bash
  kubectl kustomize k8s/overlays/dev | grep 'key: gamehouse/' | sort -u
  ```
  db 항목은 `{ "DB_HOST": ..., "DB_USERNAME": ..., "DB_PASSWORD": ... }` 세 키다.
- 실제 도메인 — 지금 `CORS_ALLOWED_ORIGINS` 는 `https://gamehouse.example.com`
  placeholder(`base/<service>/configmap.yaml`)

## match / crew

`base/match`, `base/crew` 에 매니페스트가 있지만 `base/kustomization.yaml` 의
`resources:` 에서는 주석 처리해 뒀다. backend 에 아직 모듈이 없어서
(`settings.gradle` 참고) 이미지가 존재하지 않는다.

올려 두면 파드 2개가 상시 `ImagePullBackOff` 로 남아 `kubectl get pods` 에 빨간
줄이 상주하고, 위에서 설계한 "CI가 태그 지정을 빼먹으면 ImagePullBackOff 로
드러난다"는 신호가 묻힌다. 코드가 생기면 다섯 트리(`base`, `components/aws`,
`overlays/local`, `overlays/dev`, `overlays/prod`)의 주석과 `scripts/k8s-local-up.sh` 의
rollout 루프를 함께 되살린다.

## 클러스터 애드온 (이 kustomize 트리 밖)

앱 매니페스트가 아니라 클러스터 자체에 먼저 깔아야 하는 것들이다. 빠뜨리면 매니페스트는
정상으로 apply 되는데 기능만 조용히 죽는다.

| 애드온 | local | dev/prod | 없으면 |
|---|---|---|---|
| ingress-nginx | `k8s-local-up.sh` 가 설치 | — | 외부 접속 불가 |
| AWS Load Balancer Controller | — | Helm | ALB 가 안 만들어짐 |
| External Secrets Operator | — | Helm | Secret 이 안 생겨 파드가 못 뜸 |
| **metrics-server** | `k8s-local-up.sh` 가 설치 | **직접 설치** | **HPA 가 `<unknown>` 으로 멈춤** |

**metrics-server 는 EKS 기본 탑재가 아니다.** kind 만의 문제가 아니라 dev/prod 도
마찬가지다. HPA 는 스스로 사용량을 재지 않고 metrics-server 가 kubelet 에서 긁어
Metrics API 로 노출한 값을 읽어 `resources.requests` 대비 비율을 계산한다. 없으면
HPA 오브젝트도 파드도 정상인데 스케일만 안 되고, **에러가 나지 않아서** 알아채기
어렵다.

local 은 `--kubelet-insecure-tls` 패치가 필요하다 — kind 노드의 kubelet 이 자체 서명
인증서를 쓰기 때문이다. **EKS 에서는 이 플래그를 쓰지 않는다.**

`resources.requests` 도 전제다. 비율의 분모라서, requests 가 없는 컨테이너는
metrics-server 가 있어도 `<unknown>` 이 유지된다.

## HPA 를 어디에 붙였나 (그리고 왜 전부는 아닌가)

현재 `base/chat/hpa.yaml` 과 `base/match/hpa.yaml` 뿐이다(match 는 아직 제외됨).
서비스마다 하나씩 두지 않은 이유는, HPA 가 **복제본을 늘리면 처리량이 실제로 느는**
서비스에만 의미가 있기 때문이다.

| 서비스 | 현재 | 판단 |
|---|---|---|
| post | 없음 | **필요하다.** 부하테스트 기준 전체의 75%(102 RPS)를 받는 무상태 REST 다 |
| user | 없음 | **필요하다.** 25%(34 RPS). 로그인 BCrypt 가 CPU 바운드라 스파이크에 민감하다 |
| chat | 있음 | 재검토 대상 — 아래 참고 |
| riot | 없음 | 부적합. 병목이 CPU 가 아니라 외부 Riot API 레이트 리밋이라, 파드를 늘리면 리밋에 더 빨리 걸린다 |
| rabbitmq / redis | 없음 | 붙이면 안 된다. StatefulSet 이다 |

**chat(WebSocket)에 HPA 가 애매한 이유.** 스케일아웃해도 기존 연결은 옮겨가지 않는다 —
새 파드는 새로 붙는 연결만 받으므로 이미 포화된 파드는 그대로 포화다. 스케일인은
살아 있는 연결을 끊어 재접속을 몰리게 한다. 즉 CPU/메모리는 WebSocket 부하의 좋은
신호가 아니고 **동시 연결 수**가 맞는데, 그건 커스텀 메트릭이 필요하다.
`base/chat/hpa.yaml` 의 `scaleDown.stabilizationWindowSeconds: 300` 이 그 문제의
완화책이지 해결책은 아니다.

**post/user 에 HPA 를 아직 안 만든 것은 의도적이다.** chat 의 70%/80% 를 복사하면
특성이 다른 서비스에 남의 숫자를 쓰는 셈이 된다. `infra/load-test` 회차를 돌려
CPU·메모리 곡선을 실측한 뒤 그 근거로 임계값을 정한다.

## 아직 안 한 것 (의도적으로 범위 밖)

- AWS Load Balancer Controller, External Secrets Operator 설치 자체(Helm) — 앱
  매니페스트가 아니라 클러스터 애드온이라 별도 관리를 권장한다.
- Observability(Prometheus/Grafana) 의 k8s 버전 — 현재 `infra/docker-compose.observability.yml`
  은 EC2 전용. 각 서비스 Deployment 에 `prometheus.io/scrape` 애노테이션은 이미
  붙여 놨으니, kube-prometheus-stack 같은 걸 얹으면 바로 스크레이프된다.
- **rabbitmq 이미지를 푸시하는 CI** — `infra/.github/workflows/ci-cd.yml` 은
  docker-compose 검증만 하고, compose 는 `build: ../infra/rabbitmq` 로 로컬 빌드한다.
  EC2 에서는 그래도 됐지만 EKS 는 레지스트리에서 당겨야 하므로 build-push 잡이
  필요하다. 그때까지 `overlays/prod` 의 `gamehouse-rabbitmq` 매핑은 당길 수 없는
  좌표를 가리킨다.
- 백엔드 자체의 Gradle 멀티모듈 분리(섹션13) — 이건 이 인프라 작업과 별개로
  `backend/` 리포에서 진행해야 한다.
- `UPLOAD_DIR`(현재 모놀리스의 로컬 파일 업로드) 관련 볼륨을 user/post Deployment 에
  일부러 안 넣었다. user/post 는 IRSA로 S3 버킷 권한을 받게 설계돼 있어서
  (`serviceaccount.yaml` 주석 참고), FileStorageService 가 S3 로 바뀌는 게 맞는 방향이라
  판단했다 — PVC/emptyDir 로 로컬 디스크를 다시 만드는 건 금방 버릴 코드라 생략했다.
  S3 전환 전까지 로컬 업로드가 필요하면 각 Deployment 에 emptyDir 볼륨과 UPLOAD_DIR
  env 를 추가하면 된다(다만 파드가 여러 개라 파드마다 디스크가 달라 일관성이 깨진다는
  점을 감안할 것 — 그래서 더더욱 S3 가 맞다).
