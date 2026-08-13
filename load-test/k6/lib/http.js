// ===========================================================================
// 태그 붙인 요청 래퍼.
//
// 시나리오는 http.get/post 를 직접 부르지 않는다. 반드시 이 파일을 거친다.
// 요청마다 손으로 태그를 달면 언젠가 하나가 빠지고, 빠진 요청은 threshold 의
// 선택자에 안 걸려서 조용히 판정을 통과한다. 회차가 끝난 뒤에야 안다.
// ===========================================================================

import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { BASE_URL, ENDPOINT, tagsFor } from './config.js';

// ---------------------------------------------------------------------------
// 4xx 는 "실패"가 아니다.
//
// k6 기본값은 status >= 400 을 전부 실패로 세는데, 이 서비스에서 4xx 는
// 대부분 정상적인 비즈니스 거절이다.
//   · 시나리오 4 중복 신청 → 400 "이미 참가 신청한 글입니다"
//     600 계정 × 300 글 조합이 소진되면서 회차 끝에 약 5% 까지 오른다
//   · 본인 글 신청, 마감된 글 → 400
//
// 이것을 실패로 세면 http_req_failed 가 5% 로 뜨고 가용성 SLO(99.5%)가
// 통과할 수 없다. 그래서 시나리오 4 에 한해 400 을 정상으로 인정한다.
//
// ⚠️ 다만 '4xx 는 전부 정상' 이 아니다. 그렇게 두면 토큰 만료로 전 요청이 401 이
//    되거나 시드가 어긋나 전부 404 가 나도 회차가 끝까지 정상으로 돌고 결과만
//    무의미해진다. 실제로 정상인 4xx 는 시나리오 4 의 중복 신청 400 하나뿐이다.
//
//    그래서 전역 기본값은 2xx 로 좁히고, 시나리오마다 config.js 의 expect 로
//    개별 지정한다(아래 CALLBACK).
//
// ⚠️ 이 호출은 모듈 최상단(init 컨텍스트)에서 한 번만 실행된다.
// ---------------------------------------------------------------------------
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 299 }));

// 시나리오별 responseCallback 을 init 에서 한 번만 만들어 둔다.
// 요청마다 만들면 VU 수만큼 객체가 반복 생성된다.
const CALLBACK = {};
for (const [key, ep] of Object.entries(ENDPOINT)) {
  CALLBACK[key] = http.expectedStatuses(...ep.expect);
}

/**
 * 4xx 발생 건수. 시나리오·상태코드별로 쪼개서 센다.
 *
 * 이 값이 0 이면 오히려 이상하다 — 시나리오 4 는 중복 신청이 나오는 것이
 * 정상이다. 반대로 급등하면 시딩이 어긋났다는 신호다(예: post-ids 가
 * 존재하지 않는 PK 를 가리켜 전부 404).
 */
export const clientErrors = new Counter('lt_client_errors');

// ---------------------------------------------------------------------------
// 대상이 사라진 경우 — 4xx·5xx 와 완전히 다른 사건이다.
//
// 컨테이너가 죽거나 OOM 으로 재시작하면 status 0 (HTTP 응답 자체가 없음)이
// 돌아온다. 실측 error_code:
//   1212  dial: connection refused   ← 프로세스가 없다
//   1101  lookup: no such host       ← DNS
//   그 외 타임아웃·소켓 오류도 전부 status 0 이므로 status 로 판정한다.
//
// ⚠️ 이것을 http_req_failed 에만 맡기면 안 된다. 거기서는 "500 을 돌려줬다" 와
//    "서버가 없다" 가 같은 값으로 섞인다. 원인도 대응도 완전히 다르다.
//
// ⚠️ 그리고 이때는 회차를 중단시킨다. thresholds.js 가 abortOnFail 을 건다.
//    "회차 A 는 실패해도 완주시킨다" 는 원칙은 **서버가 느리거나 에러를 내는**
//    경우의 이야기다. 서버가 아예 없으면 남은 15분은 전부 같은 에러라 얻을 것이
//    없고, AWS 회차에서는 그 시간이 그대로 러너 요금이다.
// ---------------------------------------------------------------------------

/** 연결 자체가 안 된 요청 수. error_code 별로 쪼개서 센다. */
export const connErrors = new Counter('lt_conn_errors');

// 끊긴 '시점'을 세 가지로 남긴다. 초만 있으면 "19초에 죽었다" 까지만 알고,
// 그때 부하가 얼마였는지는 모른다. 회차 B(계단식)나 C(스파이크)에서는
// 그 값이 곧 답이다 — "270 RPS 로 올린 직후 죽었다" 같은 것.
//
// k6/execution 이 실행 중 상태를 그대로 준다. Date.now() 로 직접 재는 것보다
// 정확하고(회차 시작 기준), 별도 환경변수 배관도 필요 없다.

/** 연결 오류가 난 시점 (회차 시작 후 초). min 이 곧 '언제 끊겼나'. */
export const connErrorAt = new Trend('lt_conn_error_at');

/** 그때 살아 있던 VU 수. 투입 부하의 크기를 짐작하는 값. */
export const connErrorVus = new Trend('lt_conn_error_vus');

/** 그때까지 달성한 평균 RPS. 1 iteration = 1 요청이라 그대로 RPS 다. */
export const connErrorRps = new Trend('lt_conn_error_rps');

/**
 * 태그를 붙여 요청을 보낸다.
 *
 * @param {string} scenarioKey  SCENARIO.S1 ~ S8
 * @param {object} opts
 * @param {string} [opts.path]  경로변수가 있으면 넘긴다. 없으면 ENDPOINT 기본값
 * @param {any}    [opts.body]  POST 본문
 * @param {object} [opts.headers]
 */
export function request(scenarioKey, opts = {}) {
  const ep = ENDPOINT[scenarioKey];
  const url = `${BASE_URL}${opts.path || ep.path()}`;

  const params = {
    // name 태그가 여기서 붙는다. 이게 없으면 /api/posts/{id} 가 게시글
    // ID 마다 별도 시계열이 되어 요약이 읽을 수 없게 된다.
    tags: tagsFor(scenarioKey),
    headers: opts.headers || {},
    // 이 시나리오에서 '정상' 인 상태코드. http_req_failed 의 판정 기준이 된다.
    responseCallback: CALLBACK[scenarioKey],
  };

  const res = ep.method === 'POST'
    ? http.post(url, opts.body ?? null, params)
    : http.get(url, params);

  // 대상이 사라진 경우가 먼저다. status 0 은 HTTP 응답이 아예 없었다는 뜻이라
  // 4xx/5xx 분류가 성립하지 않는다.
  if (res.status === 0) {
    const sec = exec.instance.currentTestRunDuration / 1000;
    connErrors.add(1, { scenario: scenarioKey, code: String(res.error_code) });
    connErrorAt.add(sec);
    connErrorVus.add(exec.instance.vusActive);
    // 누적 평균이지 순간값이 아니다. 요약에도 그렇게 표시한다.
    if (sec > 0) connErrorRps.add(exec.instance.iterationsCompleted / sec);
  } else if (res.status >= 400 && res.status < 500) {
    clientErrors.add(1, { scenario: scenarioKey, status: String(res.status) });
  }

  return res;
}

/**
 * 응답이 이 시나리오에서 '정상' 인지 확인한다.
 *
 * http_req_failed 와 같은 기준을 쓴다. 둘이 어긋나면 threshold 는 통과인데
 * checks 는 실패하는(또는 그 반대) 읽기 어려운 결과가 나온다.
 *
 * status 0(연결 실패) 은 어떤 범위에도 안 들어가므로 자동으로 실패다.
 *
 * @param {string} scenarioKey  SCENARIO.S1 ~ S8
 */
export function isOk(scenarioKey) {
  const expect = ENDPOINT[scenarioKey].expect;
  return (res) => expect.some((e) =>
    typeof e === 'number' ? res.status === e : res.status >= e.min && res.status <= e.max);
}
