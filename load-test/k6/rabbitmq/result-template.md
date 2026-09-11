# RabbitMQ Load / Recovery Test Result

## 1. 테스트 정보

- 테스트 일시:
- 실행자:
- Git branch:
- Git commit:
- Kubernetes context:
- Namespace:
- 테스트 Round:
  - [ ] Pre-Smoke
  - [ ] Queue Drain
  - [ ] RabbitMQ Failure Recovery
  - [ ] Normal Load (Optional)

---

## 2. Preflight

실행 명령:

~~~bash
./preflight.sh
~~~

결과:

- Kubernetes context:
- RabbitMQ StatefulSet:
- RabbitMQ Pod:
- Post Deployment:
- Chat Deployment:
- RabbitMQ 전용 token:
- Queue 조회:
- Chat Consumer:
- Chat room 조회:

최종 결과:

- [ ] PASSED
- [ ] FAILED

비고:

---

## 3. Baseline

### RabbitMQ

| 항목 | 값 |
|---|---:|
| Queue | |
| messages_ready | |
| messages_unacknowledged | |
| consumers | |

### 애플리케이션

| 항목 | 값 |
|---|---:|
| Post Ready replicas | |
| Chat Ready replicas | |
| RabbitMQ Ready | |
| 테스트 사용자 Chat room 수 | |

Baseline 기록 시각:

- UTC:
- Local:

---

## 4. Pre-Smoke

실행 명령:

~~~bash
./run-load.sh smoke
~~~

### 결과

| 항목 | 값 |
|---|---:|
| 요청 수 | |
| 성공 요청 수 | |
| 실패 요청 수 | |
| HTTP 오류율 | |
| 신규 Chat room 수 | |
| 테스트 전 Queue ready | |
| 테스트 후 Queue ready | |

판정:

- [ ] PASS
- [ ] FAIL

확인 내용:

- [ ] `POST /api/posts` 요청 성공
- [ ] Post → RabbitMQ 이벤트 전달 확인
- [ ] Chat consumer 이벤트 처리 확인
- [ ] Chat room 생성 확인

---

## 5. Queue Drain Test

### 5-1. Chat Consumer 중단

~~~bash
ALLOW_FAULT=1 ./inject.sh chat-down
~~~

- 중단 시각 UTC:
- 중단 시각 Local:
- 기존 Chat replicas:
- 중단 후 Consumer 수:

### 5-2. 이벤트 발생

~~~bash
./run-load.sh smoke
~~~

| 항목 | 값 |
|---|---:|
| 성공 Post 수 | |
| 최대 messages_ready | |
| messages_unacknowledged | |
| Chat Consumer 수 | |

- 최대 Queue backlog:
- 발생 시각:

### 5-3. Chat Consumer 복구

~~~bash
ALLOW_FAULT=1 ./inject.sh chat-up
~~~

- 복구 시작 시각:
- Chat Pod Ready 시각:
- Consumer 재등록 시각:
- Queue Drain 완료 시각:
- Queue Drain 소요 시간:
- 복구된 Chat replicas:

### 5-4. 무결성 확인

| 항목 | 값 |
|---|---:|
| 성공 Post 수 | |
| 신규 Chat room 수 | |
| 차이 | |
| 최종 messages_ready | |
| 최종 messages_unacknowledged | |

판정:

- [ ] PASS
- [ ] FAIL

판정 근거:

---

## 6. RabbitMQ Pod Failure Recovery

### 6-1. 장애 주입

~~~bash
ALLOW_FAULT=1 ./inject.sh rabbitmq-kill
~~~

- Pod 삭제 시각:
- 삭제된 Pod:
- 장애 직전 Queue ready:
- 장애 직전 Consumer 수:

### 6-2. RabbitMQ 복구

- 새 RabbitMQ Pod 생성 시각:
- RabbitMQ Pod Ready 시각:
- Pod 복구 소요 시간:
- Chat 재연결 확인 시각:
- Post 재연결 확인 시각:

### 6-3. 복구 후 상태

| 항목 | 값 |
|---|---:|
| RabbitMQ Ready | |
| messages_ready | |
| messages_unacknowledged | |
| Chat Consumer 수 | |
| 성공 Post 수 | |
| 신규 Chat room 수 | |

확인 내용:

- [ ] RabbitMQ Pod 자동 재생성
- [ ] RabbitMQ Ready 복구
- [ ] Chat RabbitMQ 재연결
- [ ] Post RabbitMQ 재연결
- [ ] Queue 처리 재개
- [ ] 최종 데이터 무결성 확인

판정:

- [ ] PASS
- [ ] FAIL

---

## 7. Normal Load Test (Optional)

| Stage | Rate | Duration | Success | Fail | Max Queue | Drain Time | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| Low | | | | | | | |
| Medium | | | | | | | |
| High | | | | | | | |
| Burst | | | | | | | |

---

## 8. 증거 자료

- Timeline: `results/timeline.log`
- k6 Summary JSON:
- Kubernetes Events:
- RabbitMQ Queue:
- Consumer 변화:
- Grafana Queue backlog:
- Grafana Publish / ACK:
- RabbitMQ CPU / Memory:
- Chat / Post 로그:
- RabbitMQ 재연결 로그:
- Queue Drain 스크린샷:
- RabbitMQ Pod 복구 스크린샷:

---

## 9. 최종 결과

### 핵심 수치

| 항목 | 결과 |
|---|---:|
| 최대 Queue backlog | |
| Queue Drain 시간 | |
| RabbitMQ Pod Ready 복구 시간 | |
| Chat Consumer 재연결 시간 | |
| 성공 Post 수 | |
| 신규 Chat room 수 | |
| 데이터 누락 수 | |

### 최종 판정

- [ ] PASS
- [ ] PARTIAL PASS
- [ ] FAIL

### 확인된 문제

-

### 원인

-

### 조치

-

### 재검증 결과

-

### 발표용 한 줄 요약

>
