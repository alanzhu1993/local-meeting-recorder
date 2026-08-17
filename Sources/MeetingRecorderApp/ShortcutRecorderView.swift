import AppKit
import Carbon
import MeetingRecorderCore
import SwiftUI

enum ShortcutCaptureError: Error, Equatable, LocalizedError {
    case missingRequiredModifier
    case unsupportedKey

    var errorDescription: String? {
        switch self {
        case .missingRequiredModifier:
            "快捷键必须包含 Control 或 Command。"
        case .unsupportedKey:
            "这个按键不能用作快捷键，请换一个按键。"
        }
    }
}

enum ShortcutDescriptorFactory {
    static func make(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) throws -> HotkeyDescriptor {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control) || flags.contains(.command) else {
            throw ShortcutCaptureError.missingRequiredModifier
        }
        guard let rawKey = charactersIgnoringModifiers?.uppercased(),
              let key = displayKey(for: rawKey, keyCode: keyCode) else {
            throw ShortcutCaptureError.unsupportedKey
        }

        var carbonModifiers: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey); display += "⌘" }
        display += key
        return HotkeyDescriptor(
            keyCode: UInt32(keyCode),
            modifiers: carbonModifiers,
            displayText: display
        )
    }

    private static func displayKey(for characters: String, keyCode: UInt16) -> String? {
        let namedKeys: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫",
            115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let named = namedKeys[keyCode] { return named }
        guard characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        return characters
    }
}

@MainActor
protocol ShortcutEventMonitoring: AnyObject {
    func install(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any
    func remove(_ token: Any)
}

@MainActor
final class ShortcutCaptureController {
    var onCapture: (HotkeyDescriptor) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    private let monitor: any ShortcutEventMonitoring
    private var monitorToken: Any?

    init(monitor: any ShortcutEventMonitoring = LocalShortcutEventMonitor()) {
        self.monitor = monitor
    }

    isolated deinit {
        removeMonitor()
    }

    func update(isFocused: Bool, windowIsActive: Bool) {
        if isFocused && windowIsActive {
            installMonitorIfNeeded()
        } else {
            removeMonitor()
        }
    }

    private func installMonitorIfNeeded() {
        guard monitorToken == nil else { return }
        monitorToken = monitor.install { [weak self] event in
            self?.handle(event)
        }
    }

    private func removeMonitor() {
        guard let monitorToken else { return }
        self.monitorToken = nil
        monitor.remove(monitorToken)
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            onCancel()
            return nil
        }
        do {
            let descriptor = try ShortcutDescriptorFactory.make(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            onCapture(descriptor)
        } catch {
            onError(error.localizedDescription)
        }
        return nil
    }
}

@MainActor
private final class LocalShortcutEventMonitor: ShortcutEventMonitoring {
    func install(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler) as Any
    }

    func remove(_ token: Any) {
        NSEvent.removeMonitor(token)
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    let displayText: String
    let onCapture: (HotkeyDescriptor) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        ShortcutRecorderNSView(
            displayText: displayText,
            onCapture: onCapture,
            onError: onError
        )
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.displayText = displayText
        nsView.captureController.onCapture = { [weak nsView] descriptor in
            onCapture(descriptor)
            nsView?.window?.makeFirstResponder(nil)
        }
        nsView.captureController.onError = onError
    }
}

@MainActor
final class ShortcutRecorderNSView: NSView {
    var displayText: String {
        didSet {
            needsDisplay = true
            setAccessibilityLabel("录制快捷键，当前为 \(displayText)")
        }
    }
    let captureController = ShortcutCaptureController()
    private var observers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 32) }

    init(
        displayText: String,
        onCapture: @escaping (HotkeyDescriptor) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.displayText = displayText
        super.init(frame: .zero)
        captureController.onCapture = { [weak self] descriptor in
            onCapture(descriptor)
            self?.window?.makeFirstResponder(nil)
        }
        captureController.onCancel = { [weak self] in self?.window?.makeFirstResponder(nil) }
        captureController.onError = onError
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("录制快捷键，当前为 \(displayText)")
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let window else {
            updateMonitor()
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateMonitor() } })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateMonitor() } })
        updateMonitor()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        updateMonitor(assumingFocused: result)
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        captureController.update(isFocused: false, windowIsActive: window?.isKeyWindow == true)
        return result
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        NSColor.white.setFill()
        path.fill()
        NSColor(calibratedRed: 215 / 255, green: 219 / 255, blue: 227 / 255, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = window?.firstResponder === self ? "请按新的组合键…" : displayText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 23 / 255, green: 27 / 255, blue: 35 / 255, alpha: 1)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 10, y: (bounds.height - size.height) / 2 + 1),
            withAttributes: attributes
        )
        if window?.firstResponder === self {
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }

    private func updateMonitor(assumingFocused: Bool? = nil) {
        let focused = assumingFocused ?? (window?.firstResponder === self)
        captureController.update(isFocused: focused, windowIsActive: window?.isKeyWindow == true)
    }
}
