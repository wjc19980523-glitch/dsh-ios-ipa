# DSH iOS — 1.1.0（Build 31）

本仓库 **fork 自 [everettjf/dsh-ios](https://github.com/everettjf/dsh-ios)**。
感谢 Everett 和上游贡献者提供原始 iOS 集成，也感谢 DeepSeek Harness、iSH / iSH-ARM64、
Alpine Linux 及其他依赖项目。本 fork 的维护仓库为
[wjc19980523-glitch/dsh-ios-ipa](https://github.com/wjc19980523-glitch/dsh-ios-ipa)。

[English](README.md) · [更新记录](CHANGELOG.md) · [云端构建](docs/cloud-build.md) ·
[签名安装步骤](docs/install-sign.md) · [常见问题](docs/faq.md)

DSH 在 iPad/iPhone App 中运行 Alpine Linux guest 与 DeepSeek Harness。
Agent、会话和 shell 在设备上运行，模型推理请求发送到所配置的在线 API。
**iOS 安装包由 GitHub Actions 的云端 macOS/Xcode 编译，产物是未签名 IPA，需要自行签名安装。**
要求 iOS/iPadOS 16 或更高版本。

> **当前状态：** Build 31 是 Hotfix 测试候选，非稳定版。P0 消息链、两项原生升级兼容性、
> 真机架构归档和 IPA 完整性门禁已通过，最终 iPad 真机功能仍待验收。
> 本版不修复旧会话里已经保存的异常历史消息。

## 本版改动

- 新安装的 Harness 界面默认中文，已有语言设置继续保留。
- 增加会话隔离的任务历史、任务状态（`job_history`、`job_status`）和更明确的 Activity 状态。
- 增加只读开发预检，明确提示原生 iOS 编译需要 macOS/Xcode。
- 增加大文件工作区导出 `workspace_export`：分块传输、哈希校验、原生保存确认，
  单文件最高 512 MiB，仍受存储和生命周期限制；保留原 8 MiB 小文件接口。
- 改进 Harness 认证、启动、前后台生命周期及诊断，补充相关回归测试。
- Build 31 修正 `output.render(args, value)` 参数契约，避免把工具参数对象作为文本结果发给模型。

从 1.0.16 到 1.1.0 的变化和验收边界见 [CHANGELOG.md](CHANGELOG.md)。

## 已知限制

- **iPad 本地不能编译原生 iOS App。** 内置 Linux guest 没有 Xcode / iPhoneOS SDK。
- **App 内一键云端构建尚未完成。** `experimental/cloud-build/` 是未接入草稿，不在 Build 31 资源包中；
  维护者手动运行 GitHub Actions 是另一条流程。
- iOS 仍可能挂起或终止 App；任务历史不等于后台常驻或进程恢复。
- 分享仓库不包含模型 Key、Apple 签名账号或证书，也不等于别人下载后即可直接安装。

## 快速开始

1. 打开 [Build 31 Pre-release](https://github.com/wjc19980523-glitch/dsh-ios-ipa/releases/tag/v1.1.0-build31)，
   在 Assets 中下载 `DSH-1.1.0-build31-unsigned.ipa`。
2. 按照[版本记录](releases/1.1.0-build31.json)核对 IPA 的 SHA256。
3. 按[签名安装步骤](docs/install-sign.md)，使用自己的账号和签名工具，连接并信任 iPad，
   签名安装后按系统提示启用开发者模式。
4. 覆盖升级前备份，保留原 App 和签名身份；首次使用在 DSH 内配置自己的模型 Key。

该下载是未签名 Pre-release 测试候选，最终 iPad 真机功能仍需验收。
两条工作流和固定 RootFS 的获取限制见[云端构建说明](docs/cloud-build.md)。

## 克隆与源码构建

```bash
git clone https://github.com/wjc19980523-glitch/dsh-ios-ipa.git
cd dsh-ios-ipa
```

原生编译需要 macOS、合适的 Xcode 和模拟器工具链；可使用云端流程，
或按照[本地 Mac 构建步骤](docs/install-sign.md#3-使用自己的-mac-从源码构建)操作。
仓库不提供开发者证书或账号凭据，自己的签名 profile 必须与启用的 entitlement 匹配。

`docs/` 中原有截图与导览属于上游参考资料，不作为 Build 31 的真机验收证据。

## 工作原理

```
┌─ DSH.app ────────────────────────────────────────────────────────┐
│  DSHRootViewController ──► WKWebView ──► http://127.0.0.1:3080    │
│         │                                        ▲                │
│  DSHHarness  (选端口 · 就绪探测 · 重启 · 健康检查)                │
│         │  ISHShellExecutor                      │ 回环           │
│  ┌──────▼──── iSH-ARM64 模拟器 (Alpine 3.21 aarch64) ─────────┐   │
│  │  /usr/local/bin/dsh-serve                                  │   │
│  │    → node --expose-internals @deepseek-ai/dsh web          │   │
│  │        --host 127.0.0.1 --port N  ─────────────────────────┘   │
│  └────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

- **模拟器。** iSH-ARM64 是用户态 Linux 模拟器（Asbestos threaded-code 解释器 + AArch64 guest 后端）。
  guest 的 socket 直通宿主 socket，所以 dsh 监听的回环端口在 app 的 WebView（以及 Safari）里都能访问。
- **Guest 镜像。** `scripts/build-rootfs.sh` **在 Mac 上用同一个模拟器**构建 `root.tar.gz`：Alpine
  minirootfs → `apk add nodejs npm …` → 把 `rootfs/staging` 里锁定版本的 npm 依赖树（在宿主上按
  linux/arm64/musl 安装）放进去 → 为 musl 重新编译 `node-pty` → 叠加 overlay → 用 `unfakefsify` 导出。
  `rootfs/overlay` 包含入口脚本 `dsh-serve`、guest 自检脚本，以及 `cordis.patch.yml`——dsh 的 profile
  层，用来关闭逐命令沙箱（整个 guest 本身就是沙箱）并定义 `guest-ask` 权限预设。
- **监督器。** `DSHHarness` 选一个空闲回环端口，通过 `ISHShellExecutor` 启动 `dsh-serve`，轮询直到 HTTP
  可用，崩溃时重启，并把状态发布给 UI。`DSHRootUpgrader` 每次启动都比对内置镜像的 SHA-256 与已导入的
  root，不一致时导入新镜像并迁移用户数据。

### 对模拟器的改动（`ish-arm64`，vendored 自 OpenMinis/ish-arm64）

| 改动 | 原因 |
|---|---|
| 新增 `FCVTL/FCVTL2`、`FCVTN/FCVTN2`、`FCVTXN/FCVTXN2` 及向量定点转换 `SCVTF/UCVTF/FCVTZS/FCVTZU #fbits` gadget | libvips（dsh 图片附件插件 `sharp` 用到）会在这些指令上触发非法指令 |
| 修复 `FMOV (scalar, immediate)` 解码 | imm8 的 bit 6 未取反，`2.25`、`31.0` 这类常量在 guest 里全部算错 |
| `waitpid()` 不再在 1 秒有界等待超时时误返回 `EINTR` | 曾导致 gcc/g++（`failed to get exit status`）、node-gyp 以及任何等待子进程超过 1 秒的程序失败 |
| 返回真实 `Response` 对象的流式 `fetch()` polyfill（`app/RootfsPatch.bundle`） | undici 的 LLM 流式（SSE）需要 WebAssembly，而 jitless V8 没有 |
| `ISHShellExecutor` 返回 shell 退出码并在进程退出后排空管道；`ContainerURL()` 在没有 app group 时回退；部署目标 15.0 | app 集成需要 |

vendored 副本的上游 commit 记录在 [`ish-arm64/UPSTREAM.md`](ish-arm64/UPSTREAM.md)；这些修复相互独立，欢迎回馈上游。

## 测试

```bash
make test               # 在这台 Mac 上无人值守：模拟器 + rootfs + 模拟器上的 XCTest/XCUITest
make test-device-unit   # 连接的 iPad 上跑单元测试 + guest 集成测试
make test-device        # 再加 UI 测试（需先在 iPad 设置 ▸ 开发者 中打开 UI Automation）
```

| 套件 | 覆盖内容 | 运行环境 |
|---|---|---|
| `tests/emu-test.sh` | 新增的 NEON gadget 与 FMOV 修复（在 guest 里用 gcc 编译的 C 测试）、`waitpid` 回归、fetch polyfill（宿主 node，11 项） | macOS |
| `tests/rootfs-test.sh` | 像 app 一样导入 `root.tar.gz`、guest 自检（node-pty/koffi/ripgrep/sharp）、profile patch、**通过 mock DeepSeek SSE 服务器的 headless 完整对话回路**、`dsh-serve` 本机可达 | macOS |
| `DSHTests`（XCTest，宿主在 app 内） | 端口分配、日志环、就绪探测、监督器状态机（假 launcher + 本地 HTTP 服务器）；host bridge 的认证/能力开关/限流；guest 集成：真实服务响应、`dsh-selftest`、node/dsh 版本、镜像簿记、**用 app 内 mock 模型跑完整一轮 agent 对话并通过 bridge 调用 `device_info`** | 模拟器 / 真机 |
| `DSHUITests`（XCUITest） | 启动到 DeepSeek Harness 界面、状态栏端口、服务日志页、终端页、横屏布局 | 模拟器 / 真机 |

Build 31 已通过的 Hotfix 门禁为：13 项消息链、2 项原生升级测试、未签名真机归档和 IPA 完整性。
未变化的宿主测试复用已有证据，不代表重新完成全量或真机验收。详见[云构建证据](docs/cloud-build.md)。

## 目录结构

```
DSH.xcodeproj   生成的 Xcode 工程（target：DSH、DSHTests、DSHUITests；scheme：DSH）
app/            Objective-C 源码、AppDSH.xcconfig、Info.plist、素材、启动页、隐私清单
rootfs/         打进 guest 镜像的 overlay + 锁定版本的 npm 清单（staging/package.json）
scripts/        build-rootfs.sh · gen-xcode-project.rb
tests/          emu-test.sh · rootfs-test.sh · mock-deepseek.mjs · fetch-polyfill-test.mjs
                emu/（guest 内 C 测试）· DSHTests/ · DSHUITests/
docs/           截图
build/          生成物：root.tar.gz、工作目录、xcresult（已 gitignore）
ish-arm64/      模拟器（vendored，见其 UPSTREAM.md）
site/           上游遗留网站源码（不作为本 fork 下载入口）
```

`DSH.xcodeproj` 由 `scripts/gen-xcode-project.rb`（`make project`）生成，增删源码文件后重新运行即可。
所有构建设置在 `app/AppDSH.xcconfig`；bundle id 为 `com.xnuapp.dsh`（自己构建请改 `DSH_BUNDLE_ID_PREFIX`）。

## iOS 能力（host bridge）

app 内运行一个 loopback HTTP 服务，guest 里的 dsh 工具通过它访问 iOS 能力。已落地：

| 工具 | 作用 | 开关 |
|---|---|---|
| `device_info`、`device_power` | 型号、iOS 版本、地区、电量、温度 | 默认开启 |
| `calendar_query`、`reminders_query` | 日历事件、提醒事项 | 开关 + iOS 授权 |
| `health_query` | 步数/距离/能量、心率、睡眠、运动记录 | 开关 + iOS 授权 |
| `location_query` | 单次定位，附带精度——不做持续跟踪 | 开关 + iOS 授权 |
| `contacts_search` | 按姓名查联系人（没有"列出全部"的接口） | 开关 + iOS 授权 |
| `notify` | 长任务完成时发通知，每小时上限 10 条 | 开关 + iOS 授权 |
| `file_import` | 你挑一个文件交给 agent | 文件选择器本身即确认 |
| `calendar_create_event`、`reminders_create` | 新建事件/提醒 | **每次都问** |
| `file_export` | 从 DSH 导出文件 | **每次都问** |
| `photo_import` | 一张照片，由你在系统选择器里挑 | 开关（选择器即为门） |
| `share` | 把文本交给 iOS 分享面板 | 开关 + 每次确认 |
| `shortcut_run` | 运行你的某个快捷指令 | **每次都问** |

照片和分享已完成设计但尚未实现——每加一个能力 = app 侧一个路由 + guest 插件里一个 tool。
剪贴板**整个不做**：读取会让 iOS 每次都打断用户（跨来源读取必须确认，没有 API 能绕开），
写入虽然不弹窗，但也一并去掉了——不值得为这点便利留下一个最坏情况是"agent 悄悄换掉了
你正要粘贴的内容"的工具。

所有会**改变**东西的操作都会先问，而且弹窗里写的是具体后果（"添加提醒？'买牛奶'，
周五到期，在'家庭'列表"），不是能力名称。没人应答的确认会被拒绝而不是一直挂着；
DSH 在后台时到达的调用直接拒绝，而不是排队一个你看不见的弹窗；连续调用也不会把
弹窗叠成一摞。

**默认全部开启**，在 **⋯ ▸ Capabilities** 里逐个关闭。开关打开不代表数据就流得出去：
读操作仍然要过 iOS 自己的授权框（agent 第一次调用时弹出），写操作仍然每次都问。开关
对 agent 的下一次工具调用即刻生效（回合中途也算）。任一道门没开时
调用会返回可恢复的 `permission_denied`，告诉模型需要用户做什么，而不是卡在系统弹窗上等。

agent 做的每件事都会被记录：每次能力调用、每次你回答的确认框，以及它在 guest 里跑过的
每个工具（包括完全不碰 iOS 的那些）。**⋯ ▸ Activity** 是时间线；每个开关下面会显示上次
使用时间；有能力刚被用过时，顶栏会亮一下。参数只记一行摘要，读操作**返回的内容一律不记**
——所以这份记录本身是可以放心保留和分享的。

Apple Health 有个值得注意的地方：iOS 从不告诉 app **读**权限是否被拒绝，所以"没有数据"
和"被拒绝"长得一模一样。因此 Health 的返回里会带一条说明，并要求模型如实转述，而不是
直接断定你这个月一步没走。

能力由 app 把关，而不是 guest：每次启动随机生成的 bearer token 挡住**其他 app**，
而每个能力的开关（敏感能力还要原生确认）才是约束 **agent** 的手段——agent 在 guest
里是 root，能读到我们放在那里的任何秘密。每次调用都会记录到「服务日志」。

协议、安全模型与能力/权限矩阵见 [docs/host-bridge.md](docs/host-bridge.md)；
已完成的部分和后续计划见 [docs/roadmap.md](docs/roadmap.md)。

## 常见问题

详见 [FAQ](docs/faq.md)：签名安装、本地与云端编译、任务与导出限制、模型凭据、测试证书和未完成的一键云构建。

## 参与贡献

欢迎 issue 和 PR。提 PR 前请先跑 `make test`（需要 Apple Silicon Mac + Xcode）；改动模拟器时请在
`tests/emu/neon_convert_test.c` 或 `tests/emu-test.sh` 里补上用例。升级内置的 dsh：修改
`rootfs/staging/package.json`，执行 `make rootfs`，再 `make test-rootfs`。

## 致谢

- [everettjf/dsh-ios](https://github.com/everettjf/dsh-ios) —— 原始项目与上游实现。

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) —— agent harness 本体（MIT）。
- [iSH](https://github.com/ish-app/ish) 与 [iSH-ARM64](https://github.com/OpenMinis/ish-arm64) —— 本 app 所依赖的模拟器（GPLv3）。
- [libarchive](https://github.com/libarchive/libarchive)、[hterm](https://chromium.googlesource.com/apps/libapps/)、[Alpine Linux](https://alpinelinux.org)。

## 许可证

**GPL-3.0。** DSH 编译并静态链接了 GPLv3 的 iSH / iSH-ARM64 模拟器，因此整个 app 以 GPLv3 发布；iSH
在 [`ish-arm64/LICENSE.IOS`](ish-arm64/LICENSE.IOS) 中关于 App Store 的附加条款同样适用。全文见
[LICENSE](LICENSE)，第三方声明（libarchive、hterm、DeepSeek Harness、Alpine 软件包）见 [第三方声明 / Third-party notices](docs/third-party-notices.md)。

本项目与 DeepSeek 及 iSH 项目无隶属关系。
