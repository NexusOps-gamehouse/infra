// 시나리오 8 — POST /api/auth/login (여정 밖, 1 RPS)
//
// 판정 부하 135 RPS 에 포함하지 않는다. 여정 모델은 '이미 로그인한 사용자'의
// 행동이고 로그인은 그 전에 1회 일어나기 때문이다. 그렇다고 빼면 인증 등급
// (p95 < 1s)을 판정할 데이터가 없어지므로 소량만 투입한다.
//
// 유일하게 토큰이 아니라 평문 자격증명을 쓰는 시나리오다 — users.json 이
// tokens.json 이 있어도 여전히 필요한 이유가 이것이다.
//
// ⚠️ BCrypt strength 10 은 CPU 집약적이다. 1 RPS 라도 CPU 그래프에 미치는
//    영향은 따로 본다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { userForVU } from '../lib/data.js';

export function s8() {
  const user = userForVU();
  const res = request(SCENARIO.S8, {
    body: JSON.stringify({ email: user.email, password: user.password }),
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'S8 정상 응답': isOk(SCENARIO.S8) });
}
