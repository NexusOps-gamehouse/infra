import http from 'k6/http';
import { sleep } from 'k6';
import { BASE_URL, TEST_POST_ID, thresholds } from '../config.js';
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

export default function coreRead(data) {
  const token = data.token;
  const me = http.get(`${BASE_URL}/api/users/me`, authParams('users_me', token));
  checkJsonResponse(me, 'users_me', isObject);
  sleep(1);

  const posts = http.get(`${BASE_URL}/api/posts`, authParams('posts_list', token));
  checkJsonResponse(posts, 'posts_list', isArray);
  const body = parseJson(posts);
  const postId = TEST_POST_ID || (Array.isArray(body) && body[0]?.id);
  if (postId) {
    sleep(1);
    const detail = http.get(
      `${BASE_URL}/api/posts/${encodeURIComponent(postId)}`,
      authParams('posts_detail', token),
    );
    checkJsonResponse(detail, 'posts_detail', isObject);
  }
  sleep(1);
}
