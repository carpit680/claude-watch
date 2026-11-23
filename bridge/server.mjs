#!/usr/bin/env node
// Claude Watch bridge: lets an Apple Watch app list this Mac's Claude Code sessions, talk to
// them, see their replies, and get alerts when one needs you. No dependencies beyond Node 18+.
//
//   node bridge/server.mjs                    start the bridge on 127.0.0.1
//   node bridge/server.mjs login              sign the bridge's claude in (once)
//   node bridge/server.mjs configure --team <TEAM_ID> --bundle-prefix <com.you.claudewatch> [--relay <host>]
//                                             signing settings for building the app yourself
//   node bridge/server.mjs push [AuthKey.p8]  store an Apple push key (default: newest in ~/Downloads)
//   node bridge/server.mjs pair [--relay <url>]  pair a watch through the relay (no tunnel needed)
//   node bridge/server.mjs unpair             forget the watches paired through the relay
//   node bridge/server.mjs route "<text>"     show which session a dictated message would go to
//
// Environment:
//   BRIDGE_PORT              port to listen on (default 8787)
//   BRIDGE_PERMISSION_MODE   passed to `claude --permission-mode` for watch messages (e.g. acceptEdits)
//   BRIDGE_NEW_CWD           folder for sessions started from the watch (default ~/.claude-watch/workspace)
//   BRIDGE_LIVE_MODE         "relay" (default) delivers into sessions open on the Mac; "copy" forks them
//   BRIDGE_DONE_MIN_SECONDS  shortest turn at the Mac that gets a "done" alert (default 45)
//   BRIDGE_KEEP_AWAKE        "0" lets the Mac sleep while the bridge runs
//   CLAUDE_BIN               path to the claude binary, if not found automatically

import http from 'node:http';
import http2 from 'node:http2';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HOME = os.homedir();
const CONF_DIR = path.join(HOME, '.claude-watch');
const TOKEN_FILE = path.join(CONF_DIR, 'token');
const PROJECTS = path.join(HOME, '.claude', 'projects');
const LIVE_DIR = process.env.BRIDGE_LIVE_DIR || path.join(HOME, '.claude', 'sessions'); // one file per running claude process
const FORKS_FILE = path.join(CONF_DIR, 'forks.json');
const APNS_FILE = path.join(CONF_DIR, 'apns.json'); // Apple push key details, written by `push`
const APNS_KEY_FILE = path.join(CONF_DIR, 'apns.p8');
const DEVICES_FILE = path.join(CONF_DIR, 'devices.json'); // watches that asked for notifications
const RELAY_FILE = path.join(CONF_DIR, 'relay.json'); // this Mac's relay account and key pair
const PAIRINGS_FILE = path.join(CONF_DIR, 'pairings.json'); // watches paired through the relay
// The relay a new pairing uses, unless `pair --relay <url>` or BRIDGE_RELAY says otherwise.
const DEFAULT_RELAY = process.env.BRIDGE_RELAY || 'https://claude-watch-relay.dataphy.ai';
const RECENT_MS = 24 * 60 * 60 * 1000; // sessions older than this are left out of the watch face counts
const USAGE_TTL_MS = 10 * 60 * 1000;
const WATCH_INTERVAL_MS = 3000; // how often to look for a session that started waiting on the user
const DONE_MIN_MS = Number(process.env.BRIDGE_DONE_MIN_SECONDS || 45) * 1000; // shorter turns at the Mac get no "done" alert
const PORT = Number(process.env.BRIDGE_PORT || 8787);
const PERMISSION_MODE = process.env.BRIDGE_PERMISSION_MODE || '';
const NEW_CWD = process.env.BRIDGE_NEW_CWD || path.join(CONF_DIR, 'workspace');
const JOB_TIMEOUT_MS = 20 * 60 * 1000;
const ACTIVE_WINDOW_MS = 20 * 1000; // transcript touched this recently = busy on the Mac
// How a message to a session that is open on the Mac is handled:
// "relay" delivers it into the live session; "copy" answers from a separate copy.
const LIVE_MODE = process.env.BRIDGE_LIVE_MODE === 'copy' ? 'copy' : 'relay';
const RELAY_ACCEPT_MS = 90 * 1000; // how long to wait for the Mac session to pick a relayed message up
const RELAY_HEAD = "[From your user's Apple Watch, relayed by the watch bridge on this Mac]";
const RELAY_TAIL =
  '[The reply is read on a watch: keep your final message to about 50 words of plain text. ' +
  'If you need a choice, end with a line of the form: Options: first | second]';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const WATCH_PROMPT =
  "This message was dictated on the user's Apple Watch, so it may contain speech-recognition " +
  'errors; interpret it charitably. The user will read your final reply on a tiny watch screen: ' +
  'make your final message at most about 50 words of plain text, with no markdown, lists, tables ' +
  'or code blocks, leading with the outcome. Do the work as fully as usual; only the final message ' +
  'is short. Nobody can approve permission prompts right now, so if something was blocked, say so briefly. ' +
  'You cannot show question cards or buttons. If you need the user to choose, ask in one sentence and end ' +
  'your message with a final line in exactly this form: Options: first | second | third (at most four, ' +
  'each a few words). The watch turns that line into buttons.';

// ---------- token ----------

function loadToken() {
  fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
  if (!fs.existsSync(TOKEN_FILE)) {
    fs.writeFileSync(TOKEN_FILE, crypto.randomBytes(32).toString('base64url'), { mode: 0o600 });
  }
  return fs.readFileSync(TOKEN_FILE, 'utf8').trim();
}

function tokenMatches(header, token) {
  const given = Buffer.from(String(header || '').replace(/^Bearer\s+/i, ''));
  const want = Buffer.from(token);
  return given.length === want.length && crypto.timingSafeEqual(given, want);
}

// ---------- finding claude ----------

function findClaude() {
  if (process.env.CLAUDE_BIN) return process.env.CLAUDE_BIN;
  const root = path.join(HOME, 'Library', 'Application Support', 'Claude', 'claude-code');
  const found = [];
  try {
    for (const ver of fs.readdirSync(root)) {
      for (const build of fs.readdirSync(path.join(root, ver))) {
        const bin = path.join(root, ver, build, 'claude.app', 'Contents', 'MacOS', 'claude');
        if (fs.existsSync(bin)) found.push({ bin, mtime: fs.statSync(bin).mtimeMs });
      }
    }
  } catch {}
  found.sort((a, b) => b.mtime - a.mtime);
  return found[0]?.bin || 'claude';
}

// ---------- reading transcripts ----------

// Entries in [start, size) of a transcript. `end` is just past the last complete line, so a line
// still being written is read next time. `skipFirst` drops a line cut off at `start`.
function readEntries(file, start, size, skipFirst) {
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    const lastNewline = buf.lastIndexOf(0x0a);
    if (lastNewline < 0) return { entries: [], end: start };
    const lines = buf.subarray(0, lastNewline).toString('utf8').split('\n');
    if (skipFirst) lines.shift();
    const entries = [];
    for (const line of lines) {
      if (!line) continue;
      try { entries.push(JSON.parse(line)); } catch {}
    }
    return { entries, end: start + lastNewline + 1 };
  } finally {
    fs.closeSync(fd);
  }
}

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter((b) => b?.type === 'text').map((b) => b.text).join('\n');
}

function clean(text) {
  return text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
}

function clip(text, max) {
  return text.length > max ? text.slice(0, max - 1).trimEnd() + '…' : text;
}

// A trailing "Options: a | b | c" line, which the watch shows as buttons.
const OPTIONS_LINE = /\n?^\s*Options:\s*(.+?)\s*$/im;

function splitOptions(text) {
  const m = text.match(OPTIONS_LINE);
  if (!m || text.slice(m.index + m[0].length).trim()) return { text, options: [] };
  const options = m[1].split('|').map((o) => o.trim()).filter(Boolean).slice(0, 4);
  return options.length >= 2 ? { text: text.slice(0, m.index).trim(), options } : { text, options: [] };
}

// The text of a relayed watch message inside a cross-session envelope, or null.
function relayedText(raw) {
  if (typeof raw !== 'string' || !raw.includes(RELAY_HEAD)) return null;
  const body = raw.replace(/<\/?cross-session-message[^>]*>/g, '');
  const start = body.indexOf(RELAY_HEAD) + RELAY_HEAD.length;
  const end = body.indexOf(RELAY_TAIL);
  return body.slice(start, end < 0 ? undefined : end).trim() || null;
}

// Folds transcript entries into `st` (from an earlier call, or fresh), so new lines can be added
// as they are written instead of re-reading the file.
function parseEntries(entries, st = { title: '', lastPrompt: '', cwd: '', turns: [], choices: null }) {
  let { title, lastPrompt, cwd, choices } = st; // choices: the question waiting on the user, if any
  const turns = st.turns;
  for (const e of entries) {
    if (e.cwd) cwd = e.cwd;
    if (e.type === 'custom-title' && e.customTitle) title = e.customTitle;
    else if (e.type === 'ai-title' && e.aiTitle && !title) title = e.aiTitle;
    else if (e.type === 'last-prompt' && e.lastPrompt) lastPrompt = e.lastPrompt;
    // A watch message relayed into a live session arrives through its queue, not as a typed prompt.
    const relayed = e.type === 'queue-operation' && e.operation === 'enqueue' ? relayedText(e.content)
      : e.type === 'user' && !e.isSidechain ? relayedText(textOf(e.message?.content)) : null;
    if (relayed) {
      choices = null;
      if (turns[turns.length - 1]?.text !== relayed) turns.push({ role: 'user', text: relayed, at: Date.parse(e.timestamp) || 0 });
      continue;
    }
    if (e.isSidechain || e.isMeta || !e.message) continue;
    if (e.type !== 'user' && e.type !== 'assistant') continue;
    const blocks = Array.isArray(e.message.content) ? e.message.content : [];

    if (e.type === 'assistant') {
      for (const b of blocks) {
        if (b?.type !== 'tool_use' || !b.input) continue;
        if (/AskUserQuestion$/.test(b.name) && Array.isArray(b.input.questions) && b.input.questions[0]) {
          const q = b.input.questions[0];
          const options = (q.options || []).map((o) => o?.label).filter(Boolean).slice(0, 4);
          if (options.length) choices = { question: q.question || '', options, toolId: b.id };
        } else if (/wrap_up$/.test(b.name) && b.input.ask) {
          const options = (b.input.actions || []).map((o) => o?.label).filter(Boolean).slice(0, 4);
          if (options.length) choices = { question: b.input.ask, options, toolId: null };
        }
      }
    } else if (choices?.toolId && blocks.some((b) => b?.type === 'tool_result' && b.tool_use_id === choices.toolId)) {
      choices = null; // the question card was answered on the Mac
    }

    let text = clean(textOf(e.message.content));
    if (!text || (e.type === 'user' && text.startsWith('<'))) continue;
    if (e.type === 'user') {
      choices = null;
    } else {
      const split = splitOptions(text);
      if (split.options.length) {
        text = split.text || text;
        choices = { question: '', options: split.options, toolId: null };
      }
    }
    const prev = turns[turns.length - 1];
    // Within one turn Claude writes interim notes between tool calls; keep the last.
    if (e.type === 'assistant' && prev?.role === 'assistant') prev.text = text;
    else turns.push({ role: e.type, text });
  }
  if (turns.length > 20) turns.splice(0, turns.length - 20);
  return { title, lastPrompt, cwd, turns, choices };
}

// file -> { key, summary }. Saved to disk so a restarted bridge answers at once instead of
// re-reading every transcript first.
const CACHE_FILE = path.join(CONF_DIR, 'summaries.json');
const cache = new Map(Object.entries(loadJson(CACHE_FILE, {})));
let cacheDirty = false;

function saveCache() {
  if (!cacheDirty) return;
  cacheDirty = false;
  const keep = {};
  for (const [file, entry] of cache) if (fs.existsSync(file)) keep[file] = entry;
  try { fs.writeFileSync(CACHE_FILE, JSON.stringify(keep), { mode: 0o600 }); } catch {}
}

const parsed = new Map(); // file -> { end, state }: how far a transcript has been read, and what it said

function summarize(file) {
  const st = fs.statSync(file);
  const key = `${st.mtimeMs}:${st.size}`;
  const hit = cache.get(file);
  if (hit?.key === key) return hit.summary;

  let p = parsed.get(file);
  if (p && st.size >= p.end) {
    // Only the lines added since the last look.
    const { entries, end } = readEntries(file, p.end, st.size, false);
    p.state = parseEntries(entries, p.state);
    p.end = end;
  } else {
    // First look: the tail, widened (up to 8 MB) until it holds a reply. Huge transcripts are
    // mostly tool output, and reading further back on every change would stall the bridge.
    for (const bytes of [1 << 20, 8 << 20]) {
      const start = Math.max(0, st.size - bytes);
      const { entries, end } = readEntries(file, start, st.size, start > 0);
      p = { end, state: parseEntries(entries) };
      const hasReply = p.state.turns.some((t) => t.role === 'assistant');
      if (start === 0 || (p.state.cwd && hasReply && p.state.turns.length >= 2)) break;
    }
    parsed.set(file, p);
  }

  const s = p.state;
  const firstUser = s.turns.find((t) => t.role === 'user')?.text || '';
  const lastReply = [...s.turns].reverse().find((t) => t.role === 'assistant')?.text || '';
  const summary = {
    id: path.basename(file, '.jsonl'),
    title: clip(s.title || s.lastPrompt || firstUser || 'Untitled', 60),
    project: s.cwd ? path.basename(s.cwd) : '',
    cwd: s.cwd,
    updatedAt: st.mtimeMs / 1000,
    preview: clip(lastReply.replace(/\s+/g, ' '), 120),
    recent: s.turns.slice(-8),
    turns: s.turns.slice(-6).map((t) => ({ role: t.role, text: clip(t.text, 1500) })),
    choices: s.choices && { question: s.choices.question, options: s.choices.options },
    asking: Boolean(s.choices?.toolId), // a question card is open on the Mac right now
  };
  cache.set(file, { key, summary });
  cacheDirty = true;
  return summary;
}

function sessionFiles() {
  const out = [];
  let dirs = [];
  try { dirs = fs.readdirSync(PROJECTS); } catch {}
  for (const dir of dirs) {
    let names = [];
    try { names = fs.readdirSync(path.join(PROJECTS, dir)); } catch { continue; }
    for (const name of names) {
      if (name.endsWith('.jsonl') && UUID.test(name.slice(0, -6))) out.push(path.join(PROJECTS, dir, name));
    }
  }
  return out;
}

function findSessionFile(id) {
  return sessionFiles().find((f) => path.basename(f, '.jsonl') === id) || null;
}

// ---------- sessions open on the Mac ----------

// Sessions that a running interactive claude process (desktop app or terminal) has open:
// session id -> { pid, socket, busy, statusAt }. A second process must never write into these.
function liveSessions() {
  const live = new Map();
  let names = [];
  try { names = fs.readdirSync(LIVE_DIR); } catch {}
  for (const name of names) {
    if (!name.endsWith('.json')) continue;
    try {
      const info = JSON.parse(fs.readFileSync(path.join(LIVE_DIR, name), 'utf8'));
      if (info.kind !== 'interactive' || !info.sessionId) continue;
      process.kill(Number(info.pid), 0); // throws if that process is gone
      live.set(info.sessionId, {
        pid: Number(info.pid),
        socket: info.messagingSocketPath || null,
        busy: info.status ? info.status !== 'idle' : null,
        statusAt: Number(info.statusUpdatedAt) || 0,
        // Showing a dialog on the Mac, such as a permission prompt: what it is waiting for.
        waiting: info.status === 'waiting' ? String(info.waitingFor || 'your input') : null,
      });
    } catch {}
  }
  return live;
}

// Copies made for the watch: copy id -> { parent, title }.
function loadForks() {
  try { return JSON.parse(fs.readFileSync(FORKS_FILE, 'utf8')); } catch { return {}; }
}

function recordFork(id, parent, title) {
  const forks = loadForks();
  forks[id] = { parent, title, createdAt: Date.now() };
  fs.writeFileSync(FORKS_FILE, JSON.stringify(forks, null, 2), { mode: 0o600 });
}

// ---------- jobs (messages sent from the watch) ----------

const jobs = new Map(); // sessionId -> { state, prompt, startedAt, error, proc }

// A relayed message is finished once the Mac session has answered it in its own conversation.
// (Its busy flag is no use here: the session may stay busy with other work, or finish before we look.)
function settleRelay(job, s) {
  const recent = s?.recent || [];
  const idx = recent.findLastIndex((t) => t.role === 'user' && t.at >= job.startedAt * 1000 - 2000 && t.text === job.prompt);
  if (idx >= 0) {
    job.seen = true;
    if (recent.slice(idx + 1).some((t) => t.role === 'assistant')) {
      job.state = 'done';
      job.finishedAt = Date.now();
      return;
    }
  }
  if (!job.seen && Date.now() - job.sentAt > RELAY_ACCEPT_MS) {
    job.state = 'error';
    job.error = 'The Mac session has not picked the message up. It may be holding messages from other sessions.';
  } else if (Date.now() - job.sentAt > JOB_TIMEOUT_MS) {
    job.state = 'done';
  }
}

// running: working on a watch message. active: mid-turn on the Mac.
// open: open on the Mac but quiet. idle: not open anywhere.
function stateOf(id, s, live) {
  const updatedAt = s?.updatedAt || 0;
  const job = jobs.get(id);
  const info = live.get(id);
  if (job?.state === 'running' && job.sentAt) settleRelay(job, s);
  if (job?.state === 'running') return 'running';
  if (info) {
    if (info.busy !== null) return info.busy ? 'active' : 'open';
    return updatedAt && Date.now() - updatedAt * 1000 < ACTIVE_WINDOW_MS ? 'active' : 'open';
  }
  // Our own finished job touched the transcript; that is not something else being busy.
  if (job?.finishedAt && updatedAt * 1000 <= job.finishedAt + 3000) return 'idle';
  if (updatedAt && Date.now() - updatedAt * 1000 < ACTIVE_WINDOW_MS) return 'active';
  return 'idle';
}

function childEnv() {
  // Don't let a parent Claude session's markers leak into the child.
  const env = { ...process.env };
  for (const k of Object.keys(env)) {
    if (k === 'CLAUDECODE' || k.startsWith('CLAUDE_CODE_') || k.startsWith('CLAUDE_AGENT_')) delete env[k];
  }
  return env;
}

// Delivers a watch message into a session that is open on the Mac, using Claude Code's
// session-to-session messaging: a small helper session sends it to the live session's inbox.
// The live session answers in its own conversation, which the watch then reads as usual.
function startRelay({ id, text, info }) {
  const body = `${RELAY_HEAD}\n${text}\n\n${RELAY_TAIL}`;
  const prompt =
    `Use the SendMessage tool exactly once to send a message to the session at address "uds:${info.socket}". ` +
    'The message must be exactly the text between the BEGIN and END lines below, unchanged and complete. ' +
    'Do nothing else. Afterwards reply with only the result text of the tool call.\n' +
    `-----BEGIN-----\n${body}\n-----END-----`;
  const args = ['-p', '--model', 'haiku', '--output-format', 'json', '--no-session-persistence', '--allowedTools', 'SendMessage'];
  fs.mkdirSync(NEW_CWD, { recursive: true });
  const proc = spawn(findClaude(), args, { cwd: NEW_CWD, env: childEnv(), stdio: ['pipe', 'pipe', 'pipe'] });
  const job = { state: 'running', prompt: text, startedAt: Date.now() / 1000, error: null, proc, relay: true, sentAt: 0 };
  jobs.set(id, job);

  let stdout = '';
  proc.stdout.on('data', (d) => { stdout += d; });
  proc.stderr.on('data', () => {});
  proc.stdin.end(prompt);
  const fail = (message) => { job.proc = null; job.state = 'error'; job.error = clip(message, 300); job.finishedAt = Date.now(); };
  const timer = setTimeout(() => proc.kill('SIGTERM'), 2 * 60 * 1000);
  proc.on('error', (err) => { clearTimeout(timer); fail(`Could not start claude: ${err.message}`); });
  proc.on('close', () => {
    clearTimeout(timer);
    if (job.state !== 'running') return;
    job.proc = null;
    let result = null;
    try { result = JSON.parse(stdout); } catch {}
    const said = String(result?.result || '');
    if (/not logged in/i.test(said)) return fail('Bridge is not signed in. On your Mac run: node bridge/server.mjs login');
    // The helper's wording varies and can't be trusted either way, so arrival is confirmed from the
    // Mac session's own conversation; if it never shows up, settleRelay reports that after a while.
    if (!result || result.is_error) return fail(said || 'Could not deliver the message to the Mac session');
    job.sentAt = Date.now(); // from here stateOf() waits for the Mac session to answer
  });
  return job;
}

// forkOf: continue from that session's history in a new session `id`, leaving the original untouched.
function startJob({ id, cwd, text, resume, forkOf }) {
  const args = ['-p', '--output-format', 'json', '--append-system-prompt', WATCH_PROMPT];
  if (forkOf) args.push('--resume', forkOf, '--fork-session', '--session-id', id);
  else args.push(resume ? '--resume' : '--session-id', id);
  if (PERMISSION_MODE) args.push('--permission-mode', PERMISSION_MODE);

  const proc = spawn(findClaude(), args, { cwd, env: childEnv(), stdio: ['pipe', 'pipe', 'pipe'] });
  const job = { state: 'running', prompt: text, startedAt: Date.now() / 1000, error: null, proc, cwd };
  jobs.set(id, job);

  let stdout = '', stderr = '';
  proc.stdout.on('data', (d) => { stdout += d; });
  proc.stderr.on('data', (d) => { stderr = (stderr + d).slice(-4000); });
  proc.stdin.end(text);

  const timer = setTimeout(() => { job.error = 'Timed out'; proc.kill('SIGTERM'); }, JOB_TIMEOUT_MS);
  const finish = (error) => {
    clearTimeout(timer);
    job.proc = null;
    job.finishedAt = Date.now();
    job.state = error ? 'error' : 'done';
    job.error = error ? clip(String(error), 300) : null;
  };
  proc.on('error', (err) => finish(job.error || `Could not start claude: ${err.message}`));
  proc.on('close', (code) => {
    if (job.state !== 'running') return;
    if (job.error) return finish(job.error);
    let result = null;
    try { result = JSON.parse(stdout); } catch {}
    if (/not logged in/i.test(result?.result || '')) return finish('Bridge is not signed in. On your Mac run: node bridge/server.mjs login');
    if (result?.is_error) return finish(result.result || 'Claude reported an error');
    if (code !== 0 && !result) return finish(stderr.trim() || `claude exited with code ${code}`);
    finish(null);
  });
  return job;
}

// ---------- overview for the watch face ----------

function loadJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

// What a session is waiting on you for, or null: a recent question it asked (an open question
// card counts even though the session still reports busy), or a dialog open on the Mac.
function attention(s, state, info) {
  const busy = state === 'running' || state === 'active';
  if (s.choices && Date.now() - s.updatedAt * 1000 < RECENT_MS && (s.asking || !busy)) {
    return { question: clip(s.choices.question || s.preview, 110), options: s.choices.options, onMac: false };
  }
  if (info?.waiting) {
    // Permission prompts and other dialogs can only be answered on the Mac.
    return { question: `Waiting for ${info.waiting} on your Mac`, options: [], onMac: true, key: `${info.waiting}:${info.statusAt}` };
  }
  return null;
}

// Every recent session with its state, plus counts and the ones waiting on you (newest first).
function overview() {
  const live = liveSessions();
  const counts = { needsYou: 0, working: 0, idle: 0 };
  const waiting = [], items = [];
  for (const file of sessionFiles()) {
    const id = path.basename(file, '.jsonl');
    try {
      const recent = Date.now() - fs.statSync(file).mtimeMs < RECENT_MS;
      if (!recent && !live.has(id)) continue;
      const s = summarize(file);
      if (!s.turns.length) continue;
      const state = stateOf(id, s, live);
      const busy = state === 'running' || state === 'active';
      const needs = attention(s, state, live.get(id));
      items.push({ id, title: s.title, preview: s.preview, busy, needs });
      if (needs) {
        counts.needsYou++;
        waiting.push({ id, title: s.title, ...needs, updatedAt: s.updatedAt });
      } else if (busy) counts.working++;
      else counts.idle++;
    } catch {}
  }
  waiting.sort((a, b) => b.updatedAt - a.updatedAt);
  return { ...counts, waiting, items };
}

// ---------- usage limits ----------

// Claude reports how much of each usage limit is spent whenever it answers, so a tiny
// request to the bridge's own claude is enough to read them. Done only when the watch asks.
const usage = { windows: {}, at: 0, probing: false };

function refreshUsage() {
  if (usage.probing || Date.now() - usage.at < USAGE_TTL_MS) return;
  usage.probing = true;
  fs.mkdirSync(NEW_CWD, { recursive: true });
  const args = ['-p', '--model', 'haiku', '--output-format', 'stream-json', '--verbose', '--no-session-persistence', 'Reply with: ok'];
  const proc = spawn(findClaude(), args, { cwd: NEW_CWD, env: childEnv(), stdio: ['ignore', 'pipe', 'ignore'] });
  let out = '';
  proc.stdout.on('data', (d) => { out += d; });
  const timer = setTimeout(() => proc.kill('SIGTERM'), 60 * 1000);
  const finish = () => {
    clearTimeout(timer);
    usage.probing = false;
    usage.at = Date.now(); // also after a failure, so a broken claude is not retried on every request
    for (const line of out.split('\n')) {
      let e = null;
      try { e = JSON.parse(line); } catch {}
      if (e?.type !== 'rate_limit_event') continue;
      for (const [name, w] of Object.entries(e.rate_limit_info?.unifiedWindows || {})) {
        if (typeof w?.utilization === 'number') usage.windows[name] = { used: w.utilization, resetsAt: Number(w.resetsAt) || 0 };
      }
    }
    out = '';
  };
  proc.on('error', finish);
  proc.on('close', finish);
}

function usageNow() {
  const pick = (name) => {
    const w = usage.windows[name];
    return w && w.resetsAt * 1000 > Date.now() ? w : null; // a window that has reset is no longer true
  };
  const session = pick('five_hour'), week = pick('seven_day');
  return session || week ? { session, week } : null;
}

// ---------- push notifications ----------

let jwtCache = null; // Apple accepts a provider token for up to an hour

function apnsJwt(cfg) {
  const now = Math.floor(Date.now() / 1000);
  if (jwtCache?.kid === cfg.keyId && now - jwtCache.iat < 40 * 60) return jwtCache.jwt;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const head = `${b64({ alg: 'ES256', kid: cfg.keyId })}.${b64({ iss: cfg.teamId, iat: now })}`;
  const sig = crypto.sign('sha256', Buffer.from(head), { key: fs.readFileSync(APNS_KEY_FILE), dsaEncoding: 'ieee-p1363' });
  jwtCache = { kid: cfg.keyId, iat: now, jwt: `${head}.${sig.toString('base64url')}` };
  return jwtCache.jwt;
}

// kind "alert" goes to the app; "widgets" asks watchOS to reload the watch face complications.
function pushOne(cfg, device, payload, { collapseId, kind = 'alert' } = {}) {
  return new Promise((resolve) => {
    const client = http2.connect(device.sandbox ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com');
    const done = (result) => { client.close(); resolve(result); };
    client.on('error', (err) => done({ status: 0, reason: err.message }));
    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${device.token}`,
      authorization: `bearer ${apnsJwt(cfg)}`,
      'apns-topic': kind === 'widgets' ? `${cfg.topic}.push-type.widgets` : cfg.topic,
      'apns-push-type': kind,
      'apns-priority': kind === 'widgets' ? '5' : '10',
    };
    if (collapseId) headers['apns-collapse-id'] = collapseId;
    const req = client.request(headers);
    let status = 0, body = '';
    req.on('response', (h) => { status = h[':status']; });
    req.on('data', (d) => { body += d; });
    req.on('end', () => done({ status, reason: loadReason(body) }));
    req.on('error', (err) => done({ status: 0, reason: err.message }));
    req.setTimeout(15 * 1000, () => req.close());
    req.end(JSON.stringify(payload));
  });
}

function loadReason(body) {
  try { return JSON.parse(body).reason || ''; } catch { return ''; }
}

async function pushAll(kind, payload, label, collapseId) {
  // Watches paired through the relay get their pushes from it, and only from it: once a watch is
  // paired, the direct pushes below would reach it a second time.
  if (Object.keys(loadJson(PAIRINGS_FILE, {})).length) {
    if (relay.ready) relay.socket.send(JSON.stringify({ type: 'push', kind, payload, collapseId }));
    return;
  }
  const cfg = loadJson(APNS_FILE, null);
  const devices = loadJson(DEVICES_FILE, []).filter((d) => (d.kind || 'app') === (kind === 'widgets' ? 'widgets' : 'app'));
  if (!cfg || !devices.length) return;
  const gone = [];
  for (const device of devices) {
    const r = await pushOne(cfg, device, payload, { collapseId, kind });
    console.log(`push ${label} -> ${device.token.slice(0, 8)}: ${r.status} ${r.reason}`);
    if (r.status === 410 || r.reason === 'BadDeviceToken') gone.push(device.token); // the app registers again on launch
  }
  if (gone.length) {
    const kept = loadJson(DEVICES_FILE, []).filter((d) => !gone.includes(d.token));
    fs.writeFileSync(DEVICES_FILE, JSON.stringify(kept, null, 2), { mode: 0o600 });
  }
}

// A session waiting on you. Its options become buttons on the notification itself.
function notifyWaiting(w) {
  return pushAll('alert', {
    aps: {
      alert: { title: w.title, subtitle: w.onMac ? 'Needs you on your Mac' : 'Needs you', body: w.question || w.options.join(' / ') },
      sound: 'default',
      'thread-id': w.id,
      category: w.onMac ? 'on-mac' : 'needs-you',
    },
    session: w.id,
    title: w.title,
    options: w.options,
  }, `needs ${w.id.slice(0, 8)}`, w.id);
}

// A session finished a stretch of work: its last reply, with a Reply button.
function notifyDone(item) {
  return pushAll('alert', {
    aps: {
      alert: { title: item.title, subtitle: 'Done', body: clip(item.preview || 'Finished.', 180) },
      sound: 'default',
      'thread-id': item.id,
      category: 'done',
    },
    session: item.id,
    title: item.title,
    options: [],
  }, `done ${item.id.slice(0, 8)}`, item.id);
}

const notified = new Set(); // questions already announced
const busySince = new Map(); // session id -> when it started working
const fromWatch = new Set(); // sessions given work from the watch, which always get a "done" alert
let primed = false; // questions already waiting when the bridge starts are not announced again
let faceSignature = '';

function watchSessions() {
  let o;
  try { o = overview(); } catch { return; }
  for (const w of o.waiting) {
    const key = `${w.id}:${w.key || `${w.question}:${w.options.join('|')}`}`;
    if (notified.has(key)) continue;
    notified.add(key);
    if (primed) notifyWaiting(w).catch(() => {});
  }
  const now = Date.now();
  for (const item of o.items) {
    if (item.busy) {
      if (!busySince.has(item.id)) busySince.set(item.id, now);
      continue;
    }
    const started = busySince.get(item.id);
    if (started === undefined) continue;
    busySince.delete(item.id);
    const long = now - started >= DONE_MIN_MS;
    const asked = fromWatch.delete(item.id);
    // A question is announced on its own; a short turn at the Mac is not worth a buzz.
    if (primed && !item.needs && (long || asked)) notifyDone(item).catch(() => {});
  }
  // Keep the watch face in step: ask watchOS to reload it when what it shows has changed.
  const signature = `${o.needsYou}:${o.working}:${o.idle}:${o.waiting[0]?.id || ''}`;
  if (primed && signature !== faceSignature) pushAll('widgets', { aps: { 'content-changed': true } }, 'face').catch(() => {});
  faceSignature = signature;
  primed = true;
}


// ---------- relay ----------
//
// With a relay, the watch needs no tunnel or domain: this bridge keeps a WebSocket open to it,
// and a paired watch's requests arrive over that socket. They are encrypted end to end with a
// key the watch and this Mac agreed on when pairing (X25519, HKDF-SHA256, ChaCha20-Poly1305);
// the relay only passes the boxes along.

const KDF_INFO = Buffer.from('claude-watch v1');
const b64u = (text) => Buffer.from(text, 'base64url');

function newKeyPair() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('x25519');
  return {
    privateKey: privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64'),
    publicKey: publicKey.export({ format: 'jwk' }).x, // 32 bytes, base64url
  };
}

// The key shared with one watch. Both sides derive the same one from their own private key and
// the other's public key; the salt ties it to this exact pair of keys.
function sharedKey(privateKeyB64, peerPublic, macPublic, watchPublic) {
  const secret = crypto.diffieHellman({
    privateKey: crypto.createPrivateKey({ key: Buffer.from(privateKeyB64, 'base64'), format: 'der', type: 'pkcs8' }),
    publicKey: crypto.createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: peerPublic }, format: 'jwk' }),
  });
  return Buffer.from(crypto.hkdfSync('sha256', secret, Buffer.concat([b64u(macPublic), b64u(watchPublic)]), KDF_INFO, 32));
}

// nonce (12) | ciphertext | tag (16), base64: the same layout as CryptoKit's ChaChaPoly.SealedBox.
function seal(key, value, aad) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
  cipher.setAAD(Buffer.from(aad));
  const data = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
  return Buffer.concat([nonce, data, cipher.getAuthTag()]).toString('base64');
}

function unseal(key, box, aad) {
  const buf = Buffer.from(box, 'base64');
  const decipher = crypto.createDecipheriv('chacha20-poly1305', key, buf.subarray(0, 12), { authTagLength: 16 });
  decipher.setAAD(Buffer.from(aad));
  decipher.setAuthTag(buf.subarray(buf.length - 16));
  return JSON.parse(Buffer.concat([decipher.update(buf.subarray(12, buf.length - 16)), decipher.final()]).toString('utf8'));
}

// Six digits both the watch and the Mac show while pairing. If they match, no one in between
// swapped the keys.
function checkNumber(macPublic, watchPublic) {
  const digest = crypto.createHash('sha256').update('claude-watch check').update(b64u(macPublic)).update(b64u(watchPublic)).digest();
  const n = String(digest.readUInt32BE(0) % 1_000_000).padStart(6, '0');
  return `${n.slice(0, 3)} ${n.slice(3)}`;
}

const relay = { socket: null, ready: false, backoff: 1000, keys: new Map() };

function keyFor(cfg, watchId) {
  const pairing = loadJson(PAIRINGS_FILE, {})[watchId];
  if (!pairing) return null;
  const cached = relay.keys.get(watchId);
  if (cached?.pk === pairing.pk) return cached.key;
  const key = sharedKey(cfg.privateKey, pairing.pk, cfg.publicKey, pairing.pk);
  relay.keys.set(watchId, { pk: pairing.pk, key });
  return key;
}

function connectRelay() {
  const cfg = loadJson(RELAY_FILE, null);
  if (!cfg || relay.socket || typeof WebSocket === 'undefined') return;
  const ws = new WebSocket(`${cfg.url.replace(/^http/, 'ws')}/v1/macs/${cfg.macId}/connect`);
  relay.socket = ws;
  ws.onopen = () => ws.send(JSON.stringify({ type: 'hello', secret: cfg.macSecret }));
  ws.onmessage = (event) => onRelayMessage(cfg, ws, event.data).catch((err) => console.log(`relay: ${err.message}`));
  ws.onerror = () => {};
  ws.onclose = (event) => {
    if (relay.ready) console.log(`relay: disconnected (${event.code})`);
    relay.socket = null;
    relay.ready = false;
    if (event.code === 4001) return console.log('relay: it no longer knows this Mac. Pair again with: node bridge/server.mjs pair');
    setTimeout(connectRelay, relay.backoff);
    relay.backoff = Math.min(relay.backoff * 2, 60 * 1000);
  };
}

async function onRelayMessage(cfg, ws, data) {
  if (data === 'pong') return;
  const msg = JSON.parse(String(data));
  if (msg.type === 'ready') {
    relay.ready = true;
    relay.backoff = 1000;
    console.log(`relay: connected to ${cfg.url}`);
    return;
  }
  if (msg.type !== 'rpc') return;
  const key = keyFor(cfg, msg.watchId);
  let reply;
  try {
    if (!key) throw new Error('This watch is not paired with this Mac');
    const request = unseal(key, msg.box, msg.watchId);
    const [status, body] = await api(String(request.method || 'GET'), String(request.path || '/'), request.body || {}, { viaRelay: true });
    reply = seal(key, { status, body }, msg.watchId);
  } catch (err) {
    reply = key ? seal(key, { status: 400, body: { error: err.message || 'Bad request' } }, msg.watchId) : null;
  }
  ws.send(JSON.stringify({ type: 'rpc-reply', id: msg.id, box: reply }));
}

async function relayFetch(cfg, method, route, body) {
  const res = await fetch(`${cfg.url}${route}`, {
    method,
    headers: { authorization: `Bearer ${cfg.macSecret}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const answer = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(answer.error || `Relay returned ${res.status}`);
  return answer;
}

function computerName() {
  try {
    return execFileSync('/usr/sbin/scutil', ['--get', 'ComputerName'], { encoding: 'utf8' }).trim();
  } catch {
    return os.hostname();
  }
}

function ask(question) {
  return new Promise((resolve) => {
    process.stdout.write(question);
    process.stdin.resume();
    process.stdin.once('data', (d) => { process.stdin.pause(); resolve(String(d).trim()); });
  });
}

// `pair`: signs this Mac up with the relay (first time only), shows a code to enter on the watch,
// then has you compare the check numbers before the watch is let in.
async function pairCommand() {
  let cfg = loadJson(RELAY_FILE, null);
  const url = (flag('--relay') || cfg?.url || DEFAULT_RELAY).replace(/\/+$/, '');
  if (!url) {
    console.error('Which relay? Run: node bridge/server.mjs pair --relay https://your-relay.example.com');
    process.exit(1);
  }
  fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
  if (!cfg || cfg.url !== url) {
    const res = await fetch(`${url}/v1/macs`, { method: 'POST' });
    const account = await res.json().catch(() => ({}));
    if (!res.ok || !account.macId) throw new Error(account.error || `Could not reach the relay at ${url}`);
    cfg = { url, macId: account.macId, macSecret: account.macSecret, ...newKeyPair() };
    fs.writeFileSync(RELAY_FILE, JSON.stringify(cfg, null, 2), { mode: 0o600 });
    fs.writeFileSync(PAIRINGS_FILE, '{}', { mode: 0o600 }); // pairings belong to one relay account
  }

  const { code } = await relayFetch(cfg, 'POST', `/v1/macs/${cfg.macId}/pairing`, { pk: cfg.publicKey, name: computerName() });
  console.log(`\nOn your watch, open Claude Watch, tap Pair with your Mac, and enter:\n\n      ${code.slice(0, 3)} ${code.slice(3)}\n\nThe code works once, for 10 minutes. Waiting for your watch…`);

  let joined;
  for (;;) {
    await new Promise((r) => setTimeout(r, 2000));
    const state = await relayFetch(cfg, 'GET', `/v1/macs/${cfg.macId}/pairing`);
    if (state.state === 'expired') throw new Error('The code expired. Run pair again.');
    if (state.state === 'joined') { joined = state; break; }
  }

  const check = checkNumber(cfg.publicKey, joined.watchPk);
  const answer = await ask(`\n"${joined.watchName}" wants to pair. Your watch shows a check number.\nIs it ${check}? Type y and press Return to allow, anything else to refuse: `);
  const accept = /^y(es)?$/i.test(answer);
  await relayFetch(cfg, 'POST', `/v1/macs/${cfg.macId}/pairing/confirm`, { watchId: joined.watchId, accept });
  if (!accept) {
    console.log('Refused. Nothing was paired.');
    return;
  }
  const pairings = loadJson(PAIRINGS_FILE, {});
  pairings[joined.watchId] = { pk: joined.watchPk, name: joined.watchName, pairedAt: Date.now() };
  fs.writeFileSync(PAIRINGS_FILE, JSON.stringify(pairings, null, 2), { mode: 0o600 });
  console.log(`\nPaired with "${joined.watchName}". The bridge connects to the relay within a few seconds.`);
}

// `unpair`: forgets every watch paired through the relay.
async function unpairCommand() {
  const cfg = loadJson(RELAY_FILE, null);
  const pairings = loadJson(PAIRINGS_FILE, {});
  for (const watchId of Object.keys(pairings)) {
    try { await relayFetch(cfg, 'DELETE', `/v1/macs/${cfg.macId}/watches/${encodeURIComponent(watchId)}`); } catch {}
    console.log(`Unpaired ${pairings[watchId].name}.`);
  }
  fs.writeFileSync(PAIRINGS_FILE, '{}', { mode: 0o600 });
}

// ---------- HTTP ----------

function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (d) => {
      data += d;
      if (data.length > 16 * 1024) { reject(new Error('Body too large')); req.destroy(); }
    });
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

function detail(id) {
  const file = findSessionFile(id);
  const job = jobs.get(id);
  if (!file && !job) return null;
  const fork = loadForks()[id];
  const s = file ? summarize(file) : { id, title: fork?.title || clip(job.prompt, 60), project: path.basename(job.cwd || NEW_CWD), updatedAt: 0, turns: [] };
  const live = liveSessions();
  const state = stateOf(id, s, live); // may settle a finished relay, so read `running` after it
  const running = job?.state === 'running';
  const waiting = live.get(id)?.waiting;
  return {
    id,
    title: s.title,
    project: s.project,
    state,
    watchCopy: Boolean(fork),
    canStop: running && !job.relay,
    turns: s.turns,
    choices: running ? null : s.choices || null,
    pending: running && !job.seen && !(s.recent || []).some((t) => t.role === 'user' && t.text === job.prompt && (t.at || Infinity) >= job.startedAt * 1000 - 2000)
      ? { prompt: job.prompt, startedAt: job.startedAt } : null,
    error: job?.state === 'error' ? job.error : null,
    waitingOnMac: waiting ? `Waiting for ${waiting} on your Mac. It can only be answered there.` : null,
  };
}

// Sends a watch message to an existing session. Returns [status, body] for the HTTP answer.
function deliver(id, text) {
  const file = findSessionFile(id);
  if (!file) return [404, { error: 'No such session' }];
  const s = summarize(file);
  const live = liveSessions();
  const state = stateOf(id, s, live);
  if (state === 'running') return [409, { error: 'Still working on your last message' }];
  if (!s.cwd || !fs.existsSync(s.cwd)) return [409, { error: "This session's folder no longer exists" }];
  // Something other than an open Mac session is writing this transcript right now.
  if (state === 'active' && !live.has(id)) return [409, { error: 'This session is busy. Try again in a moment.' }];
  const info = live.get(id);
  if (info && LIVE_MODE === 'relay' && info.socket) {
    // Open on the Mac: hand the message to the live session itself.
    startRelay({ id, text, info });
    fromWatch.add(id);
    return [202, { id, title: s.title }];
  }
  if (info) {
    // Open on the Mac: answer from a copy so the live session's history is never written by two processes.
    const copyId = crypto.randomUUID();
    recordFork(copyId, id, s.title);
    startJob({ id: copyId, cwd: s.cwd, text, forkOf: id });
    fromWatch.add(copyId);
    return [202, { id: copyId, title: s.title }];
  }
  startJob({ id, cwd: s.cwd, text, resume: true });
  fromWatch.add(id);
  return [202, { id, title: s.title }];
}

const FILLER = new Set(['the', 'a', 'an', 'session', 'project', 'chat', 'claude']);
const words = (t) => t.toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(Boolean);

// "Tell harness to run the tests" or "Ask the dataset session, how big is it?": a message for the
// session with that project folder or title, as the watch dictated it. Returns { id, text } or null.
function routeSpoken(text) {
  const m = text.match(/^\s*(?:tell|ask|message|go to)\s+(.+)$/i);
  if (!m) return null;
  const spoken = words(m[1]);
  let best = null;
  for (const file of sessionFiles()) {
    let s;
    try {
      if (Date.now() - fs.statSync(file).mtimeMs > 7 * RECENT_MS) continue;
      s = summarize(file);
    } catch { continue; }
    if (!s.turns.length) continue;
    for (const name of [s.project, s.title]) {
      const target = words(name || '').filter((w) => !FILLER.has(w));
      if (!target.length || target.join('').length < 3) continue;
      // Skip filler words before the name, then the name must match word for word.
      let i = 0;
      while (i < spoken.length && FILLER.has(spoken[i])) i++;
      if (spoken.slice(i, i + target.length).join(' ') !== target.join(' ')) continue;
      i += target.length;
      while (i < spoken.length && FILLER.has(spoken[i])) i++;
      if (!best || target.length > best.length || (target.length === best.length && s.updatedAt > best.updatedAt)) {
        best = { id: s.id, length: target.length, used: i, updatedAt: s.updatedAt };
      }
    }
  }
  if (!best) return null;
  // Keep the rest of the original wording (with its punctuation), minus a leading "to" or comma.
  let rest = m[1];
  for (let k = 0; k < best.used; k++) rest = rest.replace(/^[^a-z0-9]*[a-z0-9]+/i, '');
  rest = rest.replace(/^[\s,:;.!-]*(?:to\s+|that\s+)?/i, '').trim();
  if (!rest) return null;
  return { id: best.id, text: rest.charAt(0).toUpperCase() + rest.slice(1) };
}

let token = '';

async function handle(req, res) {
  if (!tokenMatches(req.headers.authorization, token)) {
    await new Promise((r) => setTimeout(r, 500));
    return send(res, 401, { error: 'Unauthorized' });
  }
  const body = req.method === 'POST' ? await readBody(req) : {};
  const [status, answer] = await api(req.method, new URL(req.url, 'http://localhost').pathname, body);
  return send(res, status, answer);
}

// The watch API, reached over local HTTP (with the pairing token) or through the relay (from a
// paired watch, end-to-end encrypted). Returns [status, body].
async function api(method, pathname, body, { viaRelay = false } = {}) {
  const parts = pathname.split('/').filter(Boolean);
  const [root, id, action] = parts;

  if (root === 'status' && parts.length === 1 && method === 'GET') {
    refreshUsage(); // in the background; this answer carries the last known numbers
    const { waiting, ...counts } = overview();
    const top = waiting[0] ? { id: waiting[0].id, title: waiting[0].title, question: waiting[0].question } : null;
    return [200, { ...counts, top, usage: usageNow() }];
  }

  if (root === 'devices' && parts.length === 1 && method === 'POST') {
        const deviceToken = String(body.token || '').toLowerCase();
    if (!/^[0-9a-f]{32,200}$/.test(deviceToken)) return [400, { error: 'Bad device token' }];
    // "app" gets alerts; "widgets" is the watch face, which gets reload requests.
    const kind = body.kind === 'widgets' ? 'widgets' : 'app';
    const devices = loadJson(DEVICES_FILE, []).filter((d) => d.token !== deviceToken);
    devices.push({ token: deviceToken, kind, sandbox: Boolean(body.sandbox), at: Date.now() });
    const keep = [...devices.filter((d) => (d.kind || 'app') === 'app').slice(-3), ...devices.filter((d) => d.kind === 'widgets').slice(-3)];
    fs.writeFileSync(DEVICES_FILE, JSON.stringify(keep, null, 2), { mode: 0o600 });
    return [200, { ok: true, push: fs.existsSync(APNS_FILE) }];
  }

  if (root === 'token' && id === 'rotate' && parts.length === 2 && method === 'POST' && !viaRelay) {
    // A new pairing token; the old one, including the one built into the app, stops working.
    token = crypto.randomBytes(32).toString('base64url');
    fs.writeFileSync(TOKEN_FILE, token, { mode: 0o600 });
    console.log('Pairing token rotated from the watch.');
    return [200, { token }];
  }

  if (root !== 'sessions' || parts.length > 3) return [404, { error: 'Not found' }];
  if (id && !UUID.test(id)) return [400, { error: 'Bad session id' }];

  if (method === 'GET' && !id) {
    const live = liveSessions();
    const forks = loadForks();
    const sessions = sessionFiles()
      .map((f) => { try { return summarize(f); } catch { return null; } })
      .filter((s) => s && s.turns.length > 0)
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .slice(0, 30)
      .map((s) => {
        const state = stateOf(s.id, s, live);
        const needsYou = Boolean(attention(s, state, live.get(s.id)));
        return { id: s.id, title: s.title, project: s.project, updatedAt: s.updatedAt, state, needsYou, preview: s.preview, watchCopy: Boolean(forks[s.id]) };
      });
    return [200, { sessions }];
  }

  if (method === 'GET' && id && !action) {
    const d = detail(id);
    return d ? [200, d] : [404, { error: 'No such session' }];
  }

  if (method === 'POST' && !id) {
    const text = String(body.text || '').trim();
    if (!text) return [400, { error: 'Empty message' }];
    // "Tell <session> …" goes to that session instead of starting a new one.
    const routed = routeSpoken(text);
    if (routed) {
      const [status, answer] = deliver(routed.id, routed.text);
      return [status, status === 202 ? { ...answer, routed: true } : answer];
    }
    fs.mkdirSync(NEW_CWD, { recursive: true });
    const newId = crypto.randomUUID();
    startJob({ id: newId, cwd: NEW_CWD, text, resume: false });
    fromWatch.add(newId);
    return [202, { id: newId, title: clip(text, 60) }];
  }

  if (method === 'POST' && action === 'message') {
    const text = String(body.text || '').trim();
    if (!text) return [400, { error: 'Empty message' }];
    return deliver(id, text);
  }

  if (method === 'POST' && action === 'stop') {
    const job = jobs.get(id);
    if (job?.state !== 'running') return [409, { error: 'Nothing running' }];
    if (job.relay) return [409, { error: 'This session runs on your Mac and can only be stopped there' }];
    job.error = 'Stopped';
    job.proc?.kill('SIGTERM');
    return [200, { id }];
  }

  return [404, { error: 'Not found' }];
}

// ---------- entry points ----------

const APP_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'ClaudeWatch');
const LOCAL_XCCONFIG = path.join(APP_DIR, 'Local.xcconfig');

// Values from Base.xcconfig, overridden by Local.xcconfig.
function signingSettings() {
  const out = {};
  for (const file of [path.join(APP_DIR, 'Base.xcconfig'), LOCAL_XCCONFIG]) {
    let text = '';
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    for (const m of text.matchAll(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/gm)) out[m[1]] = m[2];
  }
  return out;
}

function flag(name) {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : undefined;
}

// Writes ClaudeWatch/Local.xcconfig: your Apple team, the bundle id prefix, and (optionally) the
// relay your build of the app pairs through. Run once before building the app yourself.
function configure() {
  const current = signingSettings();
  const teamId = flag('--team') || current.DEVELOPMENT_TEAM || '';
  const bundlePrefix = flag('--bundle-prefix') || current.BUNDLE_PREFIX || '';
  const relayHost = (flag('--relay') || current.RELAY_HOST || '').replace(/^https?:\/\//, '').replace(/\/+$/, '');
  if (!/^[A-Z0-9]{10}$/.test(teamId)) {
    console.error('Usage: node bridge/server.mjs configure --team <TEAM_ID> --bundle-prefix <com.you.claudewatch> [--relay <relay host>]\n' +
      '--team is your 10-character Apple team ID (developer.apple.com → Membership).');
    process.exit(1);
  }
  if (!/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(bundlePrefix) || bundlePrefix === 'com.example.claudewatch') {
    console.error('--bundle-prefix must be a reverse-DNS prefix you own, like com.yourname.claudewatch.');
    process.exit(1);
  }
  fs.writeFileSync(LOCAL_XCCONFIG,
    '// Written by `node bridge/server.mjs configure`. Your own settings; git ignores this file.\n' +
    `DEVELOPMENT_TEAM = ${teamId}\nBUNDLE_PREFIX = ${bundlePrefix}\n` +
    (relayHost ? `RELAY_HOST = ${relayHost}\n` : ''));
  console.log(`Wrote ${path.relative(process.cwd(), LOCAL_XCCONFIG)}: team ${teamId}, apps ${bundlePrefix}.*` +
    (relayHost ? `, relay ${relayHost}.` : '.'));
}

// Stores an Apple push key (Apple Developer > Keys, with Apple Push Notifications service enabled).
function configurePush(keyPath) {
  if (!keyPath) {
    // No path given: use the newest key Apple's site saved to Downloads.
    const dl = path.join(HOME, 'Downloads');
    let names = [];
    try { names = fs.readdirSync(dl).filter((n) => /^AuthKey_[A-Z0-9]{10}\.p8$/.test(n)); } catch {}
    names.sort((a, b) => fs.statSync(path.join(dl, b)).mtimeMs - fs.statSync(path.join(dl, a)).mtimeMs);
    if (!names.length) {
      console.error('No AuthKey_….p8 file in Downloads yet. Create and download one at developer.apple.com > Keys (with Apple Push Notifications service), then run this again.');
      process.exit(1);
    }
    keyPath = path.join(dl, names[0]);
  }
  const keyId = path.basename(keyPath || '').match(/^AuthKey_([A-Z0-9]{10})\.p8$/)?.[1];
  if (!keyId || !fs.existsSync(keyPath)) {
    console.error('Usage: node bridge/server.mjs push /path/to/AuthKey_XXXXXXXXXX.p8  (keep the file name Apple gave it)');
    process.exit(1);
  }
  const { DEVELOPMENT_TEAM: teamId, BUNDLE_PREFIX: prefix } = signingSettings();
  if (!teamId || !prefix || prefix === 'com.example.claudewatch') {
    console.error('Set your team and bundle prefix first: node bridge/server.mjs configure --team <TEAM_ID> --bundle-prefix <com.you.claudewatch>');
    process.exit(1);
  }
  const topic = `${prefix}.watchkitapp`;
  fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(APNS_KEY_FILE, fs.readFileSync(keyPath), { mode: 0o600 });
  fs.writeFileSync(APNS_FILE, JSON.stringify({ keyId, teamId, topic }, null, 2), { mode: 0o600 });
  console.log(`Push key ${keyId} stored in ${CONF_DIR}. Notifications are on; you can delete the downloaded file.`);
}

if (process.argv[2] === 'configure') {
  configure();
} else if (process.argv[2] === 'push') {
  configurePush(process.argv[3]);
} else if (process.argv[2] === 'pair' || process.argv[2] === 'unpair') {
  (process.argv[2] === 'pair' ? pairCommand() : unpairCommand())
    .then(() => process.exit(0))
    .catch((err) => { console.error(err.message); process.exit(1); });
} else if (process.argv[2] === 'route') {
  // Shows which session a dictated message would go to, without sending it.
  console.log(routeSpoken(process.argv.slice(3).join(' ')) || 'No session named: it would start a new session.');
} else if (process.argv[2] === 'login') {
  // The desktop app's sign-in is not shared with the command-line claude the bridge runs.
  spawn(findClaude(), ['auth', 'login'], { stdio: 'inherit' }).on('close', (code) => process.exit(code ?? 0));
} else {
  token = loadToken();
  const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => send(res, 400, { error: err.message || 'Bad request' }));
  });
  if (process.env.BRIDGE_KEEP_AWAKE !== '0') {
    // Keeps the Mac from sleeping while it is plugged in, so the watch can reach it. On battery,
    // or with the lid closed and no external display, macOS still sleeps.
    spawn('/usr/bin/caffeinate', ['-s', '-w', String(process.pid)], { stdio: 'ignore' }).on('error', () => {});
  }
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`Claude Watch bridge listening on http://127.0.0.1:${PORT}`);
    console.log(`claude: ${findClaude()}`);
    console.log(`Pairing token is stored in ${TOKEN_FILE}`);
  });
  setInterval(watchSessions, WATCH_INTERVAL_MS);
  setInterval(saveCache, 30 * 1000);
  // The relay, once `pair` has set it up; also keeps the connection from idling out.
  connectRelay();
  setInterval(() => {
    connectRelay();
    if (relay.ready) relay.socket.send('ping');
  }, 15 * 1000);
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { saveCache(); process.exit(0); });
}
