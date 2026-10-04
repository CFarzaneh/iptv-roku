import test from 'node:test';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { App } from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { ControlRoomStack } from '../infra/stack.mjs';
import { rokuAttestationCertificates } from '../server/roku-certificates.mjs';

test('CDK retains private login and hosting, adds one small TTL mailbox, and removes Lightsail', () => {
  const app = new App();
  const stack = new ControlRoomStack(app, 'Test', { env: { account: '123456789012', region: 'us-east-2' } });
  const template = Template.fromStack(stack);
  template.hasResourceProperties('AWS::Cognito::UserPool', { AdminCreateUserConfig: { AllowAdminCreateUserOnly: true } });
  template.hasResourceProperties('AWS::Cognito::UserPool', { UserPoolTier: 'ESSENTIALS',
    Policies: Match.objectLike({ SignInPolicy: { AllowedFirstAuthFactors: ['PASSWORD', 'WEB_AUTHN'] } }),
    WebAuthnUserVerification: 'required' });
  template.hasResourceProperties('AWS::Cognito::UserPoolClient', { GenerateSecret: false, AllowedOAuthFlows: ['code'],
    ExplicitAuthFlows: Match.arrayWith(['ALLOW_USER_AUTH']) });
  template.hasResourceProperties('AWS::Cognito::UserPoolDomain', { ManagedLoginVersion: 2 });
  template.hasResourceProperties('AWS::Cognito::ManagedLoginBranding', {
    Settings: Match.objectLike({ categories: { global: { colorSchemeMode: 'DARK' } } }),
  });
  template.hasResourceProperties('AWS::DynamoDB::Table', {
    TableName: 'iptv-control-room', TimeToLiveSpecification: { AttributeName: 'expiresAt', Enabled: true },
    ProvisionedThroughput: { ReadCapacityUnits: 5, WriteCapacityUnits: 5 },
  });
  template.resourceCountIs('AWS::Amplify::App', 1);
  template.resourceCountIs('AWS::Lightsail::Container', 0);
  template.resourceCountIs('AWS::IAM::OIDCProvider', 0);
  template.resourceCountIs('AWS::SecretsManager::Secret', 0);
  template.resourceCountIs('AWS::ApiGateway::RestApi', 0);
  template.resourceCountIs('AWS::Lambda::Function', 0);
});

test('private configuration adds one Lambda Function URL with no video infrastructure', () => {
  const dir = mkdtempSync(join(tmpdir(), 'iptv-cdk-test-'));
  const path = join(dir, 'server.json');
  writeFileSync(path, JSON.stringify({ region: 'us-east-2', origins: ['https://example.com'],
    userPoolId: 'us-east-2_example', clientId: 'example', adminSub: 'example',
    attestationCertificates: rokuAttestationCertificates, devices: [] }));
  try {
    const app = new App();
    const stack = new ControlRoomStack(app, 'ApiTest', { env: { account: '123456789012', region: 'us-east-2' }, configurationPath: path });
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::Lambda::Function', 1);
    template.resourceCountIs('AWS::Lambda::Url', 1);
    template.resourceCountIs('AWS::DynamoDB::Table', 1);
    template.resourceCountIs('AWS::Lightsail::Container', 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
