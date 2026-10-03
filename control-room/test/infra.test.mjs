import test from 'node:test';
import assert from 'node:assert/strict';
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { ControlRoomStack } from '../infra/stack.mjs';

test('CDK provisions private login and a single relay without a history database', () => {
  const app = new App();
  const stack = new ControlRoomStack(app, 'Test', { env: { account: '123456789012', region: 'us-east-2' } });
  const template = Template.fromStack(stack);
  template.hasResourceProperties('AWS::Cognito::UserPool', { AdminCreateUserConfig: { AllowAdminCreateUserOnly: true } });
  template.hasResourceProperties('AWS::Cognito::UserPoolClient', { GenerateSecret: false, AllowedOAuthFlows: ['code'] });
  template.hasResourceProperties('AWS::Lightsail::Container', { Scale: 1, Power: 'nano' });
  template.resourceCountIs('AWS::Amplify::App', 1);
  template.resourceCountIs('AWS::DynamoDB::Table', 0);
  template.resourceCountIs('AWS::SecretsManager::Secret', 0);
  template.resourceCountIs('AWS::S3::Bucket', 0);
  assert.equal(stack.region, 'us-east-2');
  assert.equal(template.toJSON().Parameters?.BootstrapVersion, undefined);
});
