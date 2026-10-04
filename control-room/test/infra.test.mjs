import test from 'node:test';
import assert from 'node:assert/strict';
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { ControlRoomStack } from '../infra/stack.mjs';

test('CDK provisions private login and hosting without a billable idle relay or database', () => {
  const app = new App();
  const stack = new ControlRoomStack(app, 'Test', { env: { account: '123456789012', region: 'us-east-2' } });
  const template = Template.fromStack(stack);
  template.hasResourceProperties('AWS::Cognito::UserPool', { AdminCreateUserConfig: { AllowAdminCreateUserOnly: true } });
  template.hasResourceProperties('AWS::Cognito::UserPoolClient', { GenerateSecret: false, AllowedOAuthFlows: ['code'] });
  template.resourceCountIs('AWS::Lightsail::Container', 0);
  template.resourceCountIs('AWS::Amplify::App', 1);
  template.resourceCountIs('AWS::DynamoDB::Table', 0);
  template.resourceCountIs('AWS::SecretsManager::Secret', 0);
  template.resourceCountIs('AWS::S3::Bucket', 0);
  assert.equal(stack.region, 'us-east-2');
  assert.equal(template.toJSON().Parameters?.BootstrapVersion, undefined);
});

test('enabling the relay adds one Lightsail service and a GitHub image-only role', () => {
  const app = new App();
  const stack = new ControlRoomStack(app, 'RelayTest', { env: { account: '123456789012', region: 'us-east-2' },
    enableRelay: true, githubSubject: 'repo:CFarzaneh@1896372/iptv-roku@1403768016:ref:refs/heads/main' });
  const template = Template.fromStack(stack);
  template.hasResourceProperties('AWS::Lightsail::Container', { Scale: 1, Power: 'nano' });
  template.resourceCountIs('AWS::IAM::OIDCProvider', 1);
  template.resourceCountIs('AWS::IAM::Role', 1);
});
