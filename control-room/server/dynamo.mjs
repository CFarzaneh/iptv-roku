import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand, QueryCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { Auth, ApiError, hash, randomToken, requireThat } from './auth.mjs';

export const documentClient = () => DynamoDBDocumentClient.from(new DynamoDBClient({}),
  { marshallOptions: { removeUndefinedValues: true } });
const pk = id => `DEVICE#${id}`;
const key = (id, sk) => ({ PK: pk(id), SK: sk });
const seconds = ms => Math.ceil(ms / 1000);
const failedCondition = error => error?.name === 'ConditionalCheckFailedException' || error?.name === 'TransactionCanceledException';

export class DynamoAuth extends Auth {
  constructor(config, verifiers, db, table, now = Date.now) {
    super(config, verifiers, now); this.db = db; this.table = table;
  }
  async challenge(token) {
    const device = this.installation(token);
    const challengeId = randomToken(), nonce = randomBytes(16).toString('hex');
    await this.db.send(new UpdateCommand({ TableName: this.table, Key: key(device.id, 'AUTH'),
      UpdateExpression: 'SET challengeId=:id, challengeNonce=:nonce, challengeExpiresAt=:expiry REMOVE expiresAt',
      ExpressionAttributeValues: { ':id': challengeId, ':nonce': nonce,
        ':expiry': this.now() + 60000 } }));
    return { challengeId, nonce, expiresIn: 60 };
  }
  async session(token, { challengeId, attestation, appSessionId }) {
    const device = this.installation(token);
    const authKey = key(device.id, 'AUTH');
    const challenge = (await this.db.send(new GetCommand({ TableName: this.table, Key: authKey, ConsistentRead: true }))).Item;
    requireThat(challenge?.challengeId === challengeId && challenge.challengeExpiresAt > this.now());
    const data = await this.verifiers.attest(attestation);
    requireThat(data && typeof data === 'object' && data.nonce === challenge.challengeNonce &&
      data.developerId === device.developerId && data.channelId === device.channelId, 401, 'INVALID_ATTESTATION');
    this.installation(token);
    const sessionToken = `${device.id}.${randomToken()}`;
    const expiresAt = this.now() + 15 * 60000;
    try {
      await this.db.send(new TransactWriteCommand({ TransactItems: [
        { Update: { TableName: this.table, Key: authKey,
          UpdateExpression: 'SET sessionHash=:hash, appSessionId=:app, sessionExpiresAt=:sessionExpiry REMOVE challengeId, challengeNonce, challengeExpiresAt, expiresAt',
          ConditionExpression: 'challengeId=:id AND challengeNonce=:nonce AND challengeExpiresAt>:now',
          ExpressionAttributeValues: { ':hash': hash(sessionToken), ':app': appSessionId,
            ':sessionExpiry': expiresAt, ':id': challengeId,
            ':nonce': challenge.challengeNonce, ':now': this.now() } } },
        { Update: { TableName: this.table, Key: key(device.id, 'STATE'),
          UpdateExpression: 'SET appSessionId=:app, lastSeenAt=:zero REMOVE #snapshot',
          ExpressionAttributeNames: { '#snapshot': 'snapshot' },
          ExpressionAttributeValues: { ':app': appSessionId, ':zero': 0 } } },
      ] }));
    } catch (error) {
      if (failedCondition(error)) throw new ApiError(401, 'UNAUTHORIZED');
      throw error;
    }
    return { sessionToken, expiresIn: 900, deviceId: device.id };
  }
  async device(token) {
    const deviceId = token.split('.', 1)[0];
    const device = this.config.devices.find(d => d.id === deviceId);
    requireThat(device?.enabled);
    const record = (await this.db.send(new GetCommand({ TableName: this.table, Key: key(deviceId, 'AUTH'), ConsistentRead: true }))).Item;
    const digest = Buffer.from(hash(token), 'hex');
    const expected = Buffer.from(record?.sessionHash || '', 'hex');
    requireThat(expected.length === digest.length && timingSafeEqual(digest, expected) && record.sessionExpiresAt > this.now());
    return { deviceId, appSessionId: record.appSessionId, expiresAt: record.sessionExpiresAt, secretHash: device.secretHash };
  }
}

export class DynamoRelay {
  constructor(devices, db, table, now = Date.now) {
    this.devices = new Map(devices.map(d => [d.id, d]));
    this.db = db; this.table = table; this.now = now;
  }
  get(id) {
    const device = this.devices.get(id);
    requireThat(device?.enabled, 404, 'DEVICE_NOT_FOUND');
    return device;
  }
  async state(id) {
    return (await this.db.send(new GetCommand({ TableName: this.table, Key: key(id, 'STATE'), ConsistentRead: true }))).Item;
  }
  async rename(id, label) {
    this.get(id);
    // STATE has no TTL. Targeted updates from Roku sync/session renewal preserve the name.
    await this.db.send(new UpdateCommand({ TableName: this.table, Key: key(id, 'STATE'),
      UpdateExpression: 'SET #label=:label',
      ExpressionAttributeNames: { '#label': 'label' },
      ExpressionAttributeValues: { ':label': label } }));
    return { id, label };
  }
  async items(id, prefix) {
    const response = await this.db.send(new QueryCommand({ TableName: this.table,
      KeyConditionExpression: 'PK=:pk AND begins_with(SK,:prefix)',
      ExpressionAttributeValues: { ':pk': pk(id), ':prefix': prefix }, ConsistentRead: true, Limit: 100 }));
    return response.Items || [];
  }
  async expire(id, commands) {
    for (const command of commands.filter(c => c.expiresAt <= seconds(this.now()))) {
      try {
        await this.db.send(new TransactWriteCommand({ TransactItems: [
          { Delete: { TableName: this.table, Key: key(id, command.SK),
            ConditionExpression: 'commandId=:id AND expiresAt<=:now',
            ExpressionAttributeValues: { ':id': command.commandId, ':now': seconds(this.now()) } } },
          { Put: { TableName: this.table, Item: {
            ...key(id, `RESULT#${command.requestId}`), commandId: command.commandId,
            requestId: command.requestId, type: command.type, status: 'expired',
            appSessionId: command.appSessionId, expiresAt: seconds(this.now() + 120000),
          }, ConditionExpression: 'attribute_not_exists(PK) OR commandId=:id',
          ExpressionAttributeValues: { ':id': command.commandId } } },
        ] }));
      } catch (error) {
        if (!failedCondition(error)) throw error;
      }
    }
  }
  async view() {
    const devices = await Promise.all([...this.devices.values()].filter(d => d.enabled).map(async d => {
      const state = await this.state(d.id);
      const commands = await this.items(d.id, 'COMMAND#');
      await this.expire(d.id, commands);
      const results = (await this.items(d.id, 'RESULT#'))
        .filter(r => r.expiresAt > seconds(this.now()) && r.appSessionId === state?.appSessionId)
        .map(({ PK, SK, expiresAt, appSessionId, ...publicResult }) => publicResult);
      return { id: d.id, label: state?.label ?? d.label,
        online: Boolean(state?.lastSeenAt && this.now() - state.lastSeenAt < 15000),
        lastSeen: state?.lastSeenAt || null, snapshot: state?.snapshot || null, results };
    }));
    return { cursor: String(this.now()), devices };
  }
  async events() { return this.view(); }
  async enqueue(id, payload, type) {
    this.get(id);
    const prior = (await this.db.send(new GetCommand({ TableName: this.table,
      Key: key(id, `RESULT#${payload.requestId}`), ConsistentRead: true }))).Item;
    if (prior && prior.expiresAt > seconds(this.now()))
      return { commandId: prior.commandId, requestId: prior.requestId };
    const state = await this.state(id);
    requireThat(state?.lastSeenAt && this.now() - state.lastSeenAt < 30000, 409, 'DEVICE_OFFLINE');
    if (type === 'changeChannel') {
      requireThat(state.snapshot && payload.sourceRevision === state.snapshot.sourceRevision &&
        payload.catalogRevision === state.snapshot.catalogRevision, 409, 'STALE_CATALOG');
      requireThat(payload.expectedPlaybackRevision === state.snapshot.playbackRevision, 409, 'STALE_PLAYBACK');
    }
    const commands = await this.items(id, 'COMMAND#');
    await this.expire(id, commands);
    const active = commands.filter(c => c.expiresAt > seconds(this.now()));
    const duplicate = active.find(c => c.requestId === payload.requestId);
    if (duplicate) return { commandId: duplicate.commandId, requestId: duplicate.requestId };
    requireThat(active.length < 12, 429, 'DEVICE_BUSY');
    if (type === 'providerConfig') requireThat(!active.some(c => c.type === type), 409, 'DEVICE_BUSY');
    const commandId = randomUUID();
    const item = { ...key(id, `COMMAND#${payload.requestId}`), commandId, requestId: payload.requestId,
      type, payload, status: 'pending', createdAt: this.now(), appSessionId: state.appSessionId,
      expiresAt: seconds(this.now() + (type === 'changeChannel' ? 30000 : 60000)) };
    try {
      await this.db.send(new PutCommand({ TableName: this.table, Item: item,
        ConditionExpression: 'attribute_not_exists(PK)' }));
    } catch (error) {
      if (!failedCondition(error)) throw error;
      const previous = (await this.db.send(new GetCommand({ TableName: this.table,
        Key: key(id, item.SK), ConsistentRead: true }))).Item;
      requireThat(previous, 409, 'COMMAND_EXPIRED');
      return { commandId: previous.commandId, requestId: previous.requestId };
    }
    return { commandId, requestId: payload.requestId };
  }
  async result(id, session, result) {
    const commands = await this.items(id, 'COMMAND#');
    const command = commands.find(c => c.commandId === result.commandId && c.appSessionId === session.appSessionId);
    if (!command) {
      const previous = (await this.items(id, 'RESULT#')).find(r => r.commandId === result.commandId);
      requireThat(previous, 409, 'COMMAND_EXPIRED');
      return;
    }
    requireThat(command.expiresAt > seconds(this.now()), 409, 'COMMAND_EXPIRED');
    requireThat(command.type === 'catalog' || !result.data, 400, 'INVALID_RESULT');
    const outcome = { ...key(id, `RESULT#${command.requestId}`), ...result,
      requestId: command.requestId, type: command.type, appSessionId: session.appSessionId,
      expiresAt: seconds(this.now() + 120000) };
    requireThat(Buffer.byteLength(JSON.stringify(outcome)) < 300000, 400, 'RESULT_TOO_LARGE');
    const interim = result.status === 'received' || result.status === 'tuning';
    try {
      await this.db.send(new TransactWriteCommand({ TransactItems: [
        interim ? { Update: { TableName: this.table, Key: key(id, command.SK),
          UpdateExpression: 'SET #status=:status REMOVE payload',
          ConditionExpression: 'commandId=:id AND appSessionId=:app',
          ExpressionAttributeNames: { '#status': 'status' },
          ExpressionAttributeValues: { ':status': result.status, ':id': command.commandId,
            ':app': session.appSessionId } } }
          : { Delete: { TableName: this.table, Key: key(id, command.SK),
            ConditionExpression: 'commandId=:id AND appSessionId=:app',
            ExpressionAttributeValues: { ':id': command.commandId, ':app': session.appSessionId } } },
        { Put: { TableName: this.table, Item: outcome,
          ConditionExpression: 'attribute_not_exists(PK) OR commandId=:id',
          ExpressionAttributeValues: { ':id': command.commandId } } },
      ] }));
    } catch (error) {
      if (!failedCondition(error)) throw error;
      const previous = (await this.db.send(new GetCommand({ TableName: this.table,
        Key: key(id, `RESULT#${command.requestId}`), ConsistentRead: true }))).Item;
      requireThat(previous?.commandId === command.commandId, 409, 'COMMAND_EXPIRED');
    }
  }
  async sync(id, session, { snapshot, results }) {
    this.get(id);
    requireThat(snapshot.appSessionId === session.appSessionId, 403, 'WRONG_SESSION');
    try {
      await this.db.send(new UpdateCommand({ TableName: this.table, Key: key(id, 'STATE'),
        UpdateExpression: 'SET #snapshot=:snapshot, lastSeenAt=:seen',
        ConditionExpression: 'appSessionId=:app',
        ExpressionAttributeNames: { '#snapshot': 'snapshot' },
        ExpressionAttributeValues: { ':snapshot': snapshot, ':seen': this.now(), ':app': session.appSessionId } }));
    } catch (error) {
      if (failedCondition(error)) throw new ApiError(409, 'SESSION_REPLACED');
      throw error;
    }
    for (const result of results) await this.result(id, session, result);
    const commands = await this.items(id, 'COMMAND#');
    await this.expire(id, commands);
    const pending = commands.filter(c => (c.status === 'pending' || c.status === 'delivered') && c.payload &&
      c.appSessionId === session.appSessionId && c.expiresAt > seconds(this.now()))
      .sort((a, b) => a.createdAt - b.createdAt)[0];
    if (!pending) return { command: null };
    try {
      await this.db.send(new UpdateCommand({ TableName: this.table, Key: key(id, pending.SK),
        UpdateExpression: 'SET #status=:delivered',
        ConditionExpression: '(#status=:pending OR #status=:delivered) AND commandId=:id AND expiresAt>:now',
        ExpressionAttributeNames: { '#status': 'status' },
        ExpressionAttributeValues: { ':delivered': 'delivered', ':pending': 'pending',
          ':id': pending.commandId, ':now': seconds(this.now()) } }));
    } catch (error) {
      if (failedCondition(error)) return { command: null };
      throw error;
    }
    return { command: { commandId: pending.commandId, type: pending.type,
      expiresAt: pending.expiresAt * 1000, appSessionId: pending.appSessionId, ...pending.payload } };
  }
}
