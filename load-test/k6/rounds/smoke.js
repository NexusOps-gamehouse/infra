// ===========================================================================
// 스모크 — 로컬 전용. 성능을 재는 것이 아니라 '경로가 뚫렸는지'를 본다.
//
// 확인하는 것
//   · 8개 시나리오가 전부 요청을 보내는가
//   · grade / name / scenario 태그가 붙는가
//   · 4xx 가 http_req_failed 에 안 잡히는가
//   · 시딩 데이터와 scale 파일이 맞는가 (assertSeed)
//
// 실행 (계정 5 · 글 10 규모)
//   SCALE=smoke ./seed/generate.sh
//   SCALE=smoke k6 run k6/rounds/smoke.js
// ===========================================================================

import { VUS, SYSTEM_TAGS, assertAccountsCoverVUs } from '../lib/config.js';
import { assertSeed } from '../lib/data.js';
import { smokeScenarios } from '../options/scenarios.js';
import { connAbort } from '../options/thresholds.js';

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
  scenarios: smokeScenarios({ duration: '8s', vus: VUS.smoke }),
  // 스모크는 성능 판정이 아니다. 5xx 와 부하 생성기 문제만 본다.
  thresholds: {
    http_req_failed: ['rate<0.01'],
    dropped_iterations: ['count==0'],
    // 대상이 죽으면 스모크도 멈춘다. 없으면 1분 내내 연결 오류만 쌓는다.
    ...connAbort(),
  },
};

export function setup() {
  // 계정이 VU 상한을 감당하는지 먼저 본다. 모자라면 여러 VU 가 같은 계정을
  // 공유해 중복 신청·세션 경합이 서버 병목과 섞인다.
  assertAccountsCoverVUs();
  return assertSeed();
}
