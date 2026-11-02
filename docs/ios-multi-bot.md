# iOS 多 Bot MVP

这是 dsh-ios 自研的薄层：Chief、每 Bot 一个长期 DSH Session、独立职责和 Markdown 记忆。
只参考 [DS-Bot 的产品架构](https://github.com/Fei2411/DS-Bot)，未复制、合并或安装其插件代码。
不宣称兼容官方 ds-bot 插件；没有群聊 @、Bot 交接、Capabilities 商店、桌面数据互通或 Superagent。
本分支基于 `upgrade/harness-0.2.1-rc.3` 的 `0fbc7b8`。

## 使用

1. 打开 App，完成原有首次启动提示，在侧边栏“我的 Bots”进入 Chief。
2. 点“+ / 新建 Bot”，或在 Chief 会话标题旁点“创建 Bot”，填写名称和职责。
3. 也可直接对 Chief 说：“创建一个名为作家的 Bot，负责润色中文文章。”Chief 调用 `ios_bot_create`；列表最多约 5 秒刷新。
4. 点击 Bot 回到同一个长期会话；原生 Harness 聊天、模型选择、工具权限与停止按钮仍然适用。
5. 点侧边栏或会话标题的“记忆”读取 Markdown。可在聊天中明确要求“记住……”，由 Bot 使用记忆工具保存。
6. 清空记忆需在界面再次确认；运行中的 Bot 需先停止。清空只影响该文件，不删除聊天记录，也不消除当前上下文中已出现的事实。

## 入口和安装

`app/DSHRootViewController.m` 的 WKWebView 加载 `DSHHarness` 监督的 iSH guest `dsh web`。
没有新增 WebView、常驻服务或另一个模型后端。

`DSHBootCoordinator` 在启动 Harness 前，通过现有 `DSHSessionLifecycleInstaller` 校验并安装
`app/JobTracking.bundle/multi-bot-{store.mjs,client.js}` 和 `multi-bot.mjs`。
独立的 `multi-bot-manifest.json` 只允许修改固定 host-bridge `package.json`，声明 rc.3 的浏览器模块；
资源写入、fsync 和校验成功后才提交描述文件。随后原有 JobTracking 安装器更新导入 Bot 模块的控制器，允许从 Build 32 的已知哈希升级。
若安装中断或发现未知系统文件则停止启动，不覆盖用户文件。无需重建已固定的 rootfs，也不修改第三方包源码。

客户端通过 Harness 的 `sidebar.footer.action`、`conversation.session.header.actions`、`shell.overlay` 插槽注册。
进入 Bot 调用 `uiWorkspace.openSession(sessionId)`，继续使用现有聊天界面。
`/api/ios-multi-bot` 通过 `connection.fetch.register` 注册，复用 Harness 的启动 token / 会话 cookie 和同源校验，
没有直接暴露未认证的 webServer 路由。新增 API 不接受任意文件路径。

## 数据与会话

默认根目录为 `/root/.dsh/ios-multi-bot`（设置 `DSH_HOME` 时位于该目录下）：

```text
bots.json
<UUID>/memory.md
<UUID>/workspace/
```

`bots.json` 为数组，每项包括：

| 字段 | 含义 |
| --- | --- |
| `id` | UUID，不由名称拼路径 |
| `name` | 1–40 字符，名称不区分大小写唯一 |
| `role` | 1–1000 字符职责 |
| `sessionId` | `ios-bot-<UUID>`，创建后不变 |
| `memoryPath` | 固定的 `<根>/<UUID>/memory.md` |
| `isMain` | 仅自动创建的 Chief 为 true |
| `sessionReady` | 首次会话已落盘，用于区分尚未使用与会话文件丢失 |

创建 Bot 只保存目录和清单，不启动模型。首次进入时创建指定 ID 的 DSH 会话并等待 persistence flush，之后检查并打开同一 ID。
**不能每次切换都调用 `session.create`**：rc.3 对已经开始聊天的会话可能分配一个新 ID。
已使用 Bot 的会话若丢失、目录不匹配或读盘失败，会显示错误，不悄悄替换成空白会话。

每次模型提示词装配都按 agent/session ID 查找 Bot，附加名称、职责、约定目录和当前记忆。
普通会话不获得 Bot 工具；仅 Chief 的提示词提供创建工具，服务端也检查真实执行者，参数不能冒充 Chief。
所有 Bot 可读取/写入自己的记忆。Markdown 以引用数据加入提示词，界面仅显示文本，不执行 HTML。

清单写入使用串行队列、临时文件、fsync、rename；损坏 JSON 不会自动初始化覆盖。
相同名称和职责的创建重试返回原 Bot。记忆写入/清空比较内容 revision，拒绝过期覆盖。
最多 24 个 Bot（包括 Chief），每份记忆最多 16 KiB；不将完整会话复制到清单或内存文件中。
当前只支持单个 App 监督的 Harness 实例。不要并行启动多个进程修改同一清单。

工作目录和记忆分区是产品约定，**不是 Bot 之间的安全沙箱**。现有 guest 内的 bash/文件工具仍可能访问其他目录。
不要在记忆中保存密钥。此 MVP 没有 Bot 删除/重命名、自动记忆提炼或会话重建功能。

## 持久化和 iOS 限制

- 同一安装内，清单、已完成写入的记忆和 Harness 已落盘的会话保存在 App 的 guest 文件系统，不依赖 WebView localStorage。
- 普通页面重载或 App 重开会重新读取清单。已有 rootfs 升级流程迁移整个 `/root/.dsh`，因此包含此目录。
- 挂起、锁屏、强杀或内存回收可能中断模型流、工具和网络连接。尚未落盘的尾部输出可能丢失；“持久化会话”不等于“后台继续执行”。
- 回到前台后用户主动续聊；本薄层不自动重发消息、重做工具或恢复进程。既有 Harness 生命周期和会话恢复机制仍决定日志恢复边界。
- 切换 Bot 不等于停止旧 Bot。请用原有停止按钮结束工作，避免同时运行多个重任务。每个打开过的会话仍可能占用 Harness 内存；24 个清单条目不是 24 个并行运行承诺。
- 卸载 App、清除 guest 数据、失败的外部备份恢复可能丢失数据。这里没有云同步或跨设备备份承诺。
- iOS 真机的 jetsam、锁屏和资源压力必须单独验收，桌面浏览器和模拟器结果不能替代。

## 自动测试

准备 rc.3 原始镜像为 `build/root.tar.gz`，只使用 `rootfs/harness-0.2.1-rc.3-image.json` 中固定的哈希：

```sh
python3 tests/multi-bot-prepare.py
python3 tests/job-tracking-prepare.py --fixtures build/job-tracking-fixtures
node --test tests/multi-bot-test.mjs tests/multi-bot-runtime-test.mjs tests/job-ledger-test.mjs
python3 tests/workspace-export-app-test.py
```

测试覆盖 Chief 初始化、并发创建/重试、跨重启身份、记忆隔离与清空、过期写入、大小/数量限制、损坏文件保留、
符号链接拒绝、已有会话不重复创建、缺失会话报错、真实 rc.3 提示词/工具身份检查。
Native XCTest 验证生产 bundle 安装顺序、幂等和失败重试；UI XCTest 在真实 iSH + WKWebView 中验证 Chief、表单创建、
记忆查看、切换和杀 App 后列表恢复。`.github/workflows/multi-bot-mvp.yml` 执行这些门禁并保存 xcresult。

## 人工验收清单

- [ ] iPad 和 iPhone 侧边栏可操作；横竖屏、键盘、深色模式和长名称不遮挡控件。
- [ ] Chief / Bot A / Bot B 各聊两轮，交替切换，不串会话；重开 App 后继续原聊天。
- [ ] Chief 一句话创建成功；新 Bot 出现在列表，职责正确；普通 Bot 无法调用创建工具。
- [ ] A、B 保存不同记忆；界面与下一轮提示词分别读取；清空 A 后 B 保持不变；聊天历史仍在。
- [ ] 在回复中锁屏/切后台，随后返回：检查中断状态，不重复提交副作用工具。
- [ ] 强杀 App、模拟器 terminate、真机内存压力回收后，区分已保存与尾部未保存输出，不宣称任务完成。
- [ ] 从 Build 32 覆盖安装后，旧会话/设置保留，Chief 只初始化一次；不要卸载旧 App 来模拟升级。

截至本分支初次实现，本地 WSL 存储/回归 30 项、真实 rc.3 装配 1 项通过。模拟器及浏览器证据随实际执行结果更新；真机验收尚未完成。

## 许可

保留仓库 `LICENSE`、`LICENSE.md` 与 `docs/third-party-notices.md` 的既有许可及第三方说明。
本次自研薄层不改变 iSH/GPL 相关代码的分发要求，也不引入 DS-Bot 源码或其桌面数据格式。
