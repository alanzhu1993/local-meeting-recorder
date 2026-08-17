import Carbon
import XCTest
@testable import MeetingRecorderCore

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

    func testHandlerOnlyReceivesItsOwnCarbonIdentifier() throws {
        let backend = HotkeyBackendStub(registerResult: .success(HotkeyRegistration()))
        let service = HotkeyService(backend: backend)
        let invocationCount = LockedCounter()

        try service.register(AppMetadata.defaultHotkey) { invocationCount.increment() }
        backend.fire(HotkeyEventID(signature: 0xDEAD_BEEF, identifier: 7))
        backend.fire(HotkeyService.eventIdentifier)

        XCTAssertEqual(invocationCount.value, 1)
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

private final class HotkeyBackendStub: HotkeyBackend, @unchecked Sendable {
    let registerResult: Result<HotkeyRegistration, HotkeyBackendError>
    private var eventHandler: (@Sendable (HotkeyEventID) -> Void)?
    var installCount = 0
    var removeHandlerCount = 0
    var registerCount = 0
    var unregisterCount = 0

    init(registerResult: Result<HotkeyRegistration, HotkeyBackendError>) {
        self.registerResult = registerResult
    }

    func installEventHandler(_ handler: @escaping @Sendable (HotkeyEventID) -> Void) throws -> HotkeyHandlerToken {
        installCount += 1
        eventHandler = handler
        return HotkeyHandlerToken()
    }

    func removeEventHandler(_ token: HotkeyHandlerToken) {
        removeHandlerCount += 1
        eventHandler = nil
    }

    func register(_ descriptor: HotkeyDescriptor, identifier: HotkeyEventID) throws -> HotkeyRegistration {
        registerCount += 1
        return try registerResult.get()
    }

    func unregister(_ registration: HotkeyRegistration) {
        unregisterCount += 1
    }

    func fire(_ identifier: HotkeyEventID) {
        eventHandler?(identifier)
    }
}
