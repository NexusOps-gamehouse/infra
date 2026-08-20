// 시나리오 5 — POST /api/posts (여정 몫 5%, Peak 6 RPS)
//
// 여기서 만든 글은 cleanup/steady-state.sh 가 회차 중에 계속 지운다.
// 안 지우면 목록이 300 → 5,700 건으로 불어나 회차 A 의 p95 상승이
// 부하 탓인지 데이터 탓인지 구분할 수 없게 된다.
//
// 삭제 판정은 제목이 아니라 '작성자'(부하 계정)로 한다. 그래서 이 제목을
// 바꿔도 정리 잡은 정상 동작한다. [LT] 접두사는 사람이 알아보기 위한 것이다.
//
// 본문 크기를 시딩 글과 비슷하게 맞춘다. 훨씬 짧으면 회차가 진행될수록
// 목록 응답의 평균 크기가 줄어들어 측정이 흔들린다.
import { check } from 'k6';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';
import { tokenForVU, authHeaders } from '../lib/data.js';

const BODY = JSON.stringify({
  title: '[LT] 같이 게임하실 분 구합니다',
  content:
    '오늘 저녁에 같이 게임 하실 분 찾습니다. 티어는 크게 상관없고 소통만 잘 되면 좋겠습니다. ' +
    '초보자도 환영이고 편하게 즐기실 분이면 좋겠습니다. 마이크는 없어도 괜찮습니다. ' +
    '연락 주시면 바로 답장 드리겠습니다. 부하 테스트로 생성된 글입니다.',
  game: '리그오브레전드',
  gameMode: '일반',
  playTime: '오늘 21시',
  micRequired: false,
  positions: '정글,서폿',
  targetMembers: 4,
});

export function s5() {
  const res = request(SCENARIO.S5, {
    body: BODY,
    headers: authHeaders(tokenForVU()),
  });
  check(res, { 'S5 정상 응답': isOk(SCENARIO.S5) });
}
