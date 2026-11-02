// Interaction fixture: actual shipped client + Bot HTTP/store, minimal Harness
// slot adapter. This is not evidence of iSH/WKWebView execution (XCTest is).
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm, mkdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { BotStore } from '../app/JobTracking.bundle/multi-bot-store.mjs';
import { handleBotRequest } from '../app/JobTracking.bundle/multi-bot.mjs';
const deps = resolve(process.env.DSH_BROWSER_DEPS ?? 'build/multi-bot-browser/node_modules');
const { chromium } = await import(pathToFileURL(join(deps, 'playwright/index.mjs')).href);
const home = await mkdtemp(join(tmpdir(), 'ios-bot-browser-'));
const store = new BotStore(home); await store.ready;
const html = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
body{font:15px system-ui;margin:0;color:#243148;background:#f5f7fb}#root{display:flex;height:100dvh}aside{background:white;width:250px;padding:12px;border-right:1px solid #ddd;box-sizing:border-box}main{padding:16px;min-width:0;flex:1}@media(max-width:500px){aside{width:170px;padding:8px}main{padding:8px}}button{font:inherit}h1{font-size:18px}
</style></head><body><div id="root"></div><script src="/react.js"></script><script src="/react-dom.js"></script><script>
let plugin; window.__ModuleLoader__={load:entry=>{plugin=entry.factory(name=>{if(name==='react')return React;throw Error(name)})}};
</script><script src="/client.js"></script><script>
const slots={}, effects=[], hooks={}; let current={key:undefined};const listeners=new Set();
const ctx={slots:{inject:(_name,fn)=>fn(),register:(options,component)=>{slots[options.name]=component;return ()=>{}}},
uiSession:{current:{getSnapshot:()=>current,subscribe:fn=>{listeners.add(fn);return ()=>listeners.delete(fn)}}},
uiWorkspace:{openSession:id=>{current={key:id};listeners.forEach(fn=>fn());document.getElementById('session').textContent=id}},
effect:fn=>effects.push(fn()),on:(name,fn)=>hooks[name]=fn};plugin.apply(ctx);
const h=React.createElement;ReactDOM.createRoot(document.getElementById('root')).render(h(React.Fragment,null,
h('aside',null,h('h1',null,'DSH · Bot fixture'),h(slots['sidebar.footer.action'],{wide:true})),
// Match rc.3's blank conversation: session header actions are hidden.
h('main',null,h(slots['conversation.hero.options']),h('p',{id:'session'},'Select Chief')),
h(slots['shell.overlay'])));
</script></body></html>`;
const server = createServer(async (req, res) => {
  try {
    if (req.url === '/api/ios-multi-bot') {
      const parts = []; for await (const part of req) parts.push(part);
      const response = await handleBotRequest(new Request('http://localhost/api/ios-multi-bot', {
        method: req.method, headers: req.headers, ...(req.method === 'POST' ? { body: Buffer.concat(parts) } : {}) }),
      { store, agents: { get: () => undefined }, openBot: id => store.byId(id) });
      res.writeHead(response.status, Object.fromEntries(response.headers)); res.end(await response.text()); return;
    }
    const paths = { '/client.js': resolve('app/JobTracking.bundle/multi-bot-client.js'),
      '/react.js': join(deps, 'react/umd/react.development.js'), '/react-dom.js': join(deps, 'react-dom/umd/react-dom.development.js') };
    res.setHeader('Content-Type', paths[req.url] ? 'text/javascript; charset=utf-8' : 'text/html; charset=utf-8');
    res.end(paths[req.url] ? await readFile(paths[req.url]) : html);
  } catch (error) { res.writeHead(500); res.end(error.message); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ headless: true, ...(process.env.DSH_BROWSER_CHANNEL ? { channel: process.env.DSH_BROWSER_CHANNEL } : {}) });
try {
  await mkdir('build/multi-bot-evidence', { recursive: true });
  for (const width of [1024, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 844 } });
    const errors = []; page.on('pageerror', error => { errors.push(error.message); console.error(error.stack); });
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.screenshot({ path: `build/multi-bot-evidence/initial-${width}.png` });
    await page.getByRole('button', { name: '进入 Chief', exact: true }).click();
    await page.getByRole('button', { name: '创建 Bot', exact: true }).click();
    const dialog = page.getByRole('dialog');
    await dialog.getByLabel('名称', { exact: true }).fill(`Writer-${width}`);
    await dialog.getByLabel('职责', { exact: true }).fill('帮助写中文文章');
    await dialog.getByRole('button', { name: '创建 Bot', exact: true }).click();
    await dialog.getByRole('button', { name: '进入 Bot', exact: true }).click();
    await page.getByRole('button', { name: `进入 Writer-${width}`, exact: true }).waitFor();
    const bot = (await store.list()).find(row => row.name === `Writer-${width}`);
    const blank = await store.memory(bot.id);
    await store.writeMemory(bot.id, '# 偏好\n使用中文。\n<script>window.bad=true</script>', blank.revision);
    await page.getByRole('button', { name: `查看 Writer-${width} 记忆`, exact: true }).click();
    await dialog.getByText('使用中文。', { exact: false }).waitFor();
    assert.equal(await page.evaluate(() => window.bad), undefined);
    await page.screenshot({ path: `build/multi-bot-evidence/memory-${width}.png` });
    await dialog.getByRole('button', { name: '清空记忆', exact: true }).click();
    await dialog.getByRole('button', { name: '确认清空', exact: true }).click();
    await dialog.getByText('（记忆为空）', { exact: true }).waitFor();
    assert.equal((await store.memory(bot.id)).content, '');
    await dialog.getByRole('button', { name: '关闭', exact: true }).click();
    await page.reload();
    await page.getByRole('button', { name: `进入 Writer-${width}`, exact: true }).click();
    await page.waitForFunction(id => document.getElementById('session').textContent === id, bot.sessionId);
    assert.equal(await page.locator('#session').textContent(), bot.sessionId);
    await page.screenshot({ path: `build/multi-bot-evidence/sidebar-${width}.png` });
    // A successful background list refresh must not erase an open-session error.
    await page.route('**/api/ios-multi-bot', async route => {
      if (route.request().method() === 'POST' && route.request().postDataJSON()?.action === 'open')
        return route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ error: '会话保存失败，请重试' }) });
      return route.continue();
    });
    await page.getByRole('button', { name: '进入 Chief', exact: true }).click();
    await page.getByRole('alert').getByText('会话保存失败，请重试', { exact: false }).waitFor();
    await page.waitForResponse(response => response.url().endsWith('/api/ios-multi-bot') && response.request().method() === 'GET');
    assert.match(await page.getByRole('alert').textContent(), /会话保存失败/);
    await page.getByRole('button', { name: '刷新', exact: true }).click();
    await page.getByRole('alert').waitFor({ state: 'hidden' });
    assert.deepEqual(errors, []);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await page.close();
  }
  console.log('MULTI_BOT_BROWSER_PASS: create, enter, text-only memory, clear, reload at 1024px and 390px');
} finally {
  await browser.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  await rm(home, { recursive: true, force: true });
}
