import Carbon
import Foundation

public struct HotkeyEventID: Equatable, Sendable {
    public let signature: UInt32
    public let identifier: UInt32

    public init(signature: UInt32, identifier: UInt32) {
        self.signature = signature
        self.identifier = identifier
    }
}

public struct HotkeyHandlerToken: @unchecked Sendable {
    fileprivate let storage: AnyObject?

    public init() {
        storage = nil
    }

    fileprivate init(storage: AnyObject) {
        self.storage = storage
    }
}

public struct HotkeyRegistration: @unchecked Sendable {
    fileprivate let storage: AnyObject?

    public init() {
        storage = nil
    }

    fileprivate init(storage: AnyObject) {
        self.storage = storage
    }
}

public enum HotkeyBackendError: Error, Equatable, Sendable {
    case status(OSStatus)
}

public protocol HotkeyBackend: Sendable {
    func installEventHandler(_ handler: @escaping @Sendable (HotkeyEventID) -> Void) throws -> HotkeyHandlerToken
    func removeEventHandler(_ token: HotkeyHandlerToken)
    func register(_ descriptor: HotkeyDescriptor, identifier: HotkeyEventID) throws -> HotkeyRegistration
    func unregister(_ registration: HotkeyRegistration)
}

public enum HotkeyServiceError: Error, Equatable, Sendable, LocalizedError {
    case alreadyRegistered
    case conflict
    case unavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyRegistered:
            "快捷键已注册。"
        case .conflict:
            "此快捷键已被其他应用占用，请在设置中换一个组合键。"
        case .unavailable:
            "无法注册快捷键，请稍后重试或换一个组合键。"
        }
    }
}

public protocol HotkeyRegistering: Sendable {
    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws
    func unregister()
}

public final class HotkeyService: HotkeyRegistering, @unchecked Sendable {
    public static let eventIdentifier = HotkeyEventID(signature: 0x4D52_4352, identifier: 1)

    private let backend: any HotkeyBackend
    private let state = RegistrationState()

    public init() {
        backend = CarbonHotkeyBackend()
    }

    public init(backend: any HotkeyBackend) {
        self.backend = backend
    }

    deinit {
        unregister()
    }

    public func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws {
        try state.beginRegistration()
        var installedHandler: HotkeyHandlerToken?
        do {
            let token = try backend.installEventHandler { [state] identifier in
                state.trigger(identifier, expected: Self.eventIdentifier)
            }
            installedHandler = token
            let registration = try backend.register(descriptor, identifier: Self.eventIdentifier)
            if let resources = state.finishRegistration(handler: handler, handlerToken: token, registration: registration) {
                backend.unregister(resources.registration)
                backend.removeEventHandler(resources.handlerToken)
            }
        } catch {
            if let installedHandler {
                backend.removeEventHandler(installedHandler)
            }
            state.cancelRegistration()
            throw Self.mapError(error)
        }
    }

    public func unregister() {
        guard let resources = state.takeRegistrationForRemoval() else { return }
        backend.unregister(resources.registration)
        backend.removeEventHandler(resources.handlerToken)
    }

    private static func mapError(_ error: Error) -> HotkeyServiceError {
        guard let backendError = error as? HotkeyBackendError else {
            return .unavailable(-1)
        }
        switch backendError {
        case .status(let status) where status == eventHotKeyExistsErr:
            return .conflict
        case .status(let status):
            return .unavailable(status)
        }
    }
}

private final class RegistrationState: @unchecked Sendable {
    struct Resources {
        let handlerToken: HotkeyHandlerToken
        let registration: HotkeyRegistration
    }

    private let lock = NSLock()
    private var isRegistering = false
    private var cancellationRequested = false
    private var resources: Resources?
    private var handler: (@Sendable () -> Void)?

    func beginRegistration() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRegistering, resources == nil else {
            throw HotkeyServiceError.alreadyRegistered
        }
        isRegistering = true
        cancellationRequested = false
    }

    func finishRegistration(
        handler: @escaping @Sendable () -> Void,
        handlerToken: HotkeyHandlerToken,
        registration: HotkeyRegistration
    ) -> Resources? {
        lock.lock()
        let resourcesToRemove: Resources?
        if cancellationRequested {
            resourcesToRemove = Resources(handlerToken: handlerToken, registration: registration)
        } else {
            self.handler = handler
            resources = Resources(handlerToken: handlerToken, registration: registration)
            resourcesToRemove = nil
        }
        isRegistering = false
        lock.unlock()
        return resourcesToRemove
    }

    func cancelRegistration() {
        lock.lock()
        isRegistering = false
        cancellationRequested = false
        lock.unlock()
    }

    func takeRegistrationForRemoval() -> Resources? {
        lock.lock()
        defer { lock.unlock() }
        let currentResources = resources
        resources = nil
        handler = nil
        if isRegistering {
            cancellationRequested = true
        }
        return currentResources
    }

    func trigger(_ identifier: HotkeyEventID, expected: HotkeyEventID) {
        lock.lock()
        let callback = identifier == expected ? handler : nil
        lock.unlock()
        callback?()
    }
}

private final class CarbonHotkeyBackend: HotkeyBackend, @unchecked Sendable {
    func installEventHandler(_ handler: @escaping @Sendable (HotkeyEventID) -> Void) throws -> HotkeyHandlerToken {
        let context = CarbonHotkeyCallbackContext(handler: handler)
        let userData = Unmanaged.passRetained(context).toOpaque()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            carbonHotkeyCallback,
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard status == noErr, let eventHandler else {
            Unmanaged<CarbonHotkeyCallbackContext>.fromOpaque(userData).release()
            throw HotkeyBackendError.status(status)
        }
        return HotkeyHandlerToken(storage: CarbonHotkeyHandlerStorage(ref: eventHandler, userData: userData))
    }

    func removeEventHandler(_ token: HotkeyHandlerToken) {
        guard let storage = token.storage as? CarbonHotkeyHandlerStorage else { return }
        _ = RemoveEventHandler(storage.ref)
        Unmanaged<CarbonHotkeyCallbackContext>.fromOpaque(storage.userData).release()
    }

    func register(_ descriptor: HotkeyDescriptor, identifier: HotkeyEventID) throws -> HotkeyRegistration {
        let eventID = EventHotKeyID(signature: OSType(identifier.signature), id: identifier.identifier)
        var hotkey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.modifiers,
            eventID,
            nil,
            0,
            &hotkey
        )
        guard status == noErr, let hotkey else {
            throw HotkeyBackendError.status(status)
        }
        return HotkeyRegistration(storage: CarbonHotkeyRegistrationStorage(ref: hotkey))
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard let storage = registration.storage as? CarbonHotkeyRegistrationStorage else { return }
        _ = UnregisterEventHotKey(storage.ref)
    }
}

private final class CarbonHotkeyCallbackContext: @unchecked Sendable {
    let handler: @Sendable (HotkeyEventID) -> Void

    init(handler: @escaping @Sendable (HotkeyEventID) -> Void) {
        self.handler = handler
    }
}

private final class CarbonHotkeyHandlerStorage {
    let ref: EventHandlerRef
    let userData: UnsafeMutableRawPointer

    init(ref: EventHandlerRef, userData: UnsafeMutableRawPointer) {
        self.ref = ref
        self.userData = userData
    }
}

private final class CarbonHotkeyRegistrationStorage {
    let ref: EventHotKeyRef

    init(ref: EventHotKeyRef) {
        self.ref = ref
    }
}

private func carbonHotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    guard GetEventClass(event) == OSType(kEventClassKeyboard), GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
        return noErr
    }

    var eventID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &eventID
    )
    guard status == noErr else { return status }
    let context = Unmanaged<CarbonHotkeyCallbackContext>.fromOpaque(userData).takeUnretainedValue()
    context.handler(HotkeyEventID(signature: UInt32(eventID.signature), identifier: eventID.id))
    return noErr
}
