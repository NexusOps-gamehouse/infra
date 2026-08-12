import http from 'k6/http';
import { BASE_URL } from '../lib/config.js';
import { users } from '../lib/data.js';
import { check } from 'k6';

export default function () {
  const user = users[Math.floor(Math.random() * users.length)];
  const payload = JSON.stringify({
    email: user.email,
    password: user.password || 'password123',
  });
  const params = { headers: { 'Content-Type': 'application/json' } };
  const res = http.post(`${BASE_URL}/api/auth/login`, payload, params);
  check(res, { 's8 status 200': (r) => r.status === 200 });
}
