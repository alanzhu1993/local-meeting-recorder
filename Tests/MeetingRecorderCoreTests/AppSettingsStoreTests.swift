import Foundation
import XCTest
@testable import MeetingRecorderCore

final class AppSettingsStoreTests: XCTestCase {
    func testFirstLoadUsesProductDefaults() {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults).load()

        XCTAssertEqual(settings.recordingRoot, AppMetadata.defaultRecordingRoot)
        XCTAssertEqual(settings.hotkey, AppMetadata.defaultHotkey)
        XCTAssertTrue(settings.launchAtLogin)
    }

    func testSavedSettingsAreReadByNewStoreInstance() {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            recordingRoot: URL(fileURLWithPath: "/tmp/recordings", isDirectory: true),
            hotkey: HotkeyDescriptor(keyCode: 1, modifiers: 2, displayText: "⌃⌥S"),
            launchAtLogin: false
        )

        AppSettingsStore(defaults: defaults).save(settings)

        XCTAssertEqual(AppSettingsStore(defaults: defaults).load(), settings)
    }
}
