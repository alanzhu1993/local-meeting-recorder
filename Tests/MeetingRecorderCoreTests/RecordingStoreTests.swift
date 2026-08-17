import Foundation
import XCTest
@testable import MeetingRecorderCore

final class RecordingStoreTests: XCTestCase {
    func testUsesStartDateAndNeverOverwrites() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = ISO8601DateFormatter().date(from: "2026-08-17T23:59:59+08:00")!
        let store = RecordingStore(
            root: root,
            timeZone: TimeZone(secondsFromGMT: 28_800)!,
            availableCapacity: { 2_000_000_000 }
        )

        let first = try await store.prepare(startedAt: start)
        FileManager.default.createFile(atPath: first.finalURL.path, contents: Data())
        let second = try await store.prepare(startedAt: start)

        XCTAssertEqual(first.directoryURL.lastPathComponent, "2026-08-17")
        XCTAssertEqual(first.finalURL.lastPathComponent, "会议录音-2026-08-17-23-59-59.m4a")
        XCTAssertEqual(second.finalURL.lastPathComponent, "会议录音-2026-08-17-23-59-59-2.m4a")
        XCTAssertEqual(second.workingURL.lastPathComponent, ".会议录音-2026-08-17-23-59-59-2.inprogress.mov")
    }

    func testPrepareRejectsWhenAvailableCapacityIsBelowOneGigabyte() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root, availableCapacity: { 999_999_999 })

        do {
            _ = try await store.prepare(startedAt: Date())
            XCTFail("Expected storage failure")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .storage)
            XCTAssertEqual(failure.message, "可用空间不足 1 GB，未开始录音。")
        }
    }

    func testPrepareReservesNamesBeforeAWriterCreatesFiles() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(
            root: root,
            timeZone: TimeZone(secondsFromGMT: 28_800)!,
            availableCapacity: { 2_000_000_000 }
        )
        let start = ISO8601DateFormatter().date(from: "2026-08-17T23:59:59+08:00")!

        let first = try await store.prepare(startedAt: start)
        let second = try await store.prepare(startedAt: start)

        XCTAssertEqual(first.finalURL.lastPathComponent, "会议录音-2026-08-17-23-59-59.m4a")
        XCTAssertEqual(second.finalURL.lastPathComponent, "会议录音-2026-08-17-23-59-59-2.m4a")
        XCTAssertNotEqual(first.workingURL, second.workingURL)
    }

    func testIndependentStoresAtomicallyReserveDifferentNames() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeZone = TimeZone(secondsFromGMT: 28_800)!
        let start = ISO8601DateFormatter().date(from: "2026-08-17T23:59:59+08:00")!
        let firstStore = RecordingStore(root: root, timeZone: timeZone, availableCapacity: { 2_000_000_000 })
        let secondStore = RecordingStore(root: root, timeZone: timeZone, availableCapacity: { 2_000_000_000 })

        async let first = firstStore.prepare(startedAt: start)
        async let second = secondStore.prepare(startedAt: start)
        let (firstPaths, secondPaths) = try await (first, second)

        XCTAssertEqual(
            Set([firstPaths.finalURL.lastPathComponent, secondPaths.finalURL.lastPathComponent]),
            Set(["会议录音-2026-08-17-23-59-59.m4a", "会议录音-2026-08-17-23-59-59-2.m4a"])
        )
        XCTAssertNotEqual(firstPaths.workingURL, secondPaths.workingURL)
    }

    func testPrepareMapsDirectoryCreationFailureToWriteFailure() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.path, contents: Data())
        let store = RecordingStore(root: root, availableCapacity: { 2_000_000_000 })

        do {
            _ = try await store.prepare(startedAt: Date())
            XCTFail("Expected write failure")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .write)
        } catch {
            XCTFail("Expected RecordingFailure, got \(error)")
        }
    }

    func testReleaseReservationAfterWorkingFileMaterializesRemovesSidecar() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = ISO8601DateFormatter().date(from: "2026-08-17T23:59:59+08:00")!
        let store = RecordingStore(
            root: root,
            timeZone: TimeZone(secondsFromGMT: 28_800)!,
            availableCapacity: { 2_000_000_000 }
        )

        let paths = try await store.prepare(startedAt: start)
        FileManager.default.createFile(atPath: paths.workingURL.path, contents: Data())
        await store.releaseReservation(for: paths.finalURL)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.directoryURL
                    .appendingPathComponent(".会议录音-2026-08-17-23-59-59.reservation").path
            )
        )
    }

    func testReleaseReservationAfterCancelledPreparationAllowsNameReuse() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = ISO8601DateFormatter().date(from: "2026-08-17T23:59:59+08:00")!
        let timeZone = TimeZone(secondsFromGMT: 28_800)!
        let store = RecordingStore(root: root, timeZone: timeZone, availableCapacity: { 2_000_000_000 })

        let cancelled = try await store.prepare(startedAt: start)
        await store.releaseReservation(for: cancelled.finalURL)
        let retryStore = RecordingStore(root: root, timeZone: timeZone, availableCapacity: { 2_000_000_000 })
        let retry = try await retryStore.prepare(startedAt: start)

        XCTAssertEqual(retry.finalURL.lastPathComponent, "会议录音-2026-08-17-23-59-59.m4a")
    }

    func testPrepareReclaimsStaleReservationAfterPreviousProcessExits() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026-08-17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staleReservation = directory.appendingPathComponent(".会议录音-2026-08-17-23-59-59.reservation")
        FileManager.default.createFile(atPath: staleReservation.path, contents: Data())
        let store = RecordingStore(
            root: root,
            timeZone: TimeZone(secondsFromGMT: 28_800)!,
            availableCapacity: { 2_000_000_000 }
        )
        let start = ISO8601DateFormatter().date(from: "2026-08-17T23:59:59+08:00")!

        let paths = try await store.prepare(startedAt: start)

        XCTAssertEqual(paths.finalURL.lastPathComponent, "会议录音-2026-08-17-23-59-59.m4a")
    }

    func testRecoveredURLRemovesWorkingMarkerAndNeverOverwrites() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026-08-17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workingURL = directory.appendingPathComponent(".会议录音-2026-08-17-23-59-59.inprogress.mov")
        let existingRecoveredURL = directory.appendingPathComponent("会议录音-2026-08-17-23-59-59-未完整恢复.m4a")
        FileManager.default.createFile(atPath: existingRecoveredURL.path, contents: Data())
        let store = RecordingStore(root: root, availableCapacity: { 2_000_000_000 })

        let recoveredURL = try await store.recoveredURL(for: workingURL)

        XCTAssertEqual(recoveredURL.lastPathComponent, "会议录音-2026-08-17-23-59-59-未完整恢复-2.m4a")
        XCTAssertEqual(recoveredURL.deletingLastPathComponent(), directory)
    }

    func testRecoveredURLRejectsWorkingFileOutsideRecordingRoot() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideWorkingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(".会议录音-2026-08-17-23-59-59.inprogress.mov")
        let store = RecordingStore(root: root, availableCapacity: { 2_000_000_000 })

        do {
            _ = try await store.recoveredURL(for: outsideWorkingURL)
            XCTFail("Expected write failure")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .write)
        }
    }

    func testRecoveredURLRejectsInvalidWorkingFileNameAndDateDirectory() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026-08-17", isDirectory: true)
        let wrongDirectory = root.appendingPathComponent("2026-08-18", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrongDirectory, withIntermediateDirectories: true)
        let store = RecordingStore(root: root, availableCapacity: { 2_000_000_000 })

        for invalidURL in [
            directory.appendingPathComponent(".unrelated.inprogress.mov"),
            wrongDirectory.appendingPathComponent(".会议录音-2026-08-17-23-59-59.inprogress.mov")
        ] {
            do {
                _ = try await store.recoveredURL(for: invalidURL)
                XCTFail("Expected write failure for \(invalidURL.lastPathComponent)")
            } catch let failure as RecordingFailure {
                XCTAssertEqual(failure.code, .write)
            } catch {
                XCTFail("Expected RecordingFailure, got \(error)")
            }
        }
    }

    func testListsOnlyInterruptedWorkingFilesInSortedOrder() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026-08-17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = directory.appendingPathComponent(".会议录音-2026-08-17-10-00-01-2.inprogress.mov")
        let first = directory.appendingPathComponent(".会议录音-2026-08-17-10-00-00.inprogress.mov")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        FileManager.default.createFile(atPath: first.path, contents: Data())
        FileManager.default.createFile(atPath: directory.appendingPathComponent("会议录音-2026-08-17-10-00-00.m4a").path, contents: Data())
        FileManager.default.createFile(atPath: directory.appendingPathComponent(".unrelated.inprogress.mov").path, contents: Data())
        let wrongDateDirectory = root.appendingPathComponent("2026-08-18", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongDateDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: wrongDateDirectory.appendingPathComponent(".会议录音-2026-08-17-10-00-02.inprogress.mov").path,
            contents: Data()
        )
        let store = RecordingStore(root: root, availableCapacity: { 2_000_000_000 })

        let interrupted = try await store.listInterruptedRecordings()

        XCTAssertEqual(
            interrupted.map(\.lastPathComponent),
            [first.lastPathComponent, second.lastPathComponent]
        )
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
