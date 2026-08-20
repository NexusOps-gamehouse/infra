// ===========================================================================
// 회차 B — Stress. Break Point 좌표를 찾는다. 판정이 아니다.
//
//   45 → 90 → 135 → 180 → 225 → 270 RPS, 2분씩 계단
//
// 중단 조건: 5xx 5% 초과 (abortOnFail). p95 가 직전 단계 대비 2배가 되거나
// dropped_iterations 가 나오면 그 지점이 한계 좌표다 — 요약에서 확인한다.
//
// 회차 후 45 RPS 로 낮춰 2분 내 복구되는지 별도로 본다.
// ===========================================================================

import { MULTIPLIER, vusFor, SYSTEM_TAGS, assertAccountsCoverVUs } from '../lib/config.js';
import { assertSeed } from '../lib/data.js';
import { rampingScenarios, stepStages } from '../options/scenarios.js';
import { stressThresholds } from '../options/thresholds.js';

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
      // 각 수준을 10초에 올린 뒤 1분 50초 유지한다. 유지 구간이 없으면
      // '90 RPS 에서 무엇이 무너지나' 를 볼 시간이 0 초다(stepStages 주석 참조).
      ...stepStages(
        [
          MULTIPLIER.OFF_PEAK, //  45
          MULTIPLIER.MID,      //  90
          MULTIPLIER.PEAK,     // 135
          MULTIPLIER.S133,     // 180
          MULTIPLIER.S167,     // 225
          MULTIPLIER.S200,     // 270
        ],
        120,
      ),
      // 복구 확인 — Break Point 를 지난 뒤 45 로 낮추고 2분 관측한다.
      // 등급별 p95 가 회차 A 수준으로 돌아오지 않으면 커넥션 누수나 큐 적체다.
      // abortOnFail 로 먼저 끊기면 이 구간은 실행되지 않는다. 그 자체가 결과다.
      { duration: '10s', multiplier: MULTIPLIER.OFF_PEAK },
      { duration: '2m', multiplier: MULTIPLIER.OFF_PEAK },
    ],
    vus: vusFor('roundBC'),   // 로컬이면 축소판(VUS.localBC)
  }),
  thresholds: stressThresholds(),
};

export function setup() {
  // 계정이 VU 상한을 감당하는지 먼저 본다. 모자라면 여러 VU 가 같은 계정을
  // 공유해 중복 신청·세션 경합이 서버 병목과 섞인다.
  assertAccountsCoverVUs();
  return assertSeed();
}
