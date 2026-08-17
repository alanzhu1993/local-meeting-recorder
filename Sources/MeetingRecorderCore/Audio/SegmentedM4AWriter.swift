import Darwin
import Foundation

public actor SegmentedM4AWriter: RecoverableAudioWriting {
    private enum State {
        case idle
        case running
        case operating
        case finished
        case failed
        case aborted
    }

    private struct Segment: Sendable {
        let index: Int64
        let writer: FragmentedMOVWriter
        let finalURL: URL
    }

    private let workingURL: URL
    private let sampleRate: Double
    private let channels: Int
    private let segmentFrames: Int64
    private var state: State = .idle
    private var currentSegment: Segment?
    private var completedSegments: [URL] = []
    private var lastEndFrame: Int64?

    public init(workingURL: URL) {
        self.init(
            workingURL: workingURL,
            sampleRate: 48_000,
            channels: 2,
            segmentFrames: 480_000
        )
    }

    init(
        workingURL: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        segmentFrames: Int64
    ) {
        self.workingURL = workingURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.segmentFrames = segmentFrames
    }

    public func start() async throws {
        guard case .idle = state else {
            throw writeFailure("The segmented writer can only be started once.")
        }
        guard segmentFrames > 0, sampleRate > 0, channels == 2 else {
            state = .failed
            throw writeFailure("The segmented writer configuration is invalid.")
        }
        let descriptor = workingURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor != -1 else {
            state = .failed
            throw writeFailure("The segmented working marker already exists or could not be created.")
        }
        _ = close(descriptor)
        state = .running
    }

    public func append(_ chunk: MixedAudioChunk) async throws {
        guard case .running = state else {
            throw writeFailure("Segmented audio cannot be appended in the current state.")
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

        state = .operating
        do {
            var sourceOffset = 0
            while sourceOffset < chunk.frameCount {
                let globalStart = chunk.startFrame + Int64(sourceOffset)
                let segmentIndex = globalStart / segmentFrames
                if currentSegment?.index != segmentIndex {
                    try await closeCurrentSegment()
                    currentSegment = try await startSegment(index: segmentIndex)
                }
                guard let currentSegment else {
                    throw writeFailure("Could not create the current audio segment.")
                }
                let segmentEnd = (segmentIndex + 1) * segmentFrames
                let frameCount = min(
                    chunk.frameCount - sourceOffset,
                    Int(segmentEnd - globalStart)
                )
                let sampleStart = sourceOffset * channels
                let sampleEnd = sampleStart + frameCount * channels
                let relativeChunk = MixedAudioChunk(
                    startFrame: globalStart - segmentIndex * segmentFrames,
                    frameCount: frameCount,
                    samples: Array(chunk.samples[sampleStart..<sampleEnd])
                )
                try await currentSegment.writer.append(relativeChunk)
                sourceOffset += frameCount
            }
            lastEndFrame = chunk.startFrame + Int64(chunk.frameCount)
            state = .running
        } catch let failure as RecordingFailure {
            state = .failed
            throw failure
        } catch {
            state = .failed
            throw writeFailure("Could not append segmented audio: \(error.localizedDescription)")
        }
    }

    public func finish(finalURL: URL) async throws -> URL {
        guard case .running = state else {
            throw writeFailure("The segmented writer is not in a finishable state.")
        }
        state = .operating
        do {
            try await closeCurrentSegment()
            let output = try await M4AFinalizer().merge(
                segmentURLs: completedSegments,
                outputURL: finalURL
            )
            for segmentURL in completedSegments {
                guard segmentURL.path.withCString({ unlink($0) }) == 0 else {
                    state = .failed
                    throw RecordingFailure(
                        code: .finalize,
                        message: "Merged audio was published, but a completed segment could not be removed."
                    )
                }
            }
            guard workingURL.path.withCString({ unlink($0) }) == 0 else {
                state = .failed
                throw RecordingFailure(
                    code: .finalize,
                    message: "Merged audio was published, but the working marker could not be removed."
                )
            }
            state = .finished
            return output
        } catch let failure as RecordingFailure {
            state = .failed
            throw failure
        } catch {
            state = .failed
            throw RecordingFailure(
                code: .finalize,
                message: "Could not finalize segmented audio: \(error.localizedDescription)"
            )
        }
    }

    public func abort() async {
        let segment = currentSegment
        state = .aborted
        await segment?.writer.abort()
    }

    private func startSegment(index: Int64) async throws -> Segment {
        let prefix = String(format: "%06lld", index)
        let directory = workingURL.deletingLastPathComponent()
        let base = workingURL.lastPathComponent
        let segmentWorkingURL = directory.appendingPathComponent(
            ".\(base).segment-\(prefix).inprogress.mov"
        )
        let segmentFinalURL = directory.appendingPathComponent(
            ".\(base).segment-\(prefix).m4a"
        )
        let writer = FragmentedMOVWriter(
            workingURL: segmentWorkingURL,
            sampleRate: sampleRate,
            channels: channels
        )
        try await writer.start()
        return Segment(index: index, writer: writer, finalURL: segmentFinalURL)
    }

    private func closeCurrentSegment() async throws {
        guard let segment = currentSegment else { return }
        currentSegment = nil
        let output = try await segment.writer.finish(finalURL: segment.finalURL)
        completedSegments.append(output)
    }

    private func writeFailure(_ message: String) -> RecordingFailure {
        RecordingFailure(code: .write, message: message)
    }
}
