import awsLambdaFastify from '@fastify/aws-lambda';
import { serverConfig } from './schema.mjs';
import { productionVerifiers } from './auth.mjs';
import { createApp } from './app.mjs';
import { documentClient, DynamoAuth, DynamoRelay } from './dynamo.mjs';
import { rokuAttestationCertificates } from './roku-certificates.mjs';

let prepared;
async function prepare() {
  const config = serverConfig.parse({ ...JSON.parse(process.env.CONTROL_ROOM_CONFIG_JSON),
    attestationCertificates: rokuAttestationCertificates });
  const db = documentClient(), table = process.env.TABLE_NAME;
  const verifiers = await productionVerifiers(config);
  const auth = new DynamoAuth(config, verifiers, db, table);
  const relay = new DynamoRelay(config.devices, db, table);
  const app = createApp(config, verifiers, { auth, relay, cors: false });
  await app.ready();
  return awsLambdaFastify(app);
}

export async function handler(event, context) {
  prepared ||= prepare();
  return (await prepared)(event, context);
}
