// ===========================================================================
// 회차 C — Spike. 순간 폭증에 풀·스레드가 고갈되는지. 판정이 아니다.
//
//   45 유지 45초 → 10초에 270 → 1분 유지 → 10초에 45 → 2분 관측
//
// 정점 270 RPS 는 회차 B 최상단과 '같은 값'이다. 점진(B) 대 순간(C)의 차이가
// 곧 큐잉과 풀 고갈의 영향이다. 마지막 2분은 부하를 되돌린 뒤 회복을 본다 —
// 여기서 p95 가 안 돌아오면 고갈된 자원이 반환되지 않는다는 뜻이다.
// ===========================================================================

import { MULTIPLIER, vusFor, SYSTEM_TAGS, assertAccountsCoverVUs } from '../lib/config.js';
import { assertSeed } from '../lib/data.js';
import { rampingScenarios } from '../options/scenarios.js';
import { thresholds } from '../options/thresholds.js';

// 회차 결과를 results/<testid>/ 로 남긴다. run.sh 가 RESULT_DIR 을 넘긴다.
export { handleSummary } from '../lib/summary.js';

export { s1 } from '../scenarios/s1-list-posts.js';
export { s2 } from '../scenarios/s2-post-detail.js';
export { s3 } from '../scenarios/s3-users-me.js';
export { s4 } from '../scenarios/s4-apply.js';
export { s5 } from '../scenarios/s5-create-post.js';
export { s6 } from '../scenarios/s6-my-applications.js';
export { s7 } from '../scenarios/s7-notifications.js';
export { s8 } from '../scenarios/s8-login.js';

export const options = {
  systemTags: SYSTEM_TAGS,
  scenarios: rampingScenarios({
    startMultiplier: MULTIPLIER.OFF_PEAK,
    stages: [
      { duration: '45s', multiplier: MULTIPLIER.OFF_PEAK },  //  45 유지
      { duration: '10s', multiplier: MULTIPLIER.S200 },      // 급등 → 270
      { duration: '1m', multiplier: MULTIPLIER.S200 },       // 270 유지
      { duration: '10s', multiplier: MULTIPLIER.OFF_PEAK },  // 급락 →  45
      { duration: '2m', multiplier: MULTIPLIER.OFF_PEAK },   // 회복 관측
    ],
    vus: vusFor('roundBC'),   // 로컬이면 축소판(VUS.localBC)
  }),
  // 판정 회차가 아니므로 중단시키지 않는다. 끝까지 돌려 회복 구간을 본다.
  thresholds: thresholds({ abortOnFail: false }),
};

export function setup() {
  // 계정이 VU 상한을 감당하는지 먼저 본다. 모자라면 여러 VU 가 같은 계정을
  // 공유해 중복 신청·세션 경합이 서버 병목과 섞인다.
  assertAccountsCoverVUs();
  return assertSeed();
}
