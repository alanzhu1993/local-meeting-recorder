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

@MainActor
public protocol HotkeyBackend {
    func installEventHandler(_ handler: @escaping @MainActor @Sendable (HotkeyEventID) -> OSStatus) throws -> HotkeyHandlerToken
    // Carbon invalidates EventHandlerRef after this call regardless of its result.
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
            "快捷键移除状态无法确认。请重启应用后再设置快捷键。"
        }
    }
}

@MainActor
public protocol HotkeyRegistering {
    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws
    func unregister()
}

@MainActor
public final class HotkeyService: HotkeyRegistering {
    public let eventIdentifier: HotkeyEventID
    public private(set) var lastTeardownError: HotkeyServiceError?

    private let backend: any HotkeyBackend
    private var resources: Resources?
    private var terminalTeardownError: HotkeyServiceError?

    public init() {
        backend = CarbonHotkeyBackend()
        eventIdentifier = HotkeyIdentifierFactory.next()
    }

    public init(backend: any HotkeyBackend) {
        self.backend = backend
        eventIdentifier = HotkeyIdentifierFactory.next()
    }

    public func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws {
        if let terminalTeardownError {
            throw terminalTeardownError
        }
        guard resources == nil else { throw HotkeyServiceError.alreadyRegistered }

        let handlerToken = try backend.installEventHandler { [weak self] identifier in
            guard let self, identifier == self.eventIdentifier, let callback = self.resources?.handler else {
                return OSStatus(eventNotHandledErr)
            }
            callback()
            return noErr
        }
        do {
            let registration = try backend.register(
                descriptor,
                identifier: eventIdentifier,
                options: UInt32(kEventHotKeyExclusive)
            )
            resources = Resources(handlerToken: handlerToken, registration: registration, handler: handler)
            lastTeardownError = nil
        } catch {
            consumeHandlerRef(handlerToken)
            throw Self.mapError(error)
        }
    }

    public func unregister() {
        guard let resources else { return }
        let unregisterStatus = backend.unregister(resources.registration)
        guard unregisterStatus == noErr else {
            lastTeardownError = .teardownFailed(unregisterStatus)
            return
        }

        self.resources = nil
        consumeHandlerRef(resources.handlerToken)
    }

    private func consumeHandlerRef(_ token: HotkeyHandlerToken) {
        let removalStatus = backend.removeEventHandler(token)
        guard removalStatus != noErr else {
            lastTeardownError = nil
            return
        }

        retainContextForTerminalFailure(token)
        let error = HotkeyServiceError.teardownFailed(removalStatus)
        lastTeardownError = error
        terminalTeardownError = error
    }

    private func retainContextForTerminalFailure(_ token: HotkeyHandlerToken) {
        guard let storage = token.storage as? CarbonHotkeyHandlerStorage else { return }
        CarbonCallbackLifetime.shared.retain(storage.context)
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

    private struct Resources {
        let handlerToken: HotkeyHandlerToken
        let registration: HotkeyRegistration
        let handler: @Sendable () -> Void
    }
}

@MainActor
private enum HotkeyIdentifierFactory {
    private static var nextIdentifier: UInt32 = 1

    static func next() -> HotkeyEventID {
        defer { nextIdentifier &+= 1 }
        return HotkeyEventID(signature: 0x4D52_4352, identifier: nextIdentifier)
    }
}

@MainActor
private final class CarbonCallbackLifetime {
    static let shared = CarbonCallbackLifetime()
    private var retainedContexts: [CarbonHotkeyCallbackContext] = []

    func retain(_ context: CarbonHotkeyCallbackContext) {
        retainedContexts.append(context)
    }
}

@MainActor
private final class CarbonHotkeyBackend: HotkeyBackend {
    func installEventHandler(_ handler: @escaping @MainActor @Sendable (HotkeyEventID) -> OSStatus) throws -> HotkeyHandlerToken {
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
    let handler: @MainActor @Sendable (HotkeyEventID) -> OSStatus

    init(handler: @escaping @MainActor @Sendable (HotkeyEventID) -> OSStatus) {
        self.handler = handler
    }
}

private final class CarbonHotkeyHandlerStorage {
    let ref: EventHandlerRef
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
    // GetEventDispatcherTarget dispatches on the AppKit main event thread. The service,
    // Carbon operations and this callback therefore share MainActor isolation.
    return MainActor.assumeIsolated {
        context.handler(HotkeyEventID(signature: UInt32(eventID.signature), identifier: eventID.id))
    }
}
