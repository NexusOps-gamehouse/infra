import http from 'k6/http';
import { sleep } from 'k6';
import { CREW_BASE_URL, TEST_HOUSE_ID, thresholds } from '../config.js';
import { login, authParams } from '../helpers/auth.js';
import { checkJsonResponse, isArray, isObject, parseJson } from '../helpers/checks.js';

export const options = {
  stages: [
    { duration: '10s', target: 5 },
    { duration: '20s', target: 5 },
    { duration: '10s', target: 0 },
  ],
  thresholds,
};

export function setup() {
  return login();
}

export default function houseRead(data) {
  const token = data.token;
  const houses = http.get(
    `${CREW_BASE_URL}/api/crew/houses`,
    authParams('house_list', token),
  );
  checkJsonResponse(houses, 'house_list', isArray);
  const items = parseJson(houses);
  const houseId = TEST_HOUSE_ID || (Array.isArray(items) && items[0]?.id);
  if (!houseId) return;

  sleep(1);
  const detail = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}`,
    authParams('house_detail', token),
  );
  checkJsonResponse(detail, 'house_detail', isObject);

  // 이 세 API는 House 승인 멤버 권한이 필요한 조회다. TEST_HOUSE_ID는
  // 해당 계정이 실제로 승인된 House로 지정해야 한다.
  if (!TEST_HOUSE_ID) return;
  sleep(1);
  const notices = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}/notices`,
    authParams('house_notices', token),
  );
  checkJsonResponse(notices, 'house_notices', isArray);
  sleep(1);
  const schedules = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}/schedules`,
    authParams('house_schedules', token),
  );
  checkJsonResponse(schedules, 'house_schedules', isArray);
  sleep(1);
  const messages = http.get(
    `${CREW_BASE_URL}/api/crew/houses/${encodeURIComponent(houseId)}/chat/messages`,
    authParams('house_chat_history', token),
  );
  checkJsonResponse(messages, 'house_chat_history', isArray);
  sleep(1);
}
