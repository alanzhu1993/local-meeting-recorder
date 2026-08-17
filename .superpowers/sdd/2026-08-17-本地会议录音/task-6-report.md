# Task 6 报告（2026-08-17）

## RED

- 先新增 `PermissionServiceTests`、`HotkeyServiceTests`、`SystemServiceTests`。
- 初次运行 `swift test --filter PermissionServiceTests` 因 Task 6 的类型和服务尚未实现而编译失败，确认测试确实约束了待实现行为。

## GREEN

- `PermissionServiceTests`：3/3 通过。
- `HotkeyServiceTests`：4/4 通过。
- `SystemServiceTests`：3/3 通过。
- 全量 `swift test -Xswiftc -warnings-as-errors`：81/81 通过，无 Swift 编译警告。
- `git diff --check`：通过。

## 变更

- 权限：稳定按“屏幕与系统音频录制、麦克风”列出缺失项。请求后重新读取真实权限状态，不采用请求 API 的返回值作为最终结论。
- 热键：只使用 Carbon 的 `RegisterEventHotKey` / `UnregisterEventHotKey`；事件只匹配本服务的 signature 与 identifier。重复注册明确报错，冲突给出换键提示，注册半失败会撤销已安装的处理器，注销可重复调用。每个 Carbon 回调都有独立的持有上下文，不使用全局事件处理器、`NSEvent` monitor、辅助功能或输入监控权限。
- 睡眠：开始/结束有锁保护且幂等，使用 `ProcessInfo` 的用户发起活动和禁止空闲睡眠选项。
- 通知：通知明确静音；已保存通知只保存其自己的文件映射，点击后仅在 Finder 中定位该文件。原生后端被服务持有，避免 `UNUserNotificationCenter` 的弱 delegate 提前释放。测试使用注入后端，不发送真实通知。
- 登录启动：映射 enabled、disabled、requires approval、unavailable；`requires approval` 返回可操作的系统设置提示。测试使用注入后端，不会变更本机登录项。

## 未验证

- 未在真实用户会话中触发屏幕录制、麦克风或通知授权弹窗。
- 未真实注册默认快捷键，也未手工制造第三方快捷键冲突。
- 未实际修改本机登录项或验证系统设置中的批准流程。
