# 常见问题

## 这个项目来自哪里？

这是 [everettjf/dsh-ios](https://github.com/everettjf/dsh-ios) 的 fork，感谢原作者及
DeepSeek Harness、iSH / iSH-ARM64 等上游项目。当前维护仓库为
[wjc19980523-glitch/dsh-ios-ipa](https://github.com/wjc19980523-glitch/dsh-ios-ipa)。
本 fork 的功能和测试状态不代表上游项目的承诺。

## 分享 GitHub 链接，别人就能用吗？

别人可以查看和克隆公开源码。要在 iPad 上使用，还需下载未签名 IPA、自行签名安装，
并配置自己的模型 API Key。具体步骤见[安装说明](install-sign.md)。
本仓库不提供账号、签名证书或 API Key。

## Agent 在本地运行，为什么还要网络和 Mac？

Agent、会话、shell 和 Linux 工具在 iPad 内运行；模型推理请求发送到所配置的模型服务，
因此不是离线大模型。iOS 原生编译需要 macOS/Xcode，当前 IPA 使用 GitHub Actions 云端 macOS
构建。使用 Windows 下载和签名，不等于 iOS 编译不需要 macOS。

## 能在 iPad 本地把贪吃蛇编译成 iOS IPA 吗？

不能。内置环境是 Alpine Linux，没有 Xcode / iPhoneOS SDK。
`development_preflight` 会识别原生 iOS 开发环境不足。可以编辑源码、运行适配环境的
Web/脚本项目，随后将 iOS 项目交给外部 macOS 构建。

## 一键云端构建完成了吗？

没有。GitHub Actions 构建 DSH 本身的流程可用，但 App 内从项目提交到远端构建再取回 IPA
的一键流程尚未接入。实验草稿见 `experimental/cloud-build/`，不能作为已交付功能使用。

## Build 31 修复了什么？

修复 `output.render` 与 Harness 的参数契约不一致：使用 `render(args, value)` 读取工具执行结果，
避免把工具参数对象当成文本发送给模型。受影响入口包括 `development_preflight`、
`job_history`、`job_status`。已有异常历史消息不在修复范围；真机功能仍需验证。

## 大文件导出有多大？任务状态可信吗？

`workspace_export` 支持工作区文件分块传输、哈希验证和原生保存确认，单文件上限 512 MiB，
并受可用空间、超时与生命周期限制。原 `file_import` / `file_export` 的 8 MiB 限制不变。
任务历史与状态按会话隔离；无法确认完成的任务会标记 unknown，不会把静默、超时或重启
解释为成功。详见[导出说明](workspace-ipa-export.md)与[任务说明](task-tracking.txt)。

## 后台会一直运行吗？升级会修复全部历史会话吗？

不会承诺后台常驻，iOS 仍可能挂起或终止应用。任务元数据不是进程恢复机制。
Build 31 保持固定 RootFS，测试覆盖已知 Build 30 模块升级的数据保留边界；
这不意味着所有设备、签名方式及历史会话都已经验收。升级前备份，勿先卸载。

## 应该从哪里下载？

从 [Build 31 Pre-release](https://github.com/wjc19980523-glitch/dsh-ios-ipa/releases/tag/v1.1.0-build31) 的 Assets 下载 IPA。
原 Actions artifact 有保留期限，Release 附件不受该期限影响。重新构建仍依赖固定 RootFS
的可获取性，不能把附件可下载等同于构建依赖永久可用。详见[云构建说明](cloud-build.md)。

## 仓库里的测试证书是什么？

`tests/fixtures/web-transport/` 包含公开、无账号权限的自签名 TLS 证书及测试私钥，
只用于受控 HTTPS 测试，不是 Apple 签名材料，也不进入生产 App 资源或生产信任库。
其他测试中的 token/key 字样可能是虚构测试值。源码权限声明、变量占位符和测试数据
应与真实凭据区分；仍不要提交真实账号配置或签名文件。

## 使用什么许可证？

根目录 `LICENSE` 与 `LICENSE.md` 为相同 GPL-3.0 全文；上游附加说明和第三方声明保留在
[第三方声明](third-party-notices.md)与 `ish-arm64/LICENSE.IOS`。
