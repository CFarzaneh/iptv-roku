import { execFileSync } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';

const profile = process.env.AWS_PROFILE || 'cam';
const aws = (...args) => JSON.parse(execFileSync('aws', [...args, '--profile', profile, '--region', 'us-east-2', '--output', 'json'], { encoding: 'utf8' }));
const stack = aws('cloudformation', 'describe-stacks', '--stack-name', 'IptvControlRoom').Stacks[0];
const outputs = Object.fromEntries(stack.Outputs.map(o => [o.OutputKey, o.OutputValue]));
await writeFile('dist/runtime-config.json', JSON.stringify({ apiUrl: outputs.RelayUrl, cognitoDomain: outputs.LoginUrl, clientId: outputs.ClientId }));
await mkdir('.private', { recursive: true, mode: 0o700 });
const artifact = resolve('.private/dashboard.zip');
execFileSync('zip', ['-qr', artifact, '.'], { cwd: resolve('dist') });
const deployment = aws('amplify', 'create-deployment', '--app-id', outputs.AmplifyAppId, '--branch-name', 'main');
const upload = await fetch(deployment.zipUploadUrl, { method: 'PUT', body: await readFile(artifact), headers: { 'Content-Type': 'application/zip' } });
if (!upload.ok) throw Error('Dashboard upload failed.');
aws('amplify', 'start-deployment', '--app-id', outputs.AmplifyAppId, '--branch-name', 'main', '--job-id', deployment.jobId);
console.info(`Deployment started: ${outputs.DashboardUrl}`);
