import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://gamehouse.local';
const POST_PATH = __ENV.POST_PATH || '/api/posts';
const TOKEN = __ENV.TOKEN || '';
const RATE = Number(__ENV.RATE || 5);
const DURATION = __ENV.DURATION || '2m';
const PRE_ALLOCATED_VUS = Number(__ENV.PRE_ALLOCATED_VUS || 10);
const MAX_VUS = Number(__ENV.MAX_VUS || 100);

if (!TOKEN) {
  throw new Error('TOKEN is required');
}

if (!__ENV.POST_PAYLOAD_JSON) {
  throw new Error(
    'POST_PAYLOAD_JSON is required. Use a JSON body that is already known to succeed against POST /api/posts.'
  );
}

const basePayload = JSON.parse(__ENV.POST_PAYLOAD_JSON);
const businessErrors = new Rate('business_errors');

export const options = {
  scenarios: {
    rabbitmq_post_events: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
    },
  },
};

function payloadForRequest() {
  const payload = JSON.parse(JSON.stringify(basePayload));

  // If the API has a title field, make it unique to reduce duplicate-data conflicts.
  if (typeof payload.title === 'string') {
    payload.title = `${payload.title}-k6-${__VU}-${__ITER}-${Date.now()}`;
  }

  return JSON.stringify(payload);
}

export default function () {
  const res = http.post(
    `${BASE_URL}${POST_PATH}`,
    payloadForRequest(),
    {
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        'Content-Type': 'application/json',
      },
      tags: {
        test_type: 'rabbitmq-post-event',
      },
      timeout: __ENV.HTTP_TIMEOUT || '10s',
    },
  );

  const ok = check(res, {
    'post create returned 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  businessErrors.add(!ok);
}
