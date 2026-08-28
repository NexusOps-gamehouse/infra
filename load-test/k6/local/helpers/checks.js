import { check } from 'k6';

export function parseJson(res) {
  try {
    return JSON.parse(res.body);
  } catch {
    return null;
  }
}

export function checkStatus(res, label, expected = 200) {
  return check(res, {
    [`${label}: HTTP ${expected}`]: (response) => response.status === expected,
  });
}

export function checkJson(res, label, predicate) {
  const body = parseJson(res);
  return check(res, {
    [`${label}: JSON 구조`]: () => body !== null && predicate(body),
  });
}

export const isObject = (value) => value !== null
  && typeof value === 'object' && !Array.isArray(value);
export const isArray = (value) => Array.isArray(value);

export function checkJsonResponse(res, label, predicate, expected = 200) {
  const statusOk = checkStatus(res, label, expected);
  const shapeOk = checkJson(res, label, predicate);
  return statusOk && shapeOk;
}
