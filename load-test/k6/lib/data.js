import { SharedArray } from 'k6/data';

export const users = new SharedArray('users', function () {
  return JSON.parse(open('../../seed/data/users.json'));
});

export const posts = new SharedArray('posts', function () {
  return JSON.parse(open('../../seed/data/post-ids.json'));
});
