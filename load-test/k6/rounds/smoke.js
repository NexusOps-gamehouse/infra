import { getPosts } from '../lib/http.js';
import { getAuthHeader } from '../lib/auth.js';
import { check, sleep } from 'k6';

export const options = {
  vus: 1,
  duration: '10s',
};

export default function () {
  const params = getAuthHeader();
  const res = getPosts(params);

  check(res, {
    'status is 200': (r) => r.status === 200,
  });

  sleep(1);
}
