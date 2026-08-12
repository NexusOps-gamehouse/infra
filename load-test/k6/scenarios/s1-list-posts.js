import { getPosts } from '../lib/http.js';
import { check } from 'k6';

export default function () {
  const res = getPosts();
  check(res, { 's1 status 200': (r) => r.status === 200 });
}
