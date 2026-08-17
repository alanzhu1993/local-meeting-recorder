import Carbon
import XCTest
@testable import MeetingRecorderCore

@MainActor
final class HotkeyServiceTests: XCTestCase {
    func testHotkeyConflictIsActionableAndCleansUpInstalledHandler() {
        let backend = HotkeyBackendStub(registerResult: .failure(.status(OSStatus(eventHotKeyExistsErr))))
        let service = HotkeyService(backend: backend)

        XCTAssertThrowsError(try service.register(AppMetadata.defaultHotkey, handler: {})) { error in
            XCTAssertEqual(error as? HotkeyServiceError, .conflict)
        }
        XCTAssertEqual(backend.installCount, 1)
        XCTAssertEqual(backend.removeHandlerCount, 1)
        XCTAssertEqual(backend.unregisterCount, 0)
    }

    func testRegistersWithExclusiveCarbonOption() throws {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        let service = HotkeyService(backend: backend)

        try service.register(AppMetadata.defaultHotkey, handler: {})

        XCTAssertEqual(backend.registerOptions, UInt32(kEventHotKeyExclusive))
    }

    func testMultipleServicesUseDifferentIdentifiersAndLeaveOtherHandlersInChain() throws {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        let first = HotkeyService(backend: backend)
        let second = HotkeyService(backend: backend)
        let firstCount = LockedCounter()
        let secondCount = LockedCounter()

        try first.register(AppMetadata.defaultHotkey) { firstCount.increment() }
        try second.register(HotkeyDescriptor(keyCode: 16, modifiers: 0x1000, displayText: "⌃T")) { secondCount.increment() }
        XCTAssertNotEqual(first.eventIdentifier, second.eventIdentifier)

        XCTAssertEqual(backend.fire(first.eventIdentifier), noErr)
        XCTAssertEqual(firstCount.value, 1)
        XCTAssertEqual(secondCount.value, 0)

        XCTAssertEqual(backend.fire(second.eventIdentifier), noErr)
        XCTAssertEqual(firstCount.value, 1)
        XCTAssertEqual(secondCount.value, 1)

        XCTAssertEqual(backend.fire(HotkeyEventID(signature: 0xDEAD_BEEF, identifier: 7)), OSStatus(eventNotHandledErr))
    }

    func testDuplicateRegistrationDoesNotAskCarbonToRegisterAgain() throws {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        let service = HotkeyService(backend: backend)

        try service.register(AppMetadata.defaultHotkey, handler: {})
        XCTAssertThrowsError(try service.register(AppMetadata.defaultHotkey, handler: {})) { error in
            XCTAssertEqual(error as? HotkeyServiceError, .alreadyRegistered)
        }
        XCTAssertEqual(backend.registerCount, 1)
    }

    func testUnregisterIsIdempotent() throws {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        let service = HotkeyService(backend: backend)
        try service.register(AppMetadata.defaultHotkey, handler: {})

        service.unregister()
        service.unregister()

        XCTAssertEqual(backend.unregisterCount, 1)
        XCTAssertEqual(backend.removeHandlerCount, 1)
    }

    func testRemoveFailureConsumesHandlerRefAndBlocksFurtherRegistration() throws {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        backend.removeResults = [OSStatus(-50)]
        let service = HotkeyService(backend: backend)
        let count = LockedCounter()
        try service.register(AppMetadata.defaultHotkey) { count.increment() }

        service.unregister()
        XCTAssertNotNil(service.lastTeardownError)
        XCTAssertEqual(backend.fire(service.eventIdentifier), OSStatus(eventNotHandledErr))
        XCTAssertEqual(count.value, 0)

        service.unregister()
        XCTAssertEqual(backend.unregisterCount, 1)
        XCTAssertEqual(backend.removeHandlerCount, 1)
        XCTAssertThrowsError(try service.register(AppMetadata.defaultHotkey, handler: {})) { error in
            XCTAssertEqual(error as? HotkeyServiceError, .teardownFailed(-50))
        }
    }

    func testConcurrentRegisterAndUnregisterCallsAreLinearizedByMainActor() async {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        let service = HotkeyService(backend: backend)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { @MainActor in
                    try? service.register(AppMetadata.defaultHotkey, handler: {})
                }
            }
            await group.waitForAll()
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { @MainActor in
                    service.unregister()
                }
            }
            await group.waitForAll()
        }

        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(backend.unregisterCount, 1)
        XCTAssertEqual(backend.removeHandlerCount, 1)
    }

    func testNormalRemovalAllowsRegistrationAgain() throws {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        let service = HotkeyService(backend: backend)

        try service.register(AppMetadata.defaultHotkey, handler: {})
        service.unregister()
        try service.register(AppMetadata.defaultHotkey, handler: {})

        XCTAssertEqual(backend.registerCount, 2)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

@MainActor
private final class HotkeyBackendStub: HotkeyBackend {
    let registerResult: Result<HotkeyRegistration, HotkeyBackendError>
    private var eventHandlers: [UUID: @MainActor @Sendable (HotkeyEventID) -> OSStatus] = [:]
    var installCount = 0
    var removeHandlerCount = 0
    var registerCount = 0
    var unregisterCount = 0
    var registerOptions: UInt32?
    var removeResults: [OSStatus] = []

    init(registerResult: Result<HotkeyRegistration, HotkeyBackendError>) {
        self.registerResult = registerResult
    }

    func installEventHandler(_ handler: @escaping @MainActor @Sendable (HotkeyEventID) -> OSStatus) throws -> HotkeyHandlerToken {
        installCount += 1
        let token = HotkeyHandlerToken()
        eventHandlers[token.identifier] = handler
        return token
    }

    func removeEventHandler(_ token: HotkeyHandlerToken) -> OSStatus {
        removeHandlerCount += 1
        let result = removeResults.isEmpty ? noErr : removeResults.removeFirst()
        eventHandlers[token.identifier] = nil
        return result
    }

    func register(_ descriptor: HotkeyDescriptor, identifier: HotkeyEventID, options: UInt32) throws -> HotkeyRegistration {
        registerCount += 1
        registerOptions = options
        return try registerResult.get()
    }

    func unregister(_ registration: HotkeyRegistration) -> OSStatus {
        unregisterCount += 1
        return noErr
    }

    func fire(_ identifier: HotkeyEventID) -> OSStatus {
        for eventHandler in eventHandlers.values {
            let result = eventHandler(identifier)
            if result == noErr { return noErr }
        }
        return OSStatus(eventNotHandledErr)
    }
}
