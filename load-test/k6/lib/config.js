import openData from 'k6/data';

const scale = JSON.parse(open('../../scale.json'));

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
export const SCALE = scale;
