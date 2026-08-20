// ===========================================================================
// 판정 기준.
//
// 값의 출처는 task/k6/report-summary.md 2절이다. 여기서 정하는 것이 아니라
// 옮겨 적는 것이고, 바꾸려면 그 문서를 먼저 고친다.
//
// ⚠️ 임계값은 application.yml 의 히스토그램 버킷 경계에서만 고른다.
//      50ms / 100ms / 200ms / 500ms / 1s / 2s / 5s
//    경계 밖 값(예: 300ms)은 선형 보간이라 부정확하다.
//    preflight/histogram-buckets.sh 로 실물을 확인했다.
//
// ⚠️ 전체 합산 p95 는 쓰지 않는다. 무거운 API 가 가벼운 API 에 희석돼
//    "평균적으로는 괜찮다" 는 답이 나온다. grade 태그로 쪼개서 판정한다.
// ===========================================================================

import { GRADE } from '../lib/config.js';

// 등급별 지연 목표 (ms). k6 threshold 는 밀리초 단위다.
const LATENCY = {
  [GRADE.LIGHT_READ]: { p95: 200, p99: 500 },  // 시나리오 3·6·7
  [GRADE.LIST_READ]: { p95: 500, p99: 1000 },  // 시나리오 1·2
  [GRADE.WRITE]: { p95: 1000, p99: 2000 },     // 시나리오 4·5
  [GRADE.AUTH]: { p95: 1000, p99: 2000 },      // 시나리오 8
};

// ---------------------------------------------------------------------------
// 대상이 사라졌을 때의 중단 조건 — 모든 회차에 공통으로 건다.
//
// "회차 A 는 실패해도 완주시킨다" 는 원칙의 예외다. 그 원칙은 서버가 느리거나
// 5xx 를 내는 경우의 이야기이고, 그때는 '언제부터 얼마나 벗어났는가' 가 결과가
// 된다. 반면 프로세스가 죽으면 남은 시간은 전부 같은 연결 오류라 얻을 것이
// 없고, AWS 회차에서는 그 시간이 그대로 러너 요금이다.
//
// abortOnFail 로 멈춰도 handleSummary 는 실행된다(실측 확인). 즉 결과는
// 남는다 — 어디까지 갔고 언제 끊겼는지가 요약에 찍힌다.
//
// 임계 20 건: 연결 거부는 '아무도 안 듣고 있다' 는 뜻이라 일시적 혼잡과 다르다.
// accept 큐가 꽉 차면 타임아웃이지 refused 가 아니다. 20 건이면 확정이다.
// ---------------------------------------------------------------------------
const MAX_CONN_ERRORS = Number(__ENV.MAX_CONN_ERRORS) || 20;

export function connAbort() {
  return {
    lt_conn_errors: [
      { threshold: `count<${MAX_CONN_ERRORS}`, abortOnFail: true },
    ],
  };
}

/**
 * 회차 옵션에 넣을 thresholds 객체를 만든다.
 *
 * @param {object} opts
 * @param {boolean} [opts.abortOnFail=false]  회차 B 에서만 true
 */
export function thresholds({ abortOnFail = false } = {}) {
  const t = {};

  for (const [grade, { p95, p99 }] of Object.entries(LATENCY)) {
    t[`http_req_duration{grade:${grade}}`] = [
      `p(95)<${p95}`,
      `p(99)<${p99}`,
    ];
  }

  // 5xx 비율. 4xx 는 http.js 의 setResponseCallback 이 정상으로 재정의했으므로
  // 여기 잡히는 것은 서버 오류뿐이다.
  //
  // ⚠️ 인증 등급은 가용성 판정에서 제외한다. 1 RPS × 15분 = 900건이라
  //    한 건만 실패해도 0.11% 가 되어 표본이 부족하다.
  t['http_req_failed'] = [
    {
      threshold: 'rate<0.001',            // < 0.1%
      abortOnFail,
      delayAbortEval: '30s',              // 워밍업 구간의 튐으로 중단되지 않게
    },
  ];

  // 부하 생성기가 목표 rate 를 못 맞추면 그 구간은 '135 RPS 에서의 측정'이
  // 아니다. 대상 서버가 느린 것과 구분이 안 되므로 하나라도 나오면 실패로
  // 취급하고 그 구간을 폐기한다.
  t['dropped_iterations'] = ['count==0'];

  // check 는 시나리오별 기대 상태코드(config.js 의 expect)를 쓴다.
  // 즉 5xx 뿐 아니라 예상 밖 4xx(토큰 만료 401, 시드 불일치 404)도 실패다.
  // 시나리오 4 의 중복 신청 400 만 정상으로 통과한다.
  t['checks'] = ['rate>0.999'];

  // 대상이 사라지면 중단한다. 위 항목들과 성격이 다르다 — 판정이 아니라 보호다.
  Object.assign(t, connAbort());

  return t;
}

/**
 * 회차 B 전용 중단 조건.
 *
 * 5xx 5% 초과에서 멈춘다. Break Point 를 찾는 회차라 판정이 목적이 아니고,
 * 대상이 완전히 무너질 때까지 밀어붙일 이유가 없다.
 */
export function stressThresholds() {
  return {
    http_req_failed: [
      { threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s' },
    ],
    dropped_iterations: ['count==0'],
    ...connAbort(),
  };
}

/**
 * 회차 D 전용 — SLO 를 판정하지 않는다.
 *
 * 데이터가 커지면 깨지는 것이 당연하고 '언제 깨지는가' 가 답이다.
 * 다만 부하 생성기 문제와 대상 사망은 걸러야 한다.
 */
export function growthThresholds() {
  return {
    dropped_iterations: ['count==0'],
    ...connAbort(),
  };
}
