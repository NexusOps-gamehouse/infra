// ===========================================================================
// 계약 ② — A 가 만들고 B 의 Grafana 대시보드가 의존한다.
//
// 이 파일에서 "이름"과 "값"은 둘 다 합의 사항이다.
//   · 이름(GRADE.WRITE 등)이 바뀌면 A 의 스크립트가 깨진다.
//   · 값('write' 등)이 바뀌면 B 의 패널이 조용히 빈다. 쿼리는 그대로 돌고
//     결과만 0 이 되므로 한참 뒤에야 알아챈다.
//
// ⚠️ 값을 바꿔야 하면 반드시 둘이 같이 바꾼다. 혼자 바꾸지 않는다.
// ===========================================================================

import exec from 'k6/execution';

// 대상 주소. 로컬은 compose 의 backend, AWS 회차는 사설 IP 를 넣는다.
// 로컬 수치는 성능 판정에 쓰지 않는다(Rosetta 에뮬레이션).
export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// ---------------------------------------------------------------------------
// 태그 — 모든 요청에 아래 4 종이 빠짐없이 붙는다.
// 대시보드와 threshold 가 전부 태그에 의존하므로 첫 줄부터 고정한다.
// ---------------------------------------------------------------------------

export const KIND = {
  API: 'api',
  STATIC: 'static',
};

// SLO 지연 등급. threshold 와 대시보드 패널이 이 값으로 시계열을 쪼갠다.
// 전체 합산 p95 는 판정에 쓰지 않는다 — 무거운 API 가 가벼운 API 에 희석된다.
export const GRADE = {
  LIGHT_READ: 'light_read', // p95 < 200ms
  LIST_READ: 'list_read',   // p95 < 500ms
  WRITE: 'write',           // p95 < 1s
  AUTH: 'auth',             // p95 < 1s, 가용성 판정에서는 제외(표본 900건)
};

// 내보낼 시스템 태그.
//
// ⚠️ k6 기본값에는 'url' 이 들어 있고, name 태그로 묶어도 url 은 원본 경로를
//    그대로 들고 있다. /api/posts/{id} 가 게시글 ID 마다 별도 시계열이 된다는
//    뜻이다. 터미널 요약만 볼 때는 티가 안 나지만, 지표를 밖으로 내보내는
//    순간(remote write, JSON 출력) 시계열이 수십 배로 늘어난다.
//
// 여기서 뺀 것: url, group, tls_version, subproto, service, error
//   - url    → name 으로 대체한다
//   - error  → error_code 만으로 충분하다(문자열 카디널리티가 크다)
export const SYSTEM_TAGS = [
  'proto',
  'status',
  'method',
  'name',
  'scenario',
  'check',
  'error_code',
  'expected_response',
];

export const SCENARIO = {
  S1: 'S1', S2: 'S2', S3: 'S3', S4: 'S4',
  S5: 'S5', S6: 'S6', S7: 'S7', S8: 'S8',
};

// ---------------------------------------------------------------------------
// 엔드포인트 정의
//
// name 은 URL 이 아니라 "묶인 이름"이다. 경로변수를 그대로 두면 게시글 ID 마다
// 시계열이 생겨 카디널리티가 폭발한다. remote write 환경에서는 Prometheus
// retention 까지 위협하므로 더 중요하다.
//
// rps 는 Peak(판정 부하 135 RPS) 기준값이다. 각 단계는 여기에 배율을 곱한다.
// ---------------------------------------------------------------------------

// expectedStatus — 시나리오마다 '정상' 의 정의가 다르다.
//
// 전부 200~499 를 정상으로 두면, 토큰이 만료돼 전 요청이 401 이 되거나 시드
// ID 가 어긋나 전부 404 가 나도 회차가 끝까지 정상으로 돌고 결과만 무의미해진다.
// 가장 알아채기 어려운 실패 방식이라 시나리오별로 좁힌다.
//
//   기본        2xx 만 정상
//   시나리오 4  2xx + 400 (중복 신청은 UNIQUE 제약에 의한 정상 거절)
const OK_2XX = [{ min: 200, max: 299 }];

export const ENDPOINT = {
  [SCENARIO.S1]: {
    expect: OK_2XX,
    method: 'GET',
    name: '/api/posts',
    grade: GRADE.LIST_READ,
    rps: 54,
    path: () => '/api/posts',
  },
  [SCENARIO.S2]: {
    expect: OK_2XX,
    method: 'GET',
    name: '/api/posts/{id}',
    grade: GRADE.LIST_READ,
    rps: 30,
    path: (id) => `/api/posts/${id}`,
  },
  [SCENARIO.S3]: {
    expect: OK_2XX,
    method: 'GET',
    name: '/api/users/me',
    grade: GRADE.LIGHT_READ,
    rps: 18,
    path: () => '/api/users/me',
  },
  [SCENARIO.S4]: {
    expect: [...OK_2XX, 400],
    method: 'POST',
    name: '/api/posts/{id}/apply',
    grade: GRADE.WRITE,
    rps: 10,
    path: (id) => `/api/posts/${id}/apply`,
  },
  [SCENARIO.S5]: {
    expect: OK_2XX,
    method: 'POST',
    name: '/api/posts',
    grade: GRADE.WRITE,
    rps: 6,
    path: () => '/api/posts',
  },
  [SCENARIO.S6]: {
    expect: OK_2XX,
    method: 'GET',
    name: '/api/my/applications',
    grade: GRADE.LIGHT_READ,
    rps: 2,
    path: () => '/api/my/applications',
  },
  // 폴링. 사용자 행동이 아니라 시계가 돌린다. 여정 비중표 밖에 있으며
  // 접속자 수에만 비례한다(여정 : 폴링 = 8 : 1).
  [SCENARIO.S7]: {
    expect: OK_2XX,
    method: 'GET',
    name: '/api/notifications',
    grade: GRADE.LIGHT_READ,
    rps: 15,
    path: () => '/api/notifications',
  },
  // 여정 밖. 판정 부하 135 RPS 산출에 포함되지 않는다(총 부하의 0.7%).
  // 빼면 인증 등급 목표를 판정할 데이터가 없어지므로 1 RPS 로 투입만 한다.
  [SCENARIO.S8]: {
    expect: OK_2XX,
    method: 'POST',
    name: '/api/auth/login',
    grade: GRADE.AUTH,
    rps: 1,
    path: () => '/api/auth/login',
  },
};

// 편의용 — 문서(2절 비중표)와 대조하기 쉬우라고 따로 뽑아 둔다.
export const BASE_RPS = Object.fromEntries(
  Object.entries(ENDPOINT).map(([k, v]) => [k, v.rps]),
);

// 판정 부하 = 시나리오 8 을 뺀 합계. 135 가 아니면 표가 어긋난 것이다.
export const PEAK_RPS = Object.entries(ENDPOINT)
  .filter(([k]) => k !== SCENARIO.S8)
  .reduce((sum, [, v]) => sum + v.rps, 0);

// ---------------------------------------------------------------------------
// 단계 배율
//
// 모든 엔드포인트에 "동일 배율"을 곱한다. 그래야 비중표(45/25/15/8/5/2%)와
// 여정 : 폴링 = 8 : 1 이 전 구간에서 유지된다.
// 스트레스 단계에서 폴링을 고정한 채 여정만 올리면 비중표가 깨진다 —
// 재현하려는 상황이 "더 빨리 클릭"이 아니라 "접속자가 더 많아짐"이기 때문이다.
// ---------------------------------------------------------------------------

export const MULTIPLIER = {
  OFF_PEAK: 1 / 3, //  45 RPS · 동시 접속 50명
  MID: 2 / 3,      //  90 RPS · 100명
  PEAK: 1,         // 135 RPS · 150명  ← 판정
  S133: 4 / 3,     // 180 RPS · 200명
  S167: 5 / 3,     // 225 RPS · 250명
  S200: 2,         // 270 RPS · 300명  ← 회차 B 최상단 = 회차 C 스파이크 정점
};

/**
 * 배율을 적용한 arrival-rate executor 인자를 만든다.
 *
 * k6 의 rate 는 정수여야 한다. 그런데 배율이 1/3 계열이라 그냥 반올림하면
 * 작은 시나리오가 크게 틀어진다 — 시나리오 6(2 RPS)에 1/3 을 곱하면 0.67 인데
 * 반올림하면 1 이 되어 50% 초과 투입이 된다.
 *
 * 배율이 전부 n/3 이므로 timeUnit 을 '3s' 로 두면 모든 조합이 정수로 떨어진다.
 * rate 162 / 3s 와 rate 54 / 1s 는 같은 도착률이므로 큰 시나리오도 손해가 없다.
 */
export function arrivalRate(scenarioKey, multiplier) {
  const target = ENDPOINT[scenarioKey].rps * multiplier * 3;
  const rate = Math.round(target);
  if (Math.abs(target - rate) > 1e-9) {
    throw new Error(
      `[config] ${scenarioKey} × ${multiplier} 가 3s 단위 정수로 떨어지지 않는다 (${target}). ` +
      `MULTIPLIER 에 n/3 이 아닌 값을 추가했는지 확인할 것.`,
    );
  }
  return { rate, timeUnit: '3s' };
}

/**
 * 태그 4 종을 한 번에 만든다.
 *
 * 요청마다 손으로 태그를 달면 하나씩 빠지고, 빠진 건 threshold 가 조용히
 * 넘어가므로 회차가 끝난 뒤에야 안다. 태그는 반드시 이 함수로만 만든다.
 */
export function tagsFor(scenarioKey, extra = {}) {
  const ep = ENDPOINT[scenarioKey];
  return {
    kind: KIND.API,
    grade: ep.grade,
    scenario: scenarioKey,
    name: ep.name,
    ...extra,
  };
}

// ---------------------------------------------------------------------------
// 시드 규모 — 계약 ① 의 meta.json 과 대조해 어긋나면 즉시 실패시킨다.
//
// A 는 계정 600 개를 가정하고 B 는 300 개를 시딩한 상태로 회차를 돌리면,
// 결과가 나온 뒤에야 알게 된다. 그런 회차 하나가 AWS 비용으로 직결된다.
//
// ⚠️ 숫자를 여기에 적지 않는다. load-test/scale.json 이 유일한 출처이고
//    seed/generate.sh 도 같은 파일을 jq 로 읽는다. 한쪽만 고치는 사고가
//    구조적으로 불가능해야 하므로, 이 export 는 재수출일 뿐이다.
//
//    accounts     : preAllocatedVUs 상한과 일치시킨다
//    posts        : 운영 예상 규모 추정치
//    applications : 게시글당 평균 3건. pendingCount ≠ 0 상태를 만든다
//
// 작게 돌릴 때는 값을 고치지 말고 프로파일 이름을 넘긴다.
//   k6 run k6/rounds/round-a-load.js              → scale.json
//   SCALE=smoke k6 run k6/rounds/smoke.js         → scale.smoke.json
//
// seed/generate.sh 도 같은 SCALE 이름을 받는다. 경로가 아니라 이름인 이유는,
// 상대경로를 쓰면 bash(CWD 기준)와 k6 open()(파일 위치 기준)이 서로 다른
// 파일을 가리키기 때문이다.
// ---------------------------------------------------------------------------

// open() 은 init 컨텍스트 전용이다. config.js 는 항상 init 에서 import 되므로
// 문제없지만, 이 상수를 VU 코드 안에서 다시 로드하려 들면 안 된다.
export const SEED = JSON.parse(open(`../../scale${__ENV.SCALE ? `.${__ENV.SCALE}` : ''}.json`));

// 스모크는 계정을 다 쓸 이유가 없다. 토큰 파일이 커도 앞의 5 개만 쓴다.
export const ACCOUNT_COUNT = {
  smoke: 5,
  round: SEED.accounts,
};

// preAllocatedVUs — 부족하면 dropped_iterations 가 발생해 그 구간이 무효가 된다.
// 로컬은 맥 파일 디스크립터 상한 때문에 큰 값을 쓸 수 없다. AWS 에서 처음 검증한다.
//
// ⚠️ maxVUs 총합이 시드 계정 수를 넘으면 안 된다.
//    data.js 가 (__VU - 1) % tokens.length 로 배정하므로, VU 가 계정 수를 넘는
//    순간 여러 VU 가 같은 계정을 공유한다. 하필 그 일이 벌어지는 구간이
//    '서버가 느려져 VU 가 늘어난 구간' 이라, 서버 병목을 보려는 자리에
//    계정 경합(중복 신청·세션 충돌)이 섞여 들어간다.
//
//    회차 B 에서 maxVUs 를 줄여 막는 것은 답이 아니다. VU 가 모자라면
//    dropped_iterations 가 나서 '러너 한계' 로 기록되는데, 정작 찾으려던 것은
//    '서버 한계' 이기 때문이다. 계정을 늘려서 맞춘다.
//
// 아래 값은 8개 시나리오에 비중대로 나뉜다(options/scenarios.js). 총합은
// 지정값과 거의 같으므로 그 기준으로 계정 수와 대조한다.
export const VUS = {
  smoke: { preAllocatedVUs: 2, maxVUs: 2 },      // 8개 × 2 = 16 ≤ 계정 20
  roundA: { preAllocatedVUs: 300, maxVUs: 400 },
  roundBC: { preAllocatedVUs: 600, maxVUs: 800 },
  roundD: { preAllocatedVUs: 5, maxVUs: 10 },
};

/**
 * 계정이 VU 상한을 감당하는지 확인한다. 회차 스크립트의 setup() 에서 부른다.
 *
 * ⚠️ VUS 상수를 그대로 믿지 않는다. 빌더마다 그 값의 의미가 다르기 때문이다.
 *      rampingScenarios  maxVUs 를 8개 시나리오에 '나눈다'   → 총합 ≈ 지정값
 *      smokeScenarios    각 시나리오에 '그대로 준다'         → 총합 = 지정값 × 8
 *    그래서 지정값만 보면 스모크에서 16 을 2 로 착각한다.
 *
 *    exec.test.options.scenarios 는 k6 가 실제로 해석한 결과다. 거기서 합산하면
 *    빌더가 무엇이든, 나중에 시나리오가 늘어나도 맞는다.
 *
 * 여기서 안 막으면 회차가 정상으로 완주하고 결과만 조용히 오염된다.
 */
export function assertAccountsCoverVUs() {
  const scenarios = exec.test.options.scenarios || {};
  const total = Object.values(scenarios)
    .reduce((sum, sc) => sum + (sc.maxVUs || sc.vus || 0), 0);

  if (SEED.accounts < total) {
    const file = SEED.profile === 'round' ? 'scale.json' : `scale.${SEED.profile}.json`;
    throw new Error(
      `[config] 계정 ${SEED.accounts}개 < maxVUs 총합 ${total}개 — VU 가 계정을 공유하게 된다.\n` +
      `  data.js 는 (__VU - 1) % tokens.length 로 배정하므로, 서버가 느려져 VU 가 늘어나는\n` +
      `  바로 그 구간에서 계정 경합이 서버 병목과 섞인다.\n` +
      `  ${file} 의 accounts 를 ${total} 이상으로 올리고 seed/generate.sh 를 다시 돌릴 것.`,
    );
  }
  return total;
}

