// ===========================================================================
// options.scenarios 빌더.
//
// 회차 4개가 같은 8-시나리오 배선을 각자 복사하면, 배율 하나 바꿀 때 32곳을
// 고쳐야 하고 한 곳을 빠뜨리면 비중표가 깨진 채로 회차가 돈다. 그리고 그건
// 결과 숫자만 봐서는 안 보인다. 배선은 여기 한 곳에만 둔다.
//
// ⚠️ scenarios 객체의 '키'가 그대로 k6 의 scenario 태그가 된다.
//    그래서 키를 'S1'~'S8' 로 쓰고, 커스텀 scenario 태그를 따로 붙이지
//    않는다. 둘 다 붙이면 라벨이 이중화된다.
// ===========================================================================

import {
  SCENARIO, ENDPOINT, arrivalRate, MULTIPLIER, capMultiplier, RATE_WINDOW,
} from '../lib/config.js';

const KEYS = Object.values(SCENARIO);

// 판정 부하 기준 총 RPS(시나리오 8 포함). VU 배분의 분모다.
const TOTAL_RPS = KEYS.reduce((sum, k) => sum + ENDPOINT[k].rps, 0);

/**
 * VU 를 시나리오별로 나눈다.
 *
 * 전체 preAllocatedVUs 를 그대로 8번 쓰면 8배가 할당되어 러너가 먼저 죽는다.
 * RPS 비중대로 나누되, 작은 시나리오도 동시성이 1 이면 응답이 조금만 느려져도
 * 목표 rate 를 못 채우므로 최소 5 를 준다.
 */
function splitVUs(key, total, min = 5) {
  return Math.max(min, Math.round((ENDPOINT[key].rps / TOTAL_RPS) * total));
}

/**
 * 단계 목록을 받아 8개 시나리오의 ramping-arrival-rate 설정을 만든다.
 *
 * @param {object} spec
 * @param {Array<{duration: string, multiplier: number}>} spec.stages
 *        모든 시나리오에 '같은 배율'을 곱한다. 그래야 비중표(45/25/15/8/5/2%)와
 *        여정 : 폴링 = 8 : 1 이 전 구간에서 유지된다.
 * @param {number} spec.startMultiplier  시작 도착률의 배율
 * @param {{preAllocatedVUs: number, maxVUs: number}} spec.vus  회차 전체 기준
 * @param {string[]} [spec.only]  일부만 돌릴 때 (회차 D)
 */
export function rampingScenarios({ stages, startMultiplier, vus, only }) {
  const keys = only || KEYS;
  const out = {};

  for (const key of keys) {
    out[key] = {
      executor: 'ramping-arrival-rate',
      // 창 길이는 config.js 가 정한다(운영 3s / 로컬 9s). 여기에 다시 적으면
      // arrivalRate() 가 계산한 rate 와 창이 어긋나 도착률이 통째로 틀어진다.
      timeUnit: RATE_WINDOW,
      // capMultiplier: 로컬이면 배율을 상한으로 깎는다(config.js 의 LOCAL_CAP).
      // 여기 한 곳에서만 깎아야 8개 시나리오의 비중이 그대로 유지된다.
      startRate: arrivalRate(key, capMultiplier(startMultiplier)).rate,
      stages: stages.map((s) => ({
        duration: s.duration,
        target: arrivalRate(key, capMultiplier(s.multiplier)).rate,
      })),
      preAllocatedVUs: splitVUs(key, vus.preAllocatedVUs),
      maxVUs: splitVUs(key, vus.maxVUs),
      exec: key.toLowerCase(),   // 'S1' → 's1'. 회차 파일이 그 이름으로 export 한다
      gracefulStop: '30s',
    };
  }

  return out;
}

/**
 * 계단식 부하를 stages 배열로 만든다.
 *
 * ⚠️ ramping-arrival-rate 의 stage 는 목표까지 '선형으로 올린다'. 그래서
 *    [{2m, 45}, {2m, 90}, {2m, 135}] 은 계단이 아니라 연속 램프다 —
 *    90 에 닿는 순간 다음 구간이 시작되므로 90 RPS 를 유지하는 시간이 0 이다.
 *    실측: 4초 stage 로 10→20 을 주면 12, 13, 17, 18 건/초로 계속 오른다.
 *
 *    Break Point 는 '각 수준에서 무엇이 무너지나' 를 보는 것이므로 유지 구간이
 *    있어야 한다. 짧게 올린 뒤(rampSec) 나머지를 유지한다.
 *
 * @param {number[]} levels    배율 목록
 * @param {string} holdSec     각 수준 유지 시간(초)
 * @param {number} rampSec     다음 수준으로 올리는 시간(초)
 */
export function stepStages(levels, holdSec, rampSec = 10) {
  const out = [];
  for (const m of levels) {
    out.push({ duration: `${rampSec}s`, multiplier: m });      // 올린다
    out.push({ duration: `${holdSec - rampSec}s`, multiplier: m }); // 유지한다
  }
  return out;
}

/**
 * 회차 D 전용 — 고정 도착률.
 *
 * 데이터 크기만 바꿔가며 같은 부하를 반복해야 하므로 ramping 이 아니다.
 */
export function constantScenario(key, { rate, duration, vus }) {
  return {
    [key]: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs: vus.preAllocatedVUs,
      maxVUs: vus.maxVUs,
      exec: key.toLowerCase(),
      gracefulStop: '30s',
    },
  };
}

/**
 * 스모크 전용 — 시나리오마다 3초에 1회.
 *
 * 배율 모델을 쓰지 않는다. 스모크는 성능이 아니라 '경로가 뚫렸는지'를 보는
 * 것이라, 8개 시나리오가 각각 몇 번씩 나가기만 하면 된다.
 * OFF_PEAK(45 RPS)로 돌리면 로컬에서 dropped_iterations 가 나서, 스크립트가
 * 잘못됐는지 로컬이 느린 건지 구분할 수 없게 된다.
 */
export function smokeScenarios({ duration, vus }) {
  const out = {};
  for (const key of KEYS) {
    out[key] = {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: '3s',
      duration,
      preAllocatedVUs: vus.preAllocatedVUs,
      maxVUs: vus.maxVUs,
      exec: key.toLowerCase(),
      gracefulStop: '10s',
    };
  }
  return out;
}

export { MULTIPLIER };
