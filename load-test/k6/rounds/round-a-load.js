import s1 from '../scenarios/s1-list-posts.js';
import s2 from '../scenarios/s2-post-detail.js';

export const options = {
  stages: [
    { duration: '1m', target: 10 },  // Warm-up
    { duration: '3m', target: 50 },  // Ramp-up
    { duration: '15m', target: 50 }, // Sustained (15분)
    { duration: '1m', target: 0 },   // Cool-down
  ],
};

export default function () {
  s1();
  s2();
}
