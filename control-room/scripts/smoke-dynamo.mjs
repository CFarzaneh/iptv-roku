import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { DeleteCommand, QueryCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import { documentClient, DynamoRelay } from '../server/dynamo.mjs';

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
    Item: { PK: partition, SK: 'STATE', appSessionId: session.appSessionId, lastSeenAt: Date.now(), snapshot } }));
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
  console.info('DynamoDB mailbox smoke test passed.');
} finally {
  const items = await db.send(new QueryCommand({ TableName: table,
    KeyConditionExpression: 'PK=:pk', ExpressionAttributeValues: { ':pk': partition },
    ConsistentRead: true }));
  for (const item of items.Items || []) {
    await db.send(new DeleteCommand({ TableName: table, Key: { PK: item.PK, SK: item.SK } }));
  }
}
