import Foundation
import XCTest
@testable import MeetingRecorderCore

final class RecoveryServiceTests: XCTestCase {
    func testRecoversEachWorkingFileInIsolationAndAlwaysReleasesOutputReservation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.inprogress.mov")
        let second = directory.appendingPathComponent("second.inprogress.mov")
        let firstOutput = directory.appendingPathComponent("first-recovered.m4a")
        let secondOutput = directory.appendingPathComponent("second-recovered.m4a")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let store = RecoveryStoreSpy(
            interrupted: [first, second],
            recoveredURLs: [first: firstOutput, second: secondOutput]
        )
        let finalizer = RecoveryFinalizerSpy(failingURLs: [first])
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: finalizer
        )

        let results = await service.recoverInterruptedRecordings()

        XCTAssertEqual(results.count, 2)
        guard case let .failed(failedURL, message) = results[0].outcome else {
            return XCTFail("Expected isolated first failure.")
        }
        XCTAssertEqual(failedURL, first)
        XCTAssertEqual(message, "injected recovery failure")
        XCTAssertEqual(results[1], RecoveryResult(outcome: .recovered(secondOutput)))
        let releasedURLs = await store.releasedURLs
        XCTAssertEqual(releasedURLs, [firstOutput, secondOutput])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testConcurrentRecoveryCallsCoalesceAndExposeRecoveringState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let working = directory.appendingPathComponent("working.inprogress.mov")
        let output = directory.appendingPathComponent("recovered.m4a")
        try Data("working".utf8).write(to: working)
        let store = RecoveryStoreSpy(interrupted: [working], recoveredURLs: [working: output])
        let gate = RecoveryAsyncGate()
        let finalizer = RecoveryFinalizerSpy(gate: gate)
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: finalizer
        )

        let first = Task { await service.recoverInterruptedRecordings() }
        await finalizer.waitUntilEntered()
        let second = Task { await service.recoverInterruptedRecordings() }
        for _ in 0..<20 { await Task.yield() }

        let isRecovering = await service.isRecovering
        let listCallCount = await store.listCallCount
        let callCount = await finalizer.callCount
        XCTAssertTrue(isRecovering)
        XCTAssertEqual(listCallCount, 1)
        XCTAssertEqual(callCount, 1)

        await gate.open()
        let firstResults = await first.value
        let secondResults = await second.value
        XCTAssertEqual(firstResults, secondResults)
        let isRecoveringAfterCompletion = await service.isRecovering
        let releasedURLs = await store.releasedURLs
        XCTAssertFalse(isRecoveringAfterCompletion)
        XCTAssertEqual(releasedURLs, [output])
    }

    func testJoinerCompletesRecoveringStateBeforeReturningEvenWhenCreatorIsDelayed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let working = directory.appendingPathComponent("working.inprogress.mov")
        let output = directory.appendingPathComponent("recovered.m4a")
        try Data("working".utf8).write(to: working)
        let store = RecoveryStoreSpy(interrupted: [working], recoveredURLs: [working: output])
        let recoveryGate = RecoveryAsyncGate()
        let creatorCompletionGate = RecoveryAsyncGate()
        let joinObserved = RecoverySignal()
        let finalizer = RecoveryFinalizerSpy(gate: recoveryGate)
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: finalizer,
            beforeCreatorCompletion: { await creatorCompletionGate.wait() },
            onJoin: { joinObserved.signal() }
        )

        let creator = Task { await service.recoverInterruptedRecordings() }
        await finalizer.waitUntilEntered()
        let joiner = Task { await service.recoverInterruptedRecordings() }
        await joinObserved.wait()
        await recoveryGate.open()

        let joinerResults = await joiner.value
        XCTAssertEqual(joinerResults, [RecoveryResult(outcome: .recovered(output))])
        let isRecovering = await service.isRecovering
        XCTAssertFalse(isRecovering)
        await creatorCompletionGate.open()
        let creatorResults = await creator.value
        XCTAssertEqual(creatorResults, joinerResults)
    }

    func testDuplicateScanEntriesAreRecoveredOnlyOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let working = directory.appendingPathComponent("working.inprogress.mov")
        let output = directory.appendingPathComponent("recovered.m4a")
        try Data("working".utf8).write(to: working)
        let store = RecoveryStoreSpy(
            interrupted: [working, working.standardizedFileURL],
            recoveredURLs: [working: output]
        )
        let finalizer = RecoveryFinalizerSpy()
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: finalizer
        )

        let results = await service.recoverInterruptedRecordings()

        XCTAssertEqual(results, [RecoveryResult(outcome: .recovered(output))])
        let callCount = await finalizer.callCount
        let releasedURLs = await store.releasedURLs
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(releasedURLs, [output])
    }

    func testRecordingStoreDiscoversSegmentedManifestAndServicePassesItToFinalizer() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026-08-17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent(
            ".会议录音-2026-08-17-10-00-00.inprogress.mov"
        )
        let writer = SegmentedM4AWriter(workingURL: manifestURL, segmentFrames: 4_800)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let store = RecordingStore(root: root, availableCapacity: { 2_000_000_000 })
        let finalizer = RecoveryFinalizerSpy()
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: finalizer
        )

        let results = await service.recoverInterruptedRecordings()

        XCTAssertEqual(results.count, 1)
        let workingURLs = await finalizer.workingURLs
        XCTAssertEqual(
            workingURLs.map { $0.resolvingSymlinksInPath().path },
            [manifestURL.resolvingSymlinksInPath().path]
        )
        let expectedOutput = directory.appendingPathComponent(
            "会议录音-2026-08-17-10-00-00-未完整恢复.m4a"
        )
        guard case let .recovered(actualOutput) = results[0].outcome else {
            return XCTFail("Expected segmented manifest recovery.")
        }
        XCTAssertEqual(actualOutput.lastPathComponent, expectedOutput.lastPathComponent)
        XCTAssertEqual(
            actualOutput.deletingLastPathComponent().resolvingSymlinksInPath().path,
            expectedOutput.deletingLastPathComponent().resolvingSymlinksInPath().path
        )

        await store.releaseReservation(for: expectedOutput)
    }

    func testListFailureEndsRecoveringStateWithoutInventingPerFileResult() async throws {
        let store = RecoveryStoreSpy(
            interrupted: [],
            recoveredURLs: [:],
            listError: RecordingFailure(code: .write, message: "scan failed")
        )
        let finalizer = RecoveryFinalizerSpy()
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: finalizer
        )

        let results = await service.recoverInterruptedRecordings()

        XCTAssertTrue(results.isEmpty)
        let isRecovering = await service.isRecovering
        let callCount = await finalizer.callCount
        XCTAssertFalse(isRecovering)
        XCTAssertEqual(callCount, 0)
    }

    func testRecoveredURLFailureIsIsolatedAndDoesNotReleaseUnknownReservation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.inprogress.mov")
        let second = directory.appendingPathComponent("second.inprogress.mov")
        let secondOutput = directory.appendingPathComponent("second-recovered.m4a")
        let store = RecoveryStoreSpy(
            interrupted: [first, second],
            recoveredURLs: [second: secondOutput]
        )
        let finalizer = RecoveryFinalizerSpy()
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: finalizer
        )

        let results = await service.recoverInterruptedRecordings()

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(
            results[0],
            RecoveryResult(outcome: .failed(first, "missing recovery output"))
        )
        XCTAssertEqual(results[1], RecoveryResult(outcome: .recovered(secondOutput)))
        let workingURLs = await finalizer.workingURLs
        let releasedURLs = await store.releasedURLs
        XCTAssertEqual(workingURLs, [second])
        XCTAssertEqual(releasedURLs, [secondOutput])
    }
}

private actor RecoveryStoreSpy: InterruptedRecordingStoring {
    private let interrupted: [URL]
    private let recoveredURLs: [URL: URL]
    private let listError: Error?
    private(set) var listCallCount = 0
    private(set) var releasedURLs: [URL] = []

    init(interrupted: [URL], recoveredURLs: [URL: URL], listError: Error? = nil) {
        self.interrupted = interrupted
        self.recoveredURLs = recoveredURLs
        self.listError = listError
    }

    func listInterruptedRecordings() async throws -> [URL] {
        listCallCount += 1
        if let listError { throw listError }
        return interrupted
    }

    func recoveredURL(for workingURL: URL) async throws -> URL {
        guard let recoveredURL = recoveredURLs[workingURL] else {
            throw RecordingFailure(code: .write, message: "missing recovery output")
        }
        return recoveredURL
    }

    func releaseReservation(for outputURL: URL) async {
        releasedURLs.append(outputURL)
    }
}

private actor RecoveryFinalizerSpy: InterruptedRecordingFinalizing {
    private let failingURLs: Set<URL>
    private let gate: RecoveryAsyncGate?
    private let entered = AsyncStream<Void>.makeStream()
    private(set) var callCount = 0
    private(set) var workingURLs: [URL] = []

    init(failingURLs: Set<URL> = [], gate: RecoveryAsyncGate? = nil) {
        self.failingURLs = failingURLs
        self.gate = gate
    }

    func recover(workingURL: URL, recoveredURL: URL) async throws -> URL {
        callCount += 1
        workingURLs.append(workingURL)
        entered.continuation.yield()
        await gate?.wait()
        if failingURLs.contains(workingURL) {
            throw RecordingFailure(code: .finalize, message: "injected recovery failure")
        }
        return recoveredURL
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private actor RecoveryAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class RecoverySignal: @unchecked Sendable {
    private let stream = AsyncStream<Void>.makeStream()

    func signal() {
        stream.continuation.yield()
    }

    func wait() async {
        var iterator = stream.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
