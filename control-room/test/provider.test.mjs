import test from 'node:test';
import assert from 'node:assert/strict';
import { result } from '../server/schema.mjs';
import { providerErrorMessage } from '../web/provider.mjs';

test('provider diagnostics accept fixed codes and strip private details', () => {
  for (const code of ['PROVIDER_ERROR', 'PROVIDER_CONNECTION_FAILED', 'PROVIDER_ACCESS_DENIED',
    'PROVIDER_ACCOUNT_REJECTED', 'PROVIDER_ACCOUNT_INACTIVE', 'PROVIDER_BAD_RESPONSE']) {
    const parsed = result.parse({ commandId: 'test-validation', status: 'failed', code,
      server: 'https://private.example', username: 'private-user', password: 'private-password', body: 'private-body' });
    assert.deepEqual(parsed, { commandId: 'test-validation', status: 'failed', code });
    assert.ok(providerErrorMessage(code, 'xtream'));
  }
  assert.equal(result.safeParse({ commandId: 'test-validation', status: 'failed', code: 'raw provider error' }).success, false);
});

test('network rejection does not instruct the user to change valid credentials', () => {
  assert.match(providerErrorMessage('PROVIDER_ACCESS_DENIED', 'xtream'), /restrictions/);
  assert.doesNotMatch(providerErrorMessage('PROVIDER_ACCESS_DENIED', 'xtream'), /password/);
  assert.match(providerErrorMessage('PROVIDER_ACCOUNT_REJECTED', 'xtream'), /username and password/);
  assert.match(providerErrorMessage('PROVIDER_ERROR', 'm3u'), /complete M3U URL/);
  assert.equal(providerErrorMessage('SAVE_FAILED', 'xtream'), undefined);
});
