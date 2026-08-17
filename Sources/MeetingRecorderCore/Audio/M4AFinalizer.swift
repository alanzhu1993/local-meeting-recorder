@preconcurrency import AVFoundation
import Darwin
import Foundation

struct M4AFinalizerHooks: Sendable {
    let afterClaimAcquired: (@Sendable () async throws -> Void)?
    let onClaimContention: (@Sendable () -> Void)?
    let interruptAfterPendingPersisted: (@Sendable () -> Bool)?
    let interruptAfterLink: (@Sendable () -> Bool)?
    let afterStagingVerifiedBeforeLink: (@Sendable (URL) throws -> Void)?
    let afterStagingVerifiedBeforeCleanup: (@Sendable (URL) throws -> Void)?
    let finalizedMarkerWrite: (@Sendable () throws -> Void)?
    let cleanupSource: (@Sendable (URL) throws -> Void)?

    init(
        afterClaimAcquired: (@Sendable () async throws -> Void)? = nil,
        onClaimContention: (@Sendable () -> Void)? = nil,
        interruptAfterPendingPersisted: (@Sendable () -> Bool)? = nil,
        interruptAfterLink: (@Sendable () -> Bool)? = nil,
        afterStagingVerifiedBeforeLink: (@Sendable (URL) throws -> Void)? = nil,
        afterStagingVerifiedBeforeCleanup: (@Sendable (URL) throws -> Void)? = nil,
        finalizedMarkerWrite: (@Sendable () throws -> Void)? = nil,
        cleanupSource: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.afterClaimAcquired = afterClaimAcquired
        self.onClaimContention = onClaimContention
        self.interruptAfterPendingPersisted = interruptAfterPendingPersisted
        self.interruptAfterLink = interruptAfterLink
        self.afterStagingVerifiedBeforeLink = afterStagingVerifiedBeforeLink
        self.afterStagingVerifiedBeforeCleanup = afterStagingVerifiedBeforeCleanup
        self.finalizedMarkerWrite = finalizedMarkerWrite
        self.cleanupSource = cleanupSource
    }
}

public struct M4AFinalizer: Sendable {
    private let hooks: M4AFinalizerHooks

    public init() {
        hooks = M4AFinalizerHooks()
    }

    init(hooks: M4AFinalizerHooks) {
        self.hooks = hooks
    }

    public func recover(
        workingURL: URL,
        recoveredURL: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        let claim = try await RecoveryClaim.acquire(
            for: workingURL,
            onContention: hooks.onClaimContention
        )
        defer { claim.release() }
        try Task.checkCancellation()
        try await hooks.afterClaimAcquired?()
        try Task.checkCancellation()

        if let committed = try claim.committedOutput(
            requestedURL: recoveredURL,
            afterStagingVerifiedBeforeLink: hooks.afterStagingVerifiedBeforeLink,
            afterStagingVerifiedBeforeCleanup: hooks.afterStagingVerifiedBeforeCleanup
        ) {
            cleanupCommittedSource(claim.canonicalWorkingURL)
            return committed
        }
        guard !FileManager.default.fileExists(atPath: recoveredURL.path) else {
            throw failure("The destination recording already exists and was not replaced.")
        }
        let effectiveWorkingURL = claim.canonicalWorkingURL
        guard effectiveWorkingURL.standardizedFileURL != recoveredURL.standardizedFileURL else {
            throw failure("The working and destination recording paths must be different.")
        }

        if let manifest = try SegmentedManifestIO.load(from: effectiveWorkingURL) {
            return try await recoverSegmented(
                manifest,
                manifestURL: effectiveWorkingURL,
                recoveredURL: recoveredURL,
                claim: claim
            )
        }
        return try await recoverMovie(
            workingURL: effectiveWorkingURL,
            recoveredURL: recoveredURL,
            claim: claim
        )
    }

    private func recoverMovie(
        workingURL: URL,
        recoveredURL: URL,
        claim: RecoveryClaim
    ) async throws -> URL {
        let temporaryURL = temporaryM4A(near: recoveredURL)
        var commitAttempted = false
        defer {
            if !commitAttempted {
                removeIfPresent(temporaryURL)
            }
        }
        try await export(
            asset: AVURLAsset(url: workingURL),
            preset: AVAssetExportPresetPassthrough,
            to: temporaryURL,
            operation: "export the working recording"
        )
        try await validateM4A(at: temporaryURL)
        try Task.checkCancellation()
        commitAttempted = true
        do {
            try commit(temporaryURL, to: recoveredURL, claim: claim)
        } catch let interruption as CommitInterruption {
            throw failure(interruption.message)
        }
        cleanupCommittedSource(workingURL)
        return recoveredURL
    }

    private func recoverSegmented(
        _ manifest: SegmentedRecordingManifest,
        manifestURL: URL,
        recoveredURL: URL,
        claim: RecoveryClaim
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
        var cleanupURLs: [URL] = []
        var timelineEndFrame: Int64 = 0

        for segment in manifest.completed {
            let slotEnd = try timelineFrame(
                index: segment.index,
                segmentFrames: manifest.segmentFrames,
                includeFullSlot: true
            )
            timelineEndFrame = max(timelineEndFrame, slotEnd)
            let url = try childURL(named: segment.finalFileName, in: directory)
            cleanupURLs.append(url)
            if FileManager.default.fileExists(atPath: url.path) {
                inputsByIndex[segment.index] = RecoverySegmentInput(
                    index: segment.index,
                    url: url
                )
            }
        }

        if let current = manifest.current {
            timelineEndFrame = max(
                timelineEndFrame,
                try timelineFrame(
                    index: current.index,
                    segmentFrames: manifest.segmentFrames,
                    includeFullSlot: false
                )
            )
            let currentWorkingURL = try childURL(
                named: current.workingFileName,
                in: directory
            )
            let currentFinalURL = try childURL(
                named: current.finalFileName,
                in: directory
            )
            cleanupURLs.append(currentWorkingURL)
            cleanupURLs.append(currentFinalURL)
            if !FileManager.default.fileExists(atPath: currentFinalURL.path),
               FileManager.default.fileExists(atPath: currentWorkingURL.path) {
                do {
                    _ = try await M4AFinalizer().recover(
                        workingURL: currentWorkingURL,
                        recoveredURL: currentFinalURL
                    )
                    try Task.checkCancellation()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A just-opened fragment may not yet be exportable. Earlier
                    // completed segments remain independently recoverable.
                }
            }
            if FileManager.default.fileExists(atPath: currentFinalURL.path) {
                inputsByIndex[current.index] = RecoverySegmentInput(
                    index: current.index,
                    url: currentFinalURL
                )
            }
        }

        let inputs = inputsByIndex.values.sorted { $0.index < $1.index }
        let positioned = try await positionedComposition(
            inputs: inputs,
            sampleRate: manifest.sampleRate,
            segmentFrames: manifest.segmentFrames,
            minimumTimelineEndFrame: timelineEndFrame
        )
        guard positioned.recoveredSegmentCount > 0 else {
            throw failure("The segmented recording has no recoverable audio segments.")
        }

        let temporaryURL = temporaryM4A(near: recoveredURL)
        var commitAttempted = false
        defer {
            if !commitAttempted {
                removeIfPresent(temporaryURL)
            }
        }
        try await export(
            asset: positioned.composition,
            preset: AVAssetExportPresetAppleM4A,
            to: temporaryURL,
            operation: "merge recovered audio segments"
        )
        try await validateM4A(at: temporaryURL)
        try Task.checkCancellation()
        commitAttempted = true
        do {
            try commit(temporaryURL, to: recoveredURL, claim: claim)
        } catch let interruption as CommitInterruption {
            throw failure(interruption.message)
        }

        var cleanedPaths = Set<String>()
        for url in cleanupURLs where cleanedPaths.insert(url.path).inserted {
            cleanupCommittedSource(url)
        }
        cleanupCommittedSource(manifestURL)
        return recoveredURL
    }

    private func positionedComposition(
        inputs: [RecoverySegmentInput],
        sampleRate: Double,
        segmentFrames: Int64,
        minimumTimelineEndFrame: Int64
    ) async throws -> PositionedRecoveryComposition {
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
        var recoveredSegmentCount = 0
        for input in inputs {
            try Task.checkCancellation()
            guard input.index >= 0 else { continue }
            let asset = AVURLAsset(url: input.url)
            let tracks: [AVAssetTrack]
            let assetDuration: CMTime
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
                try Task.checkCancellation()
                assetDuration = try await asset.load(.duration)
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            guard
                tracks.count == 1,
                assetDuration.isValid,
                assetDuration.isNumeric,
                CMTimeCompare(assetDuration, .zero) > 0
            else {
                continue
            }
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
                recoveredSegmentCount += 1
            } catch {
                continue
            }
        }

        let minimumEnd = CMTime(
            value: minimumTimelineEndFrame,
            timescale: timescale
        )
        if recoveredSegmentCount > 0,
           CMTimeCompare(minimumEnd, composition.duration) > 0 {
            composition.insertEmptyTimeRange(CMTimeRange(
                start: composition.duration,
                duration: minimumEnd - composition.duration
            ))
        }
        return PositionedRecoveryComposition(
            composition: composition,
            recoveredSegmentCount: recoveredSegmentCount
        )
    }

    private func timelineFrame(
        index: Int64,
        segmentFrames: Int64,
        includeFullSlot: Bool
    ) throws -> Int64 {
        guard index >= 0 else {
            throw failure("A segmented recording contained a negative segment index.")
        }
        let slotValue: Int64
        if includeFullSlot {
            let slot = index.addingReportingOverflow(1)
            guard !slot.overflow else {
                throw failure("A segmented recording timeline exceeded its supported range.")
            }
            slotValue = slot.partialValue
        } else {
            slotValue = index
        }
        let result = slotValue.multipliedReportingOverflow(by: segmentFrames)
        guard !result.overflow else {
            throw failure("A segmented recording timeline exceeded its supported range.")
        }
        return result.partialValue
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
            try Task.checkCancellation()
            playable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            tracks = try await asset.loadTracks(withMediaType: .audio)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
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
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure("Could not inspect the exported audio format: \(error.localizedDescription)")
        }
        guard descriptions.contains(where: {
            CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
        }) else {
            throw failure("The exported audio track was not AAC.")
        }
    }

    private func commit(
        _ temporaryURL: URL,
        to outputURL: URL,
        claim: RecoveryClaim
    ) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw failure("The destination recording already exists and was not replaced.")
        }
        let prepared = try claim.prepareCommit(
            outputURL: outputURL,
            stagedURL: temporaryURL
        )
        if hooks.interruptAfterPendingPersisted?() == true {
            throw CommitInterruption.afterPending
        }
        try hooks.afterStagingVerifiedBeforeLink?(temporaryURL)
        let result = temporaryURL.path.withCString { temporaryPath in
            outputURL.path.withCString { outputPath in
                link(temporaryPath, outputPath)
            }
        }
        let linkError = errno
        let targetMatches = claim.targetMatches(prepared.marker)
        if result != 0, !targetMatches {
            let reason = String(cString: strerror(linkError))
            do {
                try claim.cancelPendingCommit(prepared.marker)
                try claim.cleanupTrustedStaging(
                    prepared.staging,
                    marker: prepared.marker,
                    afterVerification: hooks.afterStagingVerifiedBeforeCleanup
                )
            } catch {
                throw failure(
                    "Could not publish audio and could not roll back its bound pending target: \(reason)"
                )
            }
            throw failure("Could not publish audio without overwriting: \(reason)")
        }
        guard targetMatches else {
            // link(2) accepts a pathname, not the descriptor held above. A
            // replacement pathname may therefore have been linked. Preserve
            // the pending binding and working file; the wrong target cannot be
            // removed safely because its pathname is independently mutable.
            throw CommitInterruption.stagingIdentityChanged
        }
        if hooks.interruptAfterLink?() == true {
            throw CommitInterruption.afterLink
        }

        // The hard link above is the commit point. The pending inode marker was
        // persisted first and remains permanently bound to this target. Failure
        // to upgrade the marker leaves the conservative pending binding intact.
        do {
            try hooks.finalizedMarkerWrite?()
            try claim.markCommitComplete(prepared.marker)
        } catch {
            // There is no warning channel on this interface. The caller still
            // receives the committed URL; a later finalizer reads the pending
            // marker and refuses every different target.
        }
        try claim.cleanupTrustedStaging(
            prepared.staging,
            marker: prepared.marker,
            afterVerification: hooks.afterStagingVerifiedBeforeCleanup
        )
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

    private func cleanupCommittedSource(_ url: URL) {
        do {
            if let cleanupSource = hooks.cleanupSource {
                try cleanupSource(url)
                return
            }
            let result = url.path.withCString { unlink($0) }
            guard result == 0 || errno == ENOENT else {
                throw failure("Committed source cleanup failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            // Publication has committed. Cleanup failure is deliberately not
            // surfaced as finalization failure; the inode marker prevents reuse.
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

private struct PositionedRecoveryComposition {
    let composition: AVMutableComposition
    let recoveredSegmentCount: Int
}

private enum CommitInterruption: Error {
    case afterPending
    case afterLink
    case stagingIdentityChanged

    var message: String {
        switch self {
        case .afterPending:
            "Simulated process interruption after pending target persistence."
        case .afterLink:
            "Simulated process interruption after the publish commit point."
        case .stagingIdentityChanged:
            "The staged recovery path changed before publication; the pending target remains bound for manual recovery."
        }
    }
}

private struct InodeFinalizationMarker: Codable, Equatable {
    enum State: String, Codable {
        case pending
        case finalized
    }

    static let version = 2

    let version: Int
    let state: State
    let targetPath: String
    let stagedPath: String?
    let stagedDevice: UInt64
    let stagedInode: UInt64
}

private struct PreparedRecoveryCommit {
    let marker: InodeFinalizationMarker
    let staging: VerifiedStagingFile
}

private final class VerifiedStagingFile {
    let url: URL
    let descriptor: Int32
    let device: UInt64
    let inode: UInt64

    init(
        url: URL,
        expectedDevice: UInt64? = nil,
        expectedInode: UInt64? = nil
    ) throws {
        let standardizedURL = url.standardizedFileURL
        let descriptor = standardizedURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor != -1 else {
            throw RecoveryClaim.markerFailure(
                "Could not open the staged recovery output without following links."
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = close(descriptor)
            throw RecoveryClaim.markerFailure(
                "Could not inspect the staged recovery descriptor: \(reason)"
            )
        }
        let device = UInt64(status.st_dev)
        let inode = UInt64(status.st_ino)
        guard
            status.st_mode & S_IFMT == S_IFREG,
            expectedDevice.map({ $0 == device }) ?? true,
            expectedInode.map({ $0 == inode }) ?? true
        else {
            _ = close(descriptor)
            throw RecoveryClaim.markerFailure(
                "The staged recovery path no longer identifies the persisted inode."
            )
        }
        self.url = standardizedURL
        self.descriptor = descriptor
        self.device = device
        self.inode = inode
    }

    deinit {
        _ = close(descriptor)
    }
}

private final class RecoveryClaim: @unchecked Sendable {
    private static let markerName = "com.coohom.meeting-recorder.finalization"

    let canonicalWorkingURL: URL
    private let descriptor: Int32
    private let releaseLock = NSLock()
    private var released = false

    private init(descriptor: Int32, canonicalWorkingURL: URL) {
        self.descriptor = descriptor
        self.canonicalWorkingURL = canonicalWorkingURL
    }

    static func acquire(
        for workingURL: URL,
        onContention: (@Sendable () -> Void)?
    ) async throws -> RecoveryClaim {
        let canonicalURL = try canonicalURL(for: workingURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            try Task.checkCancellation()
            let descriptor = canonicalURL.path.withCString {
                open($0, O_RDONLY | O_NOFOLLOW)
            }
            guard descriptor != -1 else {
                throw claimFailure(errno)
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let errorCode = errno
                _ = close(descriptor)
                if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                    onContention?()
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                throw claimFailure(errorCode)
            }
            guard
                path(canonicalURL, matches: descriptor, followSymlink: false),
                path(workingURL, matches: descriptor, followSymlink: true)
            else {
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
                throw RecordingFailure(
                    code: .finalize,
                    message: "The working recording path changed while recovery ownership was acquired."
                )
            }
            return RecoveryClaim(
                descriptor: descriptor,
                canonicalWorkingURL: canonicalURL
            )
        }
        throw RecordingFailure(
            code: .finalize,
            message: "Timed out waiting for exclusive recovery ownership."
        )
    }

    func committedOutput(
        requestedURL: URL,
        afterStagingVerifiedBeforeLink: (@Sendable (URL) throws -> Void)?,
        afterStagingVerifiedBeforeCleanup: (@Sendable (URL) throws -> Void)?
    ) throws -> URL? {
        guard let marker = try readMarker() else { return nil }
        guard marker.version == 1 || marker.version == InodeFinalizationMarker.version else {
            throw Self.markerFailure("The working recording has an unsupported finalization marker.")
        }
        let targetURL = URL(fileURLWithPath: marker.targetPath)
        guard targetURL.standardizedFileURL == requestedURL.standardizedFileURL else {
            throw Self.markerFailure(
                "The working recording is permanently bound to a different recovery target."
            )
        }

        if targetMatches(marker) {
            if marker.state == .pending {
                do {
                    try markCommitComplete(marker)
                } catch {
                    // The target inode proves commit. Keep pending bound if the
                    // finalized marker cannot be persisted.
                }
            }
            try cleanupTrustedStaging(
                marker,
                targetURL: targetURL,
                afterVerification: afterStagingVerifiedBeforeCleanup
            )
            return targetURL
        }

        guard marker.state == .pending else {
            throw Self.markerFailure(
                "The finalized recording target is missing or was replaced; the working recording remains consumed."
            )
        }
        guard !Self.pathExists(targetURL) else {
            throw Self.markerFailure(
                "The bound recovery target was replaced by a different inode."
            )
        }
        guard let staging = trustedStagingFile(marker, targetURL: targetURL) else {
            throw Self.markerFailure(
                "The pending recovery has neither its bound target nor trusted staging; manual recovery is required."
            )
        }

        try afterStagingVerifiedBeforeLink?(staging.url)
        let result = staging.url.path.withCString { stagedPath in
            targetURL.path.withCString { targetPath in
                link(stagedPath, targetPath)
            }
        }
        let linkError = errno
        let publishedTargetMatches = targetMatches(marker)
        guard publishedTargetMatches else {
            throw Self.markerFailure(
                result == 0
                    ? "The staged recovery path changed while completing its bound target; the pending binding was preserved."
                    : "Could not complete the bound recovery target: \(String(cString: strerror(linkError)))"
            )
        }
        do {
            try markCommitComplete(marker)
        } catch {
            // The publish link is the commit point. Pending remains bound.
        }
        try cleanupTrustedStaging(
            staging,
            marker: marker,
            afterVerification: afterStagingVerifiedBeforeCleanup
        )
        return targetURL
    }

    func prepareCommit(
        outputURL: URL,
        stagedURL: URL
    ) throws -> PreparedRecoveryCommit {
        let staging = try VerifiedStagingFile(url: stagedURL)
        let marker = InodeFinalizationMarker(
            version: InodeFinalizationMarker.version,
            state: .pending,
            targetPath: outputURL.standardizedFileURL.path,
            stagedPath: staging.url.path,
            stagedDevice: staging.device,
            stagedInode: staging.inode
        )
        do {
            try writeMarker(marker)
        } catch {
            try? isolateAndCleanupStaging(staging, marker: marker, afterVerification: nil)
            throw error
        }
        return PreparedRecoveryCommit(marker: marker, staging: staging)
    }

    func cancelPendingCommit(_ marker: InodeFinalizationMarker) throws {
        guard try readMarker() == marker else { return }
        try clearMarker()
    }

    func markCommitComplete(_ marker: InodeFinalizationMarker) throws {
        try writeMarker(InodeFinalizationMarker(
            version: InodeFinalizationMarker.version,
            state: .finalized,
            targetPath: marker.targetPath,
            stagedPath: marker.stagedPath,
            stagedDevice: marker.stagedDevice,
            stagedInode: marker.stagedInode
        ))
    }

    func targetMatches(_ marker: InodeFinalizationMarker) -> Bool {
        (try? VerifiedStagingFile(
            url: URL(fileURLWithPath: marker.targetPath),
            expectedDevice: marker.stagedDevice,
            expectedInode: marker.stagedInode
        )) != nil
    }

    private func trustedStagingFile(
        _ marker: InodeFinalizationMarker,
        targetURL: URL
    ) -> VerifiedStagingFile? {
        guard let stagedPath = marker.stagedPath else { return nil }
        let stagedURL = URL(fileURLWithPath: stagedPath).standardizedFileURL
        let standardizedTarget = targetURL.standardizedFileURL
        guard
            stagedURL != standardizedTarget,
            stagedURL.deletingLastPathComponent()
                == standardizedTarget.deletingLastPathComponent(),
            stagedURL.lastPathComponent.hasPrefix(
                ".\(standardizedTarget.lastPathComponent)."
            ),
            stagedURL.lastPathComponent.hasSuffix(".tmp.m4a")
        else {
            return nil
        }
        return try? VerifiedStagingFile(
            url: stagedURL,
            expectedDevice: marker.stagedDevice,
            expectedInode: marker.stagedInode
        )
    }

    private func cleanupTrustedStaging(
        _ marker: InodeFinalizationMarker,
        targetURL: URL,
        afterVerification: (@Sendable (URL) throws -> Void)?
    ) throws {
        guard let staging = trustedStagingFile(marker, targetURL: targetURL) else {
            return
        }
        try cleanupTrustedStaging(
            staging,
            marker: marker,
            afterVerification: afterVerification
        )
    }

    func cleanupTrustedStaging(
        _ staging: VerifiedStagingFile,
        marker: InodeFinalizationMarker,
        afterVerification: (@Sendable (URL) throws -> Void)?
    ) throws {
        guard staging.device == marker.stagedDevice,
              staging.inode == marker.stagedInode else {
            throw Self.markerFailure(
                "The staged recovery descriptor did not match its persisted inode."
            )
        }
        try isolateAndCleanupStaging(
            staging,
            marker: marker,
            afterVerification: afterVerification
        )
    }

    private func isolateAndCleanupStaging(
        _ staging: VerifiedStagingFile,
        marker: InodeFinalizationMarker,
        afterVerification: (@Sendable (URL) throws -> Void)?
    ) throws {
        try afterVerification?(staging.url)
        let quarantineURL = staging.url.deletingLastPathComponent()
            .appendingPathComponent(
                ".meeting-recorder-owned-cleanup-\(UUID().uuidString).tmp"
            )
        let isolateResult = staging.url.path.withCString { stagedPath in
            quarantineURL.path.withCString { quarantinePath in
                renamex_np(stagedPath, quarantinePath, UInt32(RENAME_EXCL))
            }
        }
        guard isolateResult == 0 else {
            if errno == ENOENT { return }
            throw Self.markerFailure(
                "Could not isolate staged recovery cleanup: \(String(cString: strerror(errno)))"
            )
        }

        let isolated: VerifiedStagingFile
        do {
            isolated = try VerifiedStagingFile(
                url: quarantineURL,
                expectedDevice: marker.stagedDevice,
                expectedInode: marker.stagedInode
            )
        } catch {
            let restoreResult = quarantineURL.path.withCString { quarantinePath in
                staging.url.path.withCString { stagedPath in
                    renamex_np(quarantinePath, stagedPath, UInt32(RENAME_EXCL))
                }
            }
            guard restoreResult == 0 else {
                throw Self.markerFailure(
                    "A replacement staging file was preserved at \(quarantineURL.path); it could not be restored safely."
                )
            }
            return
        }

        // The public staging pathname is no longer used. Only this process
        // knows the fresh, exclusive quarantine name, and its descriptor was
        // verified above before the private path is removed.
        let unlinkResult = withExtendedLifetime(isolated) {
            quarantineURL.path.withCString { unlink($0) }
        }
        guard unlinkResult == 0 || errno == ENOENT else {
            // Keep the verified inode at its private quarantine name so a
            // retry or manual recovery can inspect it without risking an
            // unrelated file at the original staging pathname.
            throw Self.markerFailure(
                "Could not remove verified staging isolated at \(quarantineURL.path)."
            )
        }
    }

    func release() {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private func readMarker() throws -> InodeFinalizationMarker? {
        let size = Self.markerName.withCString {
            fgetxattr(descriptor, $0, nil, 0, 0, 0)
        }
        if size == -1 {
            if errno == ENOATTR { return nil }
            throw Self.markerFailure("Could not read the working recording finalization marker.")
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            Self.markerName.withCString {
                fgetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        guard read == size else {
            throw Self.markerFailure("Could not read a complete finalization marker.")
        }
        do {
            return try JSONDecoder().decode(InodeFinalizationMarker.self, from: data)
        } catch {
            throw Self.markerFailure("The working recording finalization marker was invalid.")
        }
    }

    private func writeMarker(_ marker: InodeFinalizationMarker) throws {
        let data = try JSONEncoder().encode(marker)
        let result = data.withUnsafeBytes { bytes in
            Self.markerName.withCString {
                fsetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        guard result == 0, fsync(descriptor) == 0 else {
            throw Self.markerFailure("Could not persist the working recording finalization marker.")
        }
    }

    private func clearMarker() throws {
        let result = Self.markerName.withCString {
            fremovexattr(descriptor, $0, 0)
        }
        guard result == 0 || errno == ENOATTR else {
            throw Self.markerFailure("Could not clear a stale finalization marker.")
        }
        guard fsync(descriptor) == 0 else {
            throw Self.markerFailure("Could not persist finalization marker cleanup.")
        }
    }

    private static func canonicalURL(for url: URL) throws -> URL {
        let resolved = url.path.withCString { realpath($0, nil) }
        guard let resolved else { throw claimFailure(errno) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private static func path(
        _ url: URL,
        matches descriptor: Int32,
        followSymlink: Bool
    ) -> Bool {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else { return false }
        var pathStatus = stat()
        let result = url.path.withCString {
            followSymlink ? stat($0, &pathStatus) : lstat($0, &pathStatus)
        }
        guard result == 0 else { return false }
        return descriptorStatus.st_dev == pathStatus.st_dev
            && descriptorStatus.st_ino == pathStatus.st_ino
    }

    private static func pathExists(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString { lstat($0, &status) } == 0
    }

    private static func claimFailure(_ errorCode: Int32) -> RecordingFailure {
        RecordingFailure(
            code: .finalize,
            message: "Could not claim the working recording inode: \(String(cString: strerror(errorCode)))"
        )
    }

    fileprivate static func markerFailure(_ message: String) -> RecordingFailure {
        RecordingFailure(code: .finalize, message: message)
    }
}
