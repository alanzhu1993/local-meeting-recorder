import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?

    func show(model: SettingsViewModel) {
        model.refreshSystemState()
        if let window {
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: controller)
        window.title = "会议录音设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 420, height: 600)
        window.setContentSize(NSSize(width: 480, height: 620))
        window.center()
        window.setAccessibilityLabel("会议录音设置")
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
