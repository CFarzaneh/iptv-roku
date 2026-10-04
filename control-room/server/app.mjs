import Fastify from 'fastify';
import cors from '@fastify/cors';
import { z } from 'zod';
import { Auth, ApiError, bearer, requireThat } from './auth.mjs';
import { Relay } from './state.mjs';
import * as schema from './schema.mjs';

export function createApp(config, verifiers, options = {}) {
  const app = Fastify({ logger: false, bodyLimit: 256 * 1024, requestTimeout: 40000, trustProxy: false });
  const now = options.now || Date.now;
  const auth = options.auth || new Auth(config, verifiers, now);
  const relay = options.relay || new Relay(config.devices, now);
  app.decorate('authState', auth); app.decorate('relay', relay);
  app.register(cors, { origin: config.origins, methods: ['GET', 'POST'], allowedHeaders: ['Authorization', 'Content-Type'] });
  app.addHook('onSend', async (_request, reply) => {
    reply.header('Cache-Control', 'no-store');
    reply.header('X-Content-Type-Options', 'nosniff');
  });
  // Global bounded buckets work even behind the managed endpoint without trusting spoofed XFF.
  const buckets = new Map();
  function rate(key, maximum) {
    const window = Math.floor(now() / 60000);
    let b = buckets.get(key);
    if (!b || b.window !== window) { b = { window, count: 0 }; buckets.set(key, b); }
    requireThat(++b.count <= maximum, 429, 'RATE_LIMITED');
  }
  const admin = async request => {
    rate('admin', 300);
    try { await verifiers.admin(bearer(request)); }
    catch (e) { if (e instanceof ApiError) throw e; throw new ApiError(401, 'UNAUTHORIZED'); }
  };
  const device = async request => {
    const token = bearer(request), session = await auth.device(token);
    rate(`device:${session.deviceId}`, 300);
    return { token, session };
  };
  const signalFor = (request, reply) => {
    const controller = new AbortController();
    reply.raw.once('close', () => controller.abort());
    request.raw.once('aborted', () => controller.abort());
    return controller.signal;
  };
  app.setErrorHandler((error, _request, reply) => {
    // Validation/auth errors and provider bodies must never be serialized into logs or replies.
    const status = error instanceof z.ZodError ? 400 : (error.statusCode || 500);
    reply.code(status).send({ error: error instanceof ApiError ? error.code : status < 500 ? 'INVALID_REQUEST' : 'SERVER_ERROR' });
  });
  app.get('/health', async () => ({ ok: true, region: 'us-east-2' }));
  app.get('/devices', { preHandler: admin }, async () => relay.view());
  app.get('/events', { preHandler: admin }, async (request, reply) => {
    const cursor = z.string().max(100).optional().parse(request.query.cursor);
    const view = await relay.events(cursor, signalFor(request, reply));
    await admin(request);
    return view;
  });
  app.post('/devices/:id/commands', { preHandler: admin }, async (request, reply) =>
    reply.code(202).send(await relay.enqueue(request.params.id, schema.tune.parse(request.body), 'changeChannel')));
  app.post('/devices/:id/catalog-requests', { preHandler: admin }, async (request, reply) =>
    reply.code(202).send(await relay.enqueue(request.params.id, schema.catalog.parse(request.body), 'catalog')));
  app.post('/devices/:id/provider-config', { preHandler: admin }, async (request, reply) =>
    reply.code(202).send(await relay.enqueue(request.params.id, schema.provider.parse(request.body), 'providerConfig')));
  app.post('/device/auth/challenge', async request => {
    rate('authentication', 60);
    return await auth.challenge(bearer(request));
  });
  app.post('/device/auth/session', async request => {
    rate('authentication', 60);
    const body = z.object({ challengeId: z.string().max(100), attestation: z.string().max(16384), appSessionId: z.string().min(1).max(160) }).strict().parse(request.body);
    return await auth.session(bearer(request), body);
  });
  app.post('/device/sync', async request => {
    const { session } = await device(request);
    const body = z.object({ snapshot: schema.snapshot,
      results: z.array(schema.result).max(24).default([]) }).strict().parse(request.body);
    requireThat(typeof relay.sync === 'function', 410, 'SYNC_UNAVAILABLE');
    return await relay.sync(session.deviceId, session, body);
  });
  app.get('/device/commands', async (request, reply) => {
    const { token, session } = await device(request);
    requireThat(typeof relay.poll === 'function', 410, 'SYNC_REQUIRED');
    return relay.poll(session.deviceId, session, signalFor(request, reply), () => auth.device(token));
  });
  app.post('/device/reports', async request => {
    const { session } = await device(request);
    requireThat(typeof relay.report === 'function', 410, 'SYNC_REQUIRED');
    await relay.report(session.deviceId, session, schema.snapshot.parse(request.body));
    return { ok: true };
  });
  app.post('/device/results', async request => {
    const { session } = await device(request);
    await relay.result(session.deviceId, session, schema.result.parse(request.body));
    return { ok: true };
  });
  if (typeof relay.prune === 'function') {
    const sweep = setInterval(() => { for (const d of relay.devices.values()) relay.prune(d); }, 5000);
    sweep.unref();
    app.addHook('onClose', async () => { clearInterval(sweep); relay.close(); });
  }
  return app;
}
