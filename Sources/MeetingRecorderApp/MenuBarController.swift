import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var subscriptions = Set<AnyCancellable>()
    private var settingsWindowController: SettingsWindowController?

    init(
        statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength),
        popover: NSPopover = NSPopover()
    ) {
        self.statusItem = statusItem
        self.popover = popover
        super.init()
        popover.delegate = self
    }

    func show(rootView: MenuBarView) {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 292, height: rootView.model.preferredHeight)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.focusRingType = .default
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp("打开或关闭会议录音控制面板")
        update(.idle)
    }

    func bind(to model: MenuBarViewModel) {
        subscriptions.removeAll()
        model.$presentation
            .sink { [weak self] presentation in self?.update(presentation) }
            .store(in: &subscriptions)
        model.$preferredHeight
            .sink { [weak self] height in
                self?.popover.contentSize = NSSize(width: 292, height: height)
            }
            .store(in: &subscriptions)
    }

    func update(_ presentation: MenuBarPresentation) {
        guard let button = statusItem.button else { return }
        button.image = statusImage(for: presentation)
        button.imagePosition = presentation.menuBarTitle.isEmpty ? .imageOnly : .imageLeading
        button.title = presentation.menuBarTitle.isEmpty ? "" : " \(presentation.menuBarTitle)"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }

    func showSettings(model: SettingsViewModel) {
        popover.performClose(nil)
        let controller = settingsWindowController ?? SettingsWindowController()
        settingsWindowController = controller
        controller.show(model: model)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(button)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func statusImage(for presentation: MenuBarPresentation) -> NSImage? {
        let base = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: nil)
        switch presentation.tone {
        case .idle, .busy:
            base?.isTemplate = true
            return base
        case .recording:
            let color = NSColor(calibratedRed: 168 / 255, green: 68 / 255, blue: 60 / 255, alpha: 1)
            let image = base?.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.isTemplate = false
            return image
        case .warning:
            let color = NSColor(calibratedRed: 141 / 255, green: 107 / 255, blue: 63 / 255, alpha: 1)
            let image = base?.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.isTemplate = false
            return image
        }
    }
}
