import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../server/app.mjs';
import { hash } from '../server/auth.mjs';

const secret = 'a'.repeat(43), other = 'b'.repeat(43), adminToken = 'admin'.repeat(10);
const config = { origins: ['https://dashboard.example'], devices: [
  { id: 'my-roku', label: 'My Roku', enabled: true, secretHash: hash(secret), developerId: 'developer-a', channelId: 'dev' },
  { id: 'dads-roku', label: "Dad’s Roku", enabled: true, secretHash: hash(other), developerId: 'developer-b', channelId: 'dev' },
] };
const snap = { appSessionId: 'boot-1', sourceRevision: 'source-1', catalogRevision: 'catalog-1', playbackRevision: 0,
  state: 'idle', channel: null, appVersion: '1.0', osVersion: '15.0', provider: { type: 'xtream', configured: true },
  metrics: Object.fromEntries(['sessionBytes','tuneBytes','bytesPerSecond','bitrate','width','height','startupMs','bufferingCount','bufferingMs'].map(k => [k, null])) };
async function fixture(t) {
  let time = 1000000;
  const app = createApp(structuredClone(config), {
    admin: async token => { if (token !== adminToken) throw Error('bad'); },
    attest: async token => JSON.parse(token),
  }, { now: () => time });
  t.after(() => app.close());
  const call = (method, url, token = adminToken, payload) => app.inject({ method, url, headers: { authorization: `Bearer ${token}` }, payload });
  async function login(key = secret, boot = 'boot-1') {
    const c = (await call('POST', '/device/auth/challenge', key)).json();
    const payload = { challengeId: c.challengeId, appSessionId: boot,
      attestation: JSON.stringify({ nonce: c.nonce, developerId: key === secret ? 'developer-a' : 'developer-b', channelId: 'dev' }) };
    const response = await call('POST', '/device/auth/session', key, payload);
    assert.equal(response.statusCode, 200);
    return { token: response.json().sessionToken, payload };
  }
  const { token } = await login();
  assert.equal((await call('POST', '/device/reports', token, snap)).statusCode, 200);
  return { app, call, login, token, advance: ms => { time += ms; } };
}
const tune = (requestId = 'r1') => ({ type: 'changeChannel', requestId, streamId: '12345', sourceRevision: 'source-1', catalogRevision: 'catalog-1', expectedPlaybackRevision: 0 });

test('native channel ID delivered only to its assigned device; real acknowledgments reach admin', async t => {
  const { call, token, login } = await fixture(t);
  const accepted = (await call('POST', '/devices/my-roku/commands', adminToken, tune())).json();
  const delivered = (await call('GET', '/device/commands', token)).json().commands[0];
  assert.equal(delivered.streamId, '12345');
  const dad = await login(other);
  assert.equal((await call('POST', '/device/results', dad.token, { commandId: accepted.commandId, status: 'playing' })).statusCode, 409);
  assert.equal((await call('POST', '/devices/my-roku/commands', token, tune())).statusCode, 401);
  await call('POST', '/device/results', token, { commandId: accepted.commandId, status: 'playing' });
  assert.equal((await call('GET', '/devices')).json().devices[0].results[0].status, 'playing');
});
test('credential payload never appears in snapshots and is discarded after receipt', async t => {
  const { app, call, token } = await fixture(t);
  const accepted = (await call('POST', '/devices/my-roku/provider-config', adminToken,
    { requestId: 'secret-update', providerType: 'xtream', server: 'https://provider.example', username: 'owner', password: 'private-password' })).json();
  assert.ok(!(await call('GET', '/devices')).body.includes('private-password'));
  assert.equal((await call('GET', '/device/commands', token)).json().commands[0].type, 'providerConfig');
  await call('POST', '/device/results', token, { commandId: accepted.commandId, status: 'received' });
  assert.equal(app.relay.get('my-roku').commands[0].payload, undefined);
});
test('attestation challenge cannot be reused, including concurrent submissions', async t => {
  const { call } = await fixture(t);
  const c = (await call('POST', '/device/auth/challenge', secret)).json();
  const data = { challengeId: c.challengeId, appSessionId: 'boot-1', attestation: JSON.stringify({ nonce: c.nonce, developerId: 'developer-a', channelId: 'dev' }) };
  const results = await Promise.all([call('POST', '/device/auth/session', secret, data), call('POST', '/device/auth/session', secret, data)]);
  assert.deepEqual(results.map(r => r.statusCode).sort(), [200, 401]);
});
test('expired, incorrect and revoked identities fail closed', async t => {
  const { app, call, token, advance } = await fixture(t);
  assert.equal((await call('POST', '/device/auth/challenge', 'wrong'.repeat(10))).statusCode, 401);
  app.authState.config.devices[0].enabled = false;
  assert.equal((await call('POST', '/device/reports', token, snap)).statusCode, 401);
  app.authState.config.devices[0].enabled = true; advance(900001);
  assert.equal((await call('POST', '/device/reports', token, snap)).statusCode, 401);
});
test('stale playback/catalog revisions, offline devices, and arbitrary commands are rejected', async t => {
  const { call, advance } = await fixture(t);
  assert.equal((await call('POST', '/devices/my-roku/commands', adminToken, { ...tune(), expectedPlaybackRevision: 2 })).statusCode, 409);
  assert.equal((await call('POST', '/devices/my-roku/commands', adminToken, { ...tune(), catalogRevision: 'old' })).statusCode, 409);
  assert.equal((await call('POST', '/devices/my-roku/commands', adminToken, { ...tune(), type: 'exec' })).statusCode, 400);
  advance(60001);
  assert.equal((await call('POST', '/devices/my-roku/commands', adminToken, tune())).statusCode, 409);
});
test('duplicate browser submission does not enqueue twice; expired commands are not replayed', async t => {
  const { app, call, advance } = await fixture(t);
  const a = await call('POST', '/devices/my-roku/commands', adminToken, tune());
  const b = await call('POST', '/devices/my-roku/commands', adminToken, tune());
  assert.equal(a.json().commandId, b.json().commandId);
  assert.equal(app.relay.get('my-roku').commands.length, 1);
  advance(30001); await call('GET', '/devices');
  assert.equal(app.relay.get('my-roku').commands.length, 0);
});
test('new app session fences old token and strips unknown telemetry fields', async t => {
  const { call, login, token } = await fixture(t);
  const next = await login(secret, 'boot-2');
  assert.equal((await call('POST', '/device/reports', token, snap)).statusCode, 401);
  await call('POST', '/device/reports', next.token, { ...snap, appSessionId: 'boot-2', password: 'do-not-echo' });
  assert.ok(!(await call('GET', '/devices')).body.includes('do-not-echo'));
});

test('a pending long poll wakes immediately for a new command', async t => {
  const { app, call, token } = await fixture(t);
  const poll = call('GET', '/device/commands', token);
  while (!app.relay.get('my-roku').waiter) await new Promise(resolve => setImmediate(resolve));
  const accepted = await call('POST', '/devices/my-roku/commands', adminToken, tune());
  const delivered = await poll;
  assert.equal(delivered.json().commands[0].commandId, accepted.json().commandId);
});
test('session authorization is checked again before pending command delivery', async t => {
  const { app, call, token } = await fixture(t);
  const poll = call('GET', '/device/commands', token);
  while (!app.relay.get('my-roku').waiter) await new Promise(resolve => setImmediate(resolve));
  app.authState.config.devices[0].enabled = false;
  app.relay.get('my-roku').waiter.wake();
  assert.equal((await poll).statusCode, 401);
});
test('wrong developer claim fails without consuming a still-valid challenge', async t => {
  const { call } = await fixture(t);
  const c = (await call('POST', '/device/auth/challenge', secret)).json();
  const payload = { challengeId: c.challengeId, appSessionId: 'boot-1', attestation: JSON.stringify({ nonce: c.nonce, developerId: 'wrong', channelId: 'dev' }) };
  assert.equal((await call('POST', '/device/auth/session', secret, payload)).statusCode, 401);
});

test('admin can rename an offline device; invalid names and other identities are rejected', async t => {
  const { app, call, token, advance } = await fixture(t);
  advance(60001);
  const renamed = await call('POST', '/devices/my-roku/settings', adminToken, { label: '  Living room 📺  ' });
  assert.equal(renamed.statusCode, 200);
  assert.deepEqual(renamed.json(), { id: 'my-roku', label: 'Living room 📺' });
  let view = (await call('GET', '/devices')).json();
  assert.equal(view.devices[0].label, 'Living room 📺');
  assert.equal(view.devices[0].online, false);
  assert.equal(view.devices[1].label, 'Dad’s Roku');
  assert.equal(app.relay.get('my-roku').commands.length, 0);
  for (const payload of [{label:''}, {label:'   '}, {label:'a'.repeat(81)}, {label:'TV\nRoom'}, {label:'Room',enabled:false}]) {
    assert.equal((await call('POST', '/devices/my-roku/settings', adminToken, payload)).statusCode, 400);
  }
  assert.equal((await call('POST', '/devices/my-roku/settings', token, { label: 'Unauthorized' })).statusCode, 401);
  assert.equal((await call('POST', '/devices/missing/settings', adminToken, { label: 'Room' })).statusCode, 404);
  app.relay.get('dads-roku').enabled = false;
  assert.equal((await call('POST', '/devices/dads-roku/settings', adminToken, { label: 'Room' })).statusCode, 404);
  await call('POST', '/device/reports', token, { ...snap, label: 'Overwrite' });
  view = (await call('GET', '/devices')).json();
  assert.equal(view.devices[0].label, 'Living room 📺');
});
