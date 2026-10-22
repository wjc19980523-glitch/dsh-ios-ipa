# Changelog

本仓库 fork 自 [everettjf/dsh-ios](https://github.com/everettjf/dsh-ios)，感谢原作者和上游贡献者。
本文件记录本 fork 从 1.0.16 到 1.1.0 Build 31 的变化，不把源码实现等同于真机验收。

## 1.1.0 (31) — Hotfix 测试候选 — 2026-10-22

### 相对 1.0.16 的主要变化

- 新安装默认使用中文 Harness 界面，保留用户已有语言配置；更新 Harness 与模型配置。
- 增加会话范围内的任务历史、任务状态和 Activity 状态跟踪；未知状态不再被当作成功。
- 增加 `development_preflight`，说明 Linux guest 不能本地编译原生 iOS App。
- 增加 `workspace_export`：工作区文件分块传输、SHA256 验证、确认保存及有边界的恢复检查点，
  单文件最高 512 MiB；保留原有小文件导入/导出接口。
- 改进 Harness 认证、启动就绪判断、会话生命周期、前后台恢复与诊断记录。
- 增加传输、原生升级、任务及导出相关回归检查与 GitHub Actions 构建流程。

### Build 31 P0 修复

- `output.render` 改为遵循 `render(args, value)`，避免工具参数对象进入模型请求的文本字段。
- 添加真实工具执行 → render → 工具结果消息 → 模型适配器序列化链测试。
- 升级清单识别已知 Build 30 模块哈希；未知版本拒绝覆盖，保留会话、配置与工作区。
- 版本号更新为 1.1.0 (31)，保留固定 RootFS。

### 交付及验证边界

- 候选源码：`c91549133e103844e5354be8849bf517f23b1322`；P0 修复基础：`12e123c`。
- [Actions 构建与证据](https://github.com/wjc19980523-glitch/dsh-ios-ipa/actions/runs/39781925031)：
  P0 链 13/13、原生升级 2/2、原生归档及实际 IPA 完整性通过，无跳过。
- 未变化的既有测试复用先前证据；本次 Hotfix 不以全量 guest/UI 回归作为交付门禁。
- 未签名、未发布稳定版，iPad 真机功能仍待验收。不承诺修复旧会话历史消息。
- App 内一键云构建未完成；仓库中的独立实验草稿未进入 Build 31。

## Build 31 仓库整理 — 2026-10-23

- 将现有 1.1.0 开发历史并入 main，保留原提交历史。
- 更新中英文入口、安装签名/云构建/FAQ 文档，补充上游致谢与能力边界。
- 保留未接入的云构建源码到 `experimental/cloud-build/`，防止进入应用资源包。
- 同步 GPL-3.0 许可文件，保留第三方声明；清理个人路径及固定开发者 Team ID。
- 更新版本元数据。此整理不重新签名、安装或替换上述已交付候选 IPA。

## 1.0.16 (18) — 历史版本

原有版本记录保留在 [releases/1.0.16-build18.json](releases/1.0.16-build18.json)，
包括该版本的提交和 IPA 校验值；不将旧记录改写成 Build 31。
