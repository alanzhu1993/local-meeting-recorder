import AppKit
import MeetingRecorderCore

@main
@MainActor
enum MeetingRecorderApp {
    private static let appDelegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "录音"
        statusItem?.button?.toolTip = "会议录音（\(AppMetadata.defaultHotkey.displayText)）"
    }
}
