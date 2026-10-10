import { z } from 'zod';

const text = z.string().max(200);
const id = z.string().min(1).max(160);
const revision = z.number().int().nonnegative();
const metric = z.number().finite().nonnegative().nullable();
export const deviceSettings = z.object({
  label: z.string().trim().min(1).max(80).regex(/^[^\u0000-\u001f\u007f]+$/),
}).strict();
export const source = {
  sourceRevision: id,
  catalogRevision: id,
};
export const tune = z.object({
  type: z.literal('changeChannel'), requestId: id, ...source,
  streamId: id, expectedPlaybackRevision: revision,
}).strict();
export const catalog = z.object({
  requestId: id, kind: z.enum(['categories', 'channels', 'search']),
  categoryId: text.default(''), query: z.string().max(100).default(''),
  offset: z.number().int().min(0).max(100000).default(0),
  limit: z.number().int().min(1).max(100).default(100),
}).strict();
export const provider = z.object({
  requestId: id, providerType: z.enum(['xtream', 'm3u']),
  server: z.url().max(4096), username: z.string().max(300).default(''),
  password: z.string().max(1000).default(''),
}).strict().refine(v => /^https?:\/\//.test(v.server), 'HTTP(S) required')
  .refine(v => v.providerType !== 'xtream' || (v.username && v.password), 'Credentials required');
// Privacy boundary: unknown fields are stripped; never forward raw Video diagnostics.
export const snapshot = z.object({
  appSessionId: id, ...source, playbackRevision: revision,
  state: z.enum(['idle', 'tuning', 'playing', 'buffering', 'paused', 'error', 'stopped']),
  channel: z.object({ streamId: text, name: text, group: text }).nullable(),
  metrics: z.object({
    sessionBytes: metric, tuneBytes: metric, bytesPerSecond: metric,
    bitrate: metric, width: metric, height: metric, startupMs: metric,
    bufferingCount: metric, bufferingMs: metric,
  }),
  appVersion: text, osVersion: text,
  provider: z.object({ type: z.enum(['xtream', 'm3u', 'none']), configured: z.boolean() }),
});
export const result = z.object({
  commandId: id,
  status: z.enum(['received', 'tuning', 'playing', 'saved', 'ok', 'failed', 'stale']),
  code: z.enum(['NONE', 'UNAVAILABLE', 'STALE', 'INVALID_CHANNEL', 'PROVIDER_ERROR', 'SAVE_FAILED', 'PLAYBACK_ERROR']).default('NONE'),
  data: z.object({
    ...source,
    categories: z.array(z.object({ id: text, name: text })).max(2000).optional(),
    channels: z.array(z.object({ streamId: id, name: text, group: text })).max(100).optional(),
    offset: revision.optional(), total: revision.optional(), incomplete: z.boolean().optional(),
  }).optional(),
});

export const serverConfig = z.object({
  region: z.literal('us-east-2'),
  origins: z.array(z.url()).min(1),
  userPoolId: z.string().startsWith('us-east-2_'), clientId: id,
  adminSub: id,
  attestationCertificates: z.array(z.string().includes('BEGIN CERTIFICATE')).min(1),
  devices: z.array(z.object({
    id: z.string().regex(/^[a-z0-9-]{1,60}$/), label: text,
    secretHash: z.string().regex(/^[a-f0-9]{64}$/), enabled: z.boolean(),
    developerId: id, channelId: id.default('dev'),
  }).strict()).max(10),
}).strict().refine(v => new Set(v.devices.map(d => d.id)).size === v.devices.length, 'Duplicate devices');
