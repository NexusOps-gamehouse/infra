// ===========================================================================
// 회차 A — Load. 본 부하 테스트의 유일한 판정 근거.
//
//   Warm-up 30초 (45 RPS) → Ramp-up 2분30초 → Sustained 135 RPS 15분 → Cool-down 30초
//
// ⚠️ Sustained 15분은 줄이지 않는다. GC 누적·커넥션 누수·데이터 축적은 짧은
//    구간에서 안 보인다. p95 가 '평평한지 우상향하는지'를 보는 회차다.
//
// 실행
//   ./seed/generate.sh                        # 시딩 (1시간 안에 회차 시작)
//   ./cleanup/steady-state.sh                 # 별도 터미널, 회차 내내
//   k6 run k6/rounds/round-a-load.js
// ===========================================================================

import { MULTIPLIER, vusFor, assertAccountsCoverVUs } from '../lib/config.js';
import { SYSTEM_TAGS } from '../lib/config.js';
import { assertSeed } from '../lib/data.js';
import { rampingScenarios } from '../options/scenarios.js';
import { thresholds } from '../options/thresholds.js';

// 회차 결과를 results/<testid>/ 로 남긴다. run.sh 가 RESULT_DIR 을 넘긴다.
export { handleSummary } from '../lib/summary.js';

// exec 는 '이 파일이 export 한 함수 이름'을 찾는다. 재수출이 필요하다.
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
      { duration: '30s', multiplier: MULTIPLIER.OFF_PEAK },  // Warm-up   45 RPS
      { duration: '2m30s', multiplier: MULTIPLIER.PEAK },    // Ramp-up  → 135
      { duration: '15m', multiplier: MULTIPLIER.PEAK },      // Sustained 135 ← 판정
      { duration: '30s', multiplier: 0 },                    // Cool-down
    ],
    // 로컬이면 축소판(VUS.localA)으로 갈아끼운다. AWS 값(300/400)을 로컬에
    // 넣으면 컨테이너가 30초에 OOM 된다 — config.js 의 IS_LOCAL 주석 참조.
    vus: vusFor('roundA'),
  }),
  thresholds: thresholds(),
};

export function setup() {
  // 계정이 VU 상한을 감당하는지 먼저 본다. 모자라면 여러 VU 가 같은 계정을
  // 공유해 중복 신청·세션 경합이 서버 병목과 섞인다.
  assertAccountsCoverVUs();
  return assertSeed();
}
