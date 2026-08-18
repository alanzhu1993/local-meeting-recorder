import CoreMedia
import XCTest
@testable import MeetingRecorderCore

final class LongTimelineTests: XCTestCase {
    func testThreeHourFramePositionUsesInt64WithoutAllocatingSilence() {
        let origin = CMTime.zero
        let threeHours = CMTime(seconds: 3 * 60 * 60, preferredTimescale: 48_000)
        let endFrame = Int64(3 * 60 * 60 * 48_000)
        XCTAssertEqual(
            AudioTimeline.framePosition(for: threeHours, origin: origin, sampleRate: 48_000),
            endFrame
        )
        XCTAssertEqual(endFrame, 518_400_000)
    }

    func testTwentyFiveHourFramePositionExceedsUInt32WithoutAllocatingSilence() {
        let origin = CMTime.zero
        let twentyFiveHours = CMTime(seconds: 25 * 60 * 60, preferredTimescale: 48_000)
        let endFrame = Int64(25 * 60 * 60 * 48_000)

        XCTAssertEqual(
            AudioTimeline.framePosition(for: twentyFiveHours, origin: origin, sampleRate: 48_000),
            endFrame
        )
        XCTAssertEqual(endFrame, 4_320_000_000)
        XCTAssertGreaterThan(endFrame, Int64(UInt32.max))
    }
}
