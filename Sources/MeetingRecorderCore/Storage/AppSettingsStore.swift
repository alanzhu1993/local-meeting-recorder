import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var recordingRoot: URL
    public var hotkey: HotkeyDescriptor
    public var launchAtLogin: Bool

    public init(recordingRoot: URL, hotkey: HotkeyDescriptor, launchAtLogin: Bool) {
        self.recordingRoot = recordingRoot
        self.hotkey = hotkey
        self.launchAtLogin = launchAtLogin
    }

    public static let `default` = AppSettings(
        recordingRoot: AppMetadata.defaultRecordingRoot,
        hotkey: AppMetadata.defaultHotkey,
        launchAtLogin: true
    )
}

public final class AppSettingsStore {
    private static let storageKey = "appSettings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard
            let data = defaults.data(forKey: Self.storageKey),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
