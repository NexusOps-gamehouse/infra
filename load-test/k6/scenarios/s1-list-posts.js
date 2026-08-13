// 시나리오 1 — GET /api/posts (여정 몫 45%, Peak 54 RPS)
//
// 페이징이 없어서 전체 글이 한 번에 나간다. 응답 크기가 글 수에 비례하므로
// 이 시나리오 하나가 전체 송신량을 지배한다(실측 PostDto 1,014 B).
//
// 로그인 상태로 부른다. PostDto 의 myApplicationStatus / mine 이 사용자별로
// 계산되기 때문에, 비로그인 요청은 실제보다 가벼워진다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { tokenForVU, authHeaders } from '../lib/data.js';

export function s1() {
  const res = request(SCENARIO.S1, { headers: authHeaders(tokenForVU()) });
  check(res, { 'S1 정상 응답': isOk(SCENARIO.S1) });
}
