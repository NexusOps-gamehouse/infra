import http from 'k6/http';
import { check } from 'k6';
import { BASE_URL, jsonParams } from '../config.js';
import { parseJson, isObject } from './checks.js';

export function login() {
  const email = String(__ENV.TEST_EMAIL || '').trim();
  const password = String(__ENV.TEST_PASSWORD || '');
  if (!email || !password) {
    throw new Error('TEST_EMAIL과 TEST_PASSWORD 환경변수가 필요합니다.');
  }

  const res = http.post(
    `${BASE_URL}/api/auth/login`,
    JSON.stringify({ email, password }),
    jsonParams('auth_login'),
  );
  const body = parseJson(res);
  const responseOk = check(res, {
    'auth_login: HTTP 200': (response) => response.status === 200,
    'auth_login: token/user 응답': () => isObject(body) && Boolean(body.token) && isObject(body.user),
  });
  if (!responseOk || !body?.token) {
    throw new Error(`로그인에 실패했습니다(HTTP ${res.status}). TEST 계정과 로컬 User service를 확인하세요.`);
  }
  return { token: body.token, user: body.user };
}

export function authParams(name, token) {
  return jsonParams(name, token);
}
