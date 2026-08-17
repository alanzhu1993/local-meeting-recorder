# Task 9 实施报告：生命周期装配与本地安装

日期：2026-08-18

## 实际完成

- 新增可测试的 `AppLifecycle`，启动顺序为：菜单栏入口先显示，然后标记恢复中、执行恢复和逐条通知，最后注册快捷键并同步登录项。
- 恢复期间菜单显示明确恢复文案，主操作不可点击。每个恢复成功或失败结果都更新状态并发送通知。
- 真实装配只创建一个 `PermissionService`、一个 `RecordingActivityGate`和一个根目录 `RecordingStore`，分别共用给权限门、录音 session 和恢复服务。采集、休眠防止、通知、快捷键、登录项均是同一个长生命周期实例；converter、mixer 和 writer 使用 `LiveRecordingSessionManager` 公开生产初始化器内的真实工厂。
- 主按钮、启动注册的全局快捷键、设置中重新注册的快捷键，共用同一个 `PermissionGatedRecordingAction`，不存在绕过权限检查的录音入口。
- 快捷键冲突或登录项等待系统批准时，错误会进入设置界面，后续启动步骤仍继续，菜单栏入口不被关闭。
- 退出处理覆盖 preparing、recording、stopping 和恢复中：都返回 `terminateLater`，并只创建一个退出任务。录音中通过同一录音动作停止；preparing 会调用 session stop 触发回滚；stopping 会等待已有保存。最终只回复 AppKit 一次。保存失败不删除 working file，仍允许退出。
- `NotificationService` 被 `AppDelegate` 强持有到应用结束，保证通知中的文件点击回调不会因启动装配结束而释放。
- 新增安装脚本，固定目标为 `/Users/alan/Applications/会议录音.app`。脚本会先解析并校验绝对路径，在动旧 app 前检查源 app、可执行文件、签名、bundle id 和 `LSUIElement`。
- 重复安装时，只会停止可执行路径精确等于已安装 app 路径的进程，并输出 PID。旧 app 移到带日期时间的 backup；复制或校验失败时，失败产物会另行保留，旧 app 尽力恢复到固定目标，不使用宽泛 `rm` 或 `pkill`。

## TDD 证据

1. 先创建 `AppLifecycleTests.swift` 并运行指定测试，编译按预期失败：`cannot find type 'AppLifecycle' in scope`。
2. 实现后，`AppLifecycleTests` 8 项全部通过，包括启动顺序、逐条恢复通知、启动服务错误、各录音阶段退出、重复退出只回复一次、恢复中退出等待。
3. 全量 warnings-as-errors 验证：164 项测试，0 失败，1 项跳过。跳过项是需要显式设置 `MEETING_RECORDER_CAPTURE_UI` 的截图用例。

## 构建和安装证据

- Release 构建成功，产物：`dist/会议录音-2026-08-18.app`。
- 产物为 arm64 Mach-O，ad-hoc 签名；`codesign --verify --deep --strict` 通过。
- `CFBundleIdentifier=com.alan.local-meeting-recorder`，`LSUIElement=true`。
- `--dry-run` 通过，输出的源和目标均为绝对路径。
- 不存在的源日期 `1900-01-01` 返回 66；当时目标前后均为 absent，未创建或移动旧 app。
- 首次真实安装和重复安装均成功。重复安装精确停止了 PID 95415，保留旧 app 为 `/Users/alan/Applications/会议录音-backup-2026-08-18-005911.app`，并启动新进程 PID 95819。
- 当前进程可执行路径精确为 `/Users/alan/Applications/会议录音.app/Contents/MacOS/MeetingRecorderApp`。
- System Events 返回 `frontmost=false, visible=false, menuBars=1`；结合 `LSUIElement=true`，已验证没有普通 Dock 应用状态。

## 尚未验证和剩余风险

- 本任务未实际点击菜单栏图标、触发全局快捷键或录制一段真实音频，因为这些会发起系统录音/麦克风权限和真实用户操作。菜单栏创建由单元测试与真实进程存活共同验证，但未做人工视觉确认。
- macOS 日志中出现 `com.apple.linkd.autoShortcut` 的 AppIntents 连接错误，属系统服务注册日志；应用进程仍稳定存活。最终版本启动后 30 秒内未再观察到之前的 AppKit layout recursion 告警。

## FixRound1 追加（2026-08-18）

### 修复内容

- 恢复失败不再随 `isRecovering=false` 消失。菜单会持续显示完整 working file 路径和具体错误，用户可点“在 Finder 中显示工作文件”，也可手动关闭。成功恢复会显示可关闭的条数摘要。
- `RecoveryService` 现在通过 `lastBatchFailure` 明确暴露目录扫描失败。`listInterruptedRecordings()` 报错时，启动层会持续显示恢复根目录和原始错误，不再伪装成“没有需要恢复的文件”。
- 新增可测试的 `ProductionCompositionRoot` 和身份快照。生产装配实际只创建一个 `PermissionService`、`RecordingActivityGate`、`RecordingStore`、`NotificationService` 和录音操作入口；主按钮与全局快捷键使用同一个 `RecordingActionEntrypoint`。
- 退出测试不再只验证字符串调用顺序。新用例使用真实 `LiveRecordingSessionManager` 和可控依赖，覆盖 preparing 取消并保留 working file、stopping 合并现有 finish、finish 失败后保留 working file 且只 reply 一次。
- 恢复进行时，菜单的设置入口禁用并有代码 guard；如果设置窗口已打开，快捷键、开机启动和存储位置控件同样禁用。恢复完成后注册快捷键和设置登录项时，读取 `SettingsViewModel` 的最新值，不再使用启动时捕获的旧值。
- 安装脚本只有在显式设置 `MEETING_RECORDER_INSTALL_TESTING=1` 时才允许工具和路径覆盖，且测试根目录必须是真实的 `mktemp` 目录。生产模式仍锁定 `/Users/alan/Applications/会议录音.app`，任何测试覆盖都会在改动目标前返回 70。
- 安装失败时会先将残缺 target 移到唯一的 `会议录音-failed-<timestamp>[-vN].app`，再尝试恢复 backup。首次安装失败也会保留失败产物，不留残缺正式 target。backup/failed 同秒重名时使用递增 `-vN`。
- 安装前只通过 AppKit AppleEvent 请求精确 bundle id 正常退出，再单独轮询精确 executable PID。AppleScript 使用 `ignoring application responses` 避免工具自身无限等待。超时则返回 68，提示用户先停止录音并退出应用；脚本不发送 `TERM`/`KILL`，不移动旧 app。

### FixRound1 TDD 和验证证据

- `RecoveryServiceTests` 7 项通过，新增扫描失败类型和原始错误断言。
- `MenuBarPresentationTests` 26 项通过（其中 1 项截图用例按环境跳过），新增启动恢复完成后反馈仍存在、完整路径和 Finder action、恢复期设置禁用测试。
- `AppLifecycleTests` 13 项通过，包括生产单实例装配、扫描失败持续反馈、真实 session 的 preparing/stopping/finalize-failure 退出。
- `InstallScriptIntegrationTests` 6 项通过。全部在 `/private/var/.../meeting-recorder-install-test.*` 临时目录中运行，覆盖 ditto 部分复制失败、target 校验失败、backup 同秒冲突、错误 PID/path 不停止、restore move 失败、正常 quit 超时。每项都断言旧 app 仍可用，或至少有一份完整 backup，不会丢失唯一旧 app。
- 全量 `swift test -Xswiftc -warnings-as-errors`：178 项，0 失败，1 项截图用例按环境跳过。
- `zsh -n scripts/install-local.sh` 通过；生产 `--dry-run` 显示绝对 source/target；非测试模式设置覆盖返回 70；不存在的 source date 返回 66，两者都未移动真实 target。
- Release build 成功，产物为 arm64 Mach-O，ad-hoc 签名且 `codesign --verify --deep --strict` 通过；`CFBundleIdentifier=com.alan.local-meeting-recorder`，`LSUIElement=true`。
- `git diff --check` 通过。

### 真实重新安装：pending，未改动旧 app

- 安装脚本识别到精确目标进程 PID `95819`，其 executable 为 `/Users/alan/Applications/会议录音.app/Contents/MacOS/MeetingRecorderApp`。
- 第一次实际验证发现旧版本收到正常 quit AppleEvent 后，AppleScript 本身一直等待。安装在 backup/copy 前被人工中断，target inode/mtime 保持不变。脚本随后已改为发送 AppleEvent 后立即返回，由 PID 轮询负责超时。
- 第二次实际验证中，脚本向 PID `95819` 发出正常 AppKit quit，5 秒后精确 PID 仍在，脚本按设计返回 68。输出为：`Installed app PID 95819 did not quit normally. Stop recording and quit the app before installing; existing app was not moved.`
- macOS AppKit 日志确认：`Handling Quit AppleEvent` → `Asking app delegate whether applicationShouldTerminate:` → `applicationShouldTerminate: NSTerminateLater`。
- 对旧进程的只读 sample 显示，异步任务仍在 `RecoveryService.recoverInterruptedRecordings()` → `RecoveryService.performRecovery` → `RecordingStore.listInterruptedRecordings()` → `NSURLDirectoryEnumerator.nextObject`。因此它一直把退出视为“恢复任务进行中”，返回 `terminateLater` 后无法完成 reply。sample 保存在 `/tmp/MeetingRecorderApp-95819-FixRound1.sample.txt`。
- 默认录音目录 `/Users/alan/Documents/快速本地录音软件/录音文件` 已只读检查：所有文件数 `0`，working/manifest/segment 匹配数 `0`。未发现录音或恢复产物。
- 本轮没有强制停止 PID `95819`，没有移动 `/Users/alan/Applications/会议录音.app`。现有 target 仍是 inode `126288769`。真实重新安装需等 Alan 另行授权精确 PID 强制停止，或在重启 Mac 后再运行脚本。
