import Darwin
import Foundation

struct SegmentedM4AWriterHooks: Sendable {
    let beforeSegmentAppend: (@Sendable () async throws -> Void)?
    let afterRecoveryCommitted: (@Sendable () async throws -> Void)?

    init(
        beforeSegmentAppend: (@Sendable () async throws -> Void)? = nil,
        afterRecoveryCommitted: (@Sendable () async throws -> Void)? = nil
    ) {
        self.beforeSegmentAppend = beforeSegmentAppend
        self.afterRecoveryCommitted = afterRecoveryCommitted
    }
}

struct SegmentedRecordingSegment: Codable, Equatable, Sendable {
    let index: Int64
    let finalFileName: String
}

struct SegmentedRecordingCurrent: Codable, Equatable, Sendable {
    let index: Int64
    let workingFileName: String
    let finalFileName: String
}

struct SegmentedRecordingManifest: Codable, Equatable, Sendable {
    static let format = "meeting-recorder-segmented-m4a-v1"

    let format: String
    let sampleRate: Double
    let channels: Int
    let segmentFrames: Int64
    var completed: [SegmentedRecordingSegment]
    var current: SegmentedRecordingCurrent?
}

public actor SegmentedM4AWriter: RecoverableAudioWriting {
    private enum State {
        case idle
        case running(SegmentedSession)
        case operating(SegmentedSession, UUID, URL?)
        case aborting(SegmentedSession, UUID)
        case finished(URL)
        case failed(SegmentedSession?)
        case aborted
    }

    private struct InFlightOperation: Sendable {
        let token: UUID
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private let workingURL: URL
    private let sampleRate: Double
    private let channels: Int
    private let segmentFrames: Int64
    private let hooks: SegmentedM4AWriterHooks
    private var state: State = .idle
    private var inFlight: InFlightOperation?
    private var abortTask: Task<Void, Never>?

    public init(workingURL: URL) {
        self.init(
            workingURL: workingURL,
            sampleRate: 48_000,
            channels: 2,
            segmentFrames: 480_000,
            hooks: SegmentedM4AWriterHooks()
        )
    }

    init(
        workingURL: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        segmentFrames: Int64,
        hooks: SegmentedM4AWriterHooks = SegmentedM4AWriterHooks()
    ) {
        self.workingURL = workingURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.segmentFrames = segmentFrames
        self.hooks = hooks
    }

    public func start() async throws {
        guard case .idle = state else {
            throw writeFailure("The segmented writer can only be started once.")
        }
        guard segmentFrames > 0, sampleRate > 0, channels == 2 else {
            state = .failed(nil)
            throw writeFailure("The segmented writer configuration is invalid.")
        }
        let manifest = SegmentedRecordingManifest(
            format: SegmentedRecordingManifest.format,
            sampleRate: sampleRate,
            channels: channels,
            segmentFrames: segmentFrames,
            completed: [],
            current: nil
        )
        do {
            try SegmentedManifestIO.create(manifest, at: workingURL)
            state = .running(SegmentedSession(manifest: manifest))
        } catch let failure as RecordingFailure {
            state = .failed(nil)
            throw failure
        } catch {
            state = .failed(nil)
            throw writeFailure("Could not create the segmented manifest: \(error.localizedDescription)")
        }
    }

    public func append(_ chunk: MixedAudioChunk) async throws {
        guard case let .running(session) = state else {
            throw writeFailure("Segmented audio cannot be appended in the current state.")
        }
        guard
            chunk.startFrame >= 0,
            chunk.frameCount > 0,
            chunk.samples.count == chunk.frameCount * channels
        else {
            state = .failed(session)
            throw writeFailure("The mixed audio chunk has an invalid frame or sample count.")
        }
        if let lastEndFrame = session.lastEndFrame,
           chunk.startFrame < lastEndFrame {
            state = .failed(session)
            throw writeFailure("The mixed audio timestamp moved backwards or overlapped prior audio.")
        }

        let token = UUID()
        let workingURL = self.workingURL
        let sampleRate = self.sampleRate
        let channels = self.channels
        let segmentFrames = self.segmentFrames
        let hooks = self.hooks
        let operationTask = Task {
            try await Self.performAppend(
                chunk,
                session: session,
                workingURL: workingURL,
                sampleRate: sampleRate,
                channels: channels,
                segmentFrames: segmentFrames,
                hooks: hooks
            )
        }
        state = .operating(session, token, nil)
        inFlight = InFlightOperation(
            token: token,
            cancel: { operationTask.cancel() },
            wait: { _ = await operationTask.result }
        )

        do {
            try await withTaskCancellationHandler {
                try await operationTask.value
            } onCancel: {
                operationTask.cancel()
            }
            guard ownsOperation(token) else {
                throw writeFailure("Segmented append completed after another operation took ownership.")
            }
            inFlight = nil
            state = .running(session)
        } catch let failure as RecordingFailure {
            guard ownsOperation(token) else { throw failure }
            inFlight = nil
            state = .failed(session)
            throw failure
        } catch {
            guard ownsOperation(token) else {
                throw writeFailure("Segmented append was cancelled because the writer was aborted.")
            }
            inFlight = nil
            state = .failed(session)
            if error is CancellationError {
                throw writeFailure("Segmented append was cancelled before completion.")
            }
            throw writeFailure("Could not append segmented audio: \(error.localizedDescription)")
        }
    }

    public func finish(finalURL: URL) async throws -> URL {
        guard case let .running(session) = state else {
            throw writeFailure("The segmented writer is not in a finishable state.")
        }
        let token = UUID()
        let workingURL = self.workingURL
        let hooks = self.hooks
        let operationTask = Task {
            try await Self.closeCurrentSegment(
                session: session,
                manifestURL: workingURL
            )
            try Task.checkCancellation()
            let output = try await M4AFinalizer().recover(
                workingURL: workingURL,
                recoveredURL: finalURL
            )
            session.markCommitted(output)
            try await hooks.afterRecoveryCommitted?()
            try Task.checkCancellation()
            return output
        }
        state = .operating(session, token, finalURL)
        inFlight = InFlightOperation(
            token: token,
            cancel: { operationTask.cancel() },
            wait: { _ = await operationTask.result }
        )

        do {
            let output = try await withTaskCancellationHandler {
                try await operationTask.value
            } onCancel: {
                operationTask.cancel()
            }
            guard ownsOperation(token) else {
                if let committed = session.committedURL { return committed }
                throw writeFailure("Segmented finish completed after another operation took ownership.")
            }
            inFlight = nil
            state = .finished(output)
            return output
        } catch let failure as RecordingFailure {
            if let committed = session.committedURL {
                if ownsOperation(token) {
                    inFlight = nil
                    state = .finished(committed)
                }
                return committed
            }
            guard ownsOperation(token) else { throw failure }
            inFlight = nil
            state = .failed(session)
            throw failure
        } catch {
            if let committed = session.committedURL {
                if ownsOperation(token) {
                    inFlight = nil
                    state = .finished(committed)
                }
                return committed
            }
            guard ownsOperation(token) else {
                throw writeFailure("Segmented finish was cancelled because the writer was aborted.")
            }
            inFlight = nil
            state = .failed(session)
            if error is CancellationError {
                throw writeFailure("Segmented finish was cancelled before publishing the recording.")
            }
            throw RecordingFailure(
                code: .finalize,
                message: "Could not finalize segmented audio: \(error.localizedDescription)"
            )
        }
    }

    public func abort() async {
        if let abortTask {
            await abortTask.value
            return
        }

        let session: SegmentedSession
        switch state {
        case .idle:
            state = .aborted
            return
        case let .running(current):
            session = current
        case let .operating(current, _, _):
            session = current
        case let .failed(current?):
            session = current
        case .failed(nil), .aborted:
            state = .aborted
            return
        case .finished:
            return
        case .aborting:
            return
        }

        let token = UUID()
        let operation = inFlight
        operation?.cancel()
        let task = Task {
            await operation?.wait()
            if session.committedURL == nil {
                await session.currentSegment?.writer.abort()
            }
        }
        abortTask = task
        state = .aborting(session, token)
        await task.value

        guard ownsAbort(token) else { return }
        inFlight = nil
        abortTask = nil
        if let committedURL = session.committedURL {
            state = .finished(committedURL)
        } else {
            state = .aborted
        }
    }

    private func ownsOperation(_ token: UUID) -> Bool {
        guard case let .operating(_, current, _) = state else { return false }
        return current == token && inFlight?.token == token
    }

    private func ownsAbort(_ token: UUID) -> Bool {
        guard case let .aborting(_, current) = state else { return false }
        return current == token
    }

    private static func performAppend(
        _ chunk: MixedAudioChunk,
        session: SegmentedSession,
        workingURL: URL,
        sampleRate: Double,
        channels: Int,
        segmentFrames: Int64,
        hooks: SegmentedM4AWriterHooks
    ) async throws {
        var sourceOffset = 0
        while sourceOffset < chunk.frameCount {
            try Task.checkCancellation()
            let globalStart = chunk.startFrame + Int64(sourceOffset)
            let segmentIndex = globalStart / segmentFrames
            if session.currentSegment?.index != segmentIndex {
                try await closeCurrentSegment(
                    session: session,
                    manifestURL: workingURL
                )
                try Task.checkCancellation()
                session.currentSegment = try await startSegment(
                    index: segmentIndex,
                    session: session,
                    manifestURL: workingURL,
                    sampleRate: sampleRate,
                    channels: channels
                )
            }
            guard let currentSegment = session.currentSegment else {
                throw RecordingFailure(code: .write, message: "Could not create the current audio segment.")
            }
            let segmentEnd = (segmentIndex + 1) * segmentFrames
            let frameCount = min(
                chunk.frameCount - sourceOffset,
                Int(segmentEnd - globalStart)
            )
            let sampleStart = sourceOffset * channels
            let sampleEnd = sampleStart + frameCount * channels
            let relativeChunk = MixedAudioChunk(
                startFrame: globalStart - segmentIndex * segmentFrames,
                frameCount: frameCount,
                samples: Array(chunk.samples[sampleStart..<sampleEnd])
            )
            try await hooks.beforeSegmentAppend?()
            try Task.checkCancellation()
            try await currentSegment.writer.append(relativeChunk)
            try Task.checkCancellation()
            sourceOffset += frameCount
        }
        session.lastEndFrame = chunk.startFrame + Int64(chunk.frameCount)
    }

    private static func startSegment(
        index: Int64,
        session: SegmentedSession,
        manifestURL: URL,
        sampleRate: Double,
        channels: Int
    ) async throws -> SegmentedSession.Segment {
        let prefix = String(format: "%06lld", index)
        let base = manifestURL.lastPathComponent
        let workingFileName = ".\(base).segment-\(prefix).inprogress.mov"
        let finalFileName = ".\(base).segment-\(prefix).m4a"
        let directory = manifestURL.deletingLastPathComponent()
        let current = SegmentedRecordingCurrent(
            index: index,
            workingFileName: workingFileName,
            finalFileName: finalFileName
        )
        session.manifest.current = current
        try SegmentedManifestIO.replace(session.manifest, at: manifestURL)
        try Task.checkCancellation()

        let writer = FragmentedMOVWriter(
            workingURL: directory.appendingPathComponent(workingFileName),
            sampleRate: sampleRate,
            channels: channels
        )
        do {
            try await writer.start()
            try Task.checkCancellation()
            return SegmentedSession.Segment(
                index: index,
                writer: writer,
                finalURL: directory.appendingPathComponent(finalFileName)
            )
        } catch {
            await writer.abort()
            throw error
        }
    }

    private static func closeCurrentSegment(
        session: SegmentedSession,
        manifestURL: URL
    ) async throws {
        guard let segment = session.currentSegment else { return }
        let output = try await segment.writer.finish(finalURL: segment.finalURL)
        try Task.checkCancellation()
        let entry = SegmentedRecordingSegment(
            index: segment.index,
            finalFileName: output.lastPathComponent
        )
        if !session.manifest.completed.contains(where: { $0.index == entry.index }) {
            session.manifest.completed.append(entry)
            session.manifest.completed.sort { $0.index < $1.index }
        }
        session.manifest.current = nil
        try SegmentedManifestIO.replace(session.manifest, at: manifestURL)
        session.currentSegment = nil
    }

    private func writeFailure(_ message: String) -> RecordingFailure {
        RecordingFailure(code: .write, message: message)
    }
}

private final class SegmentedSession: @unchecked Sendable {
    struct Segment: Sendable {
        let index: Int64
        let writer: FragmentedMOVWriter
        let finalURL: URL
    }

    var manifest: SegmentedRecordingManifest
    var currentSegment: Segment?
    var lastEndFrame: Int64?
    private let committedLock = NSLock()
    private var committedOutput: URL?

    var committedURL: URL? {
        committedLock.withLock { committedOutput }
    }

    init(manifest: SegmentedRecordingManifest) {
        self.manifest = manifest
    }

    func markCommitted(_ url: URL) {
        committedLock.withLock {
            committedOutput = url
        }
    }
}

enum SegmentedManifestIO {
    static func load(from url: URL) throws -> SegmentedRecordingManifest? {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return nil
        }
        guard let manifest = try? JSONDecoder().decode(
            SegmentedRecordingManifest.self,
            from: data
        ), manifest.format == SegmentedRecordingManifest.format else {
            return nil
        }
        return manifest
    }

    static func create(
        _ manifest: SegmentedRecordingManifest,
        at url: URL
    ) throws {
        let temporary = try writeTemporary(manifest, near: url)
        defer { _ = temporary.path.withCString { unlink($0) } }
        let result = temporary.path.withCString { temporaryPath in
            url.path.withCString { destinationPath in
                link(temporaryPath, destinationPath)
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            throw RecordingFailure(
                code: .write,
                message: "Could not create the segmented manifest without overwriting: \(reason)"
            )
        }
    }

    static func replace(
        _ manifest: SegmentedRecordingManifest,
        at url: URL
    ) throws {
        let temporary = try writeTemporary(manifest, near: url)
        let result = temporary.path.withCString { temporaryPath in
            url.path.withCString { destinationPath in
                rename(temporaryPath, destinationPath)
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            _ = temporary.path.withCString { unlink($0) }
            throw RecordingFailure(
                code: .write,
                message: "Could not atomically update the segmented manifest: \(reason)"
            )
        }
    }

    private static func writeTemporary(
        _ manifest: SegmentedRecordingManifest,
        near url: URL
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).manifest.tmp"
        )
        let descriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor != -1 else {
            let reason = String(cString: strerror(errno))
            throw RecordingFailure(code: .write, message: "Could not create manifest staging: \(reason)")
        }
        var succeeded = false
        defer {
            _ = close(descriptor)
            if !succeeded {
                _ = temporary.path.withCString { unlink($0) }
            }
        }
        let writeSucceeded = data.withUnsafeBytes { bytes -> Bool in
            guard var pointer = bytes.baseAddress else { return data.isEmpty }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
        guard writeSucceeded, fsync(descriptor) == 0 else {
            let reason = String(cString: strerror(errno))
            throw RecordingFailure(code: .write, message: "Could not persist manifest staging: \(reason)")
        }
        succeeded = true
        return temporary
    }
}
