import http from 'k6/http';
import { sleep } from 'k6';
import { BASE_URL, CREW_BASE_URL, TEST_HOUSE_ID, thresholds, jsonParams } from '../config.js';
import { login, authParams } from '../helpers/auth.js';
import { checkJsonResponse, isArray, isObject, parseJson } from '../helpers/checks.js';

export const options = {
  vus: 1,
  duration: '15s',
  thresholds,
};

export function setup() {
  return login();
}

export default function smoke(data) {
  const token = data.token;
  const me = http.get(`${BASE_URL}/api/users/me`, authParams('users_me', token));
  checkJsonResponse(me, 'users_me', isObject);
  sleep(0.5);

  const posts = http.get(`${BASE_URL}/api/posts`, authParams('posts_list', token));
  checkJsonResponse(posts, 'posts_list', isArray);
  sleep(0.5);

  const houses = http.get(`${CREW_BASE_URL}/api/crew/houses`, authParams('house_list', token));
  checkJsonResponse(houses, 'house_list', isArray);
  const houseItems = parseJson(houses);
  const houseId = TEST_HOUSE_ID || (Array.isArray(houseItems) && houseItems[0]?.id);
  if (!houseId) return;

  sleep(0.5);
  const detail = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}`,
    authParams('house_detail', token),
  );
  checkJsonResponse(detail, 'house_detail', isObject);

  // 공지/일정/채팅은 승인 멤버 권한이 필요한 조회다. 명시적인 테스트 House가
  // 있을 때만 호출해, 공개 목록의 임의 House가 403인 것을 계약 실패로 오인하지 않는다.
  if (!TEST_HOUSE_ID) return;
  sleep(0.5);
  const notices = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}/notices`,
    authParams('house_notices', token),
  );
  checkJsonResponse(notices, 'house_notices', isArray);
  sleep(0.5);
  const schedules = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}/schedules`,
    authParams('house_schedules', token),
  );
  checkJsonResponse(schedules, 'house_schedules', isArray);
  sleep(0.5);
  const messages = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}/chat/messages`,
    authParams('house_chat_history', token),
  );
  checkJsonResponse(messages, 'house_chat_history', isArray);
}
