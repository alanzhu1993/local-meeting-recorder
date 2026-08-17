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
        try await writer.append(.sine(startFrame: 9_600, frameCount: 4_800))

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
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(duration), 0.29)
    }

    func testAbortCancelsSuspendedFinishBeforePublishing() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let finalURL = directory.appendingPathComponent("final.m4a")
        let suspension = TestAsyncSuspension()
        let writer = FragmentedMOVWriter(
            workingURL: workingURL,
            hooks: FragmentedMOVWriterHooks(
                beforeRecovery: { try await suspension.suspend() }
            )
        )
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        let finishTask = Task { () -> Bool in
            do {
                _ = try await writer.finish(finalURL: finalURL)
                return true
            } catch {
                return false
            }
        }
        await suspension.waitUntilEntered()

        await writer.abort()
        let finishSucceeded = await finishTask.value

        XCTAssertFalse(finishSucceeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testAppendWaitsThroughTemporaryBackpressure() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let readiness = TestReadinessControl(ready: false)
        let writer = FragmentedMOVWriter(
            workingURL: workingURL,
            hooks: FragmentedMOVWriterHooks(
                readiness: { readiness.check() },
                readinessTimeout: .seconds(1)
            )
        )
        try await writer.start()
        let appendTask = Task {
            try await writer.append(.sine(startFrame: 0, frameCount: 960))
        }
        XCTAssertTrue(readiness.waitUntilChecked())

        readiness.setReady()
        try await appendTask.value

        await writer.abort()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testAbortInterruptsBackpressureWait() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let readiness = TestReadinessControl(ready: false)
        let writer = FragmentedMOVWriter(
            workingURL: workingURL,
            hooks: FragmentedMOVWriterHooks(
                readiness: { readiness.check() },
                readinessTimeout: .seconds(30)
            )
        )
        try await writer.start()
        let appendTask = Task { () -> Bool in
            do {
                try await writer.append(.sine(startFrame: 0, frameCount: 960))
                return true
            } catch {
                return false
            }
        }
        XCTAssertTrue(readiness.waitUntilChecked())

        await writer.abort()
        let appendSucceeded = await appendTask.value

        XCTAssertFalse(appendSucceeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testSegmentedAbortCancelsSuspendedAppendWithoutReturningToRunning() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("segmented.inprogress.mov")
        let suspension = TestAsyncSuspension()
        let writer = SegmentedM4AWriter(
            workingURL: workingURL,
            segmentFrames: 4_800,
            hooks: SegmentedM4AWriterHooks(
                beforeSegmentAppend: { try await suspension.suspend() }
            )
        )
        try await writer.start()
        let appendTask = Task { () -> Bool in
            do {
                try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
                return true
            } catch {
                return false
            }
        }
        await suspension.waitUntilEntered()

        await writer.abort()
        let appendSucceeded = await appendTask.value

        XCTAssertFalse(appendSucceeded)
        do {
            try await writer.append(.sine(startFrame: 4_800, frameCount: 4_800))
            XCTFail("Aborted segmented writer must not return to running.")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testOnlyOneConcurrentRecoveryOfSameWorkingFileCanPublish() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let firstURL = directory.appendingPathComponent("first.m4a")
        let secondURL = directory.appendingPathComponent("second.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()

        async let first = Self.recover(workingURL, to: firstURL)
        async let second = Self.recover(workingURL, to: secondURL)
        let results = await [first, second]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(
            [firstURL, secondURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testFinalizerRecoversInterruptedSegmentManifest() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("segmented.inprogress.mov")
        let recoveredURL = directory.appendingPathComponent("recovered.m4a")
        let writer = SegmentedM4AWriter(
            workingURL: workingURL,
            segmentFrames: 4_800
        )
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        try await writer.append(.sine(startFrame: 4_800, frameCount: 4_800))
        await writer.abort()

        _ = try await M4AFinalizer().recover(
            workingURL: workingURL,
            recoveredURL: recoveredURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
        let asset = AVURLAsset(url: recoveredURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(duration), 0.19)
    }

    func testHardLinkAliasesShareOneDeterministicRecoveryClaim() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let aliasURL = directory.appendingPathComponent("working-alias.mov")
        let firstURL = directory.appendingPathComponent("first.m4a")
        let secondURL = directory.appendingPathComponent("second.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        try FileManager.default.linkItem(at: workingURL, to: aliasURL)

        let firstClaimGate = TestAsyncGate()
        let secondContended = TestSignal()
        let firstFinalizer = M4AFinalizer(hooks: M4AFinalizerHooks(
            afterClaimAcquired: { await firstClaimGate.suspend() }
        ))
        let secondFinalizer = M4AFinalizer(hooks: M4AFinalizerHooks(
            onClaimContention: { secondContended.signal() }
        ))
        let firstTask = Task {
            try await firstFinalizer.recover(
                workingURL: workingURL,
                recoveredURL: firstURL
            )
        }
        await firstClaimGate.waitUntilEntered()
        let secondTask = Task { () -> Bool in
            do {
                _ = try await secondFinalizer.recover(
                    workingURL: aliasURL,
                    recoveredURL: secondURL
                )
                return true
            } catch {
                return false
            }
        }
        XCTAssertTrue(secondContended.wait())

        await firstClaimGate.open()
        let firstOutput = try await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertEqual(firstOutput, firstURL)
        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(
            [firstURL, secondURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            1
        )
    }

    func testPublishedOutputSucceedsDespiteCleanupFailureAndCannotRepublish() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let firstURL = directory.appendingPathComponent("first.m4a")
        let secondURL = directory.appendingPathComponent("second.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let finalizer = M4AFinalizer(hooks: M4AFinalizerHooks(
            cleanupSource: { _ in
                throw RecordingFailure(code: .finalize, message: "injected unlink failure")
            }
        ))

        let output = try await finalizer.recover(
            workingURL: workingURL,
            recoveredURL: firstURL
        )

        XCTAssertEqual(output, firstURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: secondURL
            )
            XCTFail("A committed working inode must not publish a second output.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testSegmentedRecoverySkipsMissingCompletedSegmentAndPreservesGap() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("segmented.inprogress.mov")
        let recoveredURL = directory.appendingPathComponent("recovered.m4a")
        let writer = SegmentedM4AWriter(workingURL: workingURL, segmentFrames: 4_800)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        try await writer.append(.sine(startFrame: 4_800, frameCount: 4_800))
        try await writer.append(.sine(startFrame: 9_600, frameCount: 4_800))
        await writer.abort()
        let missingURL = directory.appendingPathComponent(
            ".segmented.inprogress.mov.segment-000001.m4a"
        )
        try FileManager.default.removeItem(at: missingURL)

        _ = try await M4AFinalizer().recover(
            workingURL: workingURL,
            recoveredURL: recoveredURL
        )

        let duration = try await AVURLAsset(url: recoveredURL).load(.duration)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(duration), 0.29)
    }

    func testSegmentedRecoveryFallsBackWhenCurrentMovieIsDamaged() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("segmented.inprogress.mov")
        let recoveredURL = directory.appendingPathComponent("recovered.m4a")
        let writer = SegmentedM4AWriter(workingURL: workingURL, segmentFrames: 4_800)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        try await writer.append(.sine(startFrame: 4_800, frameCount: 1))
        await writer.abort()
        let currentURL = directory.appendingPathComponent(
            ".segmented.inprogress.mov.segment-000001.inprogress.mov"
        )
        try Data("damaged current movie".utf8).write(to: currentURL)

        _ = try await M4AFinalizer().recover(
            workingURL: workingURL,
            recoveredURL: recoveredURL
        )

        let duration = try await AVURLAsset(url: recoveredURL).load(.duration)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(duration), 0.099)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testFragmentedFinishReturnsCommittedOutputWhenAbortArrivesPostCommit() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let finalURL = directory.appendingPathComponent("final.m4a")
        let suspension = TestAsyncSuspension()
        let writer = FragmentedMOVWriter(
            workingURL: workingURL,
            hooks: FragmentedMOVWriterHooks(
                afterRecoveryCommitted: { try await suspension.suspend() }
            )
        )
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        let finishTask = Task { try await writer.finish(finalURL: finalURL) }
        await suspension.waitUntilEntered()

        await writer.abort()

        let finishOutput = try await finishTask.value
        XCTAssertEqual(finishOutput, finalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        do {
            try await writer.append(.sine(startFrame: 4_800, frameCount: 960))
            XCTFail("A committed writer must remain finished after abort returns.")
        } catch {}
    }

    func testSegmentedFinishReturnsCommittedOutputWhenAbortArrivesPostCommit() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("segmented.inprogress.mov")
        let finalURL = directory.appendingPathComponent("final.m4a")
        let suspension = TestAsyncSuspension()
        let writer = SegmentedM4AWriter(
            workingURL: workingURL,
            segmentFrames: 4_800,
            hooks: SegmentedM4AWriterHooks(
                afterRecoveryCommitted: { try await suspension.suspend() }
            )
        )
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        let finishTask = Task { try await writer.finish(finalURL: finalURL) }
        await suspension.waitUntilEntered()

        await writer.abort()

        let finishOutput = try await finishTask.value
        XCTAssertEqual(finishOutput, finalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        do {
            try await writer.append(.sine(startFrame: 4_800, frameCount: 960))
            XCTFail("A committed segmented writer must remain finished.")
        } catch {}
    }

    func testBackpressureTimeoutMapsToWriteFailure() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let writer = FragmentedMOVWriter(
            workingURL: workingURL,
            hooks: FragmentedMOVWriterHooks(
                readiness: { false },
                readinessTimeout: .milliseconds(20)
            )
        )
        try await writer.start()

        do {
            try await writer.append(.sine(startFrame: 0, frameCount: 960))
            XCTFail("Expected bounded backpressure timeout.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .write)
            XCTAssertTrue(failure.message.contains("Timed out"))
        }
        await writer.abort()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testPendingMarkerPermanentlyBindsOriginalTargetAcrossFinalizerInstances() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let originalURL = directory.appendingPathComponent("original.m4a")
        let differentURL = directory.appendingPathComponent("different.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let interrupted = M4AFinalizer(hooks: M4AFinalizerHooks(
            interruptAfterPendingPersisted: { true }
        ))

        do {
            _ = try await interrupted.recover(
                workingURL: workingURL,
                recoveredURL: originalURL
            )
            XCTFail("Expected simulated interruption after pending persistence.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }

        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: differentURL
            )
            XCTFail("Persisted pending target must reject a different target.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: differentURL.path))

        let completed = try await M4AFinalizer().recover(
            workingURL: workingURL,
            recoveredURL: originalURL
        )
        XCTAssertEqual(completed, originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
    }

    func testPendingAfterLinkRejectsDifferentTargetWhenOriginalWasMoved() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let originalURL = directory.appendingPathComponent("original.m4a")
        let movedURL = directory.appendingPathComponent("moved.m4a")
        let differentURL = directory.appendingPathComponent("different.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let interrupted = M4AFinalizer(hooks: M4AFinalizerHooks(
            interruptAfterLink: { true }
        ))

        do {
            _ = try await interrupted.recover(
                workingURL: workingURL,
                recoveredURL: originalURL
            )
            XCTFail("Expected simulated interruption after publish link.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: differentURL
            )
            XCTFail("A moved committed target must not permit republishing elsewhere.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: differentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    }

    func testFinalizedMarkerWriteFailureStillReturnsCommitAndRejectsDifferentTarget() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let firstURL = directory.appendingPathComponent("first.m4a")
        let differentURL = directory.appendingPathComponent("different.m4a")
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let finalizer = M4AFinalizer(hooks: M4AFinalizerHooks(
            finalizedMarkerWrite: {
                throw RecordingFailure(code: .finalize, message: "injected xattr fsync failure")
            },
            cleanupSource: { _ in
                throw RecordingFailure(code: .finalize, message: "retain marked working")
            }
        ))

        let output = try await finalizer.recover(
            workingURL: workingURL,
            recoveredURL: firstURL
        )

        XCTAssertEqual(output, firstURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: differentURL
            )
            XCTFail("Pending marker after finalized-write failure must remain bound.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: differentURL.path))
    }

    func testStagingReplacementBetweenVerificationAndLinkCannotCommitWrongInode() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let originalURL = directory.appendingPathComponent("original.m4a")
        let differentURL = directory.appendingPathComponent("different.m4a")
        let displacedStagingURL = directory.appendingPathComponent("displaced-staging.m4a")
        let replacement = Data("not the verified staged recording".utf8)
        let observedStaging = TestURLBox()
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let finalizer = M4AFinalizer(hooks: M4AFinalizerHooks(
            afterStagingVerifiedBeforeLink: { stagingURL in
                observedStaging.set(stagingURL)
                try FileManager.default.moveItem(
                    at: stagingURL,
                    to: displacedStagingURL
                )
                try replacement.write(to: stagingURL)
            }
        ))

        do {
            _ = try await finalizer.recover(
                workingURL: workingURL,
                recoveredURL: originalURL
            )
            XCTFail("A link of a replacement inode must not be reported as committed.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }

        let stagingURL = try XCTUnwrap(observedStaging.value)
        XCTAssertEqual(try Data(contentsOf: stagingURL), replacement)
        XCTAssertEqual(try Data(contentsOf: originalURL), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: differentURL
            )
            XCTFail("The pending marker must remain bound to the original target.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: differentURL.path))
    }

    func testPendingRecoveryRechecksTargetAfterStagingPathIsReplaced() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let originalURL = directory.appendingPathComponent("original.m4a")
        let differentURL = directory.appendingPathComponent("different.m4a")
        let displacedStagingURL = directory.appendingPathComponent("displaced-staging.m4a")
        let replacement = Data("pending recovery replacement".utf8)
        let observedStaging = TestURLBox()
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let interrupted = M4AFinalizer(hooks: M4AFinalizerHooks(
            interruptAfterPendingPersisted: { true }
        ))
        do {
            _ = try await interrupted.recover(
                workingURL: workingURL,
                recoveredURL: originalURL
            )
            XCTFail("Expected simulated interruption after pending persistence.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }

        let retry = M4AFinalizer(hooks: M4AFinalizerHooks(
            afterStagingVerifiedBeforeLink: { stagingURL in
                observedStaging.set(stagingURL)
                try FileManager.default.moveItem(
                    at: stagingURL,
                    to: displacedStagingURL
                )
                try replacement.write(to: stagingURL)
            }
        ))
        do {
            _ = try await retry.recover(
                workingURL: workingURL,
                recoveredURL: originalURL
            )
            XCTFail("A pending retry must reject the linked replacement inode.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }

        let stagingURL = try XCTUnwrap(observedStaging.value)
        XCTAssertEqual(try Data(contentsOf: stagingURL), replacement)
        XCTAssertEqual(try Data(contentsOf: originalURL), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: differentURL
            )
            XCTFail("A failed same-target retry must retain its original binding.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: differentURL.path))
    }

    func testStagingReplacementBetweenVerificationAndCleanupIsNotDeleted() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingURL = directory.appendingPathComponent("working.mov")
        let originalURL = directory.appendingPathComponent("original.m4a")
        let differentURL = directory.appendingPathComponent("different.m4a")
        let displacedStagingURL = directory.appendingPathComponent("displaced-staging.m4a")
        let replacement = Data("replacement must survive cleanup".utf8)
        let observedStaging = TestURLBox()
        let writer = FragmentedMOVWriter(workingURL: workingURL)
        try await writer.start()
        try await writer.append(.sine(startFrame: 0, frameCount: 4_800))
        await writer.abort()
        let finalizer = M4AFinalizer(hooks: M4AFinalizerHooks(
            afterStagingVerifiedBeforeCleanup: { stagingURL in
                observedStaging.set(stagingURL)
                try FileManager.default.moveItem(
                    at: stagingURL,
                    to: displacedStagingURL
                )
                try replacement.write(to: stagingURL)
            },
            cleanupSource: { _ in
                throw RecordingFailure(code: .finalize, message: "retain marked working")
            }
        ))

        let output = try await finalizer.recover(
            workingURL: workingURL,
            recoveredURL: originalURL
        )

        let stagingURL = try XCTUnwrap(observedStaging.value)
        XCTAssertEqual(output, originalURL)
        XCTAssertNotEqual(try Data(contentsOf: originalURL), replacement)
        XCTAssertEqual(try Data(contentsOf: stagingURL), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: differentURL
            )
            XCTFail("Cleanup contention must not clear or rebind the marker.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .finalize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: differentURL.path))
        XCTAssertEqual(try Data(contentsOf: stagingURL), replacement)
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

    private static func recover(_ workingURL: URL, to outputURL: URL) async -> Bool {
        do {
            _ = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: outputURL
            )
            return true
        } catch {
            return false
        }
    }
}

private actor TestAsyncSuspension {
    private var entered = false
    private let enteredSignal = AsyncStream<Void>.makeStream()

    func suspend() async throws {
        entered = true
        enteredSignal.continuation.yield()
        try await Task.sleep(for: .seconds(30))
    }

    func waitUntilEntered() async {
        if entered { return }
        var iterator = enteredSignal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private actor TestAsyncGate {
    private var entered = false
    private let enteredSignal = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        enteredSignal.continuation.yield()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        var iterator = enteredSignal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class TestSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() -> Bool {
        semaphore.wait(timeout: .now() + 2) == .success
    }
}

private final class TestURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: URL?

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: URL) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class TestReadinessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let checked = DispatchSemaphore(value: 0)
    private var ready: Bool
    private var didSignal = false

    init(ready: Bool) {
        self.ready = ready
    }

    func check() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !didSignal {
            didSignal = true
            checked.signal()
        }
        return ready
    }

    func setReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    func waitUntilChecked() -> Bool {
        checked.wait(timeout: .now() + 2) == .success
    }
}
