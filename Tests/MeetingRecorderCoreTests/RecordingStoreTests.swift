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

    func testListsOnlyInterruptedWorkingFilesInSortedOrder() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026-08-17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = directory.appendingPathComponent(".会议录音-2026-08-17-10-00-01.inprogress.mov")
        let first = directory.appendingPathComponent(".会议录音-2026-08-17-10-00-00.inprogress.mov")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        FileManager.default.createFile(atPath: first.path, contents: Data())
        FileManager.default.createFile(atPath: directory.appendingPathComponent("会议录音-2026-08-17-10-00-00.m4a").path, contents: Data())
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
