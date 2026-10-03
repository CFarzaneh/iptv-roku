import { randomUUID } from 'node:crypto';
import { ApiError, requireThat } from './auth.mjs';

export class Relay {
  constructor(devices, now = Date.now) {
    this.now = now; this.version = 0; this.boot = randomUUID(); this.listeners = new Set();
    this.devices = new Map(devices.map(d => [d.id, { id: d.id, label: d.label, enabled: d.enabled,
      snapshot: null, lastSeen: 0, commands: [], results: [], waiter: null }]));
  }
  changed() { this.version++; for (const wake of [...this.listeners]) wake(); }
  get(id) { const d = this.devices.get(id); requireThat(d?.enabled, 404, 'DEVICE_NOT_FOUND'); return d; }
  prune(d) {
    for (const c of d.commands) {
      if (c.expiresAt <= this.now()) {
        delete c.payload;
        d.results.push({ commandId: c.commandId, requestId: c.requestId, type: c.type, status: 'expired' });
      }
    }
    d.commands = d.commands.filter(c => c.expiresAt > this.now());
    d.results = d.results.slice(-40);
  }
  view() {
    return { cursor: `${this.boot}:${this.version}`, devices: [...this.devices.values()].filter(d => d.enabled).map(d => {
      this.prune(d);
      return { id: d.id, label: d.label, online: d.lastSeen > 0 && this.now() - d.lastSeen < 60000,
        lastSeen: d.lastSeen || null, snapshot: d.snapshot, results: d.results };
    }) };
  }
  async events(cursor, signal) {
    if (cursor === `${this.boot}:${this.version}`) await this.wait(this.listeners, signal, 25000);
    return this.view();
  }
  wait(listeners, signal, duration) {
    return new Promise(resolve => {
      const done = () => { clearTimeout(timer); listeners.delete(done); signal?.removeEventListener('abort', done); resolve(); };
      const timer = setTimeout(done, Math.max(1, duration)); timer.unref?.();
      listeners.add(done); signal?.addEventListener('abort', done, { once: true });
      if (signal?.aborted) done();
    });
  }
  enqueue(id, payload, type) {
    const d = this.get(id); this.prune(d);
    requireThat(d.lastSeen > 0 && this.now() - d.lastSeen < 60000, 409, 'DEVICE_OFFLINE');
    const duplicate = [...d.commands, ...d.results].find(c => c.requestId === payload.requestId);
    if (duplicate) return { commandId: duplicate.commandId, requestId: duplicate.requestId };
    requireThat(d.commands.length < 12, 429, 'DEVICE_BUSY');
    if (type === 'changeChannel') {
      requireThat(d.snapshot && payload.sourceRevision === d.snapshot.sourceRevision && payload.catalogRevision === d.snapshot.catalogRevision, 409, 'STALE_CATALOG');
      requireThat(payload.expectedPlaybackRevision === d.snapshot.playbackRevision, 409, 'STALE_PLAYBACK');
    }
    if (type === 'providerConfig') requireThat(!d.commands.some(c => c.type === type), 409, 'DEVICE_BUSY');
    const commandId = randomUUID();
    d.commands.push({ commandId, requestId: payload.requestId, type, payload,
      appSessionId: d.snapshot.appSessionId, expiresAt: this.now() + (type === 'changeChannel' ? 30000 : 60000) });
    d.waiter?.wake(); this.changed();
    return { commandId, requestId: payload.requestId };
  }
  async poll(id, session, signal, valid) {
    const d = this.get(id);
    requireThat(d.snapshot?.appSessionId === session.appSessionId, 409, 'SNAPSHOT_REQUIRED');
    requireThat(!d.waiter, 409, 'POLL_ALREADY_OPEN');
    d.lastSeen = this.now(); this.prune(d);
    const pending = () => d.commands.find(c => c.payload && !c.delivered && c.appSessionId === session.appSessionId);
    if (!pending()) {
      const listeners = new Set();
      d.waiter = { wake: () => { for (const f of listeners) f(); } };
      try { await this.wait(listeners, signal, Math.min(25000, session.expiresAt - this.now())); }
      finally { d.waiter = null; }
    }
    valid(); this.prune(d);
    requireThat(d.snapshot?.appSessionId === session.appSessionId, 409, 'SESSION_REPLACED');
    const c = pending();
    if (!c || signal?.aborted) return { commands: [] };
    c.delivered = true;
    // The device deduplicates commands. Lost delivery is shown as expired, never silently replayed.
    return { commands: [{ commandId: c.commandId, type: c.type, expiresAt: c.expiresAt,
      appSessionId: c.appSessionId, ...c.payload }] };
  }
  report(id, session, snapshot) {
    const d = this.get(id);
    requireThat(snapshot.appSessionId === session.appSessionId, 403, 'WRONG_SESSION');
    if (d.snapshot?.appSessionId !== snapshot.appSessionId) {
      d.commands = []; d.results = []; d.waiter?.wake();
    }
    d.snapshot = snapshot; d.lastSeen = this.now(); this.changed();
  }
  result(id, session, result) {
    const d = this.get(id); this.prune(d);
    const c = d.commands.find(c => c.commandId === result.commandId && c.appSessionId === session.appSessionId);
    requireThat(c, 409, 'COMMAND_EXPIRED');
    requireThat(c.type === 'catalog' || !result.data, 400, 'INVALID_RESULT');
    if (result.status === 'received') { delete c.payload; return; }
    if (result.status === 'tuning') {
      delete c.payload;
    } else {
      d.commands = d.commands.filter(x => x !== c);
    }
    d.results = d.results.filter(x => x.commandId !== c.commandId);
    d.results.push({ ...result, requestId: c.requestId, type: c.type });
    d.results = d.results.slice(-40); d.lastSeen = this.now(); this.changed();
  }
  close() {
    for (const wake of [...this.listeners]) wake();
    for (const d of this.devices.values()) { d.waiter?.wake(); d.commands = []; }
  }
}
