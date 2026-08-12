import s1 from '../scenarios/s1-list-posts.js';

export const options = {
  stages: [
    { duration: '45s', target: 45 },
    { duration: '10s', target: 270 },
    { duration: '1m', target: 270 },
    { duration: '10s', target: 0 },
    { duration: '2m', target: 0 },
  ],
};

export default function () {
  s1();
}
