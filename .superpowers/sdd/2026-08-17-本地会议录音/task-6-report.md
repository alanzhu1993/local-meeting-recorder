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

## Fix Round 1（2026-08-17）

- Carbon 注册现在传入 `kEventHotKeyExclusive`，系统占用会返回可操作的快捷键冲突提示。
- 每个 `HotkeyService` 在进程内取得独立的 `EventHotKeyID`；回调只消费自己的 ID，其他事件返回 `eventNotHandledErr` 让 Carbon handler chain 继续处理。
- 所有实际 Carbon 安装、注册、注销和移除操作都经主事件线程串行执行。注销失败会保留注册和回调上下文，并暴露 `lastTeardownError`；再次调用 `unregister()` 会重试。回调上下文由 handler token 强持有，直到 `RemoveEventHandler` 成功后才释放。
- 保存通知把文件 URL 写入 `UNNotificationContent.userInfo`，点击时直接读取该值；不再维护会随通知增长或因服务重建丢失的内存映射。前台通知显示 banner/list，仍不带声音。
- 登录启动的读取、判断和 register/unregister 操作由同一把锁保护；动作抛错后会重新读取状态，若目标已达成则视为成功。相反目标的调用按取得锁的顺序线性执行，后完成的调用决定最终状态。
- 新增测试覆盖独占选项、多服务 handler chain、并发注册/注销、注销失败后回调与重试、通知 payload、前台静音展示、登录启动同目标并发与动作后错误回读。
- 本轮未做真实 Carbon smoke：避免在 Alan 正在使用的会话中临时注册全局快捷键；Carbon 调用路径由注入 backend 的测试覆盖，真实系统行为仍需手工验证。
- 本轮验证：`PermissionServiceTests` 3/3、`HotkeyServiceTests` 7/7、`SystemServiceTests` 8/8 均通过；全量 `swift test -Xswiftc -warnings-as-errors` 为 89/89 通过；`git diff --check` 通过。
