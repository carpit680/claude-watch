// Claude Watch relay: connects watches to the Macs they are paired with, without either side
// needing a public address, and sends their Apple push notifications.
//
// - Each Mac's bridge keeps a WebSocket open to its own Durable Object (MacHub).
// - A watch pairs with a 6-digit code shown on the Mac, then calls /v1/watch/rpc. Those calls
//   carry only boxes encrypted end to end between watch and Mac; the relay cannot read them.
// - The relay holds the Apple push key (secrets APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC),
//   so people using the published app don't need their own. Alert text passes through it.

import { DurableObject } from 'cloudflare:workers';

const MAC_ID = /^[0-9a-f]{32}$/;
const CODE_TTL_MS = 10 * 60 * 1000;
const RPC_TIMEOUT_MS = 25 * 1000;
const MAX_BODY = 64 * 1024;

// ---------- helpers ----------

const enc = new TextEncoder();

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
}

function fail(status, error) {
  return json({ error }, status);
}

function randomBytes(n) {
  return crypto.getRandomValues(new Uint8Array(n));
}

function hex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sha256(text) {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(text))));
}

// Compares two hex digests without leaking where they differ.
function sameDigest(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function bearer(req) {
  return (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
}

async function body(req) {
  const text = await req.text();
  if (text.length > MAX_BODY) throw new Error('Body too large');
  return text ? JSON.parse(text) : {};
}

const isPublicKey = (pk) => typeof pk === 'string' && /^[A-Za-z0-9_-]{43}$/.test(pk); // 32 bytes, base64url

// ---------- entry point ----------

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname;
    try {
      if (path === '/' || path === '/v1') return json({ service: 'claude-watch-relay', version: 1 });

      // A Mac signs up: it gets an id and a secret, and nothing else is stored about it.
      if (path === '/v1/macs' && req.method === 'POST') {
        const macId = hex(randomBytes(16));
        const macSecret = b64url(randomBytes(32));
        const res = await hub(env, macId).fetch('https://hub/init', { method: 'POST', body: JSON.stringify({ secretHash: await sha256(macSecret) }) });
        if (!res.ok) return res;
        return json({ macId, macSecret });
      }

      // Everything a Mac does, and its WebSocket.
      const mac = path.match(/^\/v1\/macs\/([0-9a-f]+)(\/.*)$/);
      if (mac) {
        if (!MAC_ID.test(mac[1])) return fail(404, 'Unknown Mac');
        const inner = new URL(`https://hub/mac${mac[2]}${url.search}`);
        inner.searchParams.set('mac', mac[1]);
        return hub(env, mac[1]).fetch(new Request(inner, req));
      }

      // A watch joins with the code shown on the Mac.
      if (path === '/v1/join' && req.method === 'POST') {
        const { code, pk, name } = await body(req);
        if (!/^\d{6}$/.test(String(code || '')) || !isPublicKey(pk)) return fail(400, 'Enter the 6-digit code shown on your Mac');
        const ip = req.headers.get('cf-connecting-ip') || '';
        const claim = await codes(env).fetch('https://codes/claim', { method: 'POST', body: JSON.stringify({ code: String(code), ip }) });
        if (!claim.ok) return claim;
        const { macId } = await claim.json();
        return hub(env, macId).fetch('https://hub/join', { method: 'POST', body: JSON.stringify({ macId, code: String(code), pk, name: String(name || 'Apple Watch').slice(0, 60) }) });
      }

      // Everything a paired watch does. Its id starts with its Mac's id.
      if (path.startsWith('/v1/watch')) {
        const macId = bearer(req).split('.')[0];
        if (!MAC_ID.test(macId)) return fail(401, 'Not paired');
        return hub(env, macId).fetch(new Request(`https://hub/watch${path.slice('/v1/watch'.length)}${url.search}`, req));
      }

      return fail(404, 'Not found');
    } catch (err) {
      return fail(400, err.message || 'Bad request');
    }
  },
};

const hub = (env, macId) => env.MACS.get(env.MACS.idFromName(macId));
const codes = (env) => env.CODES.get(env.CODES.idFromName('codes'));

// ---------- pairing codes ----------

// One instance for everyone: which Mac a live 6-digit code belongs to.
export class PairingCodes extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.tries = new Map(); // ip -> { count, since }: slows down anyone guessing codes
  }

  async fetch(req) {
    const { pathname } = new URL(req.url);
    const input = await body(req);
    const now = Date.now();

    if (pathname === '/reserve') {
      // Picks a free code for this Mac.
      for (let attempt = 0; attempt < 20; attempt++) {
        const code = String(new DataView(randomBytes(4).buffer).getUint32(0) % 1_000_000).padStart(6, '0');
        const taken = await this.ctx.storage.get(code);
        if (taken && taken.expires > now) continue;
        await this.ctx.storage.put(code, { macId: input.macId, expires: now + CODE_TTL_MS });
        await this.ctx.storage.setAlarm(now + CODE_TTL_MS + 1000);
        return json({ code });
      }
      return fail(503, 'No free code, try again');
    }

    if (pathname === '/claim') {
      const t = this.tries.get(input.ip) || { count: 0, since: now };
      if (now - t.since > 60 * 1000) { t.count = 0; t.since = now; }
      t.count++;
      this.tries.set(input.ip, t);
      if (t.count > 10) return fail(429, 'Too many tries. Wait a minute.');
      const entry = await this.ctx.storage.get(input.code);
      if (!entry || entry.expires < now) return fail(404, "That code isn't valid. Check your Mac, or make a new one.");
      await this.ctx.storage.delete(input.code); // a code works once
      return json({ macId: entry.macId });
    }

    return fail(404, 'Not found');
  }

  // Forget expired codes.
  async alarm() {
    const now = Date.now();
    const all = await this.ctx.storage.list();
    const stale = [...all].filter(([, v]) => v?.expires < now).map(([k]) => k);
    if (stale.length) await this.ctx.storage.delete(stale);
    if (all.size > stale.length) await this.ctx.storage.setAlarm(now + CODE_TTL_MS);
  }
}

// ---------- one Mac ----------

export class MacHub extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.pending = new Map(); // rpc id -> { resolve, timer }
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;
    try {
      if (path === '/init') {
        if (await this.ctx.storage.get('secretHash')) return fail(409, 'Exists');
        await this.ctx.storage.put('secretHash', (await body(req)).secretHash);
        return json({ ok: true });
      }
      if (path === '/join') return this.join(await body(req));
      if (path.startsWith('/mac/')) return this.forMac(req, path.slice(4));
      if (path.startsWith('/watch')) return this.forWatch(req, path.slice(6) || '/');
      return fail(404, 'Not found');
    } catch (err) {
      return fail(400, err.message || 'Bad request');
    }
  }

  async watches() {
    return (await this.ctx.storage.get('watches')) || {};
  }

  macSocket() {
    return this.ctx.getWebSockets().find((ws) => ws.deserializeAttachment()?.auth);
  }

  // ----- the Mac's side -----

  async forMac(req, path) {
    if (path === '/connect') {
      if (req.headers.get('upgrade') !== 'websocket') return fail(426, 'WebSocket only');
      const [client, server] = Object.values(new WebSocketPair());
      this.ctx.acceptWebSocket(server);
      server.serializeAttachment({ auth: false });
      return new Response(null, { status: 101, webSocket: client });
    }

    const secretHash = await this.ctx.storage.get('secretHash');
    if (!secretHash || !sameDigest(await sha256(bearer(req)), secretHash)) return fail(401, 'Unknown Mac');

    // Start pairing: the Mac's public key and name, and a code to show.
    if (path === '/pairing' && req.method === 'POST') {
      const { pk, name } = await body(req);
      if (!isPublicKey(pk)) return fail(400, 'Bad key');
      const res = await codes(this.env).fetch('https://codes/reserve', { method: 'POST', body: JSON.stringify({ macId: this.macId(req) }) });
      if (!res.ok) return res;
      const { code } = await res.json();
      await this.ctx.storage.put('pairing', { code, pk, name: String(name || 'Mac').slice(0, 60), expires: Date.now() + CODE_TTL_MS });
      return json({ code, expiresIn: CODE_TTL_MS / 1000 });
    }

    // Has a watch used the code yet?
    if (path === '/pairing' && req.method === 'GET') {
      const pairing = await this.ctx.storage.get('pairing');
      if (!pairing || pairing.expires < Date.now()) return json({ state: 'expired' });
      if (!pairing.watchId) return json({ state: 'waiting' });
      return json({ state: 'joined', watchId: pairing.watchId, watchPk: pairing.watchPk, watchName: pairing.watchName });
    }

    // The person compared the check numbers on the Mac: let the watch in, or not.
    if (path === '/pairing/confirm' && req.method === 'POST') {
      const { watchId, accept } = await body(req);
      const pairing = await this.ctx.storage.get('pairing');
      const watches = await this.watches();
      if (!pairing || pairing.watchId !== watchId || !watches[watchId]) return fail(404, 'No such pairing');
      if (accept) watches[watchId].confirmed = true;
      else delete watches[watchId];
      await this.ctx.storage.put('watches', watches);
      await this.ctx.storage.delete('pairing');
      return json({ ok: true });
    }

    if (path === '/watches' && req.method === 'GET') {
      const watches = await this.watches();
      return json({ watches: Object.entries(watches).map(([id, w]) => ({ id, name: w.name, confirmed: w.confirmed, pairedAt: w.pairedAt })) });
    }

    const remove = path.match(/^\/watches\/([^/]+)$/);
    if (remove && req.method === 'DELETE') {
      const watches = await this.watches();
      delete watches[decodeURIComponent(remove[1])];
      await this.ctx.storage.put('watches', watches);
      return json({ ok: true });
    }

    return fail(404, 'Not found');
  }

  macId(req) {
    return new URL(req.url).searchParams.get('mac') || '';
  }

  // A watch used this Mac's code: give it credentials, pending the Mac's confirmation.
  async join({ macId, code, pk, name }) {
    const pairing = await this.ctx.storage.get('pairing');
    if (!pairing || pairing.code !== code || pairing.expires < Date.now() || pairing.watchId) {
      return fail(404, "That code isn't valid. Check your Mac, or make a new one.");
    }
    const watchId = `${macId}.${hex(randomBytes(8))}`;
    const watchSecret = b64url(randomBytes(32));
    const watches = await this.watches();
    watches[watchId] = { secretHash: await sha256(watchSecret), pk, name, confirmed: false, pairedAt: Date.now(), devices: [] };
    await this.ctx.storage.put('watches', watches);
    await this.ctx.storage.put('pairing', { ...pairing, watchId, watchPk: pk, watchName: name });
    return json({ watchId, watchSecret, macPk: pairing.pk, macName: pairing.name });
  }

  webSocketMessage(ws, raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    const state = ws.deserializeAttachment() || {};

    if (msg.type === 'hello') {
      return this.hello(ws, msg.secret);
    }
    if (!state.auth) return;

    if (msg.type === 'rpc-reply' && this.pending.has(msg.id)) {
      const p = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      p.resolve(msg);
    } else if (msg.type === 'push') {
      return this.push(msg).catch(() => {});
    }
  }

  async hello(ws, secret) {
    const secretHash = await this.ctx.storage.get('secretHash');
    if (!secretHash || !sameDigest(await sha256(String(secret || '')), secretHash)) {
      ws.close(4001, 'Unknown Mac');
      return;
    }
    // One connection per Mac: a newer one replaces an older one.
    for (const other of this.ctx.getWebSockets()) {
      if (other !== ws && other.deserializeAttachment()?.auth) other.close(4000, 'Replaced');
    }
    ws.serializeAttachment({ auth: true });
    ws.send(JSON.stringify({ type: 'ready' }));
  }

  webSocketClose(ws) {
    try { ws.close(); } catch {}
  }

  // ----- the watch's side -----

  async forWatch(req, path) {
    const [watchId, secret] = bearer(req).split(':');
    const watches = await this.watches();
    const watch = watches[watchId];
    if (!watch || !sameDigest(await sha256(String(secret || '')), watch.secretHash)) return fail(401, 'Not paired');

    if (path === '/status') {
      return json({ confirmed: Boolean(watch.confirmed), online: Boolean(this.macSocket()) });
    }
    if (!watch.confirmed) return fail(403, 'Confirm the pairing on your Mac first');

    // An encrypted request for the Mac, and its encrypted answer.
    if (path === '/rpc' && req.method === 'POST') {
      const { box } = await body(req);
      if (typeof box !== 'string') return fail(400, 'Missing box');
      const ws = this.macSocket();
      if (!ws) return fail(503, 'mac-offline');
      const id = hex(randomBytes(8));
      const reply = await new Promise((resolve) => {
        const timer = setTimeout(() => { this.pending.delete(id); resolve(null); }, RPC_TIMEOUT_MS);
        this.pending.set(id, { resolve, timer });
        ws.send(JSON.stringify({ type: 'rpc', id, watchId, box }));
      });
      if (!reply) return fail(504, 'mac-timeout');
      return json({ box: reply.box });
    }

    // Where to send this watch's notifications: "app" for alerts, "widgets" for the watch face.
    if (path === '/devices' && req.method === 'POST') {
      const { token, kind, sandbox } = await body(req);
      if (!/^[0-9a-f]{32,200}$/.test(String(token || ''))) return fail(400, 'Bad device token');
      const k = kind === 'widgets' ? 'widgets' : 'app';
      watch.devices = [...(watch.devices || []).filter((d) => d.token !== token && d.kind !== k), { token, kind: k, sandbox: Boolean(sandbox) }];
      await this.ctx.storage.put('watches', watches);
      return json({ ok: true, push: Boolean(this.env.APNS_KEY) });
    }

    // Unpair from the watch.
    if (path === '/' && req.method === 'DELETE') {
      delete watches[watchId];
      await this.ctx.storage.put('watches', watches);
      return json({ ok: true });
    }

    return fail(404, 'Not found');
  }

  // ----- Apple push -----

  async push({ kind, payload, collapseId }) {
    const env = this.env;
    if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) return;
    const pushKind = kind === 'widgets' ? 'widgets' : 'alert';
    const deviceKind = pushKind === 'widgets' ? 'widgets' : 'app';
    const watches = await this.watches();
    let changed = false;
    for (const watch of Object.values(watches)) {
      if (!watch.confirmed) continue;
      for (const device of [...(watch.devices || [])]) {
        if (device.kind !== deviceKind) continue;
        const res = await fetch(`https://${device.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com'}/3/device/${device.token}`, {
          method: 'POST',
          headers: {
            authorization: `bearer ${await this.apnsToken()}`,
            'apns-topic': pushKind === 'widgets' ? `${env.APNS_TOPIC}.push-type.widgets` : env.APNS_TOPIC,
            'apns-push-type': pushKind,
            'apns-priority': pushKind === 'widgets' ? '5' : '10',
            ...(collapseId ? { 'apns-collapse-id': String(collapseId).slice(0, 64) } : {}),
          },
          body: JSON.stringify(payload),
        });
        const reason = res.ok ? '' : await res.text();
        console.log(`push ${pushKind} -> ${device.token.slice(0, 8)}: ${res.status} ${reason}`);
        if (res.status === 410 || reason.includes('BadDeviceToken')) {
          watch.devices = watch.devices.filter((d) => d.token !== device.token);
          changed = true;
        }
      }
    }
    if (changed) await this.ctx.storage.put('watches', watches);
  }

  // Apple accepts a signed provider token for up to an hour.
  async apnsToken() {
    const now = Math.floor(Date.now() / 1000);
    if (this.jwt && now - this.jwt.iat < 40 * 60) return this.jwt.token;
    const der = Uint8Array.from(atob(this.env.APNS_KEY.replace(/-----[^-]+-----|\s+/g, '')), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const part = (o) => b64url(enc.encode(JSON.stringify(o)));
    const head = `${part({ alg: 'ES256', kid: this.env.APNS_KEY_ID })}.${part({ iss: this.env.APNS_TEAM_ID, iat: now })}`;
    const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(head)));
    this.jwt = { iat: now, token: `${head}.${b64url(sig)}` };
    return this.jwt.token;
  }
}
