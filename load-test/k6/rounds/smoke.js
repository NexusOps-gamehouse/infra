import s1 from '../scenarios/s1-list-posts.js';
import s2 from '../scenarios/s2-post-detail.js';

export const options = {
  stages: [
    { duration: '1m', target: 5 },
  ],
};

export default function () {
  s1();
  s2();
}
