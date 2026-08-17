import XCTest
@testable import MeetingRecorderCore

final class AppMetadataTests: XCTestCase {
    func testStableProductConstants() {
        XCTAssertEqual(AppMetadata.bundleIdentifier, "com.alan.local-meeting-recorder")
        XCTAssertEqual(AppMetadata.defaultRecordingRoot.path, "/Users/alan/Documents/快速本地录音软件/录音文件")
        XCTAssertEqual(AppMetadata.defaultHotkey.displayText, "⌃⌥R")
    }
}
