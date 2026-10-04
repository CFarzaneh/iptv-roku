let accessToken = '', refreshToken = '', expiresAt = 0, refreshing;
let sessionGeneration = 0;
export let config;
const refreshTokenKey = 'iptv-dashboard-refresh-token';
const encode = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const callback = () => `${location.origin}/`;
function clearSession() {
  sessionGeneration++;
  accessToken = ''; refreshToken = ''; expiresAt = 0;
  sessionStorage.removeItem(refreshTokenKey);
}
export async function initialize() {
  const response = await fetch('/runtime-config.json', { cache: 'no-store' });
  config = response.ok && response.headers.get('content-type')?.includes('json') ? await response.json() : {};
  config = { apiUrl: import.meta.env.VITE_API_URL, cognitoDomain: import.meta.env.VITE_COGNITO_DOMAIN,
    clientId: import.meta.env.VITE_COGNITO_CLIENT_ID, ...config };
  if (!config.apiUrl || !config.cognitoDomain || !config.clientId) return false;
  for (const key of ['apiUrl', 'cognitoDomain']) {
    const u = new URL(config[key]);
    if (u.protocol !== 'https:' && !(import.meta.env.DEV && u.hostname === '127.0.0.1')) throw Error('Secure configuration required');
  }
  config.apiUrl = config.apiUrl.replace(/\/+$/, '');
  const params = new URLSearchParams(location.search);
  if (params.has('error')) { history.replaceState({}, '', '/'); throw Error('Sign-in was not completed. Please try again.'); }
  if (params.has('code')) {
    const verifier = sessionStorage.getItem('oauth-verifier'), state = sessionStorage.getItem('oauth-state');
    sessionStorage.removeItem('oauth-verifier'); sessionStorage.removeItem('oauth-state');
    history.replaceState({}, '', '/');
    if (!verifier || !state || state !== params.get('state')) throw Error('Sign-in expired. Please try again.');
    await exchange({ grant_type: 'authorization_code', code: params.get('code'), code_verifier: verifier, redirect_uri: callback() });
  } else {
    refreshToken = sessionStorage.getItem(refreshTokenKey) || '';
    if (refreshToken) {
      try { await exchange({ grant_type: 'refresh_token', refresh_token: refreshToken }); }
      catch (error) { if (refreshToken) throw error; }
    }
  }
  return true;
}
async function exchange(values) {
  const generation = sessionGeneration;
  const response = await fetch(`${config.cognitoDomain}/oauth2/token`, { method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: config.clientId, ...values }) });
  if (generation !== sessionGeneration) throw Error('Session ended.');
  if (!response.ok) { clearSession(); throw Error('Please sign in again.'); }
  const data = await response.json();
  if (generation !== sessionGeneration) throw Error('Session ended.');
  if (!data.access_token || !data.expires_in) { clearSession(); throw Error('Please sign in again.'); }
  accessToken = data.access_token; refreshToken = data.refresh_token || refreshToken;
  expiresAt = Date.now() + data.expires_in * 1000;
  if (refreshToken) sessionStorage.setItem(refreshTokenKey, refreshToken);
}
export async function login() {
  clearSession();
  const verifier = encode(crypto.getRandomValues(new Uint8Array(32)));
  const state = encode(crypto.getRandomValues(new Uint8Array(32)));
  const challenge = encode(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
  sessionStorage.setItem('oauth-verifier', verifier); sessionStorage.setItem('oauth-state', state);
  location.assign(`${config.cognitoDomain}/oauth2/authorize?${new URLSearchParams({ client_id: config.clientId,
    response_type: 'code', scope: 'openid email aws.cognito.signin.user.admin', redirect_uri: callback(), state,
    code_challenge_method: 'S256', code_challenge: challenge })}`);
}
export function authenticated() { return Boolean(accessToken); }
export function passkeyEnrollmentUrl() {
  if (!authenticated()) throw Error('Sign in before adding a passkey.');
  const url = new URL('/passkeys/add', config.cognitoDomain);
  url.search = new URLSearchParams({ client_id: config.clientId, redirect_uri: callback() }).toString();
  return url.toString();
}
export function passwordResetUrl() {
  const url = new URL('/forgotPassword', config.cognitoDomain);
  url.search = new URLSearchParams({ client_id: config.clientId, redirect_uri: callback(),
    response_type: 'code', scope: 'openid email aws.cognito.signin.user.admin' }).toString();
  return url.toString();
}
export function logout() {
  clearSession();
  location.assign(`${config.cognitoDomain}/logout?${new URLSearchParams({ client_id: config.clientId, logout_uri: callback() })}`);
}
export async function api(path, body, signal) {
  if (refreshToken && expiresAt - Date.now() < 60000) {
    refreshing ||= exchange({ grant_type: 'refresh_token', refresh_token: refreshToken }).finally(() => { refreshing = null; });
    await refreshing;
  }
  const response = await fetch(`${config.apiUrl}/${path.replace(/^\/+/, '')}`, { method: body ? 'POST' : 'GET', signal,
    headers: { Authorization: `Bearer ${accessToken}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}) });
  if (!response.ok) {
    if (response.status === 401) { clearSession(); throw Error('Your session expired. Sign in again.'); }
    const codes = { DEVICE_OFFLINE: 'This Roku is offline.', STALE_CATALOG: 'The channel list changed. Refresh channels.',
      STALE_PLAYBACK: 'Playback changed on the TV. Try again.', DEVICE_BUSY: 'The Roku is busy. Try again shortly.',
      FORBIDDEN: 'This login is not the dashboard administrator.',
      REAUTH_REQUIRED: 'Sign out and sign in again to enable account settings.',
      INVALID_CODE: 'That verification code is incorrect.', EXPIRED_CODE: 'That code expired. Request another one.',
      EMAIL_IN_USE: 'That email is already used by another account.', RATE_LIMITED: 'Too many attempts. Wait a few minutes and try again.' };
    const data = await response.json().catch(() => ({}));
    throw Error(codes[data.error] || 'The request could not be completed. Please try again.');
  }
  return response.json();
}
