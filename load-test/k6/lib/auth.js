import { users } from './data.js';

export function getAuthHeader() {
  const userIndex = (__VU - 1) % users.length;
  const user = users[userIndex];
  
  return {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${user.token}`,
    },
  };
}
