// Run manually against `pnpm dev`; mock OAuth/API responses, never production auth.
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({ headless: true, channel: 'chrome' });
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
  const page = await context.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await context.route('**/runtime-config.json', route => route.fulfill({ json: {
    apiUrl: 'https://api.example.test', cognitoDomain: 'https://login.example.test', clientId: 'fixture-client',
  } }));
  const tokenGrants = [];
  await context.route('https://login.example.test/oauth2/token', route => {
    const grant = new URLSearchParams(route.request().postData()).get('grant_type');
    tokenGrants.push(grant);
    return route.fulfill({ json: { access_token: 'test-only-token',
      ...(grant === 'authorization_code' ? { refresh_token: 'test-refresh-token' } : {}), expires_in: 3600 } });
  });
  await context.route('https://login.example.test/logout*', route => route.fulfill({ status: 302, headers: { Location: 'http://127.0.0.1:5173/' } }));
  const devices = [{ id: 'my-roku', label: 'My Roku', online: true, lastSeen: Date.now(), results: [], snapshot: {
    appSessionId: 'fixture', sourceRevision: 's1', catalogRevision: 'c1', playbackRevision: 1,
    state: 'playing', channel: { streamId: '42', name: 'World News', group: 'News' },
    metrics: { sessionBytes: 342000000, bytesPerSecond: 650000, bitrate: 5200000, width: 1920, height: 1080 }, appVersion: '1.0.20', osVersion: '15',
  } }, { id: 'dads-roku', label: 'Dad’s Roku', online: false, lastSeen: null, snapshot: null, results: [] }];
  let lastCommand;
  await context.route('https://api.example.test/**', async route => {
    if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*' } });
    const headers = { 'Access-Control-Allow-Origin': '*' };
    if (route.request().method() === 'GET') {
      await new Promise(resolve => setTimeout(resolve, 100));
      return route.fulfill({ headers, json: { cursor: 'fixture-1', devices } });
    }
    const body = route.request().postDataJSON(); lastCommand = body;
    const commandId = crypto.randomUUID();
    const data = body.kind === 'categories' ? { sourceRevision: 's1', catalogRevision: 'c1', categories: [{ id: 'news', name: 'News' }] }
      : { sourceRevision: 's1', catalogRevision: 'c1', channels: [{ streamId: '42', name: 'World News', group: 'News' }, { streamId: '43', name: 'City News', group: 'News' }], offset: 0, total: 2 };
    devices[0].results = [{ requestId: body.requestId, commandId, status: body.type === 'changeChannel' ? 'playing' : 'ok', data }];
    return route.fulfill({ headers, status: 202, json: { commandId, requestId: body.requestId } });
  });
  await context.addInitScript(() => { sessionStorage.setItem('oauth-state', 'fixture-state'); sessionStorage.setItem('oauth-verifier', 'fixture-verifier'); });
  await page.goto('http://127.0.0.1:5173/?code=fixture&state=fixture-state');
  await page.getByRole('heading', { name: 'Devices', exact: true }).waitFor();
  assert.equal(await page.evaluate(() => sessionStorage.getItem('iptv-dashboard-refresh-token')), 'test-refresh-token');
  await page.reload();
  await page.getByRole('heading', { name: 'Devices', exact: true }).waitFor();
  assert.deepEqual(tokenGrants.slice(0, 2), ['authorization_code', 'refresh_token']);
  await page.getByRole('button', { name: 'Load categories' }).click();
  await page.getByRole('button', { name: 'News', exact: true }).click();
  await page.getByRole('button', { name: /City News/ }).waitFor();
  await mkdir('.private/screenshots', { recursive: true });
  await page.screenshot({ path: '.private/screenshots/dashboard-desktop.png', fullPage: true });
  await page.getByRole('button', { name: /City News/ }).click();
  await page.getByRole('status').filter({ hasText: 'City News is playing.' }).waitFor();
  assert.equal(lastCommand.streamId, '43');
  assert.equal(lastCommand.expectedPlaybackRevision, 1);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: '.private/screenshots/dashboard-mobile.png', fullPage: true });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, 'mobile layout overflows');
  await page.getByRole('button', { name: /Dad’s Roku/ }).click();
  assert.equal(await page.getByRole('button', { name: 'Load categories' }).isDisabled(), true);
  await page.getByRole('button', { name: 'Profile' }).click();
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.getByRole('heading', { name: 'Sign in' }).waitFor();
  assert.equal(await page.evaluate(() => sessionStorage.getItem('iptv-dashboard-refresh-token')), null);
  assert.deepEqual(errors, []);
  console.info('Browser smoke passed: reload, sign-out, catalog, provider ID tuning, offline controls, desktop/mobile layout.');
} finally { await browser.close(); }
