@preconcurrency import AVFoundation
import Darwin
import Foundation

public struct M4AFinalizer: Sendable {
    public init() {}

    public func recover(
        workingURL: URL,
        recoveredURL: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        let claim = try await RecoveryClaim.acquire(for: workingURL)
        defer { claim.release() }

        guard FileManager.default.fileExists(atPath: workingURL.path) else {
            throw failure("The working recording no longer exists; another recovery may have completed.")
        }
        guard !FileManager.default.fileExists(atPath: recoveredURL.path) else {
            throw failure("The destination recording already exists and was not replaced.")
        }
        guard workingURL.standardizedFileURL != recoveredURL.standardizedFileURL else {
            throw failure("The working and destination recording paths must be different.")
        }

        if let manifest = try SegmentedManifestIO.load(from: workingURL) {
            return try await recoverSegmented(
                manifest,
                manifestURL: workingURL,
                recoveredURL: recoveredURL
            )
        }
        return try await recoverMovie(
            workingURL: workingURL,
            recoveredURL: recoveredURL
        )
    }

    private func recoverMovie(
        workingURL: URL,
        recoveredURL: URL
    ) async throws -> URL {
        let temporaryURL = temporaryM4A(near: recoveredURL)
        defer { removeIfPresent(temporaryURL) }
        try await export(
            asset: AVURLAsset(url: workingURL),
            preset: AVAssetExportPresetPassthrough,
            to: temporaryURL,
            operation: "export the working recording"
        )
        try await validateM4A(at: temporaryURL)
        try Task.checkCancellation()
        try publishWithoutOverwriting(temporaryURL, to: recoveredURL)
        try removeCommittedSource(workingURL)
        return recoveredURL
    }

    private func recoverSegmented(
        _ manifest: SegmentedRecordingManifest,
        manifestURL: URL,
        recoveredURL: URL
    ) async throws -> URL {
        guard
            manifest.sampleRate > 0,
            manifest.channels == 2,
            manifest.segmentFrames > 0
        else {
            throw failure("The segmented recording manifest is invalid.")
        }
        let directory = manifestURL.deletingLastPathComponent()
        var inputsByIndex: [Int64: RecoverySegmentInput] = [:]
        for segment in manifest.completed {
            let url = try childURL(named: segment.finalFileName, in: directory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw failure("A completed audio segment is missing: \(segment.finalFileName)")
            }
            inputsByIndex[segment.index] = RecoverySegmentInput(
                index: segment.index,
                url: url
            )
        }

        if let current = manifest.current {
            let currentWorkingURL = try childURL(
                named: current.workingFileName,
                in: directory
            )
            let currentFinalURL = try childURL(
                named: current.finalFileName,
                in: directory
            )
            if !FileManager.default.fileExists(atPath: currentFinalURL.path),
               FileManager.default.fileExists(atPath: currentWorkingURL.path) {
                _ = try await M4AFinalizer().recover(
                    workingURL: currentWorkingURL,
                    recoveredURL: currentFinalURL
                )
            }
            if FileManager.default.fileExists(atPath: currentFinalURL.path) {
                inputsByIndex[current.index] = RecoverySegmentInput(
                    index: current.index,
                    url: currentFinalURL
                )
            }
        }

        let inputs = inputsByIndex.values.sorted { $0.index < $1.index }
        guard !inputs.isEmpty else {
            throw failure("The segmented recording has no recoverable audio segments.")
        }
        let temporaryURL = temporaryM4A(near: recoveredURL)
        defer { removeIfPresent(temporaryURL) }
        let composition = try await positionedComposition(
            inputs: inputs,
            sampleRate: manifest.sampleRate,
            segmentFrames: manifest.segmentFrames
        )
        try await export(
            asset: composition,
            preset: AVAssetExportPresetAppleM4A,
            to: temporaryURL,
            operation: "merge recovered audio segments"
        )
        try await validateM4A(at: temporaryURL)
        try Task.checkCancellation()
        try publishWithoutOverwriting(temporaryURL, to: recoveredURL)

        for input in inputs {
            try removeCommittedSource(input.url)
        }
        if let current = manifest.current {
            let currentWorkingURL = try childURL(
                named: current.workingFileName,
                in: directory
            )
            try removeCommittedSource(currentWorkingURL)
        }
        try removeCommittedSource(manifestURL)
        return recoveredURL
    }

    private func positionedComposition(
        inputs: [RecoverySegmentInput],
        sampleRate: Double,
        segmentFrames: Int64
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw failure("Could not create the recovered audio track.")
        }
        let timescale = CMTimeScale(sampleRate)
        let maximumSegmentDuration = CMTime(
            value: segmentFrames,
            timescale: timescale
        )
        for input in inputs {
            try Task.checkCancellation()
            guard input.index >= 0 else {
                throw failure("A segmented recording contained a negative segment index.")
            }
            let asset = AVURLAsset(url: input.url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1 else {
                throw failure("A recovered segment did not contain exactly one audio track.")
            }
            let assetDuration = try await asset.load(.duration)
            let duration = CMTimeMinimum(assetDuration, maximumSegmentDuration)
            let insertionTime = CMTime(
                value: input.index * segmentFrames,
                timescale: timescale
            )
            if CMTimeCompare(insertionTime, composition.duration) > 0 {
                composition.insertEmptyTimeRange(CMTimeRange(
                    start: composition.duration,
                    duration: insertionTime - composition.duration
                ))
            }
            do {
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: tracks[0],
                    at: insertionTime
                )
            } catch {
                throw failure("Could not position a recovered audio segment: \(error.localizedDescription)")
            }
        }
        return composition
    }

    private func export(
        asset: AVAsset,
        preset: String,
        to temporaryURL: URL,
        operation: String
    ) async throws {
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: preset
        ) else {
            throw failure("Could not \(operation): no compatible export session.")
        }
        do {
            try await exporter.export(to: temporaryURL, as: .m4a)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure("Could not \(operation): \(error.localizedDescription)")
        }
    }

    private func validateM4A(at url: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let playable: Bool
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            playable = try await asset.load(.isPlayable)
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw failure("Could not read the exported M4A: \(error.localizedDescription)")
        }
        guard duration.isValid, duration.isNumeric, CMTimeGetSeconds(duration) > 0 else {
            throw failure("The exported M4A did not have a valid positive duration.")
        }
        guard playable, tracks.count == 1 else {
            throw failure("The exported M4A was not playable with exactly one audio track.")
        }
        let descriptions: [CMFormatDescription]
        do {
            descriptions = try await tracks[0].load(.formatDescriptions)
        } catch {
            throw failure("Could not inspect the exported audio format: \(error.localizedDescription)")
        }
        guard descriptions.contains(where: {
            CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
        }) else {
            throw failure("The exported audio track was not AAC.")
        }
    }

    private func publishWithoutOverwriting(
        _ temporaryURL: URL,
        to outputURL: URL
    ) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw failure("The destination recording already exists and was not replaced.")
        }
        let result = temporaryURL.path.withCString { temporaryPath in
            outputURL.path.withCString { outputPath in
                link(temporaryPath, outputPath)
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            throw failure("Could not publish audio without overwriting: \(reason)")
        }
    }

    private func childURL(named fileName: String, in directory: URL) throws -> URL {
        guard
            !fileName.isEmpty,
            fileName == URL(fileURLWithPath: fileName).lastPathComponent,
            !fileName.contains("/")
        else {
            throw failure("The segmented manifest contained an unsafe file name.")
        }
        return directory.appendingPathComponent(fileName)
    }

    private func temporaryM4A(near outputURL: URL) -> URL {
        outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.m4a")
    }

    private func removeCommittedSource(_ url: URL) throws {
        let result = url.path.withCString { unlink($0) }
        guard result == 0 || errno == ENOENT else {
            let reason = String(cString: strerror(errno))
            throw failure("Audio was published, but committed source cleanup failed: \(reason)")
        }
    }

    private func removeIfPresent(_ url: URL) {
        _ = url.path.withCString { unlink($0) }
    }

    private func failure(_ message: String) -> RecordingFailure {
        RecordingFailure(code: .finalize, message: message)
    }
}

private struct RecoverySegmentInput: Sendable {
    let index: Int64
    let url: URL
}

private final class RecoveryClaim: @unchecked Sendable {
    private let descriptor: Int32
    private let lockURL: URL
    private let releaseLock = NSLock()
    private var released = false

    private init(descriptor: Int32, lockURL: URL) {
        self.descriptor = descriptor
        self.lockURL = lockURL
    }

    static func acquire(for workingURL: URL) async throws -> RecoveryClaim {
        let lockURL = workingURL.deletingLastPathComponent().appendingPathComponent(
            ".\(workingURL.lastPathComponent).recovery.claim"
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let existing = try acquireExisting(lockURL) {
                return existing
            }
            if let created = try createAndPublish(lockURL) {
                return created
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RecordingFailure(
            code: .finalize,
            message: "Timed out waiting for exclusive recovery ownership."
        )
    }

    func release() {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        guard !released else { return }
        released = true
        if Self.path(lockURL, matches: descriptor) {
            _ = lockURL.path.withCString { unlink($0) }
        }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private static func acquireExisting(
        _ lockURL: URL
    ) throws -> RecoveryClaim? {
        let descriptor = lockURL.path.withCString {
            open($0, O_RDWR | O_NOFOLLOW)
        }
        guard descriptor != -1 else {
            if errno == ENOENT { return nil }
            throw claimFailure(errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorCode = errno
            _ = close(descriptor)
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                return nil
            }
            throw claimFailure(errorCode)
        }
        guard path(lockURL, matches: descriptor) else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            return nil
        }
        return RecoveryClaim(descriptor: descriptor, lockURL: lockURL)
    }

    private static func createAndPublish(
        _ lockURL: URL
    ) throws -> RecoveryClaim? {
        let temporaryURL = lockURL.deletingLastPathComponent().appendingPathComponent(
            "\(lockURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporaryURL.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor != -1 else { throw claimFailure(errno) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let errorCode = errno
            _ = temporaryURL.path.withCString { unlink($0) }
            _ = close(descriptor)
            throw claimFailure(errorCode)
        }
        let result = temporaryURL.path.withCString { temporaryPath in
            lockURL.path.withCString { lockPath in
                link(temporaryPath, lockPath)
            }
        }
        let linkError = errno
        _ = temporaryURL.path.withCString { unlink($0) }
        if result == 0 {
            guard path(lockURL, matches: descriptor) else {
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
                return nil
            }
            return RecoveryClaim(descriptor: descriptor, lockURL: lockURL)
        }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        if linkError == EEXIST { return nil }
        throw claimFailure(linkError)
    }

    private static func path(_ url: URL, matches descriptor: Int32) -> Bool {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else { return false }
        var pathStatus = stat()
        guard url.path.withCString({ lstat($0, &pathStatus) }) == 0 else {
            return false
        }
        return descriptorStatus.st_dev == pathStatus.st_dev
            && descriptorStatus.st_ino == pathStatus.st_ino
    }

    private static func claimFailure(_ errorCode: Int32) -> RecordingFailure {
        RecordingFailure(
            code: .finalize,
            message: "Could not claim exclusive recovery ownership: \(String(cString: strerror(errorCode)))"
        )
    }
}
