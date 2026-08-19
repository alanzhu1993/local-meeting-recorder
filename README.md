# 本地会议录音 (Local Meeting Recorder)

macOS 菜单栏会议录音工具：一键录制屏幕画面 + 系统音频 + 麦克风，写入本地文件，不上传任何云端。

> 本地优先。所有录音只保存在你本机，无网络上传、无账号体系。

## 功能特性

- 菜单栏一键录制，支持快捷键（默认 `⌃⌥R`）启动/停止
- 同时采集屏幕画面、系统音频、麦克风，可单独开关
- 崩溃可恢复写入：意外退出时工作文件可被自动恢复并正常 finalize
- 防系统睡眠（录制期间阻止 Mac 休眠）
- 登录启动、权限预检与缺失引导
- 稳定本地代码签名：更新版本后系统权限（屏幕录制/TCC）不会失效

## 系统要求

- macOS 15 或更高
- Xcode 16+（Swift 6.2 工具链，用于本地构建）
- 首次使用需在「系统设置 → 隐私与安全性」中授予：屏幕与系统音频录制、麦克风

## 构建与安装

仓库使用 Swift Package Manager，构建脚本封装了本地签名与事务化安装。

```bash
# 1. 一次性初始化本地签名身份（会在登录钥匙串创建受限的自签证书）
./scripts/setup-local-signing.sh

# 2. 构建当天版本（产出 dist/会议录音-YYYY-MM-DD.app，带正式本地签名）
./scripts/build-app.sh

# 3. 安装到 /Users/alan/Applications（自动备份旧版本）
./scripts/install-local.sh <YYYY-MM-DD>
```

日常更新只需重复步骤 2、3。由于采用稳定签名，更新后无需重新授权系统权限。

> 说明：构建与安装脚本中的路径、钥匙串、登录启动项均针对本机用户 `alan` 预置。迁移到其他机器时需相应调整脚本中的路径常量。

## 测试

测试为全自包含设计（签名用临时钥匙串 + 桩 `security`，录屏用桩后端），无需真实证书或屏幕录制权限即可在干净环境运行。

```bash
swift test
```

## 本地签名方案

通过登录钥匙串中的受限自签证书（root + leaf 双证书、ACL 限制、pinned receipt）对 app 签名，使 designated requirement 锚定固定证书链而非 CDHash。这样每次构建内容变化导致 CDHash 改变时，系统仍认定是同一身份，TCC 权限持续有效。详见 `docs/` 下的设计与验证文档。

## 项目结构

```
Sources/MeetingRecorderCore/    领域与系统服务（录音引擎、权限、通知、签名元数据）
Sources/MeetingRecorderApp/     菜单栏 UI、生命周期、权限门控、安装入口
Tests/                           SwiftPM 测试（Core + App 两套）
scripts/                         build / install / setup-local-signing
docs/                            设计规格、SDD 计划、技术验证记录
```

## 文档

- `docs/superpowers/specs/2026-08-17-本地会议录音-design.md` — 设计规格
- `docs/superpowers/plans/2026-08-17-本地会议录音.md` — 实施计划与进度台账
- `docs/verification/2026-08-17-录音技术验证.md` — 录音技术验证

## CI

每次推送到 `main` 或发起 PR 时，GitHub Actions 会在 macOS runner 上执行 `swift build` 与 `swift test`（见 `.github/workflows/ci.yml`）。

## 许可证

本项目采用 [MIT 许可证](./LICENSE)。详见仓库根目录的 `LICENSE` 文件。
