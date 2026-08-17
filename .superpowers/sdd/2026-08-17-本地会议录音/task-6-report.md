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

## Fix Round 2（2026-08-17）

- `HotkeyRegistering`、`HotkeyService` 与 Carbon backend 现在都标为 `@MainActor`；移除了 `DispatchQueue.main.sync`。现有源码中没有其他调用点，后续菜单栏与协调器需在主线程调用，或从异步上下文 `await MainActor.run` 后调用。
- `RemoveEventHandler` 按 Carbon 的单次消费合约处理：一旦调用，不论 status 都不再保存或重试同一个 handler ref。若移除失败，服务会把 callback context 保留在 app-lifetime 存储中，进入明确的 terminal teardown failure；后续注册返回“重启应用后再设置快捷键”的可操作错误。正常移除仍允许再次注册。
- Carbon C callback 用 `MainActor.assumeIsolated` 回到与 `GetEventDispatcherTarget` 相同的主事件线程；回调只在服务仍持有匹配注册时触发用户 handler，其他事件返回 `eventNotHandledErr`。
- `LoginItemManaging`、`LoginItemService` 和注入 backend 同样改为 `@MainActor`，去除了 `@unchecked Sendable` 与锁内外部调用。注入 backend 可以在 `register()` 内重新读取或设置服务状态而不死锁；register 抛错后若状态为 `requiresApproval`，返回该明确错误而不是通用注册失败。
- Round 2 新增测试覆盖：Remove 失败后不重复 Remove、终态不允许新注册、正常移除后可重新注册、MainActor 线性并发调用、backend 重入、以及错误后的 `requiresApproval` 映射。
- 本轮验证：`PermissionServiceTests` 3/3、`HotkeyServiceTests` 8/8、`SystemServiceTests` 10/10；全量 `swift test -Xswiftc -warnings-as-errors` 为 92/92 通过，`git diff --check` 通过。

## Fix Round 3（2026-08-17）

- `HotkeyService` 使用 Swift 6.2 的 `isolated deinit` 在 MainActor 上完成安全清理。已注册实例释放时会先 `UnregisterEventHotKey`，再单次调用 `RemoveEventHandler`；后者失败仍依照终态规则保留 callback context，且不会再次移除同一 ref。注入测试模拟移除失败后仍可能被系统回调，验证它安全返回 `eventNotHandledErr`。
- 登录启动改为主线程同步重入状态机，维护 `isMutating`、`activeDesired`、`pendingDesired`。同目标重入直接合并；相反目标记录为最后一个 pending 请求，外层动作完成后在返回前排空。内层同步调用表示“请求已排队”，最终状态按请求发生顺序最后一次为准，且不会递归调用 backend。
- 每次 register/unregister 后均重新读取完整状态：`enabled` / `disabled` 代表目标达成，`requiresApproval` / `unavailable` 映射为对应具体错误，动作已抛错但目标已达成仍视为成功。
- 新增测试覆盖注册后释放、释放时 Remove 失败的安全回调与单次移除、状态未变化前同目标重入、启用中重入停用、成功但最终 unavailable，以及既有 requiresApproval 路径。
- 本轮验证：`PermissionServiceTests` 3/3、`HotkeyServiceTests` 10/10、`SystemServiceTests` 12/12；全量 `swift test -Xswiftc -warnings-as-errors` 为 96/96 通过，`git diff --check` 通过。
