import AVFoundation
import Foundation
import XCTest
@testable import MeetingRecorderCore

final class RecoverableWriterTests: XCTestCase {
    func testFinalizerNeverOverwritesExistingOutputAndKeepsWorkingFile() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let recoveredURL = directory.appendingPathComponent("recovered.m4a")
        let original = Data("existing recording".utf8)
        try Data("unfinished input".utf8).write(to: workingURL)
        try original.write(to: recoveredURL)

        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: recoveredURL
            )
            XCTFail("Expected finalization failure")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }

        XCTAssertEqual(try Data(contentsOf: recoveredURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testWriterFinishesAACM4AAndOnlyThenDeletesWorkingFile() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let finalURL = directory.appendingPathComponent("final.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        for index in 0..<15 {
            try await writer.append(.sine(startFrame: Int64(index * 960), frameCount: 960))
        }

        let output = try await writer.finish(finalURL: finalURL)

        XCTAssertEqual(output, finalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        let asset = AVURLAsset(url: finalURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(duration), 0.29)
        XCTAssertEqual(tracks.count, 1)
        let descriptions = try await tracks[0].load(.formatDescriptions)
        XCTAssertTrue(descriptions.contains {
            CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
        })
    }

    func testWriterRejectsRegressingTimestampAsWriteFailureAndKeepsWorkingFile() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 100, frameCount: 100))

        do {
            try await writer.append(.sine(startFrame: 50, frameCount: 100))
            XCTFail("Expected write failure")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .write)
        }

        await writer.abort()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testWriterNeverCreatesOrReplacesPreexistingWorkingFile() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let original = Data("do not replace".utf8)
        try original.write(to: workingURL)
        let writer = FragmentedMOVWriter(workingURL: workingURL)

        do {
            try await writer.start()
            XCTFail("Expected write failure")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .write)
        }

        XCTAssertEqual(try Data(contentsOf: workingURL), original)
    }

    func testConcurrentFinishIsLinearizedAndPublishesOnlyOneOutput() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let firstURL = directory.appendingPathComponent("first.m4a")
        let secondURL = directory.appendingPathComponent("second.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))

        async let firstSucceeded: Bool = Self.finish(writer, to: firstURL)
        async let secondSucceeded: Bool = Self.finish(writer, to: secondURL)
        let results = await [firstSucceeded, secondSucceeded]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(
            [firstURL, secondURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testFailedRecoveryLeavesWorkingFileAndDoesNotPublishPartialOutput() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("invalid.mov")
        let outputURL = directory.appendingPathComponent("recovered.m4a")
        try Data("not media".utf8).write(to: workingURL)

        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: outputURL
            )
            XCTFail("Expected finalization failure")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".tmp.m4a") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testFactoryUsesForceTerminationVerifiedFragmentedMOVStrategy() {
        XCTAssertEqual(RecoverableAudioWriterFactory.strategy, .fragmentedMOV)
        XCTAssertTrue(
            RecoverableAudioWriterFactory.make(
                workingURL: URL(fileURLWithPath: "/tmp/task-5-factory-type-check.mov")
            ) is FragmentedMOVWriter
        )
    }

    func testSegmentedWriterClosesSegmentsAndMergesThemAtFinish() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("segmented.inprogress.mov")
        let finalURL = directory.appendingPathComponent("segmented.m4a")
        let writer = SegmentedM4AWriter(
            workingURL: workingURL,
            segmentFrames: 4_800
        )
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        try await writer.append(.sine(startFrame: 4_800, frameCount: 4_800))

        let filesDuringRecording = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertTrue(filesDuringRecording.contains {
            $0.contains("segment-000000") && $0.hasSuffix(".m4a")
        })

        _ = try await writer.finish(finalURL: finalURL)

        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertEqual(remainingFiles, [finalURL.lastPathComponent])
        let duration = try await AVURLAsset(url: finalURL).load(.duration)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(duration), 0.19)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recorder-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func finish(
        _ writer: FragmentedMOVWriter,
        to url: URL
    ) async -> Bool {
        do {
            _ = try await writer.finish(finalURL: url)
            return true
        } catch {
            return false
        }
    }
}
