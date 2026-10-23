# 云端构建与 Build 31 候选包

本仓库 fork 自 [everettjf/dsh-ios](https://github.com/everettjf/dsh-ios)。
DSH 的 iOS 原生程序由 **GitHub Actions 的云端 macOS + Xcode** 编译。
iPad 内的 Alpine Linux guest 可以运行 Agent、shell 和适配 Linux 的工具，
但不能在本地用 Xcode / iPhoneOS SDK 编译 iOS App。

## 下载已经完成的 Build 31

- 版本：1.1.0 (31)，未签名 Hotfix 测试候选，非稳定版。
- [成功构建记录](https://github.com/wjc19980523-glitch/dsh-ios-ipa/actions/runs/39781925031)
- [Pre-release 下载](https://github.com/wjc19980523-glitch/dsh-ios-ipa/releases/tag/v1.1.0-build31)
- [原构建 artifact（溯源）](https://github.com/wjc19980523-glitch/dsh-ios-ipa/actions/runs/39781925031/artifacts/12428440122)
- artifact 名称：`DSH-Build31-unsigned-hotfix-candidate`。
- 源码提交：`c91549133e103844e5354be8849bf517f23b1322`。
- [版本、大小与 SHA256](../releases/1.1.0-build31.json)。SHA256 对应解压后的 IPA，不是外层 artifact ZIP。

优先从 Pre-release 页面 Assets 下载带版本号的 IPA，无需解压 Actions ZIP。
Release 附件与原 Actions 构建产物哈希一致，不受原 artifact 保留期限影响。
原 Actions artifact 仅作为构建溯源，预计于 2026-11-21 UTC 到期。
本仓库的 `releases/` 保存版本元数据，不存放 150 MB 的 IPA 二进制。
签名与安装步骤见 [install-sign.md](install-sign.md)。

## 两条工作流的区别

| 工作流 | 用途 | 条件 |
|---|---|---|
| `build31-hotfix.yml` | 固定 Build 31 紧急候选 | 13 项 P0 消息链、2 项原生升级测试、真机归档、实际 IPA 完整性均须通过 |
| `build-ipa.yml` | 原有完整 CI，手动可选打包 | 保留原有完整测试；手动设置 `build_ipa=true` 才请求 IPA |

本次候选是在 `feature/workspace-ipa-export` 的上述固定提交构建的，后续 `main` 文档整理
不会改变已经交付的 IPA。Hotfix 的 scope 门禁只允许其固定修复范围，**不能将整理文档后的
main 随意用于重新运行该 Hotfix**；会按设计拒绝。复现该候选须使用上述确切提交，
或仍指向它的原构建分支。不要放宽门禁来让不同源码冒充同一候选。

## 在自己的 fork 上构建

1. Fork 本仓库，进入 Actions 并按 GitHub 提示启用工作流。
2. 选择 `DSH CI (tests; optional unsigned IPA)`，点击 Run workflow，选择要构建的分支。
3. 选择工作流提供且可用的 macOS runner；需要打包时勾选 `build_ipa`。
4. 等待所选工作流的全部必要门禁成功，再下载该运行的 IPA artifact 和日志。
5. 核对版本、源码提交及校验值，按安装文档自行签名。CI 不需要提交 Apple 账号或签名证书。

GitHub runner、配额、Xcode 可用性和依赖下载会影响构建。当前固定 RootFS 的恢复逻辑
依赖已验证的原始 artifact 或缓存；若原始 artifact 到期或无权限，构建会失败，
不会偷偷重建或替换 RootFS。维护者需另行提供经过核验的长期保存来源，才可保证长期复现。
当前 Build 31 的 RootFS SHA256 为
`d3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0`。

## 尚未完成的部分

“在 DSH 里说一句话，就自动提交项目、调用云端构建、取回 IPA”的产品流程尚未完成。
`experimental/cloud-build/` 保存未接入草稿和相关测试；它们不在 Build 31 的资源包中，
也不代表 App 已具备可用的一键云构建入口。现阶段由维护者在 GitHub Actions 手动构建。

Build 31 的 P0 门禁使用真实 Harness 工具结果与模型适配器序列化链，模型 HTTP 端使用
受控本地服务器；不是生产 DeepSeek 服务验收。完整 guest/UI 回归不是本次 Hotfix 的交付门禁，
真机运行、系统文件保存与签名安装仍需要设备验证。旧会话中的历史异常消息不在修复范围。
