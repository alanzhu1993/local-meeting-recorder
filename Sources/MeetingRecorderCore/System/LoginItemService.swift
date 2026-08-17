import Foundation
import ServiceManagement

@MainActor
public protocol LoginItemManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LoginItemBacking {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

public enum LoginItemServiceError: Error, Equatable, Sendable, LocalizedError {
    case requiresApproval
    case unavailable
    case registrationFailed(String)
    case unregistrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "登录启动正在等待系统批准。请在系统设置 > 通用 > 登录项中允许“会议录音”。"
        case .unavailable:
            "当前应用无法设置登录启动。"
        case .registrationFailed(let detail):
            "无法开启登录启动：\(detail)"
        case .unregistrationFailed(let detail):
            "无法关闭登录启动：\(detail)"
        }
    }
}

@MainActor
public final class LoginItemService: LoginItemManaging {
    private let backend: any LoginItemBacking
    private var isMutating = false
    private var activeDesired: Bool?
    private var pendingDesired: Bool?

    public init() {
        backend = ServiceManagementLoginItemBackend()
    }

    public init(backend: any LoginItemBacking) {
        self.backend = backend
    }

    public var isEnabled: Bool {
        backend.status() == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if isMutating {
            pendingDesired = activeDesired == enabled ? nil : enabled
            return
        }

        isMutating = true
        defer {
            isMutating = false
            activeDesired = nil
            pendingDesired = nil
        }

        var desired = enabled
        while true {
            activeDesired = desired
            let result = performMutation(toward: desired)
            if let pendingDesired {
                self.pendingDesired = nil
                desired = pendingDesired
                continue
            }
            return try result.get()
        }
    }

    private func performMutation(toward desired: Bool) -> Result<Void, LoginItemServiceError> {
        let status = backend.status()
        switch (desired, status) {
        case (_, .unavailable):
            return .failure(.unavailable)
        case (true, .enabled), (false, .disabled):
            return .success(())
        case (true, .requiresApproval):
            return .failure(.requiresApproval)
        case (true, .disabled):
            return runAction(desired: true) { try backend.register() }
        case (false, .enabled), (false, .requiresApproval):
            return runAction(desired: false) { try backend.unregister() }
        }
    }

    private func runAction(
        desired: Bool,
        action: () throws -> Void
    ) -> Result<Void, LoginItemServiceError> {
        let actionError: Error?
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error
        }

        switch (desired, backend.status()) {
        case (true, .enabled), (false, .disabled):
            return .success(())
        case (_, .requiresApproval):
            return .failure(.requiresApproval)
        case (_, .unavailable):
            return .failure(.unavailable)
        case (true, .disabled):
            return .failure(.registrationFailed(
                actionError?.localizedDescription ?? "系统未确认登录启动已开启。"
            ))
        case (false, .enabled):
            return .failure(.unregistrationFailed(
                actionError?.localizedDescription ?? "系统未确认登录启动已关闭。"
            ))
        }
    }
}

@MainActor
private final class ServiceManagementLoginItemBackend: LoginItemBacking {
    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
