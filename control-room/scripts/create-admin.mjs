import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';

const email = process.argv[2];
if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
  console.error('Usage: node scripts/create-admin.mjs ADMIN_EMAIL');
  process.exit(1);
}
const profile = process.env.AWS_PROFILE || 'cam';
const username = 'control-admin';
const aws = (...args) => JSON.parse(execFileSync('aws', [...args, '--profile', profile, '--region', 'us-east-2', '--output', 'json'], { encoding: 'utf8' }));
const stack = aws('cloudformation', 'describe-stacks', '--stack-name', 'IptvControlRoom').Stacks[0];
const outputs = Object.fromEntries(stack.Outputs.map(o => [o.OutputKey, o.OutputValue]));
mkdirSync('.private', { recursive: true, mode: 0o700 });
const passwordPath = resolve('.private/admin-first-login.txt');
if (!existsSync(passwordPath)) {
  const password = `Aa1!${randomBytes(28).toString('base64url')}`;
  writeFileSync(passwordPath, password, { mode: 0o600, flag: 'wx' });
}
try {
  aws('cognito-idp', 'admin-create-user', '--user-pool-id', outputs.UserPoolId,
    '--username', username, '--user-attributes', `Name=email,Value=${email}`, 'Name=email_verified,Value=true',
    '--temporary-password', `file://${passwordPath}`, '--message-action', 'SUPPRESS');
} catch (error) {
  console.error('Cognito user creation failed; the local first-login file was not sent.');
  throw error;
}
const user = aws('cognito-idp', 'admin-get-user', '--user-pool-id', outputs.UserPoolId, '--username', username);
const sub = user.UserAttributes.find(attribute => attribute.Name === 'sub')?.Value;
if (!sub) throw Error('Cognito did not return the administrator subject.');
writeFileSync('.private/admin.json', JSON.stringify({ email, sub, userPoolId: outputs.UserPoolId,
  clientId: outputs.ClientId, dashboardUrl: outputs.DashboardUrl, loginUrl: outputs.LoginUrl }, null, 2), { mode: 0o600, flag: 'wx' });
console.info('Administrator created with no invitation email. First-login password: .private/admin-first-login.txt');
console.info(`Dashboard: ${outputs.DashboardUrl}`);
