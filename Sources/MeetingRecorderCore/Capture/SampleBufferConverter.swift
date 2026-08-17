@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public final class SampleBufferConverter: @unchecked Sendable {
    public static let outputSampleRate = 48_000.0
    public static let outputChannels: AVAudioChannelCount = 2

    private static let conversionSafetyFrames: UInt64 = 32
    private static let maximumPrimeInputFrames: UInt64 = 4_096

    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private var systemConverter: ConverterState?
    private var microphoneConverter: ConverterState?

    public init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: Self.outputChannels,
            interleaved: true
        )!
    }

    public func convert(
        _ sample: CapturedAudioSample,
        sessionStartPTS: CMTime
    ) throws -> PCMChunk {
        lock.lock()
        defer { lock.unlock() }

        guard
            sample.presentationTime.isValid,
            sample.presentationTime.isNumeric,
            sessionStartPTS.isValid,
            sessionStartPTS.isNumeric
        else {
            throw RecordingFailure(code: .capture, message: "Audio sample has an invalid presentation timestamp.")
        }

        let input = try makeInputBuffer(from: sample.buffer)
        let presentationFrame = AudioTimeline.framePosition(
            for: sample.presentationTime,
            origin: sessionStartPTS,
            sampleRate: Self.outputSampleRate
        )
        var state = try converterState(for: sample.source, inputFormat: input.format)
        if let outputCursor = state.outputCursor,
           abs(presentationFrame - outputCursor) > state.discontinuityToleranceFrames {
            state = try replaceConverterState(
                for: sample.source,
                inputFormat: input.format
            )
        }
        let startFrame = state.outputCursor ?? presentationFrame
        let capacity = try outputFrameCapacity(for: input, converter: state.converter)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw RecordingFailure(code: .capture, message: "Could not allocate converted audio storage.")
        }

        let inputProvider = ConverterInputProvider(buffer: input)
        var conversionError: NSError?
        let status = state.converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        if let conversionError {
            throw RecordingFailure(code: .capture, message: "Could not convert captured audio: \(conversionError.localizedDescription)")
        }
        guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else {
            throw RecordingFailure(code: .capture, message: "Audio converter produced no PCM frames (status \(status.rawValue)).")
        }

        let samples = try interleavedFloatSamples(from: output)
        state.outputCursor = startFrame + Int64(output.frameLength)
        return PCMChunk(
            source: sample.source,
            startFrame: startFrame,
            frameCount: Int(output.frameLength),
            samples: samples
        )
    }

    public func drain(source: CapturedAudioSource) throws -> [PCMChunk] {
        lock.lock()
        defer { lock.unlock() }
        guard let state = storedConverterState(for: source),
              var outputCursor = state.outputCursor else {
            return []
        }

        var chunks: [PCMChunk] = []
        let inputProvider = ConverterEndOfStreamProvider()
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 4_096
            ) else {
                throw RecordingFailure(code: .capture, message: "Could not allocate converter drain storage.")
            }
            var conversionError: NSError?
            let status = state.converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                inputProvider.next(status: inputStatus)
            }
            if let conversionError {
                throw RecordingFailure(
                    code: .capture,
                    message: "Could not drain captured audio: \(conversionError.localizedDescription)"
                )
            }
            if output.frameLength > 0 {
                chunks.append(PCMChunk(
                    source: source,
                    startFrame: outputCursor,
                    frameCount: Int(output.frameLength),
                    samples: try interleavedFloatSamples(from: output)
                ))
                outputCursor += Int64(output.frameLength)
            }
            if status == .endOfStream || (status == .inputRanDry && output.frameLength == 0) {
                break
            }
        }
        clearConverterState(for: source)
        return chunks
    }

    private func outputFrameCapacity(
        for input: AVAudioPCMBuffer,
        converter: AVAudioConverter
    ) throws -> AVAudioFrameCount {
        let inputSampleRate = input.format.sampleRate
        guard inputSampleRate.isFinite, inputSampleRate > 0 else {
            throw RecordingFailure(code: .capture, message: "Captured audio has an invalid sample rate.")
        }

        if inputSampleRate == Self.outputSampleRate {
            return max(1, input.frameLength)
        }

        let maximumCapacity = UInt64(AVAudioFrameCount.max)
        let ratio = Self.outputSampleRate / inputSampleRate
        let expectedValue = ceil(Double(input.frameLength) * ratio)
        guard expectedValue.isFinite, expectedValue > 0 else {
            throw RecordingFailure(code: .capture, message: "Captured audio has an invalid converted frame count.")
        }
        let expectedFrames = UInt64(min(expectedValue, Double(maximumCapacity)))

        let primeInfo = converter.primeInfo
        let reportedPrimeFrames = clampedSum(
            UInt64(primeInfo.leadingFrames),
            UInt64(primeInfo.trailingFrames),
            upperBound: Self.maximumPrimeInputFrames
        )
        let scaledPrimeValue = ceil(Double(reportedPrimeFrames) * ratio)
        let scaledPrimeFrames = UInt64(min(scaledPrimeValue, Double(maximumCapacity)))
        let withPrime = clampedSum(
            expectedFrames,
            scaledPrimeFrames,
            upperBound: maximumCapacity
        )
        let withSafety = clampedSum(
            withPrime,
            Self.conversionSafetyFrames,
            upperBound: maximumCapacity
        )
        return AVAudioFrameCount(max(1, withSafety))
    }

    private func clampedSum(
        _ left: UInt64,
        _ right: UInt64,
        upperBound: UInt64
    ) -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { return upperBound }
        return min(sum, upperBound)
    }

    private func converterState(
        for source: CapturedAudioSource,
        inputFormat: AVAudioFormat
    ) throws -> ConverterState {
        let signature = InputFormatSignature(inputFormat.streamDescription.pointee)
        let existing = storedConverterState(for: source)
        if let existing, existing.signature == signature {
            return existing
        }
        return try replaceConverterState(for: source, inputFormat: inputFormat)
    }

    private func replaceConverterState(
        for source: CapturedAudioSource,
        inputFormat: AVAudioFormat
    ) throws -> ConverterState {
        let signature = InputFormatSignature(inputFormat.streamDescription.pointee)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingFailure(code: .capture, message: "The captured audio format cannot be converted to 48 kHz stereo PCM.")
        }
        converter.primeMethod = .none
        let state = ConverterState(signature: signature, converter: converter)
        switch source {
        case .system: systemConverter = state
        case .microphone: microphoneConverter = state
        }
        return state
    }

    private func storedConverterState(for source: CapturedAudioSource) -> ConverterState? {
        switch source {
        case .system: systemConverter
        case .microphone: microphoneConverter
        }
    }

    private func clearConverterState(for source: CapturedAudioSource) {
        switch source {
        case .system: systemConverter = nil
        case .microphone: microphoneConverter = nil
        }
    }

    private func makeInputBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw RecordingFailure(code: .capture, message: "Captured audio is missing its stream format.")
        }
        guard basicDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw RecordingFailure(code: .capture, message: "Captured audio is not linear PCM.")
        }
        guard let inputFormat = AVAudioFormat(streamDescription: basicDescription) else {
            throw RecordingFailure(code: .capture, message: "Captured audio has an unsupported PCM format.")
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              frameCount <= Int(AVAudioFrameCount.max),
              let input = AVAudioPCMBuffer(
                  pcmFormat: inputFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            throw RecordingFailure(code: .capture, message: "Captured audio contains no PCM frames.")
        }
        input.frameLength = AVAudioFrameCount(frameCount)

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size else {
            throw osStatusFailure(status, operation: "read captured audio layout")
        }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let sourceList = rawList.assumingMemoryBound(to: AudioBufferList.self)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw osStatusFailure(status, operation: "copy captured audio")
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw RecordingFailure(code: .capture, message: "Captured audio buffer layout did not match its stream format.")
        }
        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let destination = destinationBuffers[index]
            guard
                let sourceData = source.mData,
                let destinationData = destination.mData,
                source.mDataByteSize <= destination.mDataByteSize
            else {
                throw RecordingFailure(code: .capture, message: "Captured audio buffer storage was invalid.")
            }
            destinationData.copyMemory(
                from: sourceData,
                byteCount: Int(source.mDataByteSize)
            )
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
        }
        _ = retainedBlockBuffer
        return input
    }

    private func interleavedFloatSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard buffers.count == 1, let data = buffers[0].mData else {
            throw RecordingFailure(code: .capture, message: "Converted PCM was not interleaved stereo audio.")
        }
        let count = Int(buffer.frameLength) * Int(Self.outputChannels)
        let pointer = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func osStatusFailure(_ status: OSStatus, operation: String) -> RecordingFailure {
        RecordingFailure(
            code: .capture,
            message: "Could not \(operation) (OSStatus \(status))."
        )
    }
}

private struct InputFormatSignature: Equatable {
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    init(_ description: AudioStreamBasicDescription) {
        sampleRate = description.mSampleRate
        formatID = description.mFormatID
        formatFlags = description.mFormatFlags
        bytesPerPacket = description.mBytesPerPacket
        framesPerPacket = description.mFramesPerPacket
        bytesPerFrame = description.mBytesPerFrame
        channelsPerFrame = description.mChannelsPerFrame
        bitsPerChannel = description.mBitsPerChannel
    }
}

private final class ConverterState {
    let signature: InputFormatSignature
    let converter: AVAudioConverter
    let discontinuityToleranceFrames: Int64
    var outputCursor: Int64?

    init(signature: InputFormatSignature, converter: AVAudioConverter) {
        self.signature = signature
        self.converter = converter
        discontinuityToleranceFrames = max(
            2,
            Int64(ceil(SampleBufferConverter.outputSampleRate / signature.sampleRate * 2))
        )
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

private final class ConverterEndOfStreamProvider: @unchecked Sendable {
    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        status.pointee = .endOfStream
        return nil
    }
}
