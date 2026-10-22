# 下载、签名与安装

当前版本为 **1.1.0 (31) unsigned Hotfix 测试候选**，支持 iOS/iPadOS 16 及以上的
相应设备架构。它由 GitHub Actions 的云端 macOS 编译，**未附 Apple 签名或描述文件**。
下载或分享仓库不等于已经能直接安装 IPA。

## 1. 下载并校验

从 [Build 31 成功构建](https://github.com/wjc19980523-glitch/dsh-ios-ipa/actions/runs/39781925031)
的 Artifacts 下载 `DSH-Build31-unsigned-hotfix-candidate`，解压得到
`DSH-1.1.0-build31-unsigned.ipa`、SHA256 文件和构建记录。

在下载目录执行其中一条：

```powershell
# Windows PowerShell
Get-FileHash .\DSH-1.1.0-build31-unsigned.ipa -Algorithm SHA256
```

```bash
# macOS
shasum -a 256 DSH-1.1.0-build31-unsigned.ipa
```

应为：

```text
e0e73f9f2c94755eec14b71d1dfa32b96bd59fe63c7bbc76bdf820b4ae496685
```

该值只适用于当前未签名 IPA；自行重新构建或签名后，文件哈希会改变。

## 2. 自行签名安装

一种可用的工具路径是 Windows/macOS 上的 [Sideloadly 官方版本](https://sideloadly.io/)。
工具、账号和系统兼容性以其[官方说明](https://sideloadly.io/faq)为准，
本项目尚未完成所有签名工具的真机兼容性验收。

1. 备份现有重要会话和工作区。升级时保留原 App，不要先卸载或重置数据。
2. 安装签名工具及其要求的 Apple 设备驱动；连接并解锁 iPad，确认“信任此电脑”。
3. 在工具中选择 iPad，导入已校验的 IPA，使用你自己的 Apple 账号完成签名和安装。
4. 覆盖安装时沿用原签名账号和 Bundle ID；不同身份可能无法覆盖或会形成另一份 App。
5. 按系统提示，在“设置 → 隐私与安全性”启用开发者模式并完成重启确认；
   若出现未受信任开发者提示，在“通用 → VPN 与设备管理”中核对并信任自己的开发者身份。
6. 启动 DSH，确认版本 1.1.0 (31)，在 App 内配置自己的模型 API Key。

开发签名的有效期和刷新限制取决于账号及描述文件，按工具提示定期续签。
Apple 的说明见 [Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。
不要把 Apple 密码、API Key、证书私钥或描述文件提交到仓库或 Issue。

## 3. 使用自己的 Mac 从源码构建

```bash
git clone https://github.com/wjc19980523-glitch/dsh-ios-ipa.git
cd dsh-ios-ipa
brew install meson ninja lld libarchive
gem install xcodeproj
make project
```

还需 Node/npm、受支持的 Xcode、Apple Silicon 环境及 RootFS。
固定候选的 RootFS 获取限制见[云构建文档](cloud-build.md)；
`make emulator` / `make rootfs` 是重新生成镜像的开发路线，不能据此声称与固定 Build 31 镜像完全相同。
打开 `DSH.xcodeproj`，选择 DSH scheme、设备和自己的 Team，设置自己可用的 Bundle ID，构建运行。

源码中的 `app/DSH.entitlements` 声明了 HealthKit 和 private-cloud-compute 等能力，
它是权限声明而非证书。签名 profile 必须与实际保留的 entitlement 匹配。
如果签名工具提示能力不受支持，需要审查该能力、账号及 profile，
不要把未知证书或描述文件加入仓库来绕过错误；权限调整可能影响相关功能。

## 4. 真机验收

- 原有会话、模型配置和工作区仍可见。
- 新建会话调用开发预检、任务历史、任务状态，确认工具结果可以继续交给模型。
- 小文件与超过 8 MiB 的工作区文件可以经确认后保存到系统“文件”。
- 检查取消保存、前后台切换和再次启动。CI 通过不等于这些设备行为已经验收。

Build 31 不承诺修复旧会话里已经保存的异常消息。遇到旧会话故障时，保留原会话并用新会话
对照验证，不要通过删除数据来掩盖问题。
