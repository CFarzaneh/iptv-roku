import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';

// AWS CLI console-login profiles work in the CLI, but older SDK credential
// chains used by CDK need the CLI's process-credentials bridge.
const profile = process.env.AWS_PROFILE || 'cam';
const aws = execFileSync('which', ['aws'], { encoding: 'utf8' }).trim();
const originalConfig = process.env.AWS_CONFIG_FILE || resolve(homedir(), '.aws/config');
const account = JSON.parse(execFileSync(aws, ['sts', 'get-caller-identity', '--profile', profile, '--region', 'us-east-2', '--output', 'json'], { encoding: 'utf8' })).Account;
const localProfile = 'iptv-cdk-process';
mkdirSync('.private', { recursive: true, mode: 0o700 });
const bridge = resolve('.private/aws-cdk-config');
const cdkHome = resolve('.private/cdk-home');
mkdirSync(cdkHome, { recursive: true, mode: 0o700 });
writeFileSync(bridge, `[profile ${localProfile}]\ncredential_process = env AWS_CONFIG_FILE="${originalConfig}" "${aws}" configure export-credentials --profile "${profile}" --format process\nregion = us-east-2\n`, { mode: 0o600 });
const result = spawnSync('pnpm', ['cdk', ...process.argv.slice(2)], {
  env: { ...process.env, AWS_CONFIG_FILE: bridge, AWS_PROFILE: localProfile,
    AWS_REGION: 'us-east-2', CDK_DEFAULT_ACCOUNT: account, CDK_HOME: cdkHome },
  stdio: 'inherit',
});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
