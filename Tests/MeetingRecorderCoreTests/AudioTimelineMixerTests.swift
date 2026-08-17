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
