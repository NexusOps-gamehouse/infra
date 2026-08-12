import http from 'k6/http';
import { BASE_URL } from '../lib/config.js';
import { getAuthHeader } from '../lib/auth.js';
import { posts } from '../lib/data.js';
import { check } from 'k6';

export default function () {
  const randomPost = posts[Math.floor(Math.random() * posts.length)];
  const postId = randomPost.id || randomPost;
  const res = http.post(`${BASE_URL}/api/posts/${postId}/apply`, null, getAuthHeader());
  check(res, { 's4 status 200 or 400': (r) => r.status === 200 || r.status === 400 });
}
