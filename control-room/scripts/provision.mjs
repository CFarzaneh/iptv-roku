import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { randomToken, hash } from '../server/auth.mjs';
const [deviceId, label, apiUrl, developerId] = process.argv.slice(2);
if (!/^[a-z0-9-]{1,60}$/.test(deviceId || '') || !label || !apiUrl?.startsWith('https://') || !developerId) {
  console.error('Usage: node scripts/provision.mjs DEVICE_ID LABEL HTTPS_API_URL VERIFIED_DEVELOPER_ID'); process.exit(1);
}
const directory = `.private/${deviceId}`;
await mkdir(directory, { recursive: true, mode: 0o700 });
const secret = randomToken();
// wx refuses accidental rotation/overwrite of an existing installation identity.
await writeFile(`${directory}/dashboard.json`, JSON.stringify({ deviceId, apiUrl, secret }, null, 2), { mode: 0o600, flag: 'wx' });
await writeFile(`${directory}/authorization.json`, JSON.stringify({ id: deviceId, label, secretHash: hash(secret), enabled: true, developerId, channelId: 'dev' }, null, 2), { mode: 0o600, flag: 'wx' });
console.info(`Created private installation files in ${directory}. Copy dashboard.json to the Roku package at source/dashboard.json. Do not commit either file.`);
