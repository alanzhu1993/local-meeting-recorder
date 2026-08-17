@preconcurrency import AVFoundation
import CoreMedia
import Foundation

struct FragmentedMOVWriterHooks: Sendable {
    let readiness: (@Sendable () -> Bool)?
    let readinessTimeout: Duration
    let beforeRecovery: (@Sendable () async throws -> Void)?

    init(
        readiness: (@Sendable () -> Bool)? = nil,
        readinessTimeout: Duration = .seconds(5),
        beforeRecovery: (@Sendable () async throws -> Void)? = nil
    ) {
        self.readiness = readiness
        self.readinessTimeout = readinessTimeout
        self.beforeRecovery = beforeRecovery
    }
}

public actor FragmentedMOVWriter: RecoverableAudioWriting {
    private enum State {
        case idle
        case writing(WriterSession)
        case appending(WriterSession, UUID)
        case finishing(WriterSession, UUID, URL)
        case aborting(WriterSession, UUID)
        case finished(URL)
        case failed(WriterSession?)
        case aborted
    }

    private struct InFlightOperation: Sendable {
        let token: UUID
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private let workingURL: URL
    private let sampleRate: Double
    private let channels: Int
    private let hooks: FragmentedMOVWriterHooks
    private var state: State = .idle
    private var lastEndFrame: Int64?
    private var inFlight: InFlightOperation?
    private var abortTask: Task<Void, Never>?

    public init(
        workingURL: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2
    ) {
        self.workingURL = workingURL
        self.sampleRate = sampleRate
        self.channels = channels
        hooks = FragmentedMOVWriterHooks()
    }

    init(
        workingURL: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        hooks: FragmentedMOVWriterHooks
    ) {
        self.workingURL = workingURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.hooks = hooks
    }

    public func start() async throws {
        guard case .idle = state else {
            throw writeFailure("The audio writer can only be started once.")
        }
        guard !FileManager.default.fileExists(atPath: workingURL.path) else {
            state = .failed(nil)
            throw writeFailure("The working recording already exists and was not replaced.")
        }
        guard FileManager.default.fileExists(
            atPath: workingURL.deletingLastPathComponent().path
        ) else {
            state = .failed(nil)
            throw writeFailure("The working recording directory does not exist.")
        }

        do {
            let writer = try AVAssetWriter(outputURL: workingURL, fileType: .mov)
            writer.initialMovieFragmentInterval = CMTime(
                seconds: 1,
                preferredTimescale: 1_000
            )
            writer.movieFragmentInterval = CMTime(
                seconds: 10,
                preferredTimescale: 1_000
            )
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                state = .failed(nil)
                throw writeFailure("AVAssetWriter rejected the AAC audio input.")
            }
            writer.add(input)
            guard writer.startWriting() else {
                state = .failed(nil)
                throw writerFailure(writer, operation: "start audio writing")
            }
            writer.startSession(atSourceTime: .zero)
            state = .writing(WriterSession(writer: writer, input: input))
        } catch let failure as RecordingFailure {
            throw failure
        } catch {
            state = .failed(nil)
            throw writeFailure("Could not create the working recording: \(error.localizedDescription)")
        }
    }

    public func append(_ chunk: MixedAudioChunk) async throws {
        guard case let .writing(session) = state else {
            throw writeFailure("Audio cannot be appended while the writer is not recording.")
        }
        guard
            chunk.startFrame >= 0,
            chunk.frameCount > 0,
            chunk.samples.count == chunk.frameCount * channels
        else {
            state = .failed(session)
            throw writeFailure("The mixed audio chunk has an invalid frame or sample count.")
        }
        if let lastEndFrame, chunk.startFrame < lastEndFrame {
            state = .failed(session)
            throw writeFailure("The mixed audio timestamp moved backwards or overlapped prior audio.")
        }

        let token = UUID()
        let waitTask = Task {
            try await Self.waitUntilReady(session: session, hooks: hooks)
        }
        state = .appending(session, token)
        inFlight = InFlightOperation(
            token: token,
            cancel: { waitTask.cancel() },
            wait: { _ = await waitTask.result }
        )

        do {
            try await withTaskCancellationHandler {
                try await waitTask.value
            } onCancel: {
                waitTask.cancel()
            }
        } catch {
            guard ownsAppend(token) else {
                throw writeFailure("Audio append was cancelled because the writer was aborted.")
            }
            inFlight = nil
            state = .failed(session)
            throw Self.writeFailure(from: error, operation: "wait for audio encoder readiness")
        }
        guard ownsAppend(token), !Task.isCancelled else {
            throw writeFailure("Audio append was cancelled because the writer was aborted.")
        }
        inFlight = nil
        state = .writing(session)

        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try Self.makeSampleBuffer(
                from: chunk,
                sampleRate: sampleRate,
                channels: channels
            )
        } catch let failure as RecordingFailure {
            state = .failed(session)
            throw failure
        } catch {
            state = .failed(session)
            throw writeFailure("Could not package mixed PCM for writing: \(error.localizedDescription)")
        }
        guard session.writer.status == .writing else {
            state = .failed(session)
            throw writerFailure(session.writer, operation: "continue audio writing")
        }
        guard session.input.append(sampleBuffer) else {
            state = .failed(session)
            throw writerFailure(session.writer, operation: "append mixed audio")
        }
        lastEndFrame = chunk.startFrame + Int64(chunk.frameCount)
    }

    public func finish(finalURL: URL) async throws -> URL {
        guard case let .writing(session) = state else {
            throw writeFailure("The audio writer is not in a finishable state.")
        }
        let token = UUID()
        let workingURL = self.workingURL
        let hooks = self.hooks
        let finishTask = Task {
            try Task.checkCancellation()
            session.input.markAsFinished()
            await session.writer.finishWriting()
            guard session.writer.status == .completed else {
                throw Self.writerFailure(
                    session.writer,
                    operation: "finish the working recording"
                )
            }
            try Task.checkCancellation()
            try await hooks.beforeRecovery?()
            try Task.checkCancellation()
            return try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: finalURL
            )
        }
        state = .finishing(session, token, finalURL)
        inFlight = InFlightOperation(
            token: token,
            cancel: { finishTask.cancel() },
            wait: { _ = await finishTask.result }
        )

        do {
            let output = try await withTaskCancellationHandler {
                try await finishTask.value
            } onCancel: {
                finishTask.cancel()
            }
            guard ownsFinish(token) else {
                throw writeFailure("Finish completed after another operation took ownership.")
            }
            inFlight = nil
            state = .finished(output)
            return output
        } catch let failure as RecordingFailure {
            guard ownsFinish(token) else { throw failure }
            inFlight = nil
            state = .failed(session)
            throw failure
        } catch {
            guard ownsFinish(token) else {
                throw writeFailure("Finish was cancelled because the writer was aborted.")
            }
            inFlight = nil
            state = .failed(session)
            if error is CancellationError {
                throw writeFailure("Finish was cancelled before publishing the recording.")
            }
            throw RecordingFailure(
                code: .finalize,
                message: "Could not finalize the recording: \(error.localizedDescription)"
            )
        }
    }

    public func abort() async {
        if let abortTask {
            await abortTask.value
            return
        }

        let session: WriterSession
        let committedURL: URL?
        switch state {
        case .idle:
            state = .aborted
            return
        case let .writing(current):
            session = current
            committedURL = nil
        case let .appending(current, _):
            session = current
            committedURL = nil
        case let .finishing(current, _, finalURL):
            session = current
            committedURL = finalURL
        case let .failed(current?):
            session = current
            committedURL = nil
        case .failed(nil), .aborted:
            state = .aborted
            return
        case .finished:
            return
        case .aborting:
            return
        }

        let token = UUID()
        let operation = inFlight
        operation?.cancel()
        let task = Task {
            await operation?.wait()
            await Self.preserveWorkingFile(session)
        }
        abortTask = task
        state = .aborting(session, token)
        await task.value

        guard ownsAbort(token) else { return }
        inFlight = nil
        abortTask = nil
        if let committedURL,
           FileManager.default.fileExists(atPath: committedURL.path),
           !FileManager.default.fileExists(atPath: workingURL.path) {
            state = .finished(committedURL)
        } else {
            state = .aborted
        }
    }

    private func ownsAppend(_ token: UUID) -> Bool {
        guard case let .appending(_, current) = state else { return false }
        return current == token && inFlight?.token == token
    }

    private func ownsFinish(_ token: UUID) -> Bool {
        guard case let .finishing(_, current, _) = state else { return false }
        return current == token && inFlight?.token == token
    }

    private func ownsAbort(_ token: UUID) -> Bool {
        guard case let .aborting(_, current) = state else { return false }
        return current == token
    }

    private static func waitUntilReady(
        session: WriterSession,
        hooks: FragmentedMOVWriterHooks
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: hooks.readinessTimeout)
        while true {
            try Task.checkCancellation()
            guard session.writer.status == .writing else {
                throw writerFailure(
                    session.writer,
                    operation: "continue audio writing"
                )
            }
            let ready = hooks.readiness?() ?? session.input.isReadyForMoreMediaData
            if ready { return }
            guard clock.now < deadline else {
                throw RecordingFailure(
                    code: .write,
                    message: "Timed out waiting for audio encoder backpressure to clear."
                )
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func preserveWorkingFile(_ session: WriterSession) async {
        guard session.writer.status == .writing else { return }
        session.input.markAsFinished()
        await session.writer.finishWriting()
    }

    private func writeFailure(_ message: String) -> RecordingFailure {
        RecordingFailure(code: .write, message: message)
    }

    private static func writeFailure(
        from error: Error,
        operation: String
    ) -> RecordingFailure {
        if let failure = error as? RecordingFailure { return failure }
        if error is CancellationError {
            return RecordingFailure(code: .write, message: "Cancelled while attempting to \(operation).")
        }
        return RecordingFailure(
            code: .write,
            message: "Could not \(operation): \(error.localizedDescription)"
        )
    }

    private func writerFailure(
        _ writer: AVAssetWriter,
        operation: String
    ) -> RecordingFailure {
        Self.writerFailure(writer, operation: operation)
    }

    private static func writerFailure(
        _ writer: AVAssetWriter,
        operation: String
    ) -> RecordingFailure {
        let detail = writer.error?.localizedDescription ?? "unknown AVAssetWriter error"
        return RecordingFailure(code: .write, message: "Could not \(operation): \(detail)")
    }

    private static func makeSampleBuffer(
        from chunk: MixedAudioChunk,
        sampleRate: Double,
        channels: Int
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let byteCount = chunk.frameCount * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RecordingFailure(
                code: .write,
                message: "Could not allocate audio sample storage (OSStatus \(status))."
            )
        }
        status = chunk.samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw RecordingFailure(
                code: .write,
                message: "Could not copy mixed audio samples (OSStatus \(status))."
            )
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw RecordingFailure(
                code: .write,
                message: "Could not describe mixed PCM (OSStatus \(status))."
            )
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: chunk.frameCount,
            presentationTimeStamp: CMTime(
                value: chunk.startFrame,
                timescale: CMTimeScale(sampleRate)
            ),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RecordingFailure(
                code: .write,
                message: "Could not create an audio sample buffer (OSStatus \(status))."
            )
        }
        return sampleBuffer
    }
}

private final class WriterSession: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }
}
