# 부하 테스트 — 실행

> 로컬 수치는 성능 판정에 쓰지 않는다. 로컬은 스크립트와 경로를 검증하는 곳이고,
> 성능 수치는 AWS 회차에서 처음 유효하다.

세 가지 중 하나를 고른다.

| | 무엇을 보나 | 무엇을 띄우나 |
| --- | --- | --- |
| **1. k6 수치만** | 터미널 요약 + `results/` 파일 | backend 만 |
| **2. 그래프까지** | 위 + Grafana 대시보드 | backend + 관측 스택 |
| **3. N+1 프로브** | 항목 1건당 쿼리 수 표 | backend 만 |

---

## 1. k6 수치만 본다 (터미널)

### 띄우기

```bash
cd infra

docker compose --env-file .env.local \
  -f docker-compose.yml \
  -f docker-compose.local.yml \
  up -d backend
```

### 회차 실행

**시딩 → 재시작 → 정리 잡 → 회차** 순서다.

```bash
cd infra

# 1. 시딩 — 계정 800 · 글 300 · 신청 1,000 (약 25초)
./load-test/seed/generate.sh

# 2. 대상 재시작 — 시딩이 대상 메모리를 먹는다
docker compose --env-file .env.local \
  -f docker-compose.yml \
  -f docker-compose.local.yml \
  up -d --force-recreate backend

# 3. 정리 잡 — 별도 터미널에서 회차 내내 켜 둔다 (회차 A·B·C 필수, D 불필요)
./load-test/cleanup/steady-state.sh

# 4. 회차
./load-test/run.sh round-a
```

회차별 명령:

```bash
# 스모크 — 경로 검증 (8초). 시딩과 회차에 SCALE 을 같은 값으로 준다
SCALE=smoke ./load-test/seed/generate.sh
SCALE=smoke ./load-test/run.sh smoke

./load-test/run.sh round-a    # Load        18분 30초
./load-test/run.sh round-b    # Break Point 14분 10초 (12분 + 복구 확인 2분 10초)
./load-test/run.sh round-c    # Spike       4분 5초

# 회차 D — 게시글 수를 바꿔가며 4번 (회차당 3분). 정리 잡은 끄고 돌린다
./load-test/run.sh round-d                 # 300건
./load-test/seed/grow.sh 1000  && ./load-test/run.sh round-d
./load-test/seed/grow.sh 3000  && ./load-test/run.sh round-d
./load-test/seed/grow.sh 10000 && ./load-test/run.sh round-d
```

회차 D 네 줄은 **한 줄씩 확인하며 돌린다.** 한 번에 붙여도 순차로 돌긴 하지만,
줄 사이는 `&&` 가 아니라서 중간이 실패해도 나머지가 그대로 실행된다 —
잘못된 데이터 위에서 남은 회차가 돈다. 한 번에 돌릴 거면 전부 `&&` 로 잇는다.

> 시딩이 20시간을 넘으면 `run.sh` 가 JWT 만료(24h)를 경고하고 **Enter 를 기다린다.**
> 붙여넣고 자리를 비우면 거기서 멈춰 있으니, 시딩 직후에 시작한다.

- **회차 A·B·C 사이마다** 시딩을 다시 돌린다. 안 하면 앞 회차가 남긴 데이터 위에서 잰다.
  회차 D 네 줄 사이에는 돌리지 않는다 — `grow.sh` 로 쌓아 올리는 것이 이 회차의 설계다.
- 정리 잡은 **하나만** 띄운다 (`pgrep -f steady-state.sh` 로 중복 확인).
- 첫 페이지 구성까지 고정하려면 `INTERVAL=1 BATCH=20 ./load-test/cleanup/steady-state.sh`. 단 `--queries` 회차에는 붙이지 않는다.
- 로컬 회차는 자동으로 축소된다(135 → 5 RPS). `manifest.json` 의 `load.reduced` 가 `true` 면 판정 근거가 아니다.

---

## 2. k6 수치를 그래프로 본다 (Grafana)

### 띄우기

```bash
cd infra

# ⚠️ -p gamehouse 를 반드시 붙인다. 빼면 프로젝트 이름이 gamehouse-observe 로
#    잡혀서 컨테이너 이름 충돌 또는 network not found 로 실패한다
docker compose -p gamehouse --env-file .env.local \
  -f docker-compose.yml \
  -f docker-compose.local.yml \
  -f docker-compose.observability.yml \
  -f docker-compose.observability.local.yml \
  up -d
```

| | 주소 |
| --- | --- |
| Grafana | http://localhost:13000 (`.env.local` 의 `GF_ADMIN_*`) |
| Prometheus | http://localhost:19090 |
| postgres-exporter | http://localhost:19187/metrics |

exporter 가 로컬 DB 를 보고 있는지 확인 (회차를 돌리면 값이 올라가야 한다):

```bash
curl -s localhost:19187/metrics | grep 'pg_stat_user_tables_idx_scan.*posts'
```

### 회차 실행

1절과 같고 **`--prom` 만 더 붙인다.** 붙인 회차만 k6 패널에 들어간다.

```bash
cd infra

# 1. 시딩
./load-test/seed/generate.sh

# 2. 대상 재시작 (관측 스택은 그대로 두고 backend 만)
docker compose -p gamehouse --env-file .env.local \
  -f docker-compose.yml \
  -f docker-compose.local.yml \
  -f docker-compose.observability.yml \
  -f docker-compose.observability.local.yml \
  up -d --force-recreate backend

# 3. 정리 잡 — 별도 터미널
./load-test/cleanup/steady-state.sh

# 4. 회차 — 담고 싶은 회차마다 --prom
./load-test/run.sh round-a --prom
```

대시보드는 **`10 load test`** 다. 회차를 고르는 변수는 없으니 상단 time picker 로 그 회차가 돈 구간을 잡는다 (`results/<testid>/` 의 폴더명이 시작 시각이다).

k6 패널을 채우는 것은 부하 회차(A·B·C)다. 회차 D 는 1 RPS 시나리오 1 단독이라 대부분 비어 보인다.

### 짧은 회차를 자세히 볼 때 (선택)

전역 수집 간격이 30초라 짧은 회차는 점이 몇 개 안 찍힌다. 힙 톱니나 GC 스파이크를
보려면 backend job 만 5초로 낮춘다.

```
회차 A  18분 30초 ÷ 30s = 약 37점   그대로 충분
회차 C   4분  5초 ÷ 30s =    8점    부족
회차 D   3분      ÷ 30s =    6점    부족
```

```bash
cd infra

# 켠다 — backend job 에만 5s 를 넣고 설정만 다시 읽힌다 (재시작 아님)
sed -i '' '/^  - job_name: backend$/a    scrape_interval: 5s
' observability/prometheus.yml
docker kill -s HUP gamehouse-prometheus

# 끈다 — 회차가 끝나면 되돌린다
git checkout observability/prometheus.yml
docker kill -s HUP gamehouse-prometheus
```

> ⚠️ **이 변경은 커밋하지 않는다.** `observability/prometheus.yml` 은 운영과 같이 쓰는
> 파일이고 `deploy.sh` 가 `develop` 을 pull 해서 올린다. 커밋해서 머지되면 운영도 5초가 된다.
> `git status` 에 뜨는지 확인하고 회차가 끝나면 되돌린다.

수집량은 전체 기준 약 +19% 늘어난다(backend 300계열 기준 10 → 60 samples/s). 활성 계열
수는 그대로라 Prometheus 메모리는 거의 변하지 않는다.

### 내리기

위 `up -d` 를 `down` 으로 바꾼다. `-p` 와 `-f` 목록을 그대로 반복한다 — 빠뜨리면 일부만 내려간다.

---

## 3. N+1 프로브

목록 API 전체를 훑어 항목 1건당 쿼리 수를 낸다. 회차와 무관하고 backend 만 있으면 된다.

```bash
cd infra
pkill -f steady-state.sh                   # 정리 잡을 끈다 (켜져 있으면 20~70% 부풀어 나온다)

./load-test/n-plus-one/probe.sh fixture    # 잴 수 있게 데이터를 만든다 (1회)
./load-test/n-plus-one/probe.sh run        # 약 2분 30초
./load-test/n-plus-one/probe.sh reset      # 프로브 데이터 제거
```

| 옵션 | 무엇 |
| --- | --- |
| `--reqs N` | 엔드포인트당 요청 수 (기본 3). `잡음` 이 20% 를 넘으면 올린다 |
| `--only a,b` | 키: `posts` `my-apps` `chat-rooms` `friends` `notifications` `users-me` |
| `PROBE_EMAIL=` | 측정 대상 계정 (기본 `lt0001@test.local`) |

```bash
./load-test/n-plus-one/probe.sh run --only friends,notifications --reqs 40
```

- `잡음` 열을 먼저 본다. 20% 를 넘으면 `판정보류` 가 뜬다.
- `fixture` 는 회차용 시딩 상태를 바꾼다. 프로브 뒤에 부하 회차를 돌릴 거면 `seed/generate.sh` 를 다시 돌린다.

---

## 옵션

```
./run.sh <회차> [--raw] [--full] [--queries] [--prom] [-- k6 인자...]
```

| 옵션 | 무엇 | 어느 회차에 |
| --- | --- | --- |
| `--prom` | k6 지표를 Prometheus 로 remote write | A·B·C (담고 싶은 회차마다) |
| `--queries` | 회차 전후 `pg_stat_user_tables` 델타로 쿼리 수 (`queries.txt`) | **D 전용.** A·B·C 는 시나리오가 섞여 의미가 없다 |
| `--raw` | 요청 단위 원시 데이터 (회차 A 압축 전 400MB 대) | B·C. 회차 A 에는 켜지 않는다 |
| `--full` | 로컬 축소를 끄고 AWS 값 그대로 | 한계 확인. 완주하지 못한다 |
| `LOCAL_CAP=1/9` | 축소 배율 (기본 `1/27`). **분수로 준다** | 5 → 15 RPS |

```bash
./load-test/run.sh round-d --queries
LOCAL_CAP=1/9 ./load-test/run.sh round-a

ulimit -n 10240                        # --full 전에. macOS 기본 256 으로는 VU 400 이 안 뜬다
./load-test/run.sh round-a --full
```

## 회차 직후 점검

모두 **"예" 여야 한다.** 하나라도 "아니오" 면 결과를 해석하지 않고 오른쪽 칸대로 한다.

| 확인 | 어디서 | 아니면 |
| --- | --- | --- |
| 대상이 끝까지 살아 있었나 (`OOMKilled` 이 `false`) | `docker inspect gamehouse-backend --format '{{.State.OOMKilled}}'` | **폐기.** 커널이 죽인 것이다 |
| `dropped_iterations` 이 **0** 인가 | `summary.txt` 투입 | **구간 폐기.** 목표 rate 를 못 채운 것이라 서버가 느린 것과 구분되지 않는다 |
| 달성 RPS 가 목표에 근접하나 | `summary.txt` 투입 | 러너 CPU·네트워크를 먼저 본다 |
| 축소 모드가 **아니었나** (`load.reduced` 이 `false`) | `manifest.json` | 판정 근거가 아니다. 완주 검증 회차다 |
| 시딩 프로파일·건수가 기대와 같나 | `manifest.json` 의 `seed` | 폐기 |
| `exitCode` 가 **0 또는 99** 인가 | `manifest.json` | 실행 오류라 결과를 쓰지 않는다 (99 는 threshold 위반이고 회차는 완주한 것이라 정상) |

회차가 남기는 것:

```
results/20260812-181354-round-a/
  summary.txt         판정 요약
  summary.json        k6 원본
  manifest.json       시딩 meta · exit code · 축소 모드 · promRw · 러너 정보
  load-mode.json      축소 회차와 --full 회차에만
  queries.txt         --queries 에만
  queries.json        --queries 에만
  pgstat-before.json  --queries 에만
```

## 끝낼 때

```bash
./load-test/seed/reset.sh    # 테스트 데이터 전량 삭제 + seed/data/ 정리
```

| | 무엇을 지우나 | 언제 |
| --- | --- | --- |
| `seed/generate.sh` | 전부 지우고 곧바로 다시 시딩 | 회차 사이 |
| `cleanup/steady-state.sh` | 부하 계정이 만든 글만 (`[SEED]` 는 안 건드린다) | 회차 **중** 상시 |
| `seed/reset.sh` | 전부 지우고 비운 채로 둔다 (`seed/data/*.json` 포함) | 부하 테스트 종료 |

## 그 밖에

설계 가정 검증 (1회):

```bash
./load-test/preflight/response-size.sh      # 응답 크기 · 한 페이지 건수
./load-test/preflight/actuator-labels.sh    # 힙 id · GC 종류
./load-test/preflight/histogram-buckets.sh  # SLO 값이 버킷 경계 위인가
```

단발 요청 하나의 쿼리 수만 잴 때:

```bash
./load-test/query-count.sh before
curl -s -o /dev/null localhost:8080/api/posts -H "Authorization: Bearer $TOKEN"
./load-test/query-count.sh after --reqs 1
```
