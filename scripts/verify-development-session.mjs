#!/usr/bin/env node
// Runs against an already launched CLI session; no GUI or platform SDK dependency.
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const [project, platform] = process.argv.slice(2);
if (!project || !platform) throw new Error('Usage: node scripts/verify-development-session.mjs PROJECT mac|android');
const folder = join(project, '.guava/build/devtools');
const sessions = readdirSync(folder).flatMap(id => {
  try { return [JSON.parse(readFileSync(join(folder, id, 'session.json'), 'utf8'))]; } catch { return []; }
}).filter(item => item.platform === platform);
assert.equal(sessions.length, 1, 'Expected exactly one session for this platform');
const session = sessions[0];
const endpoint = new URL(session.runtime.endpoint);
if (session.device) endpoint.port = String(session.device.forwardedPort);

async function rejected(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const timeout = setTimeout(() => { socket.close(); reject(new Error('Unauthenticated handshake timed out')); }, 5000);
    socket.addEventListener('open', () => { clearTimeout(timeout); socket.close(); reject(new Error('Unauthenticated client connected')); });
    socket.addEventListener('error', () => { clearTimeout(timeout); resolve(); });
  });
}
const anonymous = new URL(endpoint); anonymous.search = '';
await rejected(anonymous);
const wrong = new URL(endpoint); wrong.searchParams.set('token', 'wrong');
await rejected(wrong);

const socket = new WebSocket(endpoint);
const pending = new Map();
let nextId = 1;
const hello = new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error('No hello')), 5000);
  socket.addEventListener('message', event => {
    const message = JSON.parse(String(event.data));
    if (message.type === 'hello') { clearTimeout(timeout); resolve(message.payload); }
    if (message.id && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
  });
  socket.addEventListener('error', () => reject(new Error('Authenticated connection failed')));
});
const host = await hello;
assert.equal(host.host.pid, session.runtime.pid);
for (const capability of ['log', 'tree', 'select', 'inspect', 'style', 'source', 'recomposition', 'timeline', 'state.observe']) {
  assert(host.capabilities.includes(capability), `Missing capability ${capability}`);
}
function request(type, payload) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`No response to ${type}`)); }, 5000);
    pending.set(id, message => { clearTimeout(timeout); resolve(message); });
    socket.send(JSON.stringify({ type, id, payload }));
  });
}
const logs = await request('log.subscribe');
assert.equal(logs.type, 'log.snapshot');
assert(logs.payload.records.length > 0, 'Startup logs were not replayed');
for (const record of logs.payload.records) {
  assert(record.sequence > 0 && record.process.runID && record.location.file, 'Incomplete log record');
}
assert(logs.payload.records.some(record => record.label === 'com.guava.engine.rhi'), 'Engine logs did not join the application journal');
assert.equal((await request('log.unsubscribe')).type, 'log.unsubscribe.ok');
const tree = await request('tree.subscribe');
assert.equal(tree.type, 'tree.snapshot');
assert(tree.payload.root, 'Empty scene tree');
const ids = [];
(function visit(node) { ids.push(node.elementID ?? node.id); for (const child of node.children ?? []) visit(child); })(tree.payload.root);
assert(ids.length > 5, 'Expected real application nodes');
assert.equal((await request('select.node', { id: ids.at(-1) })).type, 'select.node.ok');
assert.equal((await request('select.clear')).type, 'select.clear.ok');
assert.equal((await request('state.list')).type, 'state.list.ok');
assert.equal((await request('timeline.subscribe')).type, 'timeline.events');
let styled = null;
for (const id of ids) {
  const reply = await request('inspect.style.set', { id, properties: { padding: { top: 3, right: 3, bottom: 3, left: 3 } } });
  if (reply.type === 'inspect.style.set.ok') { styled = reply; break; }
  assert.equal(reply.payload?.code, 'unsupported', JSON.stringify(reply.payload));
}
assert(styled, 'Expected an editable layout node');
assert.equal((await request('inspect.style.undo')).type, 'inspect.style.undo.ok');
assert.equal((await request('inspect.style.clearAll')).type, 'inspect.style.clearAll.ok');
assert.equal((await request('timeline.unsubscribe')).type, 'timeline.unsubscribe.ok');
assert.equal((await request('tree.unsubscribe')).type, 'tree.unsubscribe.ok');
socket.close();
console.log(JSON.stringify({ platform, session: session.runtime.id, nodes: ids.length, replayedLogs: logs.payload.records.length, runID: logs.payload.records[0].process.runID, authenticated: true, capabilities: host.capabilities }, null, 2));
