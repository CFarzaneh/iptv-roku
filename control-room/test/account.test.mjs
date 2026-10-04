import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../server/app.mjs';

const token = 'administrator-access-token'.repeat(2);
const headers = { authorization: `Bearer ${token}` };

test('account changes require the same admin and self-service scope as Cognito', async t => {
  const calls = [];
  let scope = 'openid email';
  const account = {
    view: async () => ({ email: 'old@example.com', emailVerified: true, passkeys: [] }),
    updateEmail: async (_, email) => calls.push(['email', email]),
    verifyEmail: async (_, code) => calls.push(['verify', code]),
    resendEmailCode: async () => calls.push(['resend']),
    deletePasskey: async (_, id) => calls.push(['delete', id]),
  };
  const app = createApp({ origins: [], devices: [], region: 'us-east-2' }, {
    admin: async value => { if (value !== token) throw Error('unauthorized'); return { scope }; },
  }, { account });
  t.after(() => app.close());
  const call = (method, url, payload, authorization = headers.authorization) => app.inject({
    method, url, headers: { authorization }, payload,
  });
  assert.equal((await call('GET', '/account')).statusCode, 403);
  assert.equal((await call('GET', '/account', undefined, 'Bearer wrong'.repeat(5))).statusCode, 401);
  scope += ' aws.cognito.signin.user.admin';
  assert.equal((await call('GET', '/account')).json().email, 'old@example.com');
  assert.equal((await call('POST', '/account/email', { email: 'bad' })).statusCode, 400);
  assert.equal((await call('POST', '/account/email', { email: 'new@example.com' })).statusCode, 200);
  assert.equal((await call('POST', '/account/verify-email', { code: '123456' })).statusCode, 200);
  assert.equal((await call('POST', '/account/resend-email-code', {})).statusCode, 200);
  assert.equal((await call('POST', '/account/delete-passkey', { credentialId: 'key-1' })).statusCode, 200);
  assert.deepEqual(calls, [['email', 'new@example.com'], ['verify', '123456'], ['resend'], ['delete', 'key-1']]);
});
