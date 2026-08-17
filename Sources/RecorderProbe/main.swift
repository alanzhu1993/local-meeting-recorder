import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import MeetingRecorderCore

private struct DualCaptureArguments {
    let seconds: Int
    let reportURL: URL

    init?(_ arguments: [String]) {
        guard arguments.first == "dual-capture" else { return nil }

        var seconds = 30
        var reportPath: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--seconds" where index + 1 < arguments.count:
                guard let value = Int(arguments[index + 1]), value > 0, value <= 30 else {
                    return nil
                }
                seconds = value
                index += 2
            case "--report" where index + 1 < arguments.count:
                reportPath = arguments[index + 1]
                index += 2
            default:
                return nil
            }
        }

        guard let reportPath else { return nil }
        self.seconds = seconds
        reportURL = URL(fileURLWithPath: reportPath)
    }
}

private struct RecordUntilKilledArguments {
    let workingURL: URL

    init?(_ arguments: [String]) {
        guard
            arguments.count == 3,
            arguments[0] == "record-until-killed",
            arguments[1] == "--working",
            !arguments[2].isEmpty
        else {
            return nil
        }
        workingURL = URL(fileURLWithPath: arguments[2])
    }
}

private struct RecoverArguments {
    let workingURL: URL
    let outputURL: URL

    init?(_ arguments: [String]) {
        guard arguments.first == "recover" else { return nil }
        var workingPath: String?
        var outputPath: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--working" where index + 1 < arguments.count:
                workingPath = arguments[index + 1]
                index += 2
            case "--output" where index + 1 < arguments.count:
                outputPath = arguments[index + 1]
                index += 2
            default:
                return nil
            }
        }
        guard let workingPath, let outputPath else { return nil }
        workingURL = URL(fileURLWithPath: workingPath)
        outputURL = URL(fileURLWithPath: outputPath)
    }
}

private actor ProbeMetrics {
    private var metrics = AudioCaptureProbeMetrics()
    private let stopped = AsyncStream<Void>.makeStream()

    func consume(_ event: AudioCaptureEvent) {
        metrics.consume(event)
        if case .stopped = event {
            stopped.continuation.yield()
        }
    }

    func waitForStoppedEvent() async {
        if metrics.snapshot.stoppedEventCount > 0 { return }
        var iterator = stopped.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func snapshot() -> AudioCaptureProbeSnapshot {
        metrics.snapshot
    }
}

private struct ProbeResult {
    let startedAt: Date
    let finishedAt: Date
    let requestedSeconds: Int
    let screenPermissionBefore: Bool
    let screenPermissionAfter: Bool
    let microphoneAuthorizationBefore: AVAuthorizationStatus
    let microphoneAuthorizationAfter: AVAuthorizationStatus
    let snapshot: AudioCaptureProbeSnapshot
    let startFailure: RecordingFailure?

    var passed: Bool {
        startFailure == nil
            && snapshot.passedCaptureChecks
    }
}

private func recordingFailure(from error: Error) -> RecordingFailure {
    if let failure = error as? RecordingFailure {
        return failure
    }
    return RecordingFailure(code: .capture, message: error.localizedDescription)
}

private func runDualCapture(_ arguments: DualCaptureArguments) async -> ProbeResult {
    let startedAt = Date()
    let screenPermissionBefore = CGPreflightScreenCaptureAccess()
    let microphoneAuthorizationBefore = AVCaptureDevice.authorizationStatus(for: .audio)
    let metrics = ProbeMetrics()
    let engine = ScreenCaptureEngine()
    var startFailure: RecordingFailure?

    do {
        try await engine.start { event in
            await metrics.consume(event)
        }
        try await Task.sleep(for: .seconds(arguments.seconds))
        await engine.stop()
        await metrics.waitForStoppedEvent()
    } catch {
        startFailure = recordingFailure(from: error)
        await engine.stop()
    }

    return await ProbeResult(
        startedAt: startedAt,
        finishedAt: Date(),
        requestedSeconds: arguments.seconds,
        screenPermissionBefore: screenPermissionBefore,
        screenPermissionAfter: CGPreflightScreenCaptureAccess(),
        microphoneAuthorizationBefore: microphoneAuthorizationBefore,
        microphoneAuthorizationAfter: AVCaptureDevice.authorizationStatus(for: .audio),
        snapshot: metrics.snapshot(),
        startFailure: startFailure
    )
}

private func authorizationDescription(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
        return "notDetermined"
    case .restricted:
        return "restricted"
    case .denied:
        return "denied"
    case .authorized:
        return "authorized"
    @unknown default:
        return "unknown(\(status.rawValue))"
    }
}

private func reportText(for result: ProbeResult, command: String) -> String {
    let timestamp = ISO8601DateFormatter()
    let status = result.passed ? "PASS" : "NOT PASSED"
    let failure = result.startFailure.map {
        "\($0.code.rawValue): \($0.message)"
    } ?? "none"
    let stoppedFailure = result.snapshot.stoppedFailure.map {
        "\($0.code.rawValue): \($0.message)"
    } ?? "none"
    let warnings = result.snapshot.warnings.isEmpty
        ? "none"
        : result.snapshot.warnings.map { "\($0.code.rawValue): \($0.message)" }
            .joined(separator: "; ")
    let microphoneChanges = result.snapshot.microphoneChanges.isEmpty
        ? "none"
        : result.snapshot.microphoneChanges.joined(separator: ", ")

    return """
    # 录音技术验证（2026-08-17）

    ## 结论

    - 真实双音源 probe：**\(status)**
    - 判定标准：系统音频和麦克风样本数都大于 0；两路 PTS 均有效、为有限数值且严格递增；恰好收到 1 个无错误的 stopped 事件；未注册或保存屏幕视频帧。
    - 这次 probe 没有注册 `.screen` output，也没有创建任何视频文件。

    ## 运行环境

    - 开始：\(timestamp.string(from: result.startedAt))
    - 结束：\(timestamp.string(from: result.finishedAt))
    - 请求采集时长：\(result.requestedSeconds) 秒
    - 系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
    - 命令：`\(command)`
    - 运行前屏幕与系统音频录制权限：\(result.screenPermissionBefore)
    - 运行后屏幕与系统音频录制权限：\(result.screenPermissionAfter)
    - 运行前麦克风授权状态：\(authorizationDescription(result.microphoneAuthorizationBefore))
    - 运行后麦克风授权状态：\(authorizationDescription(result.microphoneAuthorizationAfter))

    ## 原始关键结果

    - 系统音频样本数：\(result.snapshot.system.sampleCount)
    - 麦克风样本数：\(result.snapshot.microphone.sampleCount)
    - 系统音频无效 PTS 数：\(result.snapshot.system.invalidPresentationTimeCount)
    - 麦克风无效 PTS 数：\(result.snapshot.microphone.invalidPresentationTimeCount)
    - 系统音频 PTS 严格递增：\(result.snapshot.system.presentationTimesAreStrictlyIncreasing)
    - 麦克风 PTS 严格递增：\(result.snapshot.microphone.presentationTimesAreStrictlyIncreasing)
    - 视频样本数：0（未注册 `.screen` output）
    - 默认麦克风变更事件：\(microphoneChanges)
    - warning：\(warnings)
    - stopped 事件数：\(result.snapshot.stoppedEventCount)
    - 启动失败：\(failure)
    - 采集中止失败：\(stoppedFailure)

    ## 未验证项

    - 样本数只证明 ScreenCaptureKit 实际交付了两路音频 buffer；本 probe 不写文件，也不判断内容是否为静音。
    - 本次运行没有主动切换默认输入设备，因此只有实际发生切换时才能验证热更新事件。
    - 如果状态为 `NOT PASSED`，不能据此声称真实双音源采集已经通过；需要按上面的权限或输入条件处理后重新运行。
    """
}

private func writeReport(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func sineChunk(startFrame: Int64, frameCount: Int) -> MixedAudioChunk {
    let frequency = 440.0
    let amplitude = Float(0.25)
    let sampleRate = 48_000.0
    let samples = (0..<frameCount).flatMap { offset -> [Float] in
        let frame = startFrame + Int64(offset)
        let value = amplitude * Float(
            sin(2 * Double.pi * frequency * Double(frame) / sampleRate)
        )
        return [value, value]
    }
    return MixedAudioChunk(
        startFrame: startFrame,
        frameCount: frameCount,
        samples: samples
    )
}

private func runUntilKilled(_ arguments: RecordUntilKilledArguments) async throws -> Never {
    let writer = FragmentedMOVWriter(workingURL: arguments.workingURL)
    try await writer.start()
    print("ready pid=\(ProcessInfo.processInfo.processIdentifier) signal=TERM")
    fflush(stdout)

    let framesPerChunk = 960
    var startFrame: Int64 = 0
    while true {
        try await writer.append(
            sineChunk(startFrame: startFrame, frameCount: framesPerChunk)
        )
        startFrame += Int64(framesPerChunk)
        if startFrame % 48_000 == 0 {
            print("writtenFrames=\(startFrame) seconds=\(startFrame / 48_000)")
            fflush(stdout)
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private struct AudioFileProbeResult {
    let durationSeconds: Double
    let audioTrackCount: Int
    let hasAACTrack: Bool
    let playable: Bool
    let peakAmplitude: Float

    var passedRecoveryChecks: Bool {
        durationSeconds >= 10
            && audioTrackCount == 1
            && hasAACTrack
            && playable
            && peakAmplitude > 0.001
    }
}

private func inspectRecoveredAudio(_ url: URL) async throws -> AudioFileProbeResult {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let playable = try await asset.load(.isPlayable)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    var hasAACTrack = false
    for track in tracks {
        let descriptions = try await track.load(.formatDescriptions)
        if descriptions.contains(where: {
            CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
        }) {
            hasAACTrack = true
        }
    }

    var peak = Float.zero
    if let track = tracks.first {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else {
            throw RecordingFailure(code: .finalize, message: "AVAssetReader rejected the recovered audio track.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw RecordingFailure(
                code: .finalize,
                message: "Could not decode recovered audio: \(reader.error?.localizedDescription ?? "unknown reader error")"
            )
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Float>.size else { continue }
            var bytes = Data(count: byteCount)
            let status = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: destination.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }
            bytes.withUnsafeBytes { rawBytes in
                let values = rawBytes.bindMemory(to: Float.self)
                for value in values {
                    peak = max(peak, abs(value))
                }
            }
        }
        guard reader.status == .completed else {
            throw RecordingFailure(
                code: .finalize,
                message: "Recovered audio decoding did not complete: \(reader.error?.localizedDescription ?? "unknown reader error")"
            )
        }
    }

    return AudioFileProbeResult(
        durationSeconds: CMTimeGetSeconds(duration),
        audioTrackCount: tracks.count,
        hasAACTrack: hasAACTrack,
        playable: playable,
        peakAmplitude: peak
    )
}

private func runRecovery(_ arguments: RecoverArguments) async throws -> AudioFileProbeResult {
    _ = try await M4AFinalizer().recover(
        workingURL: arguments.workingURL,
        recoveredURL: arguments.outputURL
    )
    return try await inspectRecoveredAudio(arguments.outputURL)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "record-until-killed" {
    guard let recordArguments = RecordUntilKilledArguments(arguments) else {
        FileHandle.standardError.write(Data(
            "Usage: RecorderProbe record-until-killed --working PATH\n".utf8
        ))
        exit(64)
    }
    do {
        try await runUntilKilled(recordArguments)
    } catch {
        FileHandle.standardError.write(Data(
            "record-until-killed failed: \(error.localizedDescription)\n".utf8
        ))
        exit(74)
    }
}

if arguments.first == "recover" {
    guard let recoverArguments = RecoverArguments(arguments) else {
        FileHandle.standardError.write(Data(
            "Usage: RecorderProbe recover --working PATH --output PATH\n".utf8
        ))
        exit(64)
    }
    do {
        let result = try await runRecovery(recoverArguments)
        print(String(format: "durationSeconds=%.6f", result.durationSeconds))
        print("audioTracks=\(result.audioTrackCount)")
        print("aacTrack=\(result.hasAACTrack)")
        print("playable=\(result.playable)")
        print(String(format: "peakAmplitude=%.6f", result.peakAmplitude))
        print("result=\(result.passedRecoveryChecks ? "PASS" : "NOT_PASSED")")
        exit(result.passedRecoveryChecks ? 0 : 2)
    } catch {
        FileHandle.standardError.write(Data(
            "recover failed: \(error.localizedDescription)\n".utf8
        ))
        exit(74)
    }
}

if arguments.first == "dual-capture" {
    guard let dualCaptureArguments = DualCaptureArguments(arguments) else {
        FileHandle.standardError.write(Data(
            "Usage: RecorderProbe dual-capture --seconds 1...30 --report PATH\n".utf8
        ))
        exit(64)
    }

    let result = await runDualCapture(dualCaptureArguments)
    let command = "env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "
        + "/usr/bin/xcrun swift run RecorderProbe "
        + arguments.joined(separator: " ")
    do {
        try writeReport(
            reportText(for: result, command: command),
            to: dualCaptureArguments.reportURL
        )
    } catch {
        FileHandle.standardError.write(Data(
            "Could not write probe report: \(error.localizedDescription)\n".utf8
        ))
        exit(74)
    }

    print("systemSamples=\(result.snapshot.system.sampleCount)")
    print("microphoneSamples=\(result.snapshot.microphone.sampleCount)")
    print("systemInvalidPTS=\(result.snapshot.system.invalidPresentationTimeCount)")
    print("microphoneInvalidPTS=\(result.snapshot.microphone.invalidPresentationTimeCount)")
    print("systemPTSMonotonic=\(result.snapshot.system.presentationTimesAreStrictlyIncreasing)")
    print("microphonePTSMonotonic=\(result.snapshot.microphone.presentationTimesAreStrictlyIncreasing)")
    print("stoppedEvents=\(result.snapshot.stoppedEventCount)")
    print("screenSamples=0")
    print("result=\(result.passed ? "PASS" : "NOT_PASSED")")
    exit(result.passed ? 0 : 2)
}

print(AppMetadata.bundleIdentifier)
print(AppMetadata.defaultRecordingRoot.path)
print(AppMetadata.defaultHotkey.displayText)
