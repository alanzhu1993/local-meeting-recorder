import Foundation

public struct HotkeyDescriptor: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let displayText: String

    public init(keyCode: UInt32, modifiers: UInt32, displayText: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayText = displayText
    }
}

public enum AppMetadata {
    public static let bundleIdentifier = "com.alan.local-meeting-recorder"
    public static let defaultRecordingRoot = URL(
        fileURLWithPath: "/Users/alan/Documents/快速本地录音软件/录音文件",
        isDirectory: true
    )
    public static let defaultHotkey = HotkeyDescriptor(
        keyCode: 15,
        modifiers: 0x1000 | 0x0800,
        displayText: "⌃⌥R"
    )
}
