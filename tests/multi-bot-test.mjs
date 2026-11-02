import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, symlink, unlink, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BotStore, MAX_BOTS } from '../app/JobTracking.bundle/multi-bot-store.mjs';
import { openBotSession, handleBotRequest } from '../app/JobTracking.bundle/multi-bot.mjs';

async function fixture(t) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'ios-bots-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const store = new BotStore(home); await store.ready;
  return { home, store };
}
test('one Chief, concurrent creation, retry and restart preserve fixed identities', async t => {
  const { home, store } = await fixture(t);
  const [chief] = await store.list(); assert.equal(chief.name, 'Chief'); assert(chief.isMain);
  const [a, b, retry] = await Promise.all([store.create('研究', '查资料'), store.create('写作', '写文稿'), store.create('研究', '查资料')]);
  assert.equal(a.id, retry.id); assert.notEqual(a.sessionId, b.sessionId);
  await assert.rejects(store.create('研究', '其他职责'), /名称已存在/);
  const reopened = new BotStore(home); await reopened.ready;
  assert.deepEqual(await reopened.list(), await store.list());
  assert.equal((await reopened.list()).filter(b => b.isMain).length, 1);
  assert.equal(await readFile(a.memoryPath, 'utf8'), '');
});
test('Markdown read/write/clear is isolated, persistent and revision checked', async t => {
  const { home, store } = await fixture(t);
  const a = await store.create('A', '写作\n润色中文'), b = await store.create('B', '测试');
  const initial = await store.memory(a.id);
  const written = await store.writeMemory(a.id, '# 喜好\n请用中文。', initial.revision);
  assert.equal((await store.memory(b.id)).content, '');
  await assert.rejects(store.writeMemory(a.id, '过期写入', initial.revision), /已改变/);
  const reopened = new BotStore(home); await reopened.ready;
  assert.equal((await reopened.memory(a.id)).content, written.content);
  await reopened.writeMemory(a.id, '', written.revision);
  assert.equal(await readFile(a.memoryPath, 'utf8'), '');
  assert.equal((await reopened.byId(a.id)).sessionId, a.sessionId);
});
test('invalid inputs, corrupt registry and escaped memory path fail without reset', async t => {
  const { home, store } = await fixture(t);
  assert.throws(() => store.create('', 'role'), /名称/);
  assert.throws(() => store.create('a', 'x'.repeat(1001)), /职责/);
  const [chief] = await store.list();
  await assert.rejects(store.memory('../../sentinel'), /找不到/);
  assert.throws(() => store.writeMemory(chief.id, '字'.repeat(6000), ''), /16 KiB/);
  const raw = await readFile(store.catalog, 'utf8');
  const bots = JSON.parse(raw); bots[0].memoryPath = join(home, 'sentinel');
  await writeFile(store.catalog, JSON.stringify(bots));
  const broken = new BotStore(home); await assert.rejects(broken.ready, /记录无效/);
  assert.equal(await readFile(store.catalog, 'utf8'), JSON.stringify(bots));
  await writeFile(store.catalog, '{torn');
  const torn = new BotStore(home); await assert.rejects(torn.ready, SyntaxError);
  assert.equal(await readFile(store.catalog, 'utf8'), '{torn');
});
test('Bot count is bounded including Chief', async t => {
  const { store } = await fixture(t);
  for (let i = 1; i < MAX_BOTS; i++) await store.create(`B${i}`, 'helper');
  await assert.rejects(store.create('overflow', 'helper'), /最多/);
  assert.equal((await store.list()).length, MAX_BOTS);
});
test('links cannot turn memory clear into a write outside the Bot', { skip: process.platform === 'win32' ? 'requires POSIX symlink support; also run under WSL/CI' : false }, async t => {
  const { home, store } = await fixture(t);
  const [bot] = await store.list(), sentinel = join(home, 'sentinel');
  await writeFile(sentinel, 'preserve'); await unlink(bot.memoryPath); await symlink(sentinel, bot.memoryPath);
  await assert.rejects(store.memory(bot.id), /普通文件/);
  await assert.rejects(store.writeMemory(bot.id, '', 'revision'), /普通文件/);
  assert.equal(await readFile(sentinel, 'utf8'), 'preserve');
});
test('open creates once, flushes, and never calls create for an existing nonblank session', async t => {
  const { home, store } = await fixture(t), [bot] = await store.list();
  const records = new Map(); let creates = 0, flushes = 0;
  const workspace = { id: 'workspace-1', sessionIds: [], async attachSession(id) { this.sessionIds.push(id); } };
  const ctx = {
    workspaceRegistry: { async create(path, name) { assert.equal(path, store.workspace(bot)); assert.equal(name, bot.name); return workspace; } },
    sessionQuery: { observeSession() { throw new Error('must not hydrate conversation'); } },
    sessionController: { async create(request) { creates++; assert.equal(request.workspaceId, workspace.id); assert.equal(request.cwd, undefined); records.set(request.sessionId, store.workspace(bot)); return { sessionId: request.sessionId }; } },
    sessionPersistence: {
      async stat(id) { return records.has(id) ? { header: { cwd: records.get(id) } } : undefined; },
      async flush() { flushes++; },
    },
  };
  assert.equal((await openBotSession(ctx, store, bot.id)).sessionId, bot.sessionId);
  const reopened = new BotStore(home); await reopened.ready;
  assert.equal((await openBotSession(ctx, reopened, bot.id)).sessionId, bot.sessionId);
  assert.equal(creates, 1); assert.equal(flushes, 1);
  assert.deepEqual(workspace.sessionIds, [bot.sessionId], 'blank composer must own the Bot workspace');
  records.delete(bot.sessionId);
  await assert.rejects(openBotSession(ctx, reopened, bot.id), /文件缺失/); assert.equal(creates, 1);
});
test('session mismatch and persistence errors are visible and never silently remap identity', async t => {
  const { store } = await fixture(t), [bot] = await store.list();
  await assert.rejects(openBotSession({ sessionPersistence: { stat: async () => ({ header: { cwd: '/other' } }) } }, store, bot.id), /不匹配/);
  await assert.rejects(openBotSession({ sessionPersistence: { stat: async () => { throw new Error('disk failure'); } } }, store, bot.id), /disk failure/);
  assert.equal((await store.byId(bot.id)).sessionReady, false);
});
test('a failed first flush is retried without creating a replacement session', async t => {
  const { store } = await fixture(t), [bot] = await store.list(); let exists = false, fail = true, creates = 0;
  const ctx = { sessionController: { async create({ sessionId }) { creates++; exists = true; return { sessionId }; } },
    workspaceRegistry: { async create() { return { id: 'workspace-1', sessionIds: [], async attachSession() {} }; } },
    sessionPersistence: { async stat() { return exists ? { header: { cwd: store.workspace(bot) } } : undefined; },
      async flush() { if (fail) throw new Error('flush failed'); } } };
  await assert.rejects(openBotSession(ctx, store, bot.id), /flush failed/);
  assert.equal((await store.byId(bot.id)).sessionReady, false); fail = false;
  await openBotSession(ctx, store, bot.id);
  assert.equal(creates, 1); assert.equal((await store.byId(bot.id)).sessionReady, true);
});
test('HTTP form creation, reading, stale clear, running refusal, and empty clear', async t => {
  const { store } = await fixture(t); let running = false;
  const deps = { store, agents: { get: () => ({ status: running ? 'running' : 'idle' }) }, openBot: async id => store.byId(id) };
  const call = async body => handleBotRequest(new Request('http://localhost/api/ios-multi-bot', body ? {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) } : {}), deps);
  assert.equal((await (await call()).json()).bots[0].name, 'Chief');
  const { bot } = await (await call({ action: 'create', name: '<script>alert(1)</script>', role: 'test' })).json();
  const memory = await store.memory(bot.id); const saved = await store.writeMemory(bot.id, 'keep', memory.revision);
  assert.equal((await call({ action: 'clear', id: bot.id, revision: memory.revision })).status, 400);
  running = true;
  assert.match((await (await call({ action: 'clear', id: bot.id, revision: saved.revision })).json()).error, /先停止/);
  running = false;
  assert.equal((await (await call({ action: 'clear', id: bot.id, revision: saved.revision })).json()).content, '');
});
