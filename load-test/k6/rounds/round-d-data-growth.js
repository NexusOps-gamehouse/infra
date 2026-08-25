// ===========================================================================
// 회차 D — Data Growth. 페이징 도입 시점과 OOM 시점을 찾는다. 판정이 아니다.
//
// 시나리오 1(GET /api/posts) 단독, 1 RPS 로 3분. 부하가 아니라 '데이터 크기'가
// 변수이므로 도착률을 고정한다.
//
// 게시글 수를 바꿔가며 이 스크립트를 반복 실행한다.
//   ./seed/generate.sh          → ./run.sh round-d    # 300건
//   ./seed/grow.sh 1000         → ./run.sh round-d    # 1,000건
//   ./seed/grow.sh 3000         → ./run.sh round-d    # 3,000건
//   ./seed/grow.sh 10000        → ./run.sh round-d    # 10,000건
//
// grow.sh 는 meta.json 의 posts 도 갱신한다. 안 그러면 10,000건 구간의
// manifest.json 에 'posts: 300' 이 적혀 어느 구간의 결과인지 알 수 없게 된다.
//
// ⚠️ assertSeed() 를 부르지 않는다. 게시글 수가 scale.json 과 달라지는 것이
//    이 회차의 목적이라 대조하면 매번 실패한다.
//
// 10,000건 구간에서 볼 것: 힙 저점 · jvm_gc_pause_seconds · OOM Killer.
// 저점이 평탄한데 고점만 치솟으면 일시적 대용량 할당(→ 페이징 도입 신호),
// 저점 자체가 올라가면 진짜 누수다.
// 실측 PostDto 1,014 B 기준 10,000건이면 목록 응답 하나가 약 10 MB 다.
// ===========================================================================

import { SCENARIO, VUS, SYSTEM_TAGS } from '../lib/config.js';
import { constantScenario } from '../options/scenarios.js';
import { growthThresholds } from '../options/thresholds.js';

// 회차 결과를 results/<testid>/ 로 남긴다. run.sh 가 RESULT_DIR 을 넘긴다.
export { handleSummary } from '../lib/summary.js';

export { s1 } from '../scenarios/s1-list-posts.js';

export const options = {
  systemTags: SYSTEM_TAGS,
  scenarios: constantScenario(SCENARIO.S1, {
    rate: 1,
    duration: '3m',
    vus: VUS.roundD,
  }),
  // 여기서 SLO 를 판정하지 않는다. 데이터가 커지면 깨지는 것이 당연하고,
  // '언제 깨지는가'가 답이다. 다만 부하 생성기 문제와 대상 사망은 걸러야 한다.
  thresholds: growthThresholds(),
};
