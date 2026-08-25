// 시나리오 6 — GET /api/my/applications (여정 몫 2%, Peak 2 RPS)
//
// ⚠️ 시딩 신청은 PENDING 이고 ApplicationService.PENDING_TTL 이 1시간이다.
//    시딩 후 1시간이 지나면 만료 처리되어 응답이 빈 배열이 된다.
//    회차는 시딩 직후에 시작한다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { tokenForVU, authHeaders } from '../lib/data.js';

export function s6() {
  const res = request(SCENARIO.S6, { headers: authHeaders(tokenForVU()) });
  check(res, { 'S6 정상 응답': isOk(SCENARIO.S6) });
}
