import Darwin
import Foundation

public struct RecordingPaths: Equatable, Sendable {
    public let startedAt: Date
    public let directoryURL: URL
    public let workingURL: URL
    public let finalURL: URL
    public let recoveredURL: URL

    public init(
        startedAt: Date,
        directoryURL: URL,
        workingURL: URL,
        finalURL: URL,
        recoveredURL: URL
    ) {
        self.startedAt = startedAt
        self.directoryURL = directoryURL
        self.workingURL = workingURL
        self.finalURL = finalURL
        self.recoveredURL = recoveredURL
    }
}

public actor RecordingStore {
    public static let minimumFreeBytes: Int64 = 1_000_000_000

    private let root: URL
    private let timeZone: TimeZone
    private let availableCapacity: @Sendable () -> Int64
    private let reservationPublishedHook: (@Sendable () -> Void)?
    private var reservationDescriptors: [URL: Int32] = [:]

    public init(
        root: URL = AppMetadata.defaultRecordingRoot,
        timeZone: TimeZone = .current,
        availableCapacity: (@Sendable () -> Int64)? = nil
    ) {
        self.root = root
        self.timeZone = timeZone
        self.reservationPublishedHook = nil
        if let availableCapacity {
            self.availableCapacity = availableCapacity
        } else {
            self.availableCapacity = { @Sendable [root] in
                Self.systemAvailableCapacity(for: root)
            }
        }
    }

    init(
        root: URL,
        timeZone: TimeZone,
        availableCapacity: @escaping @Sendable () -> Int64,
        reservationPublishedHook: @escaping @Sendable () -> Void
    ) {
        self.root = root
        self.timeZone = timeZone
        self.availableCapacity = availableCapacity
        self.reservationPublishedHook = reservationPublishedHook
    }

    deinit {
        for descriptor in reservationDescriptors.values {
            _ = close(descriptor)
        }
    }

    public func prepare(startedAt: Date) throws -> RecordingPaths {
        guard availableCapacity() >= Self.minimumFreeBytes else {
            throw RecordingFailure(code: .storage, message: "可用空间不足 1 GB，未开始录音。")
        }

        let folder = format(startedAt, pattern: "yyyy-MM-dd")
        let stamp = format(startedAt, pattern: "yyyy-MM-dd-HH-mm-ss")
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordingFailure(code: .write, message: "无法创建录音目录：\(error.localizedDescription)")
        }

        let (finalURL, workingURL) = try uniqueRecordingURLs(
            directory: directory,
            base: "会议录音-\(stamp)"
        )
        let base = finalURL.deletingPathExtension().lastPathComponent
        return RecordingPaths(
            startedAt: startedAt,
            directoryURL: directory,
            workingURL: workingURL,
            finalURL: finalURL,
            recoveredURL: directory.appendingPathComponent("\(base)-未完整恢复.m4a")
        )
    }

    public func listInterruptedRecordings() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var interrupted: [URL] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else {
                continue
            }
            guard (try? workingFileBase(for: fileURL)) != nil else {
                continue
            }
            interrupted.append(fileURL)
        }

        return interrupted.sorted { $0.path < $1.path }
    }

    public func recoveredURL(for workingURL: URL) throws -> URL {
        let base = try workingFileBase(for: workingURL)
        return try uniqueURL(
            directory: workingURL.deletingLastPathComponent(),
            base: "\(base)-未完整恢复",
            pathExtension: "m4a"
        )
    }

    /// Call after the writer has created its working file, or when preparation is cancelled.
    public func releaseReservation(for outputURL: URL) {
        guard let descriptor = reservationDescriptors.removeValue(forKey: outputURL) else {
            return
        }
        removeReservationIfOwned(reservationURL(for: outputURL), descriptor: descriptor)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func uniqueURL(directory: URL, base: String, pathExtension: String) throws -> URL {
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let candidate = directory
                .appendingPathComponent(name)
                .appendingPathExtension(pathExtension)
            guard !FileManager.default.fileExists(atPath: candidate.path) else {
                suffix += 1
                continue
            }

            switch try reserve(candidate) {
            case .reserved:
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                releaseReservation(for: candidate)
                suffix += 1
            case .reclaimed:
                continue
            case .occupied:
                suffix += 1
            }
        }
    }

    private func uniqueRecordingURLs(directory: URL, base: String) throws -> (finalURL: URL, workingURL: URL) {
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let finalURL = directory.appendingPathComponent(name).appendingPathExtension("m4a")
            let workingURL = directory.appendingPathComponent(".\(name).inprogress.mov")
            guard
                !FileManager.default.fileExists(atPath: finalURL.path),
                !FileManager.default.fileExists(atPath: workingURL.path)
            else {
                suffix += 1
                continue
            }

            switch try reserve(finalURL) {
            case .reserved:
                if
                    !FileManager.default.fileExists(atPath: finalURL.path),
                    !FileManager.default.fileExists(atPath: workingURL.path)
                {
                    return (finalURL, workingURL)
                }
                releaseReservation(for: finalURL)
                suffix += 1
            case .reclaimed:
                continue
            case .occupied:
                suffix += 1
            }
        }
    }

    private enum ReservationResult {
        case reserved
        case occupied
        case reclaimed
    }

    private func reserve(_ outputURL: URL) throws -> ReservationResult {
        let reservationURL = reservationURL(for: outputURL)
        let (temporaryURL, descriptor) = try createTemporaryReservation(near: reservationURL)

        guard flock(descriptor, LOCK_EX) == 0 else {
            let errorCode = errno
            removeFile(at: temporaryURL)
            _ = close(descriptor)
            throw reservationFailure(errorCode)
        }

        let linkResult = temporaryURL.path.withCString { temporaryPath in
            reservationURL.path.withCString { reservationPath in
                link(temporaryPath, reservationPath)
            }
        }
        if linkResult == 0 {
            reservationDescriptors[outputURL] = descriptor
            reservationPublishedHook?()
            guard removeFile(at: temporaryURL) else {
                releaseReservation(for: outputURL)
                throw RecordingFailure(code: .write, message: "无法完成录音文件预留。")
            }
            return .reserved
        }

        let errorCode = errno
        removeFile(at: temporaryURL)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        guard errorCode == EEXIST else {
            throw reservationFailure(errorCode)
        }
        return try reclaimIfStale(reservationURL)
    }

    private func reclaimIfStale(_ reservationURL: URL) throws -> ReservationResult {
        let descriptor = reservationURL.path.withCString { open($0, O_RDWR | O_NOFOLLOW) }
        guard descriptor != -1 else {
            let errorCode = errno
            if errorCode == ENOENT {
                return .reclaimed
            }
            throw reservationFailure(errorCode)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorCode = errno
            _ = close(descriptor)
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                return .occupied
            }
            throw reservationFailure(errorCode)
        }

        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        guard reservationMatchesDescriptor(reservationURL, descriptor: descriptor) else {
            return .reclaimed
        }
        guard removeFile(at: reservationURL) else {
            throw RecordingFailure(code: .write, message: "无法清理过期预留。")
        }
        return .reclaimed
    }

    private func reservationFailure(_ errorCode: Int32) -> RecordingFailure {
        let reason = String(cString: strerror(errorCode))
        return RecordingFailure(code: .write, message: "无法预留录音文件：\(reason)")
    }

    private func reservationURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().lastPathComponent
        return outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(base).reservation")
    }

    private func createTemporaryReservation(near reservationURL: URL) throws -> (URL, Int32) {
        for _ in 0..<10 {
            let candidate = reservationURL.deletingLastPathComponent().appendingPathComponent(
                "\(reservationURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
            let descriptor = candidate.path.withCString {
                open($0, O_RDWR | O_CREAT | O_EXCL, 0o600)
            }
            if descriptor != -1 {
                return (candidate, descriptor)
            }
            if errno != EEXIST {
                throw reservationFailure(errno)
            }
        }
        throw RecordingFailure(code: .write, message: "无法创建录音文件预留。")
    }

    private func removeReservationIfOwned(_ reservationURL: URL, descriptor: Int32) {
        guard reservationMatchesDescriptor(reservationURL, descriptor: descriptor) else {
            return
        }
        _ = removeFile(at: reservationURL)
    }

    private func reservationMatchesDescriptor(_ reservationURL: URL, descriptor: Int32) -> Bool {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            return false
        }
        var pathStatus = stat()
        let result = reservationURL.path.withCString { lstat($0, &pathStatus) }
        guard result == 0 else {
            return false
        }
        return descriptorStatus.st_dev == pathStatus.st_dev && descriptorStatus.st_ino == pathStatus.st_ino
    }

    @discardableResult
    private func removeFile(at url: URL) -> Bool {
        url.path.withCString { unlink($0) == 0 }
    }

    private func workingFileBase(for workingURL: URL) throws -> String {
        guard isWithinRoot(workingURL) else {
            throw RecordingFailure(code: .write, message: "中断录音文件不在录音目录中。")
        }

        let name = workingURL.lastPathComponent
        let range = NSRange(name.startIndex..., in: name)
        let expression = try! NSRegularExpression(
            pattern: "^\\.会议录音-([0-9]{4}-[0-9]{2}-[0-9]{2})-(?:[01][0-9]|2[0-3])-(?:[0-5][0-9])-(?:[0-5][0-9])(?:-([1-9][0-9]*))?\\.inprogress\\.mov$"
        )
        guard let match = expression.firstMatch(in: name, range: range), match.range == range else {
            throw RecordingFailure(code: .write, message: "中断录音文件名或日期目录无效。")
        }

        let dateDirectoryName = (name as NSString).substring(with: match.range(at: 1))
        let directory = workingURL.deletingLastPathComponent()
        guard
            directory.lastPathComponent == dateDirectoryName,
            isValidDateDirectoryName(dateDirectoryName),
            isDirectChildOfRoot(directory)
        else {
            throw RecordingFailure(code: .write, message: "中断录音文件名或日期目录无效。")
        }

        return String(name.dropFirst().dropLast(".inprogress.mov".count))
    }

    private func isValidDateDirectoryName(_ name: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: name) else {
            return false
        }
        return formatter.string(from: date) == name
    }

    private func isWithinRoot(_ url: URL) -> Bool {
        let rootPath = normalizedPath(for: root)
        let candidatePath = normalizedPath(for: url)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        return candidatePath.hasPrefix(rootPrefix)
    }

    private func isDirectChildOfRoot(_ url: URL) -> Bool {
        normalizedPath(for: url.deletingLastPathComponent()) == normalizedPath(for: root)
    }

    private func normalizedPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private nonisolated static func systemAvailableCapacity(for root: URL) -> Int64 {
        var existingURL = root
        while !FileManager.default.fileExists(atPath: existingURL.path) {
            let parent = existingURL.deletingLastPathComponent()
            guard parent.path != existingURL.path else {
                return 0
            }
            existingURL = parent
        }

        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: existingURL.path) else {
            return 0
        }
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
