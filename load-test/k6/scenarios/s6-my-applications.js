import http from 'k6/http';
import { BASE_URL } from '../lib/config.js';
import { getAuthHeader } from '../lib/auth.js';
import { check } from 'k6';

export default function () {
  const res = http.get(`${BASE_URL}/api/my/applications`, getAuthHeader());
  check(res, { 's6 status 200': (r) => r.status === 200 });
}
