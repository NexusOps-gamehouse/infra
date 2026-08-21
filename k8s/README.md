# GameHouse MSA — k8s 매니페스트

설계 문서("GameHouse MSA 디렉터리 구조") 섹션 10~13을 기준으로 생성했다.
백엔드가 아직 Gradle 멀티모듈로 쪼개지지 않았어도(섹션 13의 1~2단계 전) 이 트리 자체는
독립적으로 검증 가능하다 — `kustomize build` 로 세 트리 모두 확인했다.

```
infra/
├── kind-config.yaml          dev 클러스터(kind) 정의
├── rabbitmq/Dockerfile       기존 그대로(stomp+prometheus 플러그인)
├── scripts/
│   ├── deploy.sh             기존 EC2 docker-compose 배포 스크립트(그대로 둠 — 섹션13
│   │                         3~5단계까지는 모놀리스가 여전히 compose 로 돈다)
│   └── k8s-dev-up.sh         ★ kind 클러스터 생성 + ingress-nginx + overlays/dev 적용
└── k8s/
    ├── base/                 서비스(현재 4개) + rabbitmq + redis + 네임스페이스 전역 정책
    └── overlays/
        ├── dev/               kind + ingress-nginx + in-cluster postgres + frontend Pod
        └── prod/               EKS + ALB + RDS + External Secrets (frontend 없음)
```

## 실행

```bash
cd infra
./scripts/k8s-dev-up.sh
# 또는 클러스터가 이미 있다면
kubectl apply -k k8s/overlays/dev
```

prod 는 CI 파이프라인에서:
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
docker build -t gamehouse-user:develop -f user/Dockerfile .   # 컨텍스트는 backend/ 루트
kind load docker-image gamehouse-user:develop --name gamehouse-dev
```

자세한 근거와 재현은 `task/k8s/kustomize-images-트랜스포머.md` 참고.

**네임스페이스는 dev/prod 모두 `gamehouse` 하나.** 클러스터 자체가 다르므로(kind vs
EKS) 이름이 겹칠 일이 없다. 이름을 환경별로 나누면(`gamehouse-dev`/`gamehouse-prod`)
매니페스트 안의 모든 `namespace:` 참조를 patch 해야 해서 오히려 복잡해진다.

**NetworkPolicy는 default-deny + 화이트리스트.** `base/networkpolicy-baseline.yaml`
이 네임스페이스 전체를 일단 다 막고, 서비스별 `networkpolicy.yaml` 이 필요한 통로만
연다. 새 서비스를 추가했는데 자기 NetworkPolicy 를 안 만들면 "아무 통신도 못 하는"
파드가 되도록 일부러 fail-closed 로 설계했다. 다만 ALB(prod)/ingress-nginx(dev) 에서
들어오는 트래픽은 소스 IP 로 좁히기 어려워 8080 포트를 사실상 열어 둔다 — 실제 경계는
인그레스 자체의 경로 라우팅과 (prod) AWS 보안그룹이 담당한다는 전제다.

**시크릿은 이 저장소에 실제 값이 없다.**
- `base/**/*-secret.yaml`, `base/jwt-secret.yaml` 은 전부 `CHANGE_ME` placeholder다.
- dev: `overlays/dev/patches/secret-*.yaml` 이 로컬 kind 전용 더미값으로 덮어쓴다
  (클러스터 밖으로 안 나가므로 커밋해도 안전).
- prod: 그 placeholder Secret 을 통째로 지우고(`$patch: delete`), 대신
  `overlays/prod/external-secrets/` 의 `ExternalSecret` 이 AWS Secrets Manager 값을
  15분마다 동기화한다. **External Secrets Operator 를 클러스터에 먼저 Helm 설치해야
  동작한다** — 이 kustomize 트리 범위 밖.

**JWT_SECRET 은 네임스페이스에 하나만.** user 가 발급하고 나머지 5개 서비스가
`common/security`(JwtAuthFilter)로 검증하므로 서비스별로 쪼개면 안 된다.

**Redis/RabbitMQ 는 지금 in-cluster StatefulSet.** 섹션10 메모대로 `base/redis/` 는
ElastiCache 로 대체하면 통째로 지우고 각 서비스 ConfigMap 의 `REDIS_HOST` 만
엔드포인트로 바꾸면 되는 구조로 짰다. RabbitMQ 는 관리형 대안(Amazon MQ)이
STOMP 플러그인을 지원하지 않아 지금은 이관 계획이 없다 — 단일 인스턴스라 HA 가
필요해지면 RabbitMQ Cluster Operator 도입을 검토한다.

**DB 접속 — 한 RDS, 서비스별 스키마(섹션11).** 각 서비스 Deployment 의 `DB_URL` 은
`jdbc:postgresql://$(DB_HOST):$(DB_PORT)/$(DB_NAME)?currentSchema=<service>_` 형태로
스키마를 고정한다. dev 는 `overlays/dev/postgres.yaml` 의 initdb 스크립트가 5개
스키마를 미리 만들어 두고 전 서비스가 같은 계정(`duo`)을 공유한다. prod 는 RDS 에
**서비스별 계정을 최소 권한(자기 스키마만)으로 직접 만들어야 한다** — Kubernetes 가
RDS 계정을 만들어 주지는 않는다.

## 배포 전 반드시 채워야 하는 것 (`CHANGE_ME` grep 하면 다 나옴)

```bash
grep -rn "CHANGE_ME" k8s/overlays/prod
```

- ACM 인증서 ARN (`overlays/prod/ingress.yaml`)
- IAM 계정 ID / 역할 ARN 4종 — user, post, external-secrets, (ALB 컨트롤러는 트리 밖)
- RDS 엔드포인트 — 저장소에 두지 않는다. AWS Secrets Manager 의
  `gamehouse/prod/db/<service>` JSON 에 `DB_HOST` 키로 넣으면
  `ExternalSecret` 이 받아 온다. 호스트명 자체는 자격증명이 아니지만 AWS 계정
  식별자·리전·인스턴스명이 드러나므로 커밋하지 않는다.
- AWS Secrets Manager 에 `gamehouse/prod/jwt`, `gamehouse/prod/rabbitmq`,
  `gamehouse/prod/riot`, `gamehouse/prod/db/<service>` 등록.
  db 항목은 `{ "DB_HOST": ..., "DB_USERNAME": ..., "DB_PASSWORD": ... }` 세 키다.
- 실제 도메인 — 지금 `CORS_ALLOWED_ORIGINS` 는 `https://gamehouse.example.com`
  placeholder(`base/<service>/configmap.yaml`)

## match / crew

`base/match`, `base/crew` 에 매니페스트가 있지만 `base/kustomization.yaml` 의
`resources:` 에서는 주석 처리해 뒀다. backend 에 아직 모듈이 없어서
(`settings.gradle` 참고) 이미지가 존재하지 않는다.

올려 두면 파드 2개가 상시 `ImagePullBackOff` 로 남아 `kubectl get pods` 에 빨간
줄이 상주하고, 위에서 설계한 "CI가 태그 지정을 빼먹으면 ImagePullBackOff 로
드러난다"는 신호가 묻힌다. 코드가 생기면 세 트리(`base`, `overlays/dev`,
`overlays/prod`)의 주석과 `scripts/k8s-dev-up.sh` 의 rollout 루프를 함께 되살린다.

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
