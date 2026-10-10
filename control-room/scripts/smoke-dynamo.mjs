import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { DeleteCommand, QueryCommand, PutCommand, GetCommand } from '@aws-sdk/lib-dynamodb';
import { documentClient, DynamoRelay, DynamoAuth } from '../server/dynamo.mjs';

import { hash } from '../server/auth.mjs';

const table = process.env.TABLE_NAME || 'iptv-control-room';
const id = `smoke-${randomUUID()}`;
const db = documentClient();
const partition = `DEVICE#${id}`;
const session = { appSessionId: randomUUID() };
const relay = new DynamoRelay([{ id, label: 'Smoke test', enabled: true }], db, table);
const snapshot = {
  appSessionId: session.appSessionId, sourceRevision: 'source-1', catalogRevision: 'catalog-1',
  playbackRevision: 1, state: 'playing', channel: { streamId: '100', name: 'Test', group: 'Test' },
  metrics: { sessionBytes: 1000, tuneBytes: 1000, bytesPerSecond: 100, bitrate: 800,
    width: 1920, height: 1080, startupMs: 200, bufferingCount: 0, bufferingMs: 0 },
  appVersion: 'smoke', osVersion: 'smoke', provider: { type: 'm3u', configured: true },
};

try {
  await db.send(new PutCommand({ TableName: table,
    Item: { PK: partition, SK: 'STATE', appSessionId: session.appSessionId, lastSeenAt: 0, snapshot } }));
  await relay.rename(id, 'Living room 📺');
  const freshRelay = new DynamoRelay([{ id, label: 'Original default', enabled: true }], db, table);
  const offline = (await freshRelay.view()).devices[0];
  assert.equal(offline.label, 'Living room 📺', 'custom names survive a fresh Lambda instance');
  assert.equal(offline.online, false, 'renaming must not mark a device online');
  await freshRelay.sync(id, session, { snapshot, results: [] });
  const request = { requestId: randomUUID(), sourceRevision: 'source-1', catalogRevision: 'catalog-1',
    streamId: '101', expectedPlaybackRevision: 1 };
  const created = await relay.enqueue(id, request, 'changeChannel');
  assert.equal((await relay.enqueue(id, request, 'changeChannel')).commandId, created.commandId);
  const delivery = await relay.sync(id, session, { snapshot, results: [] });
  assert.equal(delivery.command.commandId, created.commandId);
  assert.equal(delivery.command.streamId, '101');
  assert.equal((await relay.sync(id, session, { snapshot, results: [] })).command.commandId,
    created.commandId, 'unacknowledged commands must survive a lost HTTP response');
  await relay.sync(id, session, { snapshot, results: [{ commandId: created.commandId, status: 'received', code: 'NONE' }] });
  assert.equal((await relay.sync(id, session, { snapshot, results: [] })).command, null);
  await relay.sync(id, session, { snapshot, results: [{ commandId: created.commandId, status: 'playing', code: 'NONE' }] });
  assert.equal((await relay.enqueue(id, request, 'changeChannel')).commandId, created.commandId,
    'completed command retries must remain idempotent');
  const view = await relay.view();
  assert.equal(view.devices[0].results[0].status, 'playing');
  const secret = randomUUID();
  const auth = new DynamoAuth({devices:[{id,enabled:true,secretHash:hash(secret),developerId:'smoke',channelId:'dev'}]},
    {attest:async token => JSON.parse(token)}, db, table);
  const challenge = await auth.challenge(secret);
  const nextSession = {appSessionId:randomUUID()};
  await auth.session(secret, {challengeId:challenge.challengeId, appSessionId:nextSession.appSessionId,
    attestation:JSON.stringify({nonce:challenge.nonce,developerId:'smoke',channelId:'dev'})});
  await freshRelay.sync(id, nextSession, {snapshot:{...snapshot,appSessionId:nextSession.appSessionId},results:[]});
  assert.equal((await freshRelay.view()).devices[0].label, 'Living room 📺', 'session renewal and reports preserve the name');
  const state = (await db.send(new GetCommand({TableName:table,Key:{PK:partition,SK:'STATE'},ConsistentRead:true}))).Item;
  assert.equal(state.expiresAt, undefined, 'custom names must not expire');
  console.info('DynamoDB mailbox and persistent device-name smoke tests passed.');
} finally {
  const items = await db.send(new QueryCommand({ TableName: table,
    KeyConditionExpression: 'PK=:pk', ExpressionAttributeValues: { ':pk': partition },
    ConsistentRead: true }));
  for (const item of items.Items || []) {
    await db.send(new DeleteCommand({ TableName: table, Key: { PK: item.PK, SK: item.SK } }));
  }
}
