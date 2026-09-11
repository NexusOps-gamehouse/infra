# RabbitMQ load / recovery test scripts

이 파일들은 합의한 RabbitMQ 테스트 설계를 실제 실행 단위로 나눈 최소 스크립트입니다.

## 구성

- `rabbit.js`
  - `POST /api/posts`를 일정 요청률로 호출
  - HTTP 입력률을 단계적으로 증가
  - RabbitMQ 실제 Publish/ACK/Queue 수치는 Prometheus/Grafana에서 관측
- `run-load.sh`
  - `smoke`, `low`, `medium`, `high`, `burst` 단계 실행
  - k6 summary JSON 저장
  - timeline 기록
- `inject.sh`
  - baseline/queue 확인
  - Chat consumer 중단/복구
  - RabbitMQ Pod 삭제/복구
  - 안전장치 포함
- `timeline.sh`
  - 테스트 주요 시각을 `results/timeline.log`에 기록

## 0. 먼저 실제 API payload 1건 확인

`rabbit.js`는 Post API의 필드 구조를 추측하지 않습니다.
브라우저/기존 API 테스트에서 실제로 2xx가 나온 `POST /api/posts` JSON Body를 사용하세요.

예:

```bash
export POST_PAYLOAD_JSON='{"실제":"성공한 요청 body"}'
```

## 1. 공통 환경값

```bash
cd ~/NexusOps-gamehouse/infra/load-test/k6/kind

export TOKEN="$(jq -r '.users[0].token' seed-data.json)"
export BASE_URL="http://gamehouse.local"
export POST_PATH="/api/posts"
export POST_PAYLOAD_JSON='{"실제":"성공한 요청 body"}'
```

## 2. 기준선

```bash
./inject.sh baseline
./timeline.sh "baseline captured"
```

필요하면 채팅방 수 조회 endpoint를 지정:

```bash
export ROOMS_URL="http://gamehouse.local/<실제 채팅방 목록 endpoint>"
./inject.sh rabbitmq-consumed "$TOKEN"
```

## 3. 정상 부하

한 단계씩 실행하세요. Medium에서 이미 지속 적체가 생기면 High/Burst를 강행할 필요가 없습니다.

```bash
./run-load.sh smoke
./run-load.sh low
./run-load.sh medium
./run-load.sh high
./run-load.sh burst
```

각 단계에서 Grafana/Prometheus로 확인:
- Publish Rate
- ACK/Consumer Rate
- messages_ready
- messages_unacknowledged
- RabbitMQ CPU/Memory
- Chat/Post CPU/Memory
- HTTP 오류율

## 4. Queue Drain

테스트용 kind context에서만 실행 권장:

```bash
ALLOW_FAULT=1 ./inject.sh chat-down
./timeline.sh "chat consumer down"

./run-load.sh smoke

./inject.sh rabbitmq-queues
./timeline.sh "queue backlog captured"

ALLOW_FAULT=1 ./inject.sh chat-up
./timeline.sh "chat consumer restored"

./inject.sh rabbitmq-queues
```

Queue가 기준선까지 내려가는 시각을 기록하세요.

## 5. RabbitMQ Pod 복구

```bash
./inject.sh baseline
./timeline.sh "rabbitmq fault test start"

ALLOW_FAULT=1 ./inject.sh rabbitmq-kill

./timeline.sh "rabbitmq pod Ready"
./inject.sh rabbitmq-queues
```

동시에 별도 터미널에서 관측:

```bash
kubectl -n gamehouse get pod rabbitmq-0 -w
kubectl -n gamehouse get events --sort-by=.lastTimestamp -w
```

그리고 Loki에서 Post/Chat의 AMQP/STOMP 재연결 로그를 캡처하세요.

## 안전장치

`inject.sh`는 기본적으로:
- `ALLOW_FAULT=1` 없이는 장애 주입을 거부
- `kind-*`가 아닌 Kubernetes context에서는 장애 주입을 거부

EKS/dev에서 정말 테스트해야 할 경우에만 명시적으로 `ALLOW_NON_KIND=1`을 사용하세요.

## 결과물

최종적으로 아래만 남기면 됩니다.

- `results/timeline.log`
- 단계별 `*-summary.json`
- Grafana: Publish / ACK / Queue 그래프
- RabbitMQ Pod 재생성 타임라인
- Loki: Chat/Post 재연결 로그
- 성공 글 수 vs 신규 채팅방 수 비교
