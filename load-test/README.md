# 부하 테스트

> **로컬 수치는 성능 판정에 쓰지 않는다.** 로컬은 스크립트와 경로를 검증하는 곳이다.
> 성능 수치는 AWS 회차에서 처음 유효하다.

---

## 1. 구조

```
load-test/
  README.md
  .gitignore              seed/data/ 와 results/ 를 제외한다

  scale.json              ★ 시딩 규모의 유일한 출처 (계정 600 · 글 300 · 신청 1,000)
  scale.smoke.json        ★ 작게 돌릴 때 (5 · 10 · 30). 값을 고치지 말고 파일을 갈아끼운다
  db.sh                   ★ DB 접속 + 운영 DB 보호 가드. seed/ 와 cleanup/ 이 source 한다

  k6/lib/
    config.js    ★계약②★  태그·등급·엔드포인트·단계 배율. scale.json 을 읽는다
    data.js               seed 산출물 로더. SharedArray + VU↔계정 1:1 매핑

  seed/
    generate.sh  ★계약①★  시딩 실행 + 토큰 사전 발급 → data/*.json 산출
    reset.sh              테스트 데이터 전량 삭제 + data/ 정리
    sql/
      00-reset.sql        @test.local 계정에 딸린 것만 삭제 (TRUNCATE 아님)
      01-users.sql        부하 계정 :accounts 개 + 시딩 작성자 1개
      02-posts.sql        _post-rows.sql 을 :posts 건으로 호출
      03-applications.sql 신청 :applications 건. 중복 쌍이 안 나오게 결정론적으로 배치
      _post-rows.sql      ★ 게시글 INSERT 본문. 여기 한 곳에만 있다
      d-growth-*.sql      회차 D 증분. 같은 본문을 1,000 / 3,000 / 10,000 으로 호출
    data.example/         DB 없이 A 가 로더를 검증하는 용도. 계약 ① 의 실물 스펙
    data/                 (gitignore) generate.sh 산출물. A 와 B 의 유일한 접점

  cleanup/
    steady-state.sh       회차 중 상시. 부하 계정이 만든 글을 배치 삭제

  preflight/
    response-size.sh      PostDto 실제 바이트. 대역폭·비용 추정의 근거
    actuator-labels.sh    힙 영역 id · GC 종류 · uri 라벨 실물
    histogram-buckets.sh  SLO 값이 히스토그램 버킷 경계 위인지

  results/                (gitignore) 회차별 요약 JSON
```

### 각각이 왜 있는가

| | 역할 | 없으면 |
| --- | --- | --- |
| `scale.json` | 규모의 단일 출처. `config.js`(k6)와 `generate.sh`(jq)가 **같은 파일**을 읽는다 | 한쪽만 고쳐서 A 는 600 을 가정하고 B 는 300 을 시딩한다 |
| `db.sh` | `LT_DB_*` 만 보고, 로컬이 아니면 호스트명 재입력을 요구한다 | `.env` 의 `DB_HOST` 는 **공용 dev RDS** 다. `00-reset` 이 그것을 비운다 |
| `_post-rows.sql` | 게시글 INSERT 를 한 곳에 모은다 | 시딩과 회차 D 증분이 갈라진다 (실제로 한 번 갈라졌다) |
| `generate.sh` | `INSERT` 후 PK 를 되받아 JSON 으로 떨군다. 토큰 600개 사전 발급 | SQL 파일은 자기 실행 결과를 파일로 못 내보낸다. `setup()` 로그인은 순차라 90초+ |
| `data.example/` | 스택 없이 A 가 로더·태그·매핑을 검증한다 | A 가 B 의 postgres 를 기다린다. 1단계가 직렬이 된다 |
| `cleanup/` | 회차 중 데이터 크기를 고정한다 | 목록이 300 → 5,700 건. p95 상승이 부하 탓인지 데이터 탓인지 못 가린다 |
| `preflight/` | 설계 문서의 가정을 실측으로 검증한다 | PostDto 600B 가정이 실제 1,014B 인 것을 회차 끝나고 안다 |

### 접두사 규칙

```
[SEED] …   generate.sh 가 시딩한 고정 글. 시나리오 2·4 의 대상 풀
```

`posts` 테이블에 "테스트용" 플래그 컬럼이 없어서 `title` 로 표시한다. 테스트를 위해 운영 스키마를
바꾸는 것보다 낫다.

**다만 삭제 판정은 제목이 아니라 작성자로 한다.**

```
[SEED] 글 → seedauthor@test.local   ← cleanup 이 절대 안 건드린다
런타임 글 → lt0001~lt0600           ← cleanup 이 지운다
```

시나리오 5 가 붙이는 제목 접두사에 의존하면, A 가 접두사를 빠뜨리는 순간 아무것도 안 지워진다.
그런데 **회차는 정상으로 끝나고 목록만 조용히 불어난다.** 작성자로 고르면 제목과 무관하게 동작한다.

---

## 2. 실행 순서

> **로컬은 k6 네이티브 + 터미널 출력만 쓴다.** Prometheus·Grafana·대시보드를 띄우지 않는다.
> 로컬의 목적은 스크립트와 경로 검증이지 성능 판정이 아니라서, 숫자를 보관할 이유가 없다.
> 관측 스택을 안 띄우면 회차 중 Discord 알람도 울리지 않는다.

### 준비 (1회)

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

### 회차마다

```bash
# 1. 시딩 (약 20초 — 계정 600 + 토큰 600개 사전 발급)
./load-test/seed/generate.sh

# 2. 정리 잡 — 별도 터미널에서 회차 내내 켜 둔다
#    관측과 무관하게 필요하다. 시나리오 5 가 만든 글을 안 지우면
#    목록이 300 → 5,700 건으로 불어나 회차 A 가 오염된다.
./load-test/cleanup/steady-state.sh

```

### 끝낼 때

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
그 상태로 회차를 돌리면 시나리오 2·4 가 전부 404 를 받는다. **4xx 는 실패로 세지 않으므로 회차는
끝까지 정상으로 돌고 결과만 무의미해진다.**
