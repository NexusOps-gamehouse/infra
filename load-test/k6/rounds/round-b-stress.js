import s1 from '../scenarios/s1-list-posts.js';

export const options = {
  stages: [
    { duration: '2m', target: 50 },
    { duration: '2m', target: 100 },
    { duration: '2m', target: 150 },
    { duration: '2m', target: 200 },
  ],
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true }],
  },
};

export default function () {
  s1();
}
