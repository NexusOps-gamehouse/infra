// 시나리오 4 — POST /api/posts/{id}/apply (여정 몫 8%, Peak 10 RPS)
//
// ⚠️ 400 이 나는 것이 정상이다.
//    applications 에 UNIQUE(post_id, applicant_id) 가 걸려 있고, 서비스가
//    "이미 참가 신청한 글입니다" 로 400 을 돌려준다. 계정 600 × 글 300 =
//    180,000 조합인데 회차 A 는 약 9,000 건을 만들므로, 충돌 확률이 0 에서
//    시작해 회차 끝에 약 5% 까지 오른다(평균 2.5%).
//
//    그래서 이 시나리오만 config.js 의 expect 에 400 을 넣어 정상으로 본다.
//    다른 시나리오는 2xx 만 정상이므로 401·404 는 그대로 실패로 잡힌다.
//    4xx 건수 자체는 lt_client_errors 로 따로 세는데, 이 값이 0 이면 오히려
//    페어링 로직을 의심한다.
//
//    작성자는 seedauthor 이고 부하 계정과 분리돼 있으므로 "본인 글" 400 은
//    나지 않는다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { tokenForVU, authHeaders, seedPostId } from '../lib/data.js';

export function s4() {
  const res = request(SCENARIO.S4, {
    path: `/api/posts/${seedPostId()}/apply`,
    headers: authHeaders(tokenForVU()),
  });
  check(res, { 'S4 정상 응답': isOk(SCENARIO.S4) });
}
