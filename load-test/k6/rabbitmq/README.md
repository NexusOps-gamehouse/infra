# RabbitMQ Load / Recovery Test

GameHouse 로컬 Kubernetes(kind) 환경에서 RabbitMQ 기반 이벤트 전달과 장애 복구를 검증하기 위한 테스트입니다.

이번 테스트의 핵심 목적은 단순 최대 처리량 측정보다 다음 세 가지를 실제 증거로 남기는 것입니다.

1. Post에서 발생한 이벤트가 RabbitMQ를 거쳐 Chat까지 정상 전달되는지 확인
2. Chat Consumer 중단 시 Queue에 메시지가 적체되고, 복구 후 정상적으로 Drain 되는지 확인
3. RabbitMQ Pod 장애 후 Pod와 Consumer가 복구되고 최종 데이터가 누락되지 않는지 확인

---

## 1. 테스트 구조

~~~text
load-test/k6/rabbitmq/
├── README.md
├── preflight.sh
├── result-template.md
├── rabbit.js
├── run-load.sh
├── inject.sh
├── timeline.sh
├── .gitignore
├── results/
│   └── .gitkeep
└── seed/
    ├── prepare.sh
    ├── cleanup.sh
    └── data/
        └── tokens.json
~~~

`seed/` 관련 파일은 RabbitMQ 테스트 전용 계정과 JWT를 준비하기 위한 별도 영역입니다.

기존 전역 `load-test/seed` 데이터는 RabbitMQ 테스트 때문에 생성하거나 초기화하지 않습니다.

---

## 2. 주요 파일

### `preflight.sh`

실제 테스트를 시작하기 전에 필수 조건을 검사합니다.

확인 항목:

- Kubernetes context가 `kind-*`인지
- `gamehouse` Namespace 접근 가능 여부
- RabbitMQ StatefulSet 1/1 Ready
- RabbitMQ Pod Ready
- Post Deployment Ready
- Chat Deployment Ready
- RabbitMQ 테스트 전용 token 파일
- RabbitMQ Queue 조회 가능 여부
- Chat 이벤트 Queue Consumer 존재 여부
- Chat room API 조회 가능 여부

하나라도 필수 조건을 만족하지 않으면 테스트를 시작하지 않습니다.

### `rabbit.js`

`POST /api/posts` 요청을 발생시켜 실제 애플리케이션 경로를 통해 RabbitMQ 이벤트를 생성합니다.

DB에 직접 테스트 데이터를 넣는 방식으로는 RabbitMQ Publish가 발생하지 않으므로 사용하지 않습니다.

### `run-load.sh`

k6 테스트 단계를 실행합니다.

지원 단계:

- `smoke`
- `low`
- `medium`
- `high`
- `burst`

이번 RabbitMQ 장애 복구 테스트에서는 우선 `smoke`를 필수로 사용합니다.

`low` 이상 단계는 시간이 남을 경우 추가 성능 측정에 사용합니다.

### `inject.sh`

RabbitMQ와 Chat 장애 상황을 의도적으로 만듭니다.

지원 기능:

- baseline 확인
- RabbitMQ Queue 확인
- Chat Consumer 중단
- Chat Consumer 복구
- RabbitMQ Pod 삭제 및 복구 확인

장애 주입은 반드시 로컬 kind 환경에서만 수행합니다.

### `timeline.sh`

테스트 중 주요 사건의 시각을 기록합니다.

기본 결과:

~~~text
results/timeline.log
~~~

UTC와 로컬 시간을 함께 기록하여 Kubernetes Event, Grafana, Loki, k6 결과를 같은 시간축에서 비교할 수 있도록 합니다.

### `result-template.md`

각 테스트 회차의 결과와 증거를 정리하기 위한 기록 양식입니다.

주요 기록 항목:

- Queue 최대 적체량
- Queue Drain 시간
- RabbitMQ Pod 복구 시간
- Chat Consumer 재연결 시간
- 성공 Post 수
- 신규 Chat room 수
- 데이터 누락 여부
- 장애 원인 및 조치
- 재검증 결과

---

## 3. 사전 조건

Docker Desktop이 실행 중이어야 합니다.

확인:

~~~bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker NOT RUNNING"
~~~

kind 클러스터 확인:

~~~bash
kind get clusters
~~~

현재 Kubernetes context 확인:

~~~bash
kubectl config current-context
~~~

RabbitMQ 테스트는 기본적으로 다음 context를 사용합니다.

~~~text
kind-gamehouse
~~~

Namespace:

~~~text
gamehouse
~~~

---

## 4. 테스트 시작 위치

~~~bash
cd load-test/k6/rabbitmq
~~~

모든 RabbitMQ 테스트 명령은 이 디렉터리 기준으로 실행합니다.

---

## 5. Preflight

가장 먼저 실행합니다.

~~~bash
./preflight.sh
~~~

정상 예시:

~~~text
[PASS] Kubernetes context: kind-gamehouse
[PASS] Kubernetes API / namespace 접근: gamehouse
[PASS] RabbitMQ StatefulSet: 1/1 Ready
[PASS] RabbitMQ Pod Ready: rabbitmq-0
[PASS] post Deployment
[PASS] chat Deployment
[PASS] RabbitMQ 전용 token 파일 확인
[PASS] RabbitMQ Queue 조회 가능
[PASS] Chat Consumer 연결
[PASS] Chat room 조회

===== PREFLIGHT PASSED =====
~~~

`PREFLIGHT FAILED`가 나오면 해당 원인을 해결한 뒤 다시 실행합니다.

실패 상태에서 Smoke 또는 장애 주입 테스트를 진행하지 않습니다.

---

## 6. RabbitMQ Queue 기준

현재 Chat 서비스 이벤트 Queue 기본값:

~~~text
gamehouse.events.gamehouse-chat
~~~

직접 확인:

~~~bash
kubectl -n gamehouse exec rabbitmq-0 -- \
  rabbitmqctl list_queues \
  name messages_ready messages_unacknowledged consumers durable
~~~

주요 확인 값:

- `messages_ready`
  - Consumer가 아직 처리하지 못하고 대기 중인 메시지
- `messages_unacknowledged`
  - Consumer에게 전달됐지만 ACK가 완료되지 않은 메시지
- `consumers`
  - 해당 Queue에 연결된 Consumer 수

---

## 7. 테스트 전용 Seed

RabbitMQ 테스트는 다른 부하 테스트 데이터와 분리된 전용 계정/JWT를 사용합니다.

준비:

~~~bash
./seed/prepare.sh
~~~

예상 token 파일:

~~~text
seed/data/tokens.json
~~~

전용 seed가 준비되지 않은 경우 `preflight.sh`가 실패하는 것이 정상입니다.

테스트 종료 후에는 RabbitMQ 테스트가 생성한 데이터만 정리합니다.

~~~bash
./seed/cleanup.sh
~~~

기존 공용 seed 전체를 reset하거나 다른 팀 테스트 데이터를 삭제하지 않습니다.

---

## 8. Pre-Smoke

Preflight가 PASS한 후 실행합니다.

~~~bash
./run-load.sh smoke
~~~

목적:

~~~text
POST /api/posts
        ↓
Post Service
        ↓
RabbitMQ Event
        ↓
Chat Consumer
        ↓
Chat 데이터 생성
~~~

확인해야 할 것:

- Post 요청 성공 여부
- RabbitMQ Queue 변화
- Chat Consumer 존재
- 신규 Chat room 수
- k6 실패율

결과는 `results/` 아래에 저장합니다.

---

## 9. Queue Drain Test

### 9-1. 기준선 기록

~~~bash
./inject.sh baseline
./timeline.sh -t SNAPSHOT "queue drain baseline"
~~~

Queue와 Chat room 수를 테스트 전 값으로 기록합니다.

### 9-2. Chat Consumer 중단

~~~bash
ALLOW_FAULT=1 ./inject.sh chat-down
~~~

Chat이 중단된 뒤 Consumer가 감소했는지 확인합니다.

~~~bash
./inject.sh rabbitmq-queues
~~~

### 9-3. 이벤트 발생

~~~bash
./run-load.sh smoke
~~~

Chat Consumer가 없는 동안 이벤트가 생성되면서 `messages_ready`가 증가하는지 확인합니다.

### 9-4. Queue 적체 기록

~~~bash
./inject.sh rabbitmq-queues
./timeline.sh -t SNAPSHOT "queue backlog captured"
~~~

최대 Queue backlog와 시각을 기록합니다.

### 9-5. Chat 복구

~~~bash
ALLOW_FAULT=1 ./inject.sh chat-up
~~~

복구 후 확인:

- Chat Pod Ready
- RabbitMQ Consumer 재등록
- `messages_ready` 감소
- Queue가 기준선 수준으로 Drain
- 신규 Chat 데이터 생성

Queue가 정상적으로 내려간 시각까지 기록합니다.

---

## 10. RabbitMQ Pod Failure Recovery

장애 직전 기준선:

~~~bash
./inject.sh baseline
./timeline.sh -t MARK "rabbitmq failure test start"
~~~

RabbitMQ Pod 삭제:

~~~bash
ALLOW_FAULT=1 ./inject.sh rabbitmq-kill
~~~

별도 터미널에서 상태를 관측할 수 있습니다.

~~~bash
kubectl -n gamehouse get pod rabbitmq-0 -w
~~~

Kubernetes Event:

~~~bash
kubectl -n gamehouse get events --sort-by=.lastTimestamp
~~~

복구 후 확인:

~~~bash
./inject.sh rabbitmq-queues
~~~

확인 항목:

- RabbitMQ Pod 자동 재생성
- RabbitMQ Pod Ready 복구
- Chat Consumer 재연결
- Post RabbitMQ 연결 복구
- Queue 처리 재개
- 최종 Chat 데이터 누락 여부

---

## 11. 선택적 정상 부하 테스트

장애 복구 테스트가 완료되고 시간이 남을 경우에만 수행합니다.

~~~bash
./run-load.sh low
./run-load.sh medium
./run-load.sh high
./run-load.sh burst
~~~

기본 단계:

| Stage | Rate | Duration |
|---|---:|---:|
| Smoke | 5 req/s | 2m |
| Low | 20 req/s | 3m |
| Medium | 50 req/s | 5m |
| High | 100 req/s | 5m |
| Burst | 200 req/s | 1m |

한 단계에서 Queue가 지속적으로 증가하고 Drain되지 않는다면 더 높은 부하를 강행하지 않습니다.

---

## 12. 관측 항목

가능하면 다음 값을 함께 기록합니다.

### RabbitMQ

- Publish Rate
- Consumer / ACK Rate
- `messages_ready`
- `messages_unacknowledged`
- Consumer 수
- CPU
- Memory

### Post / Chat

- Pod Ready 상태
- Restart 횟수
- CPU
- Memory
- RabbitMQ 연결 / 재연결 로그

### k6

- 총 요청 수
- 성공 요청 수
- 실패 요청 수
- HTTP 오류율

---

## 13. Grafana / Loki

로컬 Observability Stack이 필요한 경우 기존 프로젝트 스크립트를 사용합니다.

~~~bash
cd <infra-repository-root>

LOWMEM=1 ./scripts/k8s-local-observability.sh
./scripts/k8s-local-observability-verify.sh
~~~

Grafana에서 우선 확인할 항목:

- RabbitMQ Queue backlog
- RabbitMQ Consumer
- RabbitMQ CPU / Memory
- Post CPU / Memory
- Chat CPU / Memory

Loki에서는 RabbitMQ 장애 시점 전후의 Post / Chat 연결 및 재연결 로그를 확인합니다.

Observability Stack이 없는 경우에도 다음 자료는 반드시 남깁니다.

- `kubectl get pods`
- `kubectl get events`
- `rabbitmqctl list_queues`
- Post / Chat 로그
- k6 summary
- `results/timeline.log`

---

## 14. 안전장치

장애 주입에는 명시적인 opt-in이 필요합니다.

~~~bash
ALLOW_FAULT=1 ./inject.sh <command>
~~~

기본적으로 `kind-*` 이외의 Kubernetes context에서는 장애 주입을 실행하지 않습니다.

이 테스트는 로컬 kind 전용으로 수행하는 것을 원칙으로 합니다.

EKS/dev/prod 환경에는 장애 주입 명령을 사용하지 않습니다.

---

## 15. 필수 테스트 우선순위

이번 RabbitMQ 테스트에서 우선순위는 다음과 같습니다.

~~~text
1. Preflight
2. Pre-Smoke
3. Queue Drain
4. RabbitMQ Pod Failure Recovery
5. 결과 정리
6. Low / Medium / High / Burst (선택)
~~~

최대 처리량을 찾는 것보다 장애 후 정상 복구와 메시지 처리 무결성을 증명하는 것이 우선입니다.

---

## 16. 결과 기록

테스트 시작 전:

~~~bash
cp result-template.md results/result-$(date '+%Y%m%d-%H%M%S').md
~~~

테스트 과정에서 기록할 핵심 수치:

- 최대 Queue backlog
- Queue Drain 시간
- RabbitMQ Pod Ready 복구 시간
- Chat Consumer 재연결 시간
- 성공 Post 수
- 신규 Chat room 수
- 데이터 누락 수

최종 발표에서는 다음 세 가지 증거를 우선 사용합니다.

1. Chat 중단 시 Queue 적체 → 복구 후 Drain
2. RabbitMQ Pod 삭제 → 자동 복구 및 Consumer 재연결
3. 성공 Post 수와 최종 Chat 데이터 비교를 통한 메시지 처리 무결성 확인
