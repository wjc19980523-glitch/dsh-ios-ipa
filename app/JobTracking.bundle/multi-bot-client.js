// Hand-authored rc.3 client module; uses Harness slots and its conversation UI.
window.__ModuleLoader__.load({ id: 'dsh-host-bridge', factory: require => {
  const React = require('react');
  const { createElement: h, useState, useEffect, useRef, useSyncExternalStore } = React;
  const inject = ['slots', 'uiWorkspace', 'uiSession'];
  function apply(ctx) {
    let snapshot = { bots: [], notice: '', error: '', loadError: '', busy: false, dialog: null };
    let alive = true, revision = 0;
    const listeners = new Set();
    const publish = patch => { if (alive) { snapshot = { ...snapshot, ...patch }; listeners.forEach(fn => fn()); } };
    const subscribe = fn => { listeners.add(fn); return () => listeners.delete(fn); };
    const useModel = () => useSyncExternalStore(subscribe, () => snapshot);
    const useCurrent = () => useSyncExternalStore(ctx.uiSession.current.subscribe, ctx.uiSession.current.getSnapshot);
    async function api(body) {
      const response = await fetch('/api/ios-multi-bot', { credentials: 'same-origin', cache: 'no-store',
        signal: AbortSignal.timeout(20000), ...(body ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {}) });
      if (!response.headers.get('content-type')?.includes('application/json')) throw new Error('Bot 服务暂不可用，请回到前台后重试');
      const value = await response.json();
      if (!response.ok) throw new Error(value.error ?? 'Bot 操作失败');
      return value;
    }
    async function refresh() {
      const serial = ++revision;
      try { const result = await api(); if (serial === revision) publish({ ...result, loadError: '' }); }
      catch (error) { if (serial === revision) publish({ loadError: error.message }); }
    }
    async function action(fn) {
      if (snapshot.busy) return;
      publish({ busy: true, error: '' });
      try { await fn(); }
      catch (error) { publish({ error: error.message }); }
      finally { publish({ busy: false }); }
    }
    const showCreate = () => publish({ dialog: { kind: 'create' }, error: '' });
    const showMemory = bot => publish({ dialog: { kind: 'memory', bot }, error: '' });
    const enter = bot => action(async () => {
      const result = await api({ action: 'open', id: bot.id });
      if (alive) ctx.uiWorkspace.openSession(result.bot.sessionId);
      await refresh();
    });
    function Sidebar({ wide = true }) {
      const model = useModel(), current = useCurrent();
      return h('section', { className: 'ios-bots', 'aria-label': '我的 Bots' },
        h('div', { className: 'ios-bots-heading' }, wide && h('strong', null, '我的 Bots'),
          h('button', { type: 'button', onClick: showCreate, disabled: model.busy, 'aria-label': '新建 Bot', title: '新建 Bot' }, '+')),
        h('div', { className: 'ios-bots-list' }, model.bots.map(bot => h('div', { key: bot.id, className: 'ios-bots-row' },
          h('button', { type: 'button', onClick: () => enter(bot), disabled: model.busy,
            'aria-current': current.key === bot.sessionId ? 'page' : undefined, title: `${bot.name}：${bot.role}`,
            'aria-label': `进入 ${bot.name}`, className: 'ios-bots-enter' }, wide ? `${bot.isMain ? '◆ ' : '○ '}${bot.name}` : bot.isMain ? '◆' : bot.name.slice(0, 1)),
          wide && h('button', { type: 'button', onClick: () => showMemory(bot), 'aria-label': `查看 ${bot.name} 记忆`, title: '查看记忆' }, '记忆')))),
        wide && h('small', null, '仅前台运行 · 会话独立保存'),
        (model.error || model.loadError) && h('div', { role: 'alert', className: 'ios-bots-error' }, model.error || model.loadError,
          h('button', { type: 'button', disabled: model.busy, onClick: () => { publish({ error: '' }); void refresh(); } }, '刷新')));
    }
    function Header() {
      const model = useModel(), current = useCurrent();
      const bot = model.bots.find(row => row.sessionId === current.key);
      return bot ? h('div', { className: 'ios-bots-header', role: 'group', 'aria-label': `当前 Bot：${bot.name}` }, h('span', { title: bot.role }, bot.name),
        h('button', { type: 'button', onClick: () => showMemory(bot) }, '记忆'),
        bot.isMain && h('button', { type: 'button', onClick: showCreate }, '创建 Bot')) : null;
    }
    function CreateForm() {
      const [name, setName] = useState(''), [role, setRole] = useState('');
      const model = useModel();
      return h('form', { onSubmit: event => { event.preventDefault(); void action(async () => {
        const { bot } = await api({ action: 'create', name, role });
        await refresh(); publish({ dialog: { kind: 'created', bot } });
      }); } },
      h('h2', { id: 'ios-bot-dialog-title' }, '创建 Bot'),
      h('p', null, '为它取名并描述职责。创建后即可开始独立的长期会话。'),
      h('label', null, '名称', h('input', { autoFocus: true, required: true, maxLength: 40, value: name, onChange: e => setName(e.target.value) })),
      h('label', null, '职责', h('textarea', { required: true, maxLength: 1000, rows: 4, value: role, onChange: e => setRole(e.target.value) })),
      h('button', { type: 'submit', disabled: model.busy || !name.trim() || !role.trim() }, model.busy ? '正在创建…' : '创建 Bot'));
    }
    function Memory({ bot }) {
      const model = useModel();
      const [memory, setMemory] = useState(null), [error, setError] = useState(''), [confirm, setConfirm] = useState(false);
      useEffect(() => { let mounted = true; api({ action: 'memory', id: bot.id }).then(value => { if (mounted) setMemory(value); }, e => { if (mounted) setError(e.message); }); return () => { mounted = false; }; }, [bot.id]);
      return h(React.Fragment, null, h('h2', { id: 'ios-bot-dialog-title' }, `${bot.name} · Markdown 记忆`),
        h('p', null, bot.role), h('p', null, '可在聊天中说“记住……”来保存。清空仅影响此文件；聊天记录和当前上下文仍保留。'),
        error && h('p', { role: 'alert' }, error),
        memory ? h(React.Fragment, null, h('code', { className: 'ios-bots-path' }, memory.path),
          h('pre', { className: 'ios-bots-memory', 'aria-label': '记忆内容' }, memory.content || '（记忆为空）'),
          confirm ? h('div', null, h('p', null, '确认清空该 Bot 的记忆文件？此操作不可撤销。'),
            h('button', { type: 'button', disabled: model.busy, onClick: () => action(async () => {
              setMemory(await api({ action: 'clear', id: bot.id, revision: memory.revision })); setConfirm(false);
            }) }, '确认清空'), h('button', { type: 'button', onClick: () => setConfirm(false), disabled: model.busy }, '取消')) :
            h('button', { type: 'button', disabled: model.busy || !memory.content, onClick: () => setConfirm(true) }, '清空记忆')) : !error && h('p', null, '正在读取…'));
    }
    function Dialog() {
      const model = useModel(), ref = useRef(null);
      useEffect(() => { if (model.dialog && ref.current && !ref.current.open) ref.current.showModal(); }, [model.dialog]);
      if (!model.dialog) return null;
      const { kind, bot } = model.dialog;
      return h('dialog', { ref, className: 'ios-bots-dialog', 'aria-labelledby': 'ios-bot-dialog-title',
        onCancel: event => { event.preventDefault(); if (!model.busy) publish({ dialog: null }); } },
        kind === 'create' ? h(CreateForm) : kind === 'memory' ? h(Memory, { key: bot.id, bot }) :
          h('div', null, h('h2', { id: 'ios-bot-dialog-title' }, `${bot.name} 已创建`), h('p', null, bot.role),
            h('button', { type: 'button', disabled: model.busy, onClick: () => action(async () => {
              const result = await api({ action: 'open', id: bot.id });
              if (alive) ctx.uiWorkspace.openSession(result.bot.sessionId); publish({ dialog: null });
            }) }, '进入 Bot')),
        (model.error || model.loadError) && h('p', { role: 'alert' }, model.error || model.loadError),
        h('p', { className: 'ios-bots-notice' }, model.notice),
        h('button', { type: 'button', disabled: model.busy, onClick: () => publish({ dialog: null, error: '' }) }, '关闭'));
    }
    ctx.slots.inject('sidebar.footer.action', () => ctx.slots.register({ name: 'sidebar.footer.action', id: 'ios-bots', order: -100 }, Sidebar));
    ctx.slots.inject('conversation.session.header.actions', () => ctx.slots.register({ name: 'conversation.session.header.actions', id: 'ios-bots', order: -100 }, Header));
    // rc.3 hides session header actions until the first message. Keep the Bot
    // identity and Chief form available in that blank conversation's controls.
    ctx.slots.inject('conversation.hero.options', () => ctx.slots.register({ name: 'conversation.hero.options', id: 'ios-bots', order: -100 }, Header));
    ctx.slots.inject('shell.overlay', () => ctx.slots.register({ name: 'shell.overlay', id: 'ios-bots' }, Dialog));
    ctx.effect(() => {
      const style = document.createElement('style');
      style.textContent = `.ios-bots{width:100%;min-width:0;font-size:13px}.ios-bots-heading,.ios-bots-row,.ios-bots-header{display:flex;align-items:center;gap:6px}.ios-bots-heading{justify-content:space-between}.ios-bots-list{max-height:28dvh;overflow:auto}.ios-bots button,.ios-bots-header button,.ios-bots-dialog button{min-height:36px;padding:6px 10px;border:1px solid #8885;border-radius:8px;background:transparent;color:inherit;cursor:pointer}.ios-bots-enter{flex:1;overflow:hidden;text-overflow:ellipsis;text-align:left;white-space:nowrap}.ios-bots [aria-current=page]{background:#5b7fff30}.ios-bots small{display:block;opacity:.7;margin:6px 0}.ios-bots-dialog{box-sizing:border-box;color:inherit;background:Canvas;border:1px solid #8886;border-radius:16px;padding:20px;width:min(480px,calc(100vw - 32px));max-height:85dvh;overflow:auto}.ios-bots-dialog::backdrop{background:#0007}.ios-bots-dialog h2{font-size:19px;margin:0 0 12px}.ios-bots-dialog label{display:block;margin:12px 0}.ios-bots-dialog input,.ios-bots-dialog textarea{display:block;box-sizing:border-box;width:100%;margin-top:6px;padding:10px;border:1px solid #8888;border-radius:8px;background:transparent;color:inherit;font-size:16px}.ios-bots-dialog p{line-height:1.6;font-size:13px}.ios-bots-memory{white-space:pre-wrap;overflow-wrap:anywhere;padding:12px;background:#8881;max-height:32dvh;overflow:auto}.ios-bots-path{font-size:11px;overflow-wrap:anywhere}.ios-bots-error{color:#b33;overflow-wrap:anywhere}.ios-bots-notice{opacity:.7}.ios-bots button:disabled,.ios-bots-header button:disabled,.ios-bots-dialog button:disabled{cursor:default;opacity:.55}`;
      document.head.append(style);
      const refreshVisible = () => { if (document.visibilityState !== 'hidden' && !snapshot.busy) void refresh(); };
      const timer = setInterval(refreshVisible, 5000);
      document.addEventListener('visibilitychange', refreshVisible);
      window.addEventListener('focus', refreshVisible);
      void refresh();
      return () => { alive = false; clearInterval(timer); style.remove(); document.removeEventListener('visibilitychange', refreshVisible); window.removeEventListener('focus', refreshVisible); listeners.clear(); };
    });
    ctx.on('connection/reset', refresh);
  }
  return { inject, apply };
} });
