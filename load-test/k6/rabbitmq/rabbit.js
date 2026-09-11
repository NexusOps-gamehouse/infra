// ===========================================================================
// RabbitMQ 회차 — 도메인 이벤트 생성기
//
// 조회만으로는 브로커를 검증할 수 없다. 브로커가 죽어 있는 동안 **식별
// 가능한 메시지를 실제로 만들어 내는** 요청이 필요하다.
//
//   POST /api/posts  →  PostCreatedEvent  →  chat 이 그 글의 채팅방 생성
//                                            (ChatRoomProvisioningService)
//
// 그래서 성공한 글 수와 늘어난 채팅방 수를 대조하면 메시지가 소비됐는지
// 알 수 있다. 이것이 이 회차의 판정 기준이다.
//
// ⚠️ DB 시드 SQL 로 글을 넣으면 안 된다. 이벤트가 발행되지 않아 검증 대상
//    자체가 생기지 않는다. 반드시 HTTP API 로 만든다.
//
// 실행은 run-load.sh 를 거친다. 직접 부를 때는 BASE_URL 을 명시한다.
//   BASE_URL=http://gamehouse.local k6 run rabbit.js
// ===========================================================================

import { check } from 'k6';
import { Counter } from 'k6/metrics';
import exec from 'k6/execution';
import { SCENARIO } from '../lib/config.js';
import { request, isOk } from '../lib/http.js';

// ---------------------------------------------------------------------------
// 전용 시드
//
// 공용 lib/data.js 를 쓰지 않는다. 그쪽은 load-test/seed/ 의 공용 JWT 를
// 읽어서, 다른 팀 회차와 계정을 공유하게 된다. RabbitMQ 회차는 전용 계정만
// 쓴다(설계 1절 "RabbitMQ 전용 시드 원칙").
// ---------------------------------------------------------------------------
const TOKENS_FILE = __ENV.RMQ_TOKENS_FILE || './seed/data/tokens.json';
const META_FILE = __ENV.RMQ_META_FILE || './seed/data/meta.json';

function loadJson(path, what) {
  let raw;
  try {
    raw = open(path);
  } catch (e) {
    throw new Error(`${what} 을 읽을 수 없다: ${path} — ./seed/prepare.sh 를 먼저 실행한다 (${e})`);
  }
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`${what} 이 JSON 이 아니다: ${path} (${e})`);
  }
}

const TOKENS = loadJson(TOKENS_FILE, '전용 토큰');
const META = loadJson(META_FILE, '회차 메타');

if (!Array.isArray(TOKENS) || TOKENS.length === 0) {
  throw new Error(`전용 토큰이 비어 있다: ${TOKENS_FILE} — ./seed/prepare.sh 를 다시 실행한다`);
}

const TITLE_PREFIX = META.titlePrefix || '[RMQ-TEST]';
const ROUND_ID = META.roundId || 'RMQ-UNKNOWN';

// ---------------------------------------------------------------------------
// 발행자 고정
//
// 판정이 "만든 글 수 == 늘어난 채팅방 수" 대조인데, GET /api/chat/rooms 는
// **로그인 사용자 소속 방만** 돌려준다(ChatService.myRooms 가 userId 로
// 조회한다). 계정을 나눠 쓰면 대조가 성립하지 않는다.
//
// 그래서 기본은 첫 계정 하나로 전부 발행한다. 여러 계정으로 흩고 싶으면
// RMQ_SPREAD_AUTHORS=1 을 준다(대신 채팅방 대조는 포기한다).
// ---------------------------------------------------------------------------
const SPREAD = __ENV.RMQ_SPREAD_AUTHORS === '1';

function tokenFor() {
  if (!SPREAD) return TOKENS[0].token;
  return TOKENS[(exec.vu.idInTest - 1) % TOKENS.length].token;
}

const RATE = Number(__ENV.RATE || 5);
const DURATION = __ENV.DURATION || '2m';
const PRE_ALLOCATED_VUS = Number(__ENV.PRE_ALLOCATED_VUS || Math.max(10, RATE * 2));
const MAX_VUS = Number(__ENV.MAX_VUS || Math.max(50, RATE * 10));

export const options = {
  scenarios: {
    rabbitmq_post_events: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: '30s',
    },
  },
  // 판정은 회차 뒤 채팅방 수 대조로 한다. 여기서는 집계만 만든다.
  // 장애를 일부러 넣는 회차라 실패율이 오르는 것이 정상이고, 임계를 걸면
  // 회차 자체가 실패로 끝나 오해를 부른다.
  thresholds: {
    'http_req_failed{scenario:S5}': ['rate<=1'],
    'http_req_duration{scenario:S5}': ['p(95)>=0'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

/** 발행 성공 수. 회차 뒤 채팅방 증가분과 대조할 값이다. */
export const published = new Counter('rmq_published');
/** 발행 실패 수. 상태코드별로 쪼갠다. */
export const publishFailed = new Counter('rmq_publish_failed');

// ---------------------------------------------------------------------------
// 본문
//
// 필드는 PostDto.WriteRequest 기준이다.
//   title content game gameMode playTime voiceChat targetMembers roles tier playStyle
//
// ⚠️ scenarios/s5-create-post.js 의 본문에는 micRequired · positions 가 있는데
//    현재 WriteRequest 에는 없는 필드다. 그쪽을 그대로 베끼지 않는다.
// ---------------------------------------------------------------------------
const BASE_BODY = {
  content: 'RabbitMQ 회차에서 자동 생성한 글이다. 이벤트 발행과 채팅방 생성 경로를 검증한다.',
  game: 'LOL',
  gameMode: '랭크',
  playTime: '저녁',
  voiceChat: 'PREFERRED',
  targetMembers: 5,
  roles: '미드',
  tier: '골드',
  playStyle: '즐겜',
};

export default function () {
  // 제목에 회차 ID 를 넣는다. cleanup.sh 가 이 접두사로 찾아 지우고,
  // 다른 회차 데이터와도 구분된다.
  const body = JSON.stringify({
    ...BASE_BODY,
    title: `${TITLE_PREFIX} ${ROUND_ID} ${__VU}-${__ITER}`,
  });

  const res = request(SCENARIO.S5, {
    body,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${tokenFor()}`,
    },
  });

  const ok = check(res, { '글 작성 2xx': isOk(SCENARIO.S5) });

  if (ok) {
    published.add(1);
  } else {
    publishFailed.add(1, { status: String(res.status) });
  }
}
