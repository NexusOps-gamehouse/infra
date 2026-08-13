// 시나리오 7 — GET /api/notifications (폴링, Peak 15 RPS)
//
// 여정 밖이다. 사용자 행동이 아니라 시계 기반이라 접속자 수에만 비례한다.
// 그래서 여정 비중표에 넣지 않고, 모든 단계에서 여정 : 폴링 = 8 : 1 을 지킨다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { tokenForVU, authHeaders } from '../lib/data.js';

export function s7() {
  const res = request(SCENARIO.S7, { headers: authHeaders(tokenForVU()) });
  check(res, { 'S7 정상 응답': isOk(SCENARIO.S7) });
}
