const trimTrailingSlash = (value) => String(value).replace(/\/+$/, '');

// 로컬 기본값. 원격/운영 주소는 환경변수로만 명시적으로 선택한다.
export const BASE_URL = trimTrailingSlash(__ENV.BASE_URL || 'http://localhost:8080');
export const CREW_BASE_URL = trimTrailingSlash(__ENV.CREW_BASE_URL || 'http://localhost:8086');
export const TEST_HOUSE_ID = String(__ENV.TEST_HOUSE_ID || '').trim();
export const TEST_POST_ID = String(__ENV.TEST_POST_ID || '').trim();

export const thresholds = {
  http_req_failed: ['rate<0.01'],
  http_req_duration: ['p(95)<500'],
};

export const jsonParams = (name, token = '') => ({
  headers: {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  },
  tags: { name },
});
