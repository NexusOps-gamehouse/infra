// 시나리오 3 — GET /api/users/me (여정 몫 15%, Peak 18 RPS)
// 가장 가벼운 읽기. p95 < 200ms 등급의 기준선 역할을 한다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { tokenForVU, authHeaders } from '../lib/data.js';

export function s3() {
  const res = request(SCENARIO.S3, { headers: authHeaders(tokenForVU()) });
  check(res, { 'S3 정상 응답': isOk(SCENARIO.S3) });
}
