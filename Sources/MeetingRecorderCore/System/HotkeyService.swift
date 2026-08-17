import Carbon
import Dispatch
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
    public let identifier: UUID
    fileprivate let storage: AnyObject?

    public init() {
        identifier = UUID()
        storage = nil
    }

    fileprivate init(storage: AnyObject) {
        identifier = UUID()
        self.storage = storage
    }
}

public struct HotkeyRegistration: @unchecked Sendable {
    public let identifier: UUID
    fileprivate let storage: AnyObject?

    public init() {
        identifier = UUID()
        storage = nil
    }

    fileprivate init(storage: AnyObject) {
        identifier = UUID()
        self.storage = storage
    }
}

public enum HotkeyBackendError: Error, Equatable, Sendable {
    case status(OSStatus)
}

public protocol HotkeyBackend: Sendable {
    func installEventHandler(_ handler: @escaping @Sendable (HotkeyEventID) -> OSStatus) throws -> HotkeyHandlerToken
    func removeEventHandler(_ token: HotkeyHandlerToken) -> OSStatus
    func register(_ descriptor: HotkeyDescriptor, identifier: HotkeyEventID, options: UInt32) throws -> HotkeyRegistration
    func unregister(_ registration: HotkeyRegistration) -> OSStatus
}

public enum HotkeyServiceError: Error, Equatable, Sendable, LocalizedError {
    case alreadyRegistered
    case conflict
    case unavailable(OSStatus)
    case teardownFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyRegistered:
            "快捷键已注册。"
        case .conflict:
            "此快捷键已被其他应用占用，请在设置中换一个组合键。"
        case .unavailable:
            "无法注册快捷键，请稍后重试或换一个组合键。"
        case .teardownFailed:
            "快捷键尚未完全移除，请稍后重试。"
        }
    }
}

public protocol HotkeyRegistering: Sendable {
    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws
    func unregister()
}

public final class HotkeyService: HotkeyRegistering, @unchecked Sendable {
    public let eventIdentifier: HotkeyEventID

    private let backend: any HotkeyBackend
    private let state = HotkeyRegistrationState()

    public var lastTeardownError: HotkeyServiceError? {
        MainEventThreadExecutor.sync { state.lastTeardownError }
    }

    public init() {
        backend = CarbonHotkeyBackend()
        eventIdentifier = HotkeyIdentifierFactory.next()
    }

    public init(backend: any HotkeyBackend) {
        self.backend = backend
        eventIdentifier = HotkeyIdentifierFactory.next()
    }

    deinit {
        unregister()
    }

    public func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws {
        try MainEventThreadExecutor.sync {
            guard state.resources == nil else { throw HotkeyServiceError.alreadyRegistered }

            let handlerToken = try backend.installEventHandler { [state, eventIdentifier] identifier in
                state.dispatch(identifier, expected: eventIdentifier)
            }
            do {
                let registration = try backend.register(
                    descriptor,
                    identifier: eventIdentifier,
                    options: UInt32(kEventHotKeyExclusive)
                )
                state.resources = .init(handlerToken: handlerToken, registration: registration, handler: handler)
                state.lastTeardownError = nil
            } catch {
                let removalStatus = backend.removeEventHandler(handlerToken)
                if removalStatus != noErr {
                    state.resources = .init(handlerToken: handlerToken, registration: nil, handler: handler)
                    state.lastTeardownError = .teardownFailed(removalStatus)
                }
                throw Self.mapError(error)
            }
        }
    }

    public func unregister() {
        MainEventThreadExecutor.sync {
            guard var resources = state.resources else { return }
            if let registration = resources.registration, !resources.registrationRemoved {
                let unregisterStatus = backend.unregister(registration)
                guard unregisterStatus == noErr else {
                    state.lastTeardownError = .teardownFailed(unregisterStatus)
                    return
                }
                resources.registrationRemoved = true
                state.resources = resources
            }

            let removalStatus = backend.removeEventHandler(resources.handlerToken)
            guard removalStatus == noErr else {
                state.lastTeardownError = .teardownFailed(removalStatus)
                return
            }
            state.resources = nil
            state.lastTeardownError = nil
        }
    }

    private static func mapError(_ error: Error) -> HotkeyServiceError {
        guard let backendError = error as? HotkeyBackendError else {
            return .unavailable(-1)
        }
        switch backendError {
        case .status(let status) where status == OSStatus(eventHotKeyExistsErr):
            return .conflict
        case .status(let status):
            return .unavailable(status)
        }
    }
}

private enum MainEventThreadExecutor {
    static func sync<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try body()
        }
        return try DispatchQueue.main.sync(execute: body)
    }
}

private enum HotkeyIdentifierFactory {
    private static let generator = HotkeyIdentifierGenerator()

    static func next() -> HotkeyEventID {
        generator.next()
    }
}

private final class HotkeyIdentifierGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIdentifier: UInt32 = 1

    func next() -> HotkeyEventID {
        lock.withLock {
            defer { nextIdentifier &+= 1 }
            return HotkeyEventID(signature: 0x4D52_4352, identifier: nextIdentifier)
        }
    }
}

private final class HotkeyRegistrationState: @unchecked Sendable {
    struct Resources {
        let handlerToken: HotkeyHandlerToken
        let registration: HotkeyRegistration?
        let handler: @Sendable () -> Void
        var registrationRemoved = false
    }

    var resources: Resources?
    var lastTeardownError: HotkeyServiceError?

    func dispatch(_ identifier: HotkeyEventID, expected: HotkeyEventID) -> OSStatus {
        guard identifier == expected, let handler = resources?.handler else {
            return OSStatus(eventNotHandledErr)
        }
        handler()
        return noErr
    }
}

private final class CarbonHotkeyBackend: HotkeyBackend, @unchecked Sendable {
    func installEventHandler(_ handler: @escaping @Sendable (HotkeyEventID) -> OSStatus) throws -> HotkeyHandlerToken {
        let context = CarbonHotkeyCallbackContext(handler: handler)
        let userData = Unmanaged.passUnretained(context).toOpaque()
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
            throw HotkeyBackendError.status(status)
        }
        return HotkeyHandlerToken(storage: CarbonHotkeyHandlerStorage(ref: eventHandler, context: context))
    }

    func removeEventHandler(_ token: HotkeyHandlerToken) -> OSStatus {
        guard let storage = token.storage as? CarbonHotkeyHandlerStorage else { return noErr }
        return RemoveEventHandler(storage.ref)
    }

    func register(_ descriptor: HotkeyDescriptor, identifier: HotkeyEventID, options: UInt32) throws -> HotkeyRegistration {
        let eventID = EventHotKeyID(signature: OSType(identifier.signature), id: identifier.identifier)
        var hotkey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.modifiers,
            eventID,
            nil,
            options,
            &hotkey
        )
        guard status == noErr, let hotkey else {
            throw HotkeyBackendError.status(status)
        }
        return HotkeyRegistration(storage: CarbonHotkeyRegistrationStorage(ref: hotkey))
    }

    func unregister(_ registration: HotkeyRegistration) -> OSStatus {
        guard let storage = registration.storage as? CarbonHotkeyRegistrationStorage else { return noErr }
        return UnregisterEventHotKey(storage.ref)
    }
}

private final class CarbonHotkeyCallbackContext: @unchecked Sendable {
    let handler: @Sendable (HotkeyEventID) -> OSStatus

    init(handler: @escaping @Sendable (HotkeyEventID) -> OSStatus) {
        self.handler = handler
    }
}

private final class CarbonHotkeyHandlerStorage {
    let ref: EventHandlerRef
    // This strong reference outlives raw userData. Carbon API calls and callback
    // dispatch are all on the main event thread, so removal cannot race a callback.
    let context: CarbonHotkeyCallbackContext

    init(ref: EventHandlerRef, context: CarbonHotkeyCallbackContext) {
        self.ref = ref
        self.context = context
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
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    guard GetEventClass(event) == OSType(kEventClassKeyboard), GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
        return OSStatus(eventNotHandledErr)
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
    return context.handler(HotkeyEventID(signature: UInt32(eventID.signature), identifier: eventID.id))
}
