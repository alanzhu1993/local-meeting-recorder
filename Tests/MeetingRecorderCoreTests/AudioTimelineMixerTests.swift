import CoreMedia
import XCTest
@testable import MeetingRecorderCore

final class AudioTimelineMixerTests: XCTestCase {
    func testAlignsSourcesByPresentationFrame() {
        var mixer = AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 4)
        _ = mixer.ingest(.fixture(source: .system, startFrame: 0, monoValues: [1, 0, 0, 0]))

        let output = mixer.ingest(
            .fixture(source: .microphone, startFrame: 1, monoValues: [1, 0, 0, 0])
        )

        XCTAssertFloatArraysEqual(output.flatMap(\.leftChannel), [0.5, 0.5, 0, 0])
    }

    func testKeepsSystemAtOriginalAmplitudeWhenMicrophoneIsMissing() {
        var mixer = AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 4)
        _ = mixer.ingest(.fixture(source: .system, startFrame: 0, monoValues: [0.4, 0.2, 0, 0]))

        let output = mixer.flush()

        XCTAssertFloatArraysEqual(output.flatMap(\.leftChannel), [0.4, 0.2, 0, 0])
    }

    func testClipsMixedSamplesToFloatRange() {
        var mixer = AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 4)
        _ = mixer.ingest(.fixture(source: .system, startFrame: 0, monoValues: [2, -2, 0.5, -0.5]))

        let output = mixer.ingest(
            .fixture(source: .microphone, startFrame: 0, monoValues: [2, -2, 0.5, -0.5])
        )

        XCTAssertFloatArraysEqual(output.flatMap(\.leftChannel), [1, -1, 0.5, -0.5])
    }

    func testAdvancesWithSilenceAfterOtherSourceStallsFor250Milliseconds() {
        var mixer = AudioTimelineMixer(sampleRate: 16, channels: 2, chunkFrames: 4)
        _ = mixer.ingest(.fixture(source: .microphone, startFrame: 0, monoValues: [0, 0, 0, 0]))
        let initial = mixer.ingest(
            .fixture(source: .system, startFrame: 0, monoValues: Array(repeating: 0.4, count: 8))
        )
        XCTAssertEqual(initial.map(\.startFrame), [0])

        let afterStall = mixer.ingest(
            .fixture(source: .system, startFrame: 8, monoValues: Array(repeating: 0.4, count: 4))
        )

        XCTAssertEqual(afterStall.map(\.startFrame), [4])
        XCTAssertFloatArraysEqual(afterStall.flatMap(\.leftChannel), Array(repeating: 0.2, count: 4))
    }

    func testDropsRegressingTimestampAndExposesWarningWithoutGrowingBuffer() {
        var mixer = AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 4)
        _ = mixer.ingest(.fixture(source: .system, startFrame: 10, monoValues: [0.1, 0.1, 0.1, 0.1]))

        let output = mixer.ingest(
            .fixture(source: .system, startFrame: 9, monoValues: Array(repeating: 1, count: 20_000))
        )

        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(mixer.warnings.count, 1)
        XCTAssertEqual(mixer.warnings[0].code, .capture)
        XCTAssertLessThanOrEqual(mixer.bufferedFrameCount, mixer.bufferedFrameCapacity)
    }

    func testConvertsMonoInt16SampleBufferTo48kStereoInterleavedFloat() throws {
        let inputRate = 44_100.0
        let values = (0..<441).map { index in
            Int16(Double(Int16.max) * 0.25 * sin(2 * Double.pi * 440 * Double(index) / inputRate))
        }
        let presentationTime = CMTime(seconds: 1.5, preferredTimescale: 44_100)
        let buffer = try AudioTestFactory.int16MonoSampleBuffer(
            sampleRate: inputRate,
            values: values,
            presentationTime: presentationTime
        )
        let converter = SampleBufferConverter()

        let chunk = try converter.convert(
            CapturedAudioSample(
                source: .microphone,
                buffer: buffer,
                presentationTime: presentationTime
            ),
            sessionStartPTS: CMTime(seconds: 1, preferredTimescale: 48_000)
        )

        XCTAssertEqual(chunk.source, .microphone)
        XCTAssertEqual(chunk.startFrame, 24_000)
        XCTAssertEqual(chunk.samples.count, chunk.frameCount * 2)
        XCTAssertGreaterThanOrEqual(chunk.frameCount, 479)
        XCTAssertLessThanOrEqual(chunk.frameCount, 481)
        XCTAssertGreaterThan(chunk.samples.map(abs).max() ?? 0, 0.1)
        for frame in 0..<chunk.frameCount {
            XCTAssertEqual(chunk.samples[frame * 2], chunk.samples[frame * 2 + 1], accuracy: 0.0001)
        }
    }

    func testConvertsConsecutive48kFloat32StereoBuffersWithoutChangingFramesOrSamples() throws {
        let converter = SampleBufferConverter()
        let origin = CMTime(value: 10_000, timescale: 48_000)
        var firstValues: [Float] = []
        var secondValues: [Float] = []
        firstValues.reserveCapacity(1_920)
        secondValues.reserveCapacity(1_920)
        for frame in 0..<960 {
            firstValues.append(Float(frame % 16) / 16 - 0.5)
            firstValues.append(Float(frame % 20) / 20 - 0.5)
            secondValues.append(0.5 - Float(frame % 20) / 20)
            secondValues.append(0.5 - Float(frame % 16) / 16)
        }
        let inputChunks = [firstValues, secondValues]
        var chunks: [PCMChunk] = []

        for (index, values) in inputChunks.enumerated() {
            let presentationTime = origin + CMTime(value: Int64(index * 960), timescale: 48_000)
            let buffer = try AudioTestFactory.float32InterleavedSampleBuffer(
                sampleRate: 48_000,
                channels: 2,
                values: values,
                presentationTime: presentationTime
            )
            chunks.append(try converter.convert(
                CapturedAudioSample(
                    source: .system,
                    buffer: buffer,
                    presentationTime: presentationTime
                ),
                sessionStartPTS: origin
            ))
        }

        XCTAssertEqual(chunks.map(\.frameCount), [960, 960])
        XCTAssertEqual(chunks.map(\.startFrame), [0, 960])
        XCTAssertFloatArraysEqual(chunks.flatMap(\.samples), inputChunks.flatMap { $0 })
    }

    func testConverts48kInt16StereoWithOneOutputFramePerInputFrame() throws {
        var values: [Int16] = []
        values.reserveCapacity(1_920)
        for frame in 0..<960 {
            values.append(Int16((frame % 64) * 512 - 16_384))
            values.append(Int16(16_384 - (frame % 64) * 512))
        }
        let presentationTime = CMTime(value: 24_000, timescale: 48_000)
        let buffer = try AudioTestFactory.int16InterleavedSampleBuffer(
            sampleRate: 48_000,
            channels: 2,
            values: values,
            presentationTime: presentationTime
        )

        let chunk = try SampleBufferConverter().convert(
            CapturedAudioSample(
                source: .system,
                buffer: buffer,
                presentationTime: presentationTime
            ),
            sessionStartPTS: presentationTime
        )

        XCTAssertEqual(chunk.frameCount, 960)
        XCTAssertEqual(chunk.startFrame, 0)
        XCTAssertFloatArraysEqual(chunk.samples, values.map { Float($0) / 32_768 })
    }

    func testConverts48kInt16MonoWithOneOutputFramePerInputFrame() throws {
        let values: [Int16] = (0..<960).map { frame in
            Int16((frame % 64) * 512 - 16_384)
        }
        let presentationTime = CMTime(value: 72_000, timescale: 48_000)
        let buffer = try AudioTestFactory.int16MonoSampleBuffer(
            sampleRate: 48_000,
            values: values,
            presentationTime: presentationTime
        )

        let chunk = try SampleBufferConverter().convert(
            CapturedAudioSample(
                source: .microphone,
                buffer: buffer,
                presentationTime: presentationTime
            ),
            sessionStartPTS: presentationTime
        )

        XCTAssertEqual(chunk.frameCount, values.count)
        XCTAssertEqual(chunk.startFrame, 0)
        XCTAssertFloatArraysEqual(
            chunk.samples,
            values.flatMap { value in
                let normalized = Float(value) / 32_768
                return [normalized, normalized]
            }
        )
    }

    func testFramePositionRoundsAtOutputSampleRate() {
        XCTAssertEqual(
            AudioTimeline.framePosition(
                for: CMTime(value: 501, timescale: 1_000),
                origin: CMTime(value: 1, timescale: 2),
                sampleRate: 48_000
            ),
            48
        )
    }

    func testEarlierSecondSourceCanMoveCursorBeforeFirstOutput() {
        var mixer = AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 4)
        _ = mixer.ingest(.fixture(source: .system, startFrame: 100, monoValues: [1, 0, 0, 0]))

        let output = mixer.ingest(
            .fixture(source: .microphone, startFrame: 99, monoValues: [1, 0, 0, 0])
        )

        XCTAssertEqual(output.map(\.startFrame), [99])
        XCTAssertFloatArraysEqual(output.flatMap(\.leftChannel), [0.5, 0.5, 0, 0])
    }

    func testTrimsOverlappingFramesFromSameSourceAndWarns() {
        var mixer = AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 4)
        _ = mixer.ingest(
            .fixture(source: .system, startFrame: 0, monoValues: Array(repeating: 0.1, count: 8))
        )

        _ = mixer.ingest(
            .fixture(source: .system, startFrame: 4, monoValues: Array(repeating: 0.2, count: 8))
        )
        let output = mixer.flush()

        XCTAssertFloatArraysEqual(
            output.flatMap(\.leftChannel),
            Array(repeating: 0.1, count: 8) + Array(repeating: 0.2, count: 4)
        )
        XCTAssertEqual(mixer.warnings.count, 1)
    }

    func testConverterKeepsMultipleResampledBuffersContiguousAndDrains() throws {
        let converter = SampleBufferConverter()
        let inputRate = 44_100.0
        let origin = CMTime(seconds: 1, preferredTimescale: 44_100)
        var chunks: [PCMChunk] = []
        for index in 0..<12 {
            let values = (0..<100).map { sample in
                Int16(Double(Int16.max) * 0.2 * sin(
                    2 * Double.pi * 440 * Double(index * 100 + sample) / inputRate
                ))
            }
            let presentationTime = origin + CMTime(value: Int64(index * 100), timescale: 44_100)
            let buffer = try AudioTestFactory.int16MonoSampleBuffer(
                sampleRate: inputRate,
                values: values,
                presentationTime: presentationTime
            )
            chunks.append(try converter.convert(
                CapturedAudioSample(
                    source: .microphone,
                    buffer: buffer,
                    presentationTime: presentationTime
                ),
                sessionStartPTS: origin
            ))
        }
        chunks.append(contentsOf: try converter.drain(source: .microphone))

        XCTAssertFalse(chunks.isEmpty)
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(
                pair.1.startFrame,
                pair.0.startFrame + Int64(pair.0.frameCount)
            )
        }
        XCTAssertGreaterThanOrEqual(chunks.reduce(0) { $0 + $1.frameCount }, 1_305)
        XCTAssertLessThanOrEqual(chunks.reduce(0) { $0 + $1.frameCount }, 1_360)
    }
}
