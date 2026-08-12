import s1 from '../scenarios/s1-list-posts.js';

export const options = {
  scenarios: {
    constant_rate: {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 1,
      maxVUs: 5,
    },
  },
};

export default function () {
  s1();
}
