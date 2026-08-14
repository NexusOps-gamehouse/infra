# 부하 테스트 — 실행

> **로컬 수치는 성능 판정에 쓰지 않는다.** 로컬은 스크립트와 경로를 검증하는 곳이다.
> 성능 수치는 AWS 회차에서 처음 유효하다.

## 1. 빠른 시작

백엔드가 떠 있다는 전제로 네 단계다.

```bash
cd infra

# 1. 시딩 — 계정 800 · 글 300 · 신청 1,000 + 토큰 사전 발급 (약 25초)
./load-test/seed/generate.sh

# 2. 대상 재시작 — 시딩이 대상 메모리를 먹는다
docker compose --env-file .env.local \
  -f docker-compose.yml -f docker-compose.local.yml up -d --force-recreate backend

# 3. 정리 잡 — 별도 터미널에서 회차 내내 켜 둔다
./load-test/cleanup/steady-state.sh

# 4. 회차 실행
./load-test/run.sh smoke      # 8초. 경로 검증
./load-test/run.sh round-a    # 18분 30초. 로컬에서는 자동으로 축소 모드
```

### 빠뜨리면 안 되는 세 가지

> **3번을 빠뜨리면 회차가 통째로 오염된다.** 시나리오 5 가 초당 6건씩 글을 만드는데
> 목록 API 에 페이징도 상한도 없어서, 15분이면 300 → 5,700 건이 된다. 응답이 300KB →
> 5MB 로 불어나면 "135 RPS 에서의 성능" 이라는 말 자체가 성립하지 않는다.
> **에러가 안 나므로 결과를 볼 때까지 모른다.**

> **2번을 빠뜨리면 회차 도중 대상이 죽는다.** 대상은 요청 수에 비례해 메모리가 늘고
> 반환하지 않는다. 시딩의 토큰 발급만으로 800 요청이라
> 그것만으로 한도에 근접한다. 회차는 깨끗한 메모리에서 시작해야 한다.

> **로컬 회차는 자동으로 축소된다.** `run.sh` 가 대상이 localhost 면 배율과 VU 를
> 낮춘다(135 → 5 RPS). 성능을 재는 것이 아니라 **스크립트가 완주하는지** 보는 것이라
> 그렇다. 축소 사실은 시작 배너·요약 헤더·`manifest.json` 세 곳에 남는다.
> **축소 회차의 5 RPS 결과를 135 RPS 결과로 보고하지 않는다.**

---

## 2. 준비 (1회)

```bash
cd infra

# 대상만 띄운다. depends_on 이 postgres·rabbitmq 를 같이 올린다.
# frontend 와 관측 스택은 API 부하 테스트에 필요 없다.
docker compose --env-file .env.local \
  -f docker-compose.yml -f docker-compose.local.yml up -d backend

# 설계 가정 검증
./load-test/preflight/response-size.sh      # PostDto 실제 크기
./load-test/preflight/actuator-labels.sh    # 힙 id · GC 종류 실물
./load-test/preflight/histogram-buckets.sh  # SLO 값이 버킷 경계 위인가
```

> **로컬은 k6 네이티브 + 터미널 출력만 쓴다.** Prometheus·Grafana·대시보드를 띄우지 않는다.
> 로컬의 목적은 스크립트와 경로 검증이지 성능 판정이 아니라서, 숫자를 보관할 이유가 없다.
> 관측 스택을 안 띄우면 회차 중 Discord 알람도 울리지 않는다.

---

## 3. 회차 전 점검

```
□ backend 가 떠 있는가              curl localhost:8080/api/posts
□ 시딩 뒤에 대상을 재시작했는가     docker stats 로 RSS 가 500MB 근처인지 본다
□ 시딩이 1시간 이내인가             PENDING_TTL = 1시간
□ 정리 잡이 돌고 있는가             pgrep -f steady-state.sh — 중복 실행도 같이 본다
□ scale 파일과 시딩이 같은가        assertSeed() 가 자동으로 잡는다
```

마지막 항목은 자동이다. 어긋나면 회차가 시작되기 전에 멈춘다.

```
[seed] 계약 ① 불일치 — seed/generate.sh 를 다시 돌릴 것
  - 프로파일 'smoke' ≠ 기대 'round' — 다른 규모로 시딩된 데이터다
  - 계정 20 ≠ 기대 800
```

> **정리 잡은 하나만 띄운다.** 이전 회차의 것이 남아 있으면 중복으로 돈다. 동작은 하지만
> DB 에 배경 쿼리가 계속 섞여 들어가 다른 측정을 방해한다.

**정리 잡은 회차 A·B·C 에 전부 필요하다.** 세 회차 다 시나리오 8개를 투입하고, 그중 시나리오 5
(`POST /api/posts`)가 계속 글을 만든다. 회차 D 만 시나리오 1 단독이라 필요 없다.

| 회차 | 시나리오 5 가 만드는 글 | 정리 잡 |
| --- | --- | --- |
| A | 6 RPS × 15분 ≈ 5,400 건 | **필수** |
| B | 배율 1/3~2 × 12분 ≈ 4,300 건 | **필수** |
| C | 4분 5초 (270 구간에서 12 RPS) | **필수** |
| D | 안 돈다 | 불필요 |

---

## 4. 회차 실행

**회차마다 네 가지를 순서대로 한다.** 시딩은 회차 사이마다 다시 돌린다 — 안 하면 앞 회차가
남긴 데이터 위에서 재기 때문에 회차별 비교가 성립하지 않는다.

```bash
cd infra

# 스모크 — 경로 검증. 시나리오당 3초에 1회, 8초 (시나리오당 약 3요청)
SCALE=smoke ./load-test/seed/generate.sh
SCALE=smoke ./load-test/run.sh smoke

# 회차 A — 15분 + 앞뒤 3분30초. AWS 에서는 판정 회차, 로컬에서는 완주 검증
./load-test/seed/generate.sh          # SCALE 없이 = round 프로파일 (800·300·1,000)
./load-test/run.sh round-a

# 회차 B — Break Point 탐색 (12분)
./load-test/run.sh round-b

# 회차 C — 스파이크 (4분5초)
./load-test/run.sh round-c

# 회차 D — 데이터 증가. 게시글 수를 바꿔가며 4번 반복
./load-test/run.sh round-d                 # 300건
./load-test/seed/grow.sh 1000              # 채우고 meta.json 갱신
./load-test/run.sh round-d                 # 1,000건
./load-test/seed/grow.sh 3000
./load-test/run.sh round-d                 # 3,000건
./load-test/seed/grow.sh 10000
./load-test/run.sh round-d                 # 10,000건
```

**`run.sh` 로 돌린다.** k6 를 직접 불러도 되지만, 래퍼가 회차 전후로 네 가지를 더 한다 —
시딩 프로파일 확인, `testid` 부여, exit code 기록, `manifest.json` 저장.

<details>
<summary>k6 를 직접 부르는 경우</summary>

결과 파일과 `testid` 가 남지 않는다. 스크립트만 빠르게 확인할 때 쓴다.

```bash
SCALE=smoke k6 run load-test/k6/rounds/smoke.js
k6 run load-test/k6/rounds/round-a-load.js
```

</details>

### `SCALE` — 시딩과 회차에 같은 값을 준다

한쪽만 주면 회차가 시작되기 전에 멈춘다.

```
시딩 프로파일이 다르다: 지금 데이터='smoke' / 이 회차가 기대='round'
  'round' 규모로 다시 시딩한다: ./load-test/seed/generate.sh
```

스모크 데이터(계정 20개)로 회차를 돌리면 여러 VU 가 같은 계정을 잡아 500 이 나고,
그건 서버 결함과 구분되지 않는다. 그래서 경고가 아니라 정지다.

`SCALE` 은 경로가 아니라 **프로파일 이름**이다 — `smoke` → `scale.smoke.json`.
경로로 받으면 bash 는 실행 위치(CWD) 기준으로, k6 의 `open()` 은 파일 위치 기준으로 풀어서
같은 문자열이 양쪽에서 다른 파일을 가리킨다. 이름으로 받으면 어디서 실행하든 같다.

---

## 5. 옵션

| 옵션 | 무엇 | 언제 |
| --- | --- | --- |
| `--raw` | 요청 단위 원시 데이터까지 남긴다 (회차 A 기준 압축 전 400MB 대) | 회차 B·C 에서 무너지는 순간을 파고들 때 |
| `--queries` | 회차 전후 `pg_stat_user_tables` 델타로 쿼리 수를 센다 | N+1 판별 (회차 D) |
| `--full` | 로컬에서 축소를 끄고 AWS 값 그대로 | 한계 확인 |
| `LOCAL_CAP=1/9` | 축소 배율을 직접 준다 (기본 1/27) | 5 → 15 RPS 로 올려 볼 때 |

회차와 무관한 도구가 둘 더 있다.

| 도구 | 무엇 | 언제 |
| --- | --- | --- |
| `query-count.sh` | 임의 구간의 쿼리 수를 센다 (`--queries` 가 이걸 부른다) | 요청 하나를 직접 잴 때 |
| `n-plus-one/probe.sh` | 의심 API 목록을 하나씩 두드려 항목당 쿼리 수를 표로 | **목록 API 전체를 훑을 때** |

### 로컬 축소 모드 (회차 A·B·C)

대상이 `localhost` 면 `run.sh` 가 `LOCAL=1` 을 넘기고, `config.js` 가 **배율과 VU 를 함께**
낮춘다. 회차의 모양(단계 구성·지속 시간)은 그대로다 — 크기만 줄인다.

| | AWS | 로컬 |
| --- | --- | --- |
| Sustained | 135 RPS | **5 RPS** (`LOCAL_CAP` 기본 1/27) |
| VU (회차 A) | 300 / 400 | **20 / 40** |
| 도착률 창 | 3s | **27s** (상한에서 자동 계산) |
| 지속 시간 | 18분 30초 | 그대로 |

**왜 이렇게까지 낮추나.** 로컬이 느려서가 아니라 대상이 **요청 수에 비례해 죽기** 때문이다.
실측으로 45 RPS 는 46초, 15 RPS 는 10분 42초에 OOM 됐다. 5 RPS 는 계산상 회차 길이를
버틴다 — `5 RPS × 1,110초 × 요청당 125KB ≈ 690MB < 여유 약 950MB`.

```bash
LOCAL_CAP=1/9 ./load-test/run.sh round-a     # 15 RPS 로 올려 본다 (완주 못 할 수 있다)
```

`LOCAL_CAP` 은 **분수로 준다.** `0.111` 처럼 쓰면 도착률이 정수로 떨어지지 않아
회차가 시작 전에 멈춘다(의도된 것이다). 창 길이는 상한에서 자동으로 정해진다.

### `--full` — 로컬에서 전체 규모로

축소를 끄고 AWS 값(135 RPS · VU 300/400) 그대로 돌린다. **완주하지 못한다** — 위 실측대로
45 RPS 가 46초에 죽으니 135 RPS 면 1분 안이다. 그래서 이건 판정이 아니라 **한계 확인**이다.

```bash
ulimit -n 10240                        # macOS 기본 256 으로는 VU 400 이 안 뜬다
./load-test/run.sh round-a --full      # 확인을 한 번 물어본다
```

두 경우에만 쓴다 — 메모리 증가를 고친 뒤 **정말 고쳐졌는지** 확인할 때(축소 회차는 5 RPS 라
누수가 있어도 완주한다), `mem_limit` 을 올린 compose 로 **어디까지 버티는지** 볼 때.

**`LOCAL=0` 으로 속이지 않는다.** 그렇게 하면 축소는 똑같이 꺼지지만 요약 하단의
`⚠ 로컬 실행이다` 경고까지 사라져서, Rosetta 에뮬레이션 위에서 나온 숫자가 정상 회차 결과처럼
남는다. `--full` 은 **축소만 끄고 '로컬' 이라는 사실은 남긴다** — `manifest.json` 의
`load.localFull: true` 가 그것이다. 시딩은 그대로 쓴다.

### `--queries` — 쿼리 수 측정

```bash
./load-test/run.sh round-d --queries
```

```
════════════════════════════════════════════════════════════════════════════
 쿼리 수 — pg_stat_user_tables 델타
 localhost:15432/duo · 요청 10건 · 분모 게시글 300건
════════════════════════════════════════════════════════════════════════════

  테이블                          스캔       요청당        건당      쓰기
  applications                  9,008      900.8       3.003         0
  chat_rooms                    3,016      301.6       1.005         0
  users                            64        6.4       0.021        10
  posts                            27        2.7       0.009         0
```

읽는 법은 **`건당` 열 하나**다. 계산식이 그대로 뜻이다.

```
건당 = 스캔 ÷ 요청 수 ÷ 분모        분모는 표 위 머리글이 말한다 (여기서는 게시글 300건)

applications:  9,008 ÷ 10 = 900.8  ÷ 300 = 3.003
```

`GET /api/posts` 한 번은 글 300건을 응답에 담는다. **그 300건 하나하나마다** `applications`
를 3번씩 더 조회했다는 뜻이다. 코드와 맞는다 — `PostService.toDto()` 가 글마다
`findByPostIdAndApplicantId` 1번 + `countByPostIdAndStatus` 2번을 부른다.

**`요청당` 이 아니라 `건당` 을 보는 이유.** `요청당`(900.8)은 글이 늘면 같이 커진다.
글을 3,000건으로 늘리면 9,008 이 되는데, 데이터를 10배로 넣었으니 당연한 것이라 알려주는 게 없다.
`건당` 은 데이터 양으로 나눠버린 값이라 **코드의 모양만 남는다** — 글이 300건이든 3,000건이든
3.003 이다. "글 하나를 응답에 넣는 데 쿼리 몇 개를 쓰는 구현인가" 이고, 이건 데이터가 아니라
코드가 정한다.

| 테이블 | 건당 | 무슨 뜻 |
| --- | --- | --- |
| `posts` | 0.009 | 요청당 2.7번인데 **글이 몇 건이든 2.7번**이다 (목록을 가져오는 본 쿼리) |
| `users` | 0.021 | 마찬가지로 글 수와 무관한 고정 비용 |
| `chat_rooms` | **1.005** | 글 하나당 1번 |
| `applications` | **3.003** | 글 하나당 3번 |

위 둘은 쿼리 수가 글 수와 무관해서, 고정값을 300 으로 나누니 0 에 가까워진다. 글을 3,000건으로
늘리면 더 작아진다. 아래 둘은 쿼리 수가 글 수에 붙어 있어서 아무리 나눠도 1 과 3 에서 안 떨어진다.
**1번(목록) + N번(글마다) 이 곧 N+1 이라, `건당` 이 정수 근처에 고정되는 것 자체가 신호다.**
3.003 의 소수점 0.003 은 글 수와 무관한 잔여 고정 비용이다.

**다만 한 회차만으로 확정하지 않는다** — 두 회차를 비교한다.

> ⚠️ **재는 동안 다른 트래픽이 없어야 한다.** 정리 잡(`cleanup/steady-state.sh`)의 DELETE 도
> 같이 세어진다. 회차 D 는 시나리오 1 단독(쓰기 없음)이라 정리 잡이 필요 없고, 그래서 이 측정에
> 가장 알맞은 회차다. 회차 A·B·C 에 붙이면 8개 시나리오가 섞여 `건당` 열의 의미가 흐려진다.

**단발 요청 하나만 재고 싶을 때**는 스크립트를 직접 쓴다. 회차와 무관하다.

```bash
./load-test/query-count.sh before
curl -s -o /dev/null localhost:8080/api/posts -H "Authorization: Bearer $TOKEN"
./load-test/query-count.sh after --reqs 1
```

### 다른 API 도 재기 — `n-plus-one/probe.sh`

`--queries` 는 회차가 부르는 API 만 본다. 목록 API 전체를 훑으려면 프로브를 쓴다.
**세 줄이다.**

```bash
cd infra
./load-test/n-plus-one/probe.sh fixture    # 잴 수 있게 데이터를 만든다 (1회)
./load-test/n-plus-one/probe.sh run        # 약 2분 30초
./load-test/n-plus-one/probe.sh reset      # 프로브 데이터 제거
```

```
  경로                            항목      요청당       건당   잡음   판정
  /api/posts                         300      1215.3       4.05     0%   ⚠ N+1
  /api/my/applications                30        65.3       2.18     1%   ⚠ N+1
  /api/chat/rooms                     10       106.3      10.63     0%   ⚠ N+1
  /api/friends                        30        34.3       1.14     1%   ⚠ N+1
  /api/notifications                  30         5.3       0.18     6%   정상
  /api/users/me                        1         4.3       4.33     8%   대조군
```

**`fixture` 가 왜 필요한가.** 회차용 시딩은 계정·글·신청만 만든다. 채팅방·친구·알림은 0건이라
그대로 재면 빈 배열이 오고, 그건 "N+1 이 없다" 가 아니라 "잰 적이 없다" 다. 분모가 0 이면
`건당` 을 계산할 수 없다. `fixture` 는 계정 하나(`lt0001@test.local`)에 친구 30 · 알림 30 ·
채팅방 10(멤버 5) · 신청 30 을 몰아준다. 30인 이유는, 분모가 한 자리면 `건당 1회`(N+1)와
`상수 1회`(정상)가 안 갈리기 때문이다.

> ⚠️ **`fixture` 는 회차용 시딩 상태를 바꾼다.** 프로브 뒤에 부하 회차를 돌릴 거면
> `seed/generate.sh` 를 다시 돌린다. `reset` 은 프로브가 만든 것만 지운다.

| 옵션 | 무엇 |
| --- | --- |
| `--reqs N` | 엔드포인트당 요청 수 (기본 3). **가벼운 API 는 40 정도로 올린다** — 아래 참조 |
| `--only a,b` | 일부만. 키: `posts` `my-apps` `chat-rooms` `friends` `notifications` `users-me` |
| `PROBE_EMAIL=` | 측정 대상 계정 (기본 `lt0001@test.local`) |

**`잡음` 열을 먼저 본다.** 측정 창에 든 모든 쿼리를 세기 때문에, DB GUI 나 프런트 탭이
붙어 있으면 그것도 들어온다. 20% 를 넘으면 `판정보류` 가 뜬다 — 그때는 `--reqs` 를 올린다
(잡음은 창 길이에, 신호는 요청 수에 비례한다).

```bash
./load-test/n-plus-one/probe.sh run --only friends,notifications --reqs 40
```

정리 잡을 끄지 않으면 값이 20~70% 부풀어 나오니, 재기 전에 `pkill -f steady-state.sh` 를 먼저 한다.

**`--raw` 는 기본으로 끈다.** 이유는 용량이 아니다 — 압축하면 회차 A 가 25 MB 뿐이다.
압축 *전* 552 MB 를 회차 내내 실시간으로 만들어내면서 CPU 와 디스크 I/O 가 부하 생성과
경쟁하고, **러너가 먼저 포화되면 `dropped_iterations` 가 나서 그 구간이 폐기된다.**
회차 A 에는 켜지 않는다(판정 회차라 오염을 감수할 수 없다). 회차 D 는 720 요청 ≈ 3 MB 라 무해하다.

---

## 6. 회차 직후 — 이 측정이 유효한가

**여기서 하나라도 걸리면 결과를 해석하지 않고 재측정한다.** 무효한 측정의 p95 를 읽는 것은
시간 낭비가 아니라 **잘못된 결론의 출처**다.

| 확인 | 어디서 | 걸리면 |
| --- | --- | --- |
| **대상이 끝까지 살아 있었나** | `docker inspect gamehouse-backend --format '{{.State.OOMKilled}}'` | **폐기.** `true` 면 커널이 죽인 것이다. 요약 맨 위의 연결 실패 블록이 먼저 알려준다 |
| `dropped_iterations` = 0 | `summary.txt` 투입 | **구간 폐기.** 목표 rate 를 못 채운 것이라 서버가 느린 것과 구분되지 않는다 |
| 달성 RPS ≈ 목표 | `summary.txt` 투입 | 러너 CPU·네트워크를 먼저 본다. 러너 여유 + 서버 포화여야 원하는 관측이다 |
| 축소 모드였나 | `manifest.json` 의 `load.reduced` | `true` 면 **판정 근거가 아니다.** 완주 검증 회차다 |
| 시딩 프로파일·건수 | `manifest.json` 의 `seed` | 폐기. `assertSeed()` 가 보통 시작 전에 잡는다 |
| 정리 잡이 돌았는가 | 별도 터미널 | 목록이 300 → 5,700 건으로 불어나 회차 내내 조건이 달라진다 |
| `exitCode` | `manifest.json` | **99 는 오류가 아니라 결과다** (threshold 위반, 회차는 완주). 그 외 값은 실행 오류라 결과를 쓰지 않는다 |

> **대상 사망은 로그에 안 남는다.** cgroup OOM 은 커널이 SIGKILL 을 보내는 것이라
> `docker logs` 가 조용하고, macOS 에서는 `dmesg` 도 못 쓴다. 확정시켜 주는 것은
> `docker inspect` 의 `OOMKilled` 한 줄뿐이다. 실측으로 세 번 겪었다.

### 회차가 남기는 것

```
results/20260812-181354-round-a/
  summary.txt      사람이 읽을 판정 요약        약 2 KB
  summary.json     k6 원본 구조. 재분석용       약 5 KB
  manifest.json    시딩 meta 사본 · exit code · 축소 모드 · 러너 정보   약 1 KB
  load-mode.json   축소 회차와 --full 회차에만. 적용된 상한·창·VU
  queries.txt      --queries 에만. 테이블별 스캔 수 표
  queries.json     --queries 에만. 그 표의 기계용 원본
  pgstat-before.json  --queries 에만. 회차 직전 카운터. 델타의 기준점이라 남긴다
```

`testid` 는 디렉토리 이름이자 k6 태그다. **둘이 같은 값이라 Grafana 에서 `$testid` 로 고른
그래프와 `results/` 의 폴더가 이어진다.**

로컬에서는 `results/` 가 그냥 남는다. **AWS 회차는 러너를 종료하면 같이 사라지므로 회수 절차가
따로 필요하다**

---

## 7. 끝낼 때

```bash
# 테스트 데이터 전량 삭제 + seed/data/ 정리
./load-test/seed/reset.sh
```

세 가지 정리 수단의 쓰임이 다르다.

| | 무엇을 지우나 | 언제 |
| --- | --- | --- |
| `generate.sh` | 전부 지우고 **곧바로 다시 시딩** (`00-reset` 이 1단계) | 회차 사이 |
| `cleanup/steady-state.sh` | 부하 계정이 만든 글만. `[SEED]` 는 안 건드린다 | 회차 **중** 상시 |
| `seed/reset.sh` | 전부 지우고 **비운 채로 둔다**. `seed/data/*.json` 도 함께 | 부하 테스트 종료 |

`reset.sh` 가 JSON 까지 지우는 이유: DB 만 비우고 `post-ids.json` 을 남기면 없는 PK 를 가리키게 되고,
그 상태로 회차를 돌리면 시나리오 2·4 가 전부 404 를 받는다. **404 는 이제 실패로 잡히므로 회차는
끝까지 정상으로 돌고 결과만 무의미해진다.**
