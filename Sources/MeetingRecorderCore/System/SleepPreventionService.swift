import Foundation

public protocol SleepPreventing: Sendable {
    func begin()
    func end()
}

public struct SleepActivityToken: @unchecked Sendable {
    fileprivate let storage: AnyObject?

    public init() {
        storage = nil
    }

    fileprivate init(storage: AnyObject) {
        self.storage = storage
    }
}

public protocol SleepActivityBacking: Sendable {
    func beginActivity() -> SleepActivityToken
    func endActivity(_ token: SleepActivityToken)
}

public final class SleepPreventionService: SleepPreventing, @unchecked Sendable {
    private let backend: any SleepActivityBacking
    private let lock = NSLock()
    private var activity: SleepActivityToken?

    public init() {
        backend = ProcessSleepActivityBackend()
    }

    public init(backend: any SleepActivityBacking) {
        self.backend = backend
    }

    deinit {
        end()
    }

    public func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard activity == nil else { return }
        activity = backend.beginActivity()
    }

    public func end() {
        lock.lock()
        let currentActivity = activity
        activity = nil
        lock.unlock()
        if let currentActivity {
            backend.endActivity(currentActivity)
        }
    }
}

private final class ProcessSleepActivityBackend: SleepActivityBacking, @unchecked Sendable {
    func beginActivity() -> SleepActivityToken {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "正在保存会议录音"
        )
        return SleepActivityToken(storage: activity as AnyObject)
    }

    func endActivity(_ token: SleepActivityToken) {
        guard let activity = token.storage as? NSObjectProtocol else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}
