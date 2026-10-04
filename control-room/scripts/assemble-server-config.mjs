import { readFileSync, writeFileSync } from 'node:fs';
import { serverConfig } from '../server/schema.mjs';

const admin = JSON.parse(readFileSync('.private/admin.json', 'utf8'));
const certificate = readFileSync('.private/roku-attestation.pem', 'utf8')
  .match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/)?.[0];
if (!certificate) throw Error('No PEM certificate in .private/roku-attestation.pem');
const devices = process.argv.slice(2).map(path => JSON.parse(readFileSync(path, 'utf8')));
const config = serverConfig.parse({ region: 'us-east-2', origins: [admin.dashboardUrl.replace(/\/$/, '')],
  userPoolId: admin.userPoolId, clientId: admin.clientId, adminSub: admin.sub,
  attestationCertificates: [certificate], devices });
writeFileSync('.private/server.json', JSON.stringify(config, null, 2), { mode: 0o600, flag: 'wx' });
console.info(`Created private server configuration for ${devices.length} verified device(s).`);
