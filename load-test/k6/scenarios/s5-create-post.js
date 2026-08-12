import http from 'k6/http';
import { BASE_URL } from '../lib/config.js';
import { getAuthHeader } from '../lib/auth.js';
import { check } from 'k6';

export default function () {
  const payload = JSON.stringify({
    title: '[LOAD_TEST] 게릴라 모집 글',
    content: 'k6 부하 테스트로 자동 생성된 게시글 본문입니다.',
  });
  const res = http.post(`${BASE_URL}/api/posts`, payload, getAuthHeader());
  check(res, { 's5 status 200 or 201': (r) => r.status === 200 || r.status === 201 });
}
