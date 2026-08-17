@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public actor FragmentedMOVWriter: RecoverableAudioWriting {
    private enum State {
        case idle
        case writing(WriterSession)
        case finishing
        case finished(URL)
        case failed
        case aborted
    }

    private let workingURL: URL
    private let sampleRate: Double
    private let channels: Int
    private var state: State = .idle
    private var lastEndFrame: Int64?

    public init(
        workingURL: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2
    ) {
        self.workingURL = workingURL
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public func start() async throws {
        guard case .idle = state else {
            throw writeFailure("The audio writer can only be started once.")
        }
        guard !FileManager.default.fileExists(atPath: workingURL.path) else {
            state = .failed
            throw writeFailure("The working recording already exists and was not replaced.")
        }
        guard FileManager.default.fileExists(
            atPath: workingURL.deletingLastPathComponent().path
        ) else {
            state = .failed
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
                state = .failed
                throw writeFailure("AVAssetWriter rejected the AAC audio input.")
            }
            writer.add(input)
            guard writer.startWriting() else {
                state = .failed
                throw writerFailure(writer, operation: "start audio writing")
            }
            writer.startSession(atSourceTime: .zero)
            state = .writing(WriterSession(writer: writer, input: input))
        } catch let failure as RecordingFailure {
            throw failure
        } catch {
            state = .failed
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
            state = .failed
            throw writeFailure("The mixed audio chunk has an invalid frame or sample count.")
        }
        if let lastEndFrame, chunk.startFrame < lastEndFrame {
            state = .failed
            throw writeFailure("The mixed audio timestamp moved backwards or overlapped prior audio.")
        }
        guard session.writer.status == .writing else {
            state = .failed
            throw writerFailure(session.writer, operation: "continue audio writing")
        }
        guard session.input.isReadyForMoreMediaData else {
            state = .failed
            throw writeFailure("The audio encoder could not accept data at the capture rate.")
        }

        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try Self.makeSampleBuffer(
                from: chunk,
                sampleRate: sampleRate,
                channels: channels
            )
        } catch let failure as RecordingFailure {
            state = .failed
            throw failure
        } catch {
            state = .failed
            throw writeFailure("Could not package mixed PCM for writing: \(error.localizedDescription)")
        }
        guard session.input.append(sampleBuffer) else {
            state = .failed
            throw writerFailure(session.writer, operation: "append mixed audio")
        }
        lastEndFrame = chunk.startFrame + Int64(chunk.frameCount)
    }

    public func finish(finalURL: URL) async throws -> URL {
        guard case let .writing(session) = state else {
            throw writeFailure("The audio writer is not in a finishable state.")
        }
        state = .finishing
        session.input.markAsFinished()
        await session.writer.finishWriting()
        guard session.writer.status == .completed else {
            state = .failed
            throw writerFailure(session.writer, operation: "finish the working recording")
        }

        do {
            let output = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: finalURL
            )
            state = .finished(output)
            return output
        } catch let failure as RecordingFailure {
            state = .failed
            throw failure
        } catch {
            state = .failed
            throw RecordingFailure(
                code: .finalize,
                message: "Could not finalize the recording: \(error.localizedDescription)"
            )
        }
    }

    public func abort() async {
        guard case let .writing(session) = state else {
            state = .aborted
            return
        }
        state = .finishing
        session.input.markAsFinished()
        await session.writer.finishWriting()
        state = .aborted
    }

    private func writeFailure(_ message: String) -> RecordingFailure {
        RecordingFailure(code: .write, message: message)
    }

    private func writerFailure(
        _ writer: AVAssetWriter,
        operation: String
    ) -> RecordingFailure {
        let detail = writer.error?.localizedDescription ?? "unknown AVAssetWriter error"
        return writeFailure("Could not \(operation): \(detail)")
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

private final class WriterSession {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }
}
