import AppKit

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
