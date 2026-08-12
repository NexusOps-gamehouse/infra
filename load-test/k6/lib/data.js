// ===========================================================================
// 계약 ① — 소비자 쪽(A).
//
// B 의 seed/generate.sh 가 만든 JSON 만 읽는다. 이 파일은 DB 에 붙지 않는다.
//
// 그 덕에 "시나리오 2·4 는 시딩 300건 ID 풀에서만 고른다"는 4xx 차단 규칙이
// 규율이 아니라 구조로 지켜진다 — 애초에 다른 ID 를 알 방법이 없다.
// ===========================================================================

import { SharedArray } from 'k6/data';
import { SEED } from './config.js';

// 아직 generate.sh 가 없을 때는 data.example 을 가리켜 두면 A 가 먼저 시작할 수 있다.
//   SEED_DATA_DIR=../../seed/data.example k6 run k6/rounds/smoke.js
const DIR = __ENV.SEED_DATA_DIR || '../../seed/data';

// SharedArray 는 VU 수와 무관하게 메모리에 한 벌만 올린다.
// 그냥 배열로 두면 계정 600개 × VU 600 이 전부 복제되어 러너가 먼저 죽는다.
export const users = new SharedArray('users', () => JSON.parse(open(`${DIR}/users.json`)));
export const postIds = new SharedArray('postIds', () => JSON.parse(open(`${DIR}/post-ids.json`)));
export const tokens = new SharedArray('tokens', () => JSON.parse(open(`${DIR}/tokens.json`)));

const meta = JSON.parse(open(`${DIR}/meta.json`));
export { meta };

/**
 * 시드 규모가 config.js 의 가정과 맞는지 확인한다.
 *
 * 회차 스크립트의 setup() 첫 줄에서 부른다. 여기서 걸러지는 불일치 하나가
 * 회차 하나를 아낀다 — 어긋난 채로 돌면 15분을 다 쓰고 나서야 알게 된다.
 *
 * @param {'smoke'|'round'} mode 스모크는 계정 수만 느슨하게 본다.
 */
export function assertSeed(mode = 'round') {
  const problems = [];

  if (mode === 'round') {
    if (meta.accounts !== SEED.accounts) {
      problems.push(`계정 ${meta.accounts} ≠ 기대 ${SEED.accounts}`);
    }
    if (meta.posts !== SEED.posts) {
      problems.push(`게시글 ${meta.posts} ≠ 기대 ${SEED.posts}`);
    }
    if (meta.applications !== SEED.applications) {
      problems.push(`신청 ${meta.applications} ≠ 기대 ${SEED.applications}`);
    }
  }

  // 파일 사이의 일관성 — generate.sh 가 중간에 실패하면 여기서 걸린다.
  if (tokens.length !== users.length) {
    problems.push(`tokens ${tokens.length} ≠ users ${users.length}`);
  }
  if (postIds.length !== meta.posts) {
    problems.push(`post-ids ${postIds.length} ≠ meta.posts ${meta.posts}`);
  }

  if (problems.length > 0) {
    throw new Error(
      `[seed] 계약 ① 불일치 — seed/generate.sh 를 다시 돌릴 것\n  - ` +
      problems.join('\n  - '),
    );
  }

  return meta;
}

/**
 * VU 에 계정을 1:1 로 고정 배정한다.
 *
 * Math.random() 으로 고르면 여러 VU 가 같은 계정을 동시에 집어 500 을 유발한다.
 * __VU 는 1부터 시작하므로 -1 을 한다.
 */
export function tokenForVU(count = tokens.length) {
  return tokens[(__VU - 1) % Math.min(count, tokens.length)].token;
}

export function userForVU(count = users.length) {
  return users[(__VU - 1) % Math.min(count, users.length)];
}

/**
 * 시딩 300건 풀에서만 게시글을 고른다.
 *
 * 계정과 달리 무작위가 맞다. 시나리오 4 의 중복 신청(기대값 약 2.5%)은
 * 결함이 아니라 정상적인 비즈니스 거절이며, 4xx 는 실패로 세지 않는다.
 * 이 비율이 크게 튀면 페어링 로직을 점검한다.
 */
export function seedPostId() {
  return postIds[Math.floor(Math.random() * postIds.length)];
}

/** 인증 헤더. 토큰은 generate.sh 가 미리 발급한 것을 읽기만 한다. */
export function authHeaders(token) {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}
