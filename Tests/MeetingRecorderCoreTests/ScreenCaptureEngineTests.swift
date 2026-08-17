import ScreenCaptureKit
import XCTest
@testable import MeetingRecorderCore

final class ScreenCaptureEngineTests: XCTestCase {
    func testConfigurationCapturesBothSources() {
        let configuration = ScreenCaptureEngine.makeConfiguration(
            microphoneDeviceID: "mic-1"
        )

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertEqual(configuration.microphoneCaptureDeviceID, "mic-1")
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
        XCTAssertEqual(
            configuration.minimumFrameInterval,
            CMTime(value: 1, timescale: 1)
        )
    }

    func testOutputTypesRouteOnlyAudioSamples() {
        XCTAssertEqual(ScreenCaptureEngine.source(for: .audio), .system)
        XCTAssertEqual(ScreenCaptureEngine.source(for: .microphone), .microphone)
        XCTAssertNil(ScreenCaptureEngine.source(for: .screen))
    }
}
