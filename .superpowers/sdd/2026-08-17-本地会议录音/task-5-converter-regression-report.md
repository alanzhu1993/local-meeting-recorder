# Task 5 — 48 kHz SampleBufferConverter 回归修复报告

## 结论

`SampleBufferConverter` 不再用 48 kHz identity conversion 的 `AVAudioConverter.primeInfo` 计算输出容量。48 kHz Float32 stereo、Int16 stereo 和 Int16 mono 现在都保持一个输入 frame 对应一个输出 frame，连续 buffer 的时间轴连续，样本值正确。

## 根本原因与证据

- 原实现将 `primeInfo.leadingFrames + trailingFrames` 直接加入输出容量，再转为 `AVAudioFrameCount`。
- 本机调查中，48 kHz stereo identity converter 曾返回 `leadingFrames=4,096,000,984` / `trailingFrames=1`，而 44.1→48 kHz converter 返回正常的 `16/16`。Task 7 的 LLDB 调查还观察到同一 getter 前后值不稳定，一次 prime 总和为 `5,368,702,976`，已超出 `UInt32`。
- Apple SDK 本地头文件 `AVAudioConverter.h` 明确说明：`AVAudioConverterPrimeMethod_None` 需要的额外输入 frame 为 0。当前 converter 已设置 `primeMethod = .none`，因此 identity conversion 将 primeInfo 加入容量没有依据。

## RED

修改实现前，先加入 48 kHz PCM `CMSampleBuffer` 回归测试。将 48 kHz mono 测试用独立 xctest 进程重复运行，前 4 次通过，第 5 次以 signal 5 退出：

```text
Swift/arm64e-apple-macos.swiftinterface:13152: Fatal error: Not enough bits to represent the passed value
```

这个结果证明问题是 `primeInfo` 不稳定造成的整数转换 fatal trap，不是某一种音频样本内容造成的普通抛错。最终回归样本已加强为每包 960 frames，贴近 48 kHz 采集链路的 20 ms buffer。

## 修改

- 48 kHz identity sample-rate 路径不读取 `primeInfo`，输出容量直接等于输入 `frameLength`。
- 非 identity 重采样路径保留容量余量，但将报告的 prime 输入帧数限制在 4096，再按采样率比例换算为输出帧数。
- 容量加法改为 `addingReportingOverflow`，溢出或超出可表示范围时限制到 `AVAudioFrameCount.max`，不再使用会 fatal trap 的直接窄化转换。
- 从 `CMSampleBuffer` 创建输入 `AVAudioPCMBuffer` 前也检查 sample count 是否可由 `AVAudioFrameCount` 表示。
- 测试工厂新增可复用的 Float32 / Int16 interleaved PCM sample-buffer 构造器。

## GREEN 和回归验证

```text
AudioTimelineMixerTests: 13 tests, 0 failures
48 kHz Int16 mono independent launches: 20/20 PASS
LiveRecordingSessionManagerTests: 13 tests, 0 failures
RecoveryServiceTests: 5 tests, 0 failures
Full swift test: 123 tests, 0 failures
swift build -Xswiftc -warnings-as-errors: PASS
git diff --check: PASS
```

`AudioTimelineMixerTests` 包含：

- 连续两包 48 kHz Float32 stereo，每包 960 frames；检查 frameCount、startFrame 连续性和全部 interleaved samples。
- 48 kHz Int16 stereo，960 frames；检查一比一 frame 转换和归一化样本值。
- 48 kHz Int16 mono，960 frames；检查一比一 frame 转换和左右声道复制。
- 原有 44.1→48 kHz 转换、12 个连续重采样 buffer 和 drain 测试继续通过。

## 未验证项

- 本修复使用贴近 ScreenCaptureKit 配置的 48 kHz stereo Float32 ASBD，但本报告没有重跑真实 ScreenCaptureKit 采集。Task 7 会将完整 converter→mixer→writer 会话测试从 44.1 kHz mono 改回 48 kHz stereo 后再验证。

## Fix Round 1：确定性验证 primeInfo 容量逻辑

外部审查指出：实际 48 kHz PCM 转换测试能验证结果，但旧实现的 `primeInfo` getter 返回值是随机的，单次测试可能恰好通过，因此无法确定性防止回归。这个问题成立。

### 修改

- 生产 `convert` 的容量计算提取为 internal static `outputFrameCapacity`；测试直接调用这一个 helper，不存在“测试一套、生产另一套”。
- `primeInfo` 通过延迟 provider 读取。Helper 先校验 frameCount 和 sample rate；48 kHz identity 直接返回精确输入帧数，不调用 provider。
- 非 identity 路径才读取 provider，仍执行 4096 prime-input-frame 限制、采样率换算、受检加法和 `AVAudioFrameCount.max` 限幅。
- Helper 入参使用 `UInt64` 表示输入 frameCount，从而可以确定性测试超出 `AVAudioFrameCount.max` 的输入；该情况抛出 `.capture`，不做窄化转换，也不读取 provider。

### TDD 证据

RED 阶段先加测试，生产代码尚只有 private instance helper，编译失败：

```text
error: 'outputFrameCapacity' is inaccessible due to 'private' protection level
error: extra arguments at positions #2, #3 in call
```

GREEN 阶段的确定性断言：

- 48 kHz identity：`inputFrameCount=960`，provider 注入两个 `UInt32.max`；结果容量精确为 960，provider 调用次数为 0。
- 24→48 kHz：分别注入两个 `UInt32.max` 和会让 `UInt64` 加法溢出的 `UInt64.max + 1`；两次都按 4096 prime frames 限制后返回同一有界容量 9106，没有 trap。
- `inputFrameCount=UInt32.max+1`：抛出 `.capture`，provider 调用次数为 0。

### Fix Round 1 验证

```text
AudioTimelineMixerTests: 16 tests, 0 failures
Full swift test: 126 tests, 0 failures
swift build -Xswiftc -warnings-as-errors: PASS
git diff --check: PASS
```

Task 7 的完整会话链路已改为 48 kHz Float32 stereo；本轮全量测试中该 converter→mixer→fragmented writer 测试通过。仍未在本轮重跑真实 ScreenCaptureKit 采集。
