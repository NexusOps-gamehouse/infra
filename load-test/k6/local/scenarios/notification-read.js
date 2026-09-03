import http from 'k6/http';
import { sleep } from 'k6';
import { BASE_URL, thresholds } from '../config.js';
import { login, authParams } from '../helpers/auth.js';
import { checkJsonResponse, isObject } from '../helpers/checks.js';

export const options = {
  vus: 5,
  duration: '30s',
  thresholds,
};

export function setup() {
  return login();
}

export default function notificationRead(data) {
  const response = http.get(
    `${BASE_URL}/api/notifications`,
    authParams('notification_list', data.token),
  );
  checkJsonResponse(response, 'notification_list', (body) => (
    isObject(body) && Array.isArray(body.items) && Number.isFinite(Number(body.unreadCount))
  ));
  // NavBar.jsx의 실제 polling 주기(10초)를 따른다.
  sleep(10);
}
