// 시나리오 2 — GET /api/posts/{id} (여정 몫 25%, Peak 30 RPS)
//
// 대상은 seedPostId() 로만 고른다. 시딩 300건 밖의 ID 를 고를 방법이 애초에
// 없으므로 "4xx 차단" 이 규율이 아니라 구조로 지켜진다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { tokenForVU, authHeaders, seedPostId } from '../lib/data.js';

export function s2() {
  const res = request(SCENARIO.S2, {
    path: `/api/posts/${seedPostId()}`,
    headers: authHeaders(tokenForVU()),
  });
  check(res, { 'S2 정상 응답': isOk(SCENARIO.S2) });
}
