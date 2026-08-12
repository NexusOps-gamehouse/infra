import http from 'k6/http';
import { BASE_URL } from './config.js';

export function getPosts(params = {}) {
  return http.get(`${BASE_URL}/api/posts`, params);
}

export function getPostDetail(postId, params = {}) {
  return http.get(`${BASE_URL}/api/posts/${postId}`, params);
}
