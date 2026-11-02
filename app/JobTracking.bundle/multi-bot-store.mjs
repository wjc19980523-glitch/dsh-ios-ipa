// DSH iOS' own small registry. No DS-Bot code or data format is imported.
import { mkdir, lstat, open, rename, unlink } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';

export const MAX_BOTS = 24;
export const MAX_MEMORY_BYTES = 16384;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const text = (value, max, label, multiline = false) => {
  const controls = multiline ? /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u : /[\u0000-\u001f\u007f]/u;
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max || controls.test(value))
    throw new Error(`${label}格式无效（1–${max} 字符，不含控制字符）`);
  return value.trim();
};
const digest = value => createHash('sha256').update(value).digest('hex');

export class BotStore {
  constructor(home) {
    this.root = resolve(home, 'ios-multi-bot');
    this.catalog = join(this.root, 'bots.json');
    this.queue = Promise.resolve();
    this.ready = this.initialize();
  }
  async directory(path) {
    await mkdir(path, { recursive: true, mode: 0o700 });
    if (!(await lstat(path)).isDirectory()) throw new Error('Bot 目录不可用或为符号链接');
  }
  async read(path, limit) {
    const info = await lstat(path);
    if (!info.isFile() || info.nlink !== 1 || info.size > limit) throw new Error('Bot 文件非普通文件或超过大小限制');
    const file = await open(path, 'r');
    try {
      const actual = await file.stat();
      if (actual.ino !== info.ino || actual.dev !== info.dev) throw new Error('Bot 文件在读取期间改变');
      const bytes = Buffer.alloc(limit + 1);
      let length = 0;
      while (length < bytes.length) {
        const { bytesRead } = await file.read(bytes, length, bytes.length - length, length);
        if (!bytesRead) break;
        length += bytesRead;
      }
      if (length > limit) throw new Error('Bot 文件超过大小限制');
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, length));
    } finally { await file.close(); }
  }
  async atomic(path, value) {
    try {
      const info = await lstat(path);
      if (!info.isFile() || info.nlink !== 1) throw new Error('拒绝覆盖链接或非普通 Bot 文件');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const temporary = `${path}.${randomUUID()}.tmp`;
    const file = await open(temporary, 'wx', 0o600);
    try {
      try { await file.writeFile(value, 'utf8'); await file.sync(); }
      finally { await file.close(); }
      await rename(temporary, path);
      // iSH's fakefs owns final durability. fsync the directory where supported.
      if (process.platform !== 'win32') {
        const dir = await open(resolve(path, '..'), 'r');
        try { await dir.sync(); } finally { await dir.close(); }
      }
    } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
  }
  record(id, name, role, isMain = false) {
    return { id, name, role, sessionId: `ios-bot-${id}`, memoryPath: join(this.root, id, 'memory.md'), isMain, sessionReady: false };
  }
  async prepare(bot) {
    await this.directory(join(this.root, bot.id));
    await this.directory(this.workspace(bot));
    try { await this.read(bot.memoryPath, MAX_MEMORY_BYTES); }
    catch (error) { if (error.code !== 'ENOENT') throw error; await this.atomic(bot.memoryPath, ''); }
  }
  workspace(bot) { return join(this.root, bot.id, 'workspace'); }
  async initialize() {
    await this.directory(this.root);
    try { await this.load(); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error; // A corrupt registry is never silently reset.
      const chief = this.record(randomUUID(), 'Chief', '帮助用户梳理任务，按用户要求创建职责明确的 Bot。', true);
      await this.prepare(chief);
      await this.save([chief]);
    }
  }
  async load() {
    if (!(await lstat(this.root)).isDirectory()) throw new Error('Bot 根目录不可用');
    const bots = JSON.parse(await this.read(this.catalog, 128 * 1024));
    if (!Array.isArray(bots) || !bots.length || bots.length > MAX_BOTS || bots.filter(b => b?.isMain === true).length !== 1)
      throw new Error('bots.json 无效；请保留原文件进行恢复');
    const ids = new Set(), names = new Set();
    for (const bot of bots) {
      if (!bot || !UUID.test(bot.id) || ids.has(bot.id) || typeof bot.isMain !== 'boolean' || typeof bot.sessionReady !== 'boolean' ||
          bot.sessionId !== `ios-bot-${bot.id}` || bot.memoryPath !== join(this.root, bot.id, 'memory.md')) throw new Error('Bot 记录无效');
      if (text(bot.name, 40, '名称') !== bot.name || text(bot.role, 1000, '职责', true) !== bot.role || names.has(bot.name.toLocaleLowerCase()))
        throw new Error('Bot 名称或职责无效');
      ids.add(bot.id); names.add(bot.name.toLocaleLowerCase());
    }
    return bots;
  }
  save(bots) { return this.atomic(this.catalog, `${JSON.stringify(bots, null, 2)}\n`); }
  serial(operation) {
    const result = this.queue.then(() => this.ready).then(operation);
    this.queue = result.catch(() => {});
    return result;
  }
  list() { return this.serial(() => this.load()); }
  async bySession(sessionId) { return (await this.list()).find(bot => bot.sessionId === sessionId); }
  async byId(id) {
    const bot = (await this.list()).find(bot => bot.id === id);
    if (!bot) throw new Error('找不到这个 Bot');
    return bot;
  }
  create(name, role) {
    name = text(name, 40, '名称'); role = text(role, 1000, '职责', true);
    return this.serial(async () => {
      const bots = await this.load();
      const existing = bots.find(bot => bot.name.toLocaleLowerCase() === name.toLocaleLowerCase());
      if (existing) {
        if (existing.role === role && !existing.isMain) return existing; // Lost-response retry.
        throw new Error('名称已存在，请使用不同名称');
      }
      if (bots.length >= MAX_BOTS) throw new Error(`MVP 最多 ${MAX_BOTS} 个 Bot（含 Chief）`);
      const bot = this.record(randomUUID(), name, role);
      await this.prepare(bot);
      await this.save([...bots, bot]);
      return bot;
    });
  }
  markReady(id) {
    return this.serial(async () => {
      const bots = await this.load(), bot = bots.find(row => row.id === id);
      if (!bot) throw new Error('找不到这个 Bot');
      bot.sessionReady = true;
      await this.save(bots);
    });
  }
  memory(id) {
    return this.serial(async () => {
      const bot = (await this.load()).find(row => row.id === id);
      if (!bot) throw new Error('找不到这个 Bot');
      // Validate the parent every time; a workspace is a convention, not a sandbox.
      if (!(await lstat(join(this.root, bot.id))).isDirectory()) throw new Error('Bot 目录不可用');
      const content = await this.read(bot.memoryPath, MAX_MEMORY_BYTES);
      return { content, revision: digest(content), path: bot.memoryPath };
    });
  }
  writeMemory(id, content, expectedRevision) {
    if (typeof content !== 'string' || Buffer.byteLength(content, 'utf8') > MAX_MEMORY_BYTES) throw new Error('记忆最多 16 KiB');
    return this.serial(async () => {
      const bot = (await this.load()).find(row => row.id === id);
      if (!bot) throw new Error('找不到这个 Bot');
      if (!(await lstat(join(this.root, bot.id))).isDirectory()) throw new Error('Bot 目录不可用');
      const current = await this.read(bot.memoryPath, MAX_MEMORY_BYTES);
      if (digest(current) !== expectedRevision) throw new Error('记忆已改变，请重新读取后再操作');
      await this.atomic(bot.memoryPath, content);
      return { content, revision: digest(content), path: bot.memoryPath };
    });
  }
}
