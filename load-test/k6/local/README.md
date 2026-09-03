# GameHouse Local Load Test

`infra/load-test/k6/local`은 GameHouse의 로컬 REST 조회 흐름을 짧게 검증하는
k6 시나리오 모음이다. 기존 `infra/load-test/k6`의 장시간 회차와 분리되어 있으며,
이 디렉터리의 기본 대상은 로컬 서비스다.

## 1. 목적

- 로컬 Main backend와 Crew service의 실제 조회 endpoint가 연결되는지 확인
- 로그인과 Bearer JWT 인증 경계를 확인
- 일반 모집글, House, 알림 조회의 초기 latency 기준선을 확인
- 쓰기 요청 없이 안전하게 읽기 부하를 재현

수치는 로컬 머신과 Docker 상태에 의존하므로 실제 서비스 SLO가 아니다.

## 2. 사전 준비

Main backend와 Crew service, 그리고 각 서비스가 의존하는 PostgreSQL/RabbitMQ를
프로젝트의 기존 실행 방법으로 먼저 띄운다.

기본 로컬 주소는 backend Controller와 프로젝트 설정을 기준으로 한다.

| 서비스 | 기본 주소 | 근거 |
| --- | --- | --- |
| Main backend | `http://localhost:8080` | 기존 GameHouse backend 로컬 포트 |
| Crew service | `http://localhost:8086` | `backend/crew/application.yml`의 `server.port` |

Crew는 별도 서비스이므로 House 요청은 `CREW_BASE_URL`로 직접 보낸다.

## 3. k6 설치

```bash
brew install k6
k6 version
```

스크립트가 k6를 자동 설치하지 않는다.

## 4. 테스트 계정 준비

이미 존재하는 로컬 테스트 계정만 사용한다. 계정 생성, 비밀번호 추측, JWT 생성은
하지 않는다.

로그인 계약은 `backend/user/.../AuthController.java`와 `AuthDtos.java` 기준이다.

```http
POST /api/auth/login
Content-Type: application/json

{"email":"...","password":"..."}
```

응답의 `token`과 `user`를 확인하고, 이후 요청에는 frontend `client.js`와 같은
형식으로 `Authorization: Bearer {token}`을 보낸다. 토큰은 출력하지 않는다.

## 5. 환경변수

```bash
export TEST_EMAIL='기존 로컬 테스트 계정 이메일'
export TEST_PASSWORD='기존 로컬 테스트 계정 비밀번호'

# 선택값
export BASE_URL='http://localhost:8080'
export CREW_BASE_URL='http://localhost:8086'
export TEST_HOUSE_ID='승인 멤버인 House ID'
export TEST_POST_ID='조회할 모집글 ID'
```

`TEST_HOUSE_ID`를 지정하면 해당 계정이 승인 멤버인 House의 공지·일정·채팅
history까지 조회한다. 지정하지 않으면 House 목록의 첫 House 상세까지만 조회한다.
공개 목록의 임의 House는 멤버가 아닐 수 있어 보호된 조회를 건너뛴다.

## 6. Smoke 실행

```bash
./load-test/k6/local/run-local.sh smoke
```

VU 1, 15초로 로그인 후 `/api/users/me`, `/api/posts`, House 목록/상세를 확인한다.
`TEST_HOUSE_ID`가 있으면 공지·일정·채팅 history도 확인한다.

## 7. Core Read 실행

```bash
./load-test/k6/local/run-local.sh core-read
```

실제 사용자 탐색 흐름을 단순화해 `/api/users/me` → `/api/posts` → 모집글 상세를
조회한다. 0→5 VU 10초, 5 VU 20초, 5→0 VU 10초로 실행한다.

## 8. House Read 실행

```bash
./load-test/k6/local/run-local.sh house-read
```

Crew의 House 목록 → 상세 → (승인 멤버 House인 경우) 공지 → 일정 → 채팅 history를
조회한다. 가입, 생성, 승인, 공지 작성/삭제, 일정 작성, XP/HC 보상, 대량 채팅은
포함하지 않는다.

## 9. Notification 실행

```bash
./load-test/k6/local/run-local.sh notification-read
```

현재 frontend `src/components/NavBar.jsx`가 `/api/notifications`를 최초 1회와
10초 간격으로 polling하므로, 5 VU가 10초 think time으로 조회한다.

실제 응답 계약은 `items` 배열과 `unreadCount`를 확인한다.

## 10. 실제 조회 endpoint

아래 경로는 backend Controller를 직접 대조한 읽기 대상이다.

| Method | Path | 인증 | 시나리오 |
| --- | --- | --- | --- |
| POST | `/api/auth/login` | 없음 | 모든 시나리오 setup |
| GET | `/api/users/me` | 필요 | smoke/core-read |
| GET | `/api/posts` | 선택 가능, 테스트에서는 JWT 사용 | smoke/core-read |
| GET | `/api/posts/{id}` | 선택 가능, 테스트에서는 JWT 사용 | core-read |
| GET | `/api/crew/houses` | 없음 | smoke/house-read |
| GET | `/api/crew/houses/{houseId}` | 없음 | smoke/house-read |
| GET | `/api/crew/houses/{houseId}/notices` | House 멤버 권한 | smoke/house-read |
| GET | `/api/crew/houses/{houseId}/schedules` | House 멤버 권한 | smoke/house-read |
| GET | `/api/crew/houses/{houseId}/chat/messages` | House 멤버 권한 | smoke/house-read |
| GET | `/api/notifications` | 필요 | notification-read |

쓰기 endpoint는 기본 시나리오에 넣지 않았다.

## 11. 결과 읽는 법

- `http_reqs`: 전체 HTTP 요청 수와 초당 요청량
- `http_req_duration`: 요청의 전체 소요 시간
- `http_req_failed`: k6가 실패로 본 요청 비율
- `iterations`: VU 함수가 완료된 횟수
- `vus`: 현재 가상 사용자 수
- `p90`: 요청 시간의 90%가 이 값 이하라는 뜻
- `p95`: 요청 시간의 95%가 이 값 이하라는 뜻
- `p99`: 요청 시간의 99%가 이 값 이하라는 뜻

기본 threshold는 `http_req_failed rate < 1%`, `http_req_duration p95 < 500ms`다.
이는 로컬 초기 기준값이며 운영 SLO나 성능 보증값이 아니다.

## 12. 주의사항

- `run-local.sh`는 localhost/127.0.0.1 이외의 대상을 기본 차단한다.
- 원격 대상은 `K6_ALLOW_REMOTE=1`을 명시해야 하며, 운영 서버 부하는 권장하지 않는다.
- 실제 계정과 읽기 대상 ID만 사용한다. 운영/공유 데이터에 쓰기 요청을 보내지 않는다.
- 결과를 자동 파일로 저장하지 않는다. 필요하면 k6 설치 버전이 지원하는 옵션으로
  사용자가 별도 경로를 지정한다.
- 결과 디렉터리와 raw k6 산출물은 저장소에 추가하지 않는다.

## 13. WebSocket/STOMP — 2차 테스트 대상

House 채팅은 SockJS `/ws-house`, STOMP `/sub/house/{houseId}`와
`/pub/house/chat`을 사용한다. 이번 1차 시나리오는 REST 조회와 분리하기 위해
WebSocket 부하를 구현하지 않았다.

다음 단계 후보:

- 동시 WebSocket 연결 수
- STOMP CONNECT JWT 검증
- House topic SUBSCRIBE
- SEND 및 broadcast fan-out

프로토콜 구현을 불완전하게 넣어 REST 결과를 오염시키지 않는 것이 목적이다.
