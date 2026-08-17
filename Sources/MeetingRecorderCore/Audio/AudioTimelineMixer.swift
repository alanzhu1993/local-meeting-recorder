import CoreMedia
import Foundation

public struct PCMChunk: Sendable {
    public let source: CapturedAudioSource
    public let startFrame: Int64
    public let frameCount: Int
    public let samples: [Float]

    public init(
        source: CapturedAudioSource,
        startFrame: Int64,
        frameCount: Int,
        samples: [Float]
    ) {
        self.source = source
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.samples = samples
    }
}

public struct MixedAudioChunk: Sendable {
    public let startFrame: Int64
    public let frameCount: Int
    public let samples: [Float]

    public init(startFrame: Int64, frameCount: Int, samples: [Float]) {
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.samples = samples
    }
}

public enum AudioTimeline {
    public static func framePosition(
        for time: CMTime,
        origin: CMTime,
        sampleRate: Double
    ) -> Int64 {
        Int64((CMTimeGetSeconds(time - origin) * sampleRate).rounded())
    }
}

public struct AudioTimelineMixer: Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let chunkFrames: Int
    public let bufferedFrameCapacity: Int
    public private(set) var warnings: [RecordingFailure] = []

    public var bufferedFrameCount: Int {
        max(systemBuffer.count, microphoneBuffer.count)
    }

    private let stallFrames: Int64
    private var systemBuffer: FrameRingBuffer
    private var microphoneBuffer: FrameRingBuffer
    private var nextOutputFrame: Int64?
    private var systemLatestEnd: Int64?
    private var microphoneLatestEnd: Int64?
    private var systemLastStart: Int64?
    private var microphoneLastStart: Int64?
    private var systemLastEnd: Int64?
    private var microphoneLastEnd: Int64?
    private var hasEmittedOutput = false

    public init(sampleRate: Double, channels: Int, chunkFrames: Int) {
        precondition(sampleRate > 0)
        precondition(channels == 2, "The meeting recorder mixer only emits stereo PCM.")
        precondition(chunkFrames > 0)
        self.sampleRate = sampleRate
        self.channels = channels
        self.chunkFrames = chunkFrames
        stallFrames = max(1, Int64((sampleRate * 0.25).rounded(.up)))
        bufferedFrameCapacity = max(
            chunkFrames * 4,
            Int(stallFrames) + chunkFrames * 2
        )
        systemBuffer = FrameRingBuffer(capacity: bufferedFrameCapacity, channels: channels)
        microphoneBuffer = FrameRingBuffer(capacity: bufferedFrameCapacity, channels: channels)
    }

    public mutating func ingest(_ chunk: PCMChunk) -> [MixedAudioChunk] {
        guard chunk.frameCount > 0, chunk.samples.count == chunk.frameCount * channels else {
            recordWarning("Discarded an audio chunk whose frame count did not match its samples.")
            return []
        }

        if let lastStart = lastStart(for: chunk.source), chunk.startFrame < lastStart {
            recordWarning("Discarded an audio chunk with a regressing presentation timestamp.")
            return []
        }
        setLastStart(chunk.startFrame, for: chunk.source)

        if !hasEmittedOutput {
            nextOutputFrame = min(nextOutputFrame ?? chunk.startFrame, chunk.startFrame)
        }
        guard let outputFrame = nextOutputFrame else { return [] }
        let chunkEnd = chunk.startFrame + Int64(chunk.frameCount)
        var acceptedStart = chunk.startFrame
        if let sourceEnd = lastEnd(for: chunk.source) {
            acceptedStart = max(acceptedStart, sourceEnd)
        }
        if hasEmittedOutput {
            acceptedStart = max(acceptedStart, outputFrame)
        }
        if acceptedStart > chunk.startFrame {
            recordWarning("Trimmed overlapping or late audio frames that were already on the timeline.")
        }
        setLastEnd(max(lastEnd(for: chunk.source) ?? chunkEnd, chunkEnd), for: chunk.source)
        guard acceptedStart < chunkEnd else {
            return []
        }

        var output: [MixedAudioChunk] = []
        var sourceOffset = Int(acceptedStart - chunk.startFrame)
        while sourceOffset < chunk.frameCount {
            let frame = chunk.startFrame + Int64(sourceOffset)
            advanceSource(chunk.source, through: frame)
            output.append(contentsOf: drainCompleteChunks())

            guard let cursor = nextOutputFrame else { break }
            if frame >= cursor + Int64(bufferedFrameCapacity) {
                recordWarning("Discarded audio that exceeded the bounded alignment window.")
                break
            }

            let framesToCopy = min(chunkFrames, chunk.frameCount - sourceOffset)
            store(
                source: chunk.source,
                startFrame: frame,
                frameCount: framesToCopy,
                samples: chunk.samples,
                sampleOffset: sourceOffset * channels
            )
            sourceOffset += framesToCopy
            advanceSource(chunk.source, through: frame + Int64(framesToCopy))
            output.append(contentsOf: drainCompleteChunks())
        }
        return output
    }

    public mutating func flush() -> [MixedAudioChunk] {
        guard let cursor = nextOutputFrame else { return [] }
        let finalFrame = max(systemLatestEnd ?? cursor, microphoneLatestEnd ?? cursor)
        var output = drain(upTo: finalFrame, includePartialChunk: true)
        if output.isEmpty, finalFrame > cursor {
            output = [makeOutput(startFrame: cursor, frameCount: Int(finalFrame - cursor))]
            nextOutputFrame = finalFrame
        }
        return output
    }

    private mutating func drainCompleteChunks() -> [MixedAudioChunk] {
        guard let safeFrame = safeOutputEnd() else { return [] }
        return drain(upTo: safeFrame, includePartialChunk: false)
    }

    private mutating func drain(
        upTo endFrame: Int64,
        includePartialChunk: Bool
    ) -> [MixedAudioChunk] {
        var output: [MixedAudioChunk] = []
        while let cursor = nextOutputFrame, cursor < endFrame {
            let available = Int(endFrame - cursor)
            guard available >= chunkFrames || includePartialChunk else { break }
            let frames = includePartialChunk ? min(chunkFrames, available) : chunkFrames
            output.append(makeOutput(startFrame: cursor, frameCount: frames))
            nextOutputFrame = cursor + Int64(frames)
        }
        return output
    }

    private mutating func makeOutput(startFrame: Int64, frameCount: Int) -> MixedAudioChunk {
        hasEmittedOutput = true
        let hasBothSources = systemLatestEnd != nil && microphoneLatestEnd != nil
        let gain: Float = hasBothSources ? 0.5 : 1
        var samples = Array(repeating: Float.zero, count: frameCount * channels)
        for offset in 0..<frameCount {
            let frame = startFrame + Int64(offset)
            let system = systemBuffer.take(frame: frame)
            let microphone = microphoneBuffer.take(frame: frame)
            for channel in 0..<channels {
                let value = gain * (system?[channel] ?? 0)
                    + gain * (microphone?[channel] ?? 0)
                samples[offset * channels + channel] = min(1, max(-1, value))
            }
        }
        return MixedAudioChunk(startFrame: startFrame, frameCount: frameCount, samples: samples)
    }

    private func safeOutputEnd() -> Int64? {
        switch (systemLatestEnd, microphoneLatestEnd) {
        case let (system?, microphone?):
            let commonEnd = min(system, microphone)
            let leadingEnd = max(system, microphone)
            return max(commonEnd, leadingEnd - stallFrames)
        case let (system?, nil):
            guard let cursor = nextOutputFrame, system - cursor > stallFrames else { return nil }
            return system - stallFrames
        case let (nil, microphone?):
            guard let cursor = nextOutputFrame, microphone - cursor > stallFrames else { return nil }
            return microphone - stallFrames
        case (nil, nil):
            return nil
        }
    }

    private mutating func store(
        source: CapturedAudioSource,
        startFrame: Int64,
        frameCount: Int,
        samples: [Float],
        sampleOffset: Int
    ) {
        switch source {
        case .system:
            systemBuffer.store(
                startFrame: startFrame,
                frameCount: frameCount,
                samples: samples,
                sampleOffset: sampleOffset
            )
        case .microphone:
            microphoneBuffer.store(
                startFrame: startFrame,
                frameCount: frameCount,
                samples: samples,
                sampleOffset: sampleOffset
            )
        }
    }

    private func lastStart(for source: CapturedAudioSource) -> Int64? {
        switch source {
        case .system: systemLastStart
        case .microphone: microphoneLastStart
        }
    }

    private mutating func setLastStart(_ frame: Int64, for source: CapturedAudioSource) {
        switch source {
        case .system: systemLastStart = frame
        case .microphone: microphoneLastStart = frame
        }
    }

    private func lastEnd(for source: CapturedAudioSource) -> Int64? {
        switch source {
        case .system: systemLastEnd
        case .microphone: microphoneLastEnd
        }
    }

    private mutating func setLastEnd(_ frame: Int64, for source: CapturedAudioSource) {
        switch source {
        case .system: systemLastEnd = frame
        case .microphone: microphoneLastEnd = frame
        }
    }

    private mutating func advanceSource(_ source: CapturedAudioSource, through frame: Int64) {
        switch source {
        case .system:
            systemLatestEnd = max(systemLatestEnd ?? frame, frame)
        case .microphone:
            microphoneLatestEnd = max(microphoneLatestEnd ?? frame, frame)
        }
    }

    private mutating func recordWarning(_ message: String) {
        if warnings.count == 64 {
            warnings.removeFirst()
        }
        warnings.append(RecordingFailure(code: .capture, message: message))
    }
}

private struct FrameRingBuffer: Sendable {
    let capacity: Int
    let channels: Int
    private var tags: [Int64]
    private var values: [Float]
    private(set) var count = 0

    init(capacity: Int, channels: Int) {
        self.capacity = capacity
        self.channels = channels
        tags = Array(repeating: .min, count: capacity)
        values = Array(repeating: 0, count: capacity * channels)
    }

    mutating func store(
        startFrame: Int64,
        frameCount: Int,
        samples: [Float],
        sampleOffset: Int
    ) {
        for offset in 0..<frameCount {
            let frame = startFrame + Int64(offset)
            let slot = index(for: frame)
            if tags[slot] == .min {
                count += 1
            }
            tags[slot] = frame
            let destination = slot * channels
            let source = sampleOffset + offset * channels
            for channel in 0..<channels {
                values[destination + channel] = samples[source + channel]
            }
        }
    }

    mutating func take(frame: Int64) -> [Float]? {
        let slot = index(for: frame)
        guard tags[slot] == frame else { return nil }
        tags[slot] = .min
        count -= 1
        let start = slot * channels
        return Array(values[start..<(start + channels)])
    }

    private func index(for frame: Int64) -> Int {
        let raw = frame % Int64(capacity)
        return Int(raw >= 0 ? raw : raw + Int64(capacity))
    }
}
