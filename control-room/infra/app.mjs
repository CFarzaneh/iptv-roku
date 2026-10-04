import { App } from 'aws-cdk-lib';
import { ControlRoomStack } from './stack.mjs';

const app = new App();
const region = app.node.tryGetContext('region') || 'us-east-2';
if (region !== 'us-east-2') throw Error('This project is deployed only in us-east-2.');
new ControlRoomStack(app, 'IptvControlRoom', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region },
  configurationPath: app.node.tryGetContext('relayConfig'),
});
