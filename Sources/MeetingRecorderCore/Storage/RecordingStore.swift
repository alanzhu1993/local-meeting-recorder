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
    private var reservedURLs: Set<URL> = []

    public init(
        root: URL = AppMetadata.defaultRecordingRoot,
        timeZone: TimeZone = .current,
        availableCapacity: (@Sendable () -> Int64)? = nil
    ) {
        self.root = root
        self.timeZone = timeZone
        if let availableCapacity {
            self.availableCapacity = availableCapacity
        } else {
            self.availableCapacity = { @Sendable [root] in
                Self.systemAvailableCapacity(for: root)
            }
        }
    }

    public func prepare(startedAt: Date) throws -> RecordingPaths {
        guard availableCapacity() >= Self.minimumFreeBytes else {
            throw RecordingFailure(code: .storage, message: "可用空间不足 1 GB，未开始录音。")
        }

        let folder = format(startedAt, pattern: "yyyy-MM-dd")
        let stamp = format(startedAt, pattern: "yyyy-MM-dd-HH-mm-ss")
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let (finalURL, workingURL) = uniqueRecordingURLs(
            directory: directory,
            base: "会议录音-\(stamp)"
        )
        reservedURLs.insert(finalURL)
        reservedURLs.insert(workingURL)
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
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".inprogress.mov") else {
                continue
            }
            interrupted.append(fileURL)
        }

        return interrupted.sorted { $0.path < $1.path }
    }

    public func recoveredURL(for workingURL: URL) throws -> URL {
        guard isWithinRoot(workingURL) else {
            throw RecordingFailure(code: .write, message: "中断录音文件不在录音目录中。")
        }

        var base = workingURL.lastPathComponent
        guard base.hasPrefix("."), base.hasSuffix(".inprogress.mov") else {
            throw RecordingFailure(code: .write, message: "中断录音文件名无效。")
        }
        base.removeFirst()
        base.removeLast(".inprogress.mov".count)
        guard !base.isEmpty else {
            throw RecordingFailure(code: .write, message: "中断录音文件名无效。")
        }

        let recoveredURL = uniqueURL(
            directory: workingURL.deletingLastPathComponent(),
            base: "\(base)-未完整恢复",
            pathExtension: "m4a"
        )
        reservedURLs.insert(recoveredURL)
        return recoveredURL
    }

    private func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func uniqueURL(directory: URL, base: String, pathExtension: String) -> URL {
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let candidate = directory
                .appendingPathComponent(name)
                .appendingPathExtension(pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path), !reservedURLs.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private func uniqueRecordingURLs(directory: URL, base: String) -> (finalURL: URL, workingURL: URL) {
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let finalURL = directory.appendingPathComponent(name).appendingPathExtension("m4a")
            let workingURL = directory.appendingPathComponent(".\(name).inprogress.mov")
            if
                !FileManager.default.fileExists(atPath: finalURL.path),
                !FileManager.default.fileExists(atPath: workingURL.path),
                !reservedURLs.contains(finalURL),
                !reservedURLs.contains(workingURL)
            {
                return (finalURL, workingURL)
            }
            suffix += 1
        }
    }

    private func isWithinRoot(_ url: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        return candidatePath.hasPrefix(rootPrefix)
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
