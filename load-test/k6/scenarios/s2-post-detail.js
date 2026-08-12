import { getPostDetail } from '../lib/http.js';
import { posts } from '../lib/data.js';
import { check } from 'k6';

export default function () {
  const randomPost = posts[Math.floor(Math.random() * posts.length)];
  const postId = randomPost.id || randomPost;
  const res = getPostDetail(postId);
  check(res, { 's2 status 200': (r) => r.status === 200 });
}
