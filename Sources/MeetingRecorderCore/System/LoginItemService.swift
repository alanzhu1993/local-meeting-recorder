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
        let status = backend.status()
        switch (enabled, status) {
        case (_, .unavailable):
            throw LoginItemServiceError.unavailable
        case (true, .enabled), (false, .disabled):
            return
        case (true, .requiresApproval):
            throw LoginItemServiceError.requiresApproval
        case (true, .disabled):
            do {
                try backend.register()
            } catch {
                switch backend.status() {
                case .enabled:
                    return
                case .requiresApproval:
                    throw LoginItemServiceError.requiresApproval
                default:
                    throw LoginItemServiceError.registrationFailed(error.localizedDescription)
                }
            }
        case (false, .enabled), (false, .requiresApproval):
            do {
                try backend.unregister()
            } catch {
                if backend.status() == .disabled { return }
                throw LoginItemServiceError.unregistrationFailed(error.localizedDescription)
            }
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
