import AVFoundation
import CoreGraphics
import Foundation

public enum CapturePermission: String, Equatable, Sendable {
    case systemAudio
    case microphone

    fileprivate var displayName: String {
        switch self {
        case .systemAudio: "屏幕与系统音频录制"
        case .microphone: "麦克风"
        }
    }
}

public struct CapturePermissionStatus: Equatable, Sendable {
    public let missing: [CapturePermission]

    public init(missing: [CapturePermission]) {
        self.missing = missing
    }

    public var isGranted: Bool { missing.isEmpty }

    public var userMessage: String {
        guard !missing.isEmpty else { return "权限已就绪" }
        var message = "请在系统设置 > 隐私与安全性中开启「会议录音」的："
            + missing.map(\.displayName).joined(separator: "、") + "。"
        if missing.contains(.systemAudio) {
            message += "开启屏幕录制后需要退出并重新打开本应用。"
        }
        return message
    }
}

public enum MicrophoneAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized

    fileprivate var isAuthorized: Bool { self == .authorized }
}

public protocol PermissionChecking: Sendable {
    func currentStatus() async -> CapturePermissionStatus
    func requestMissingPermissions() async -> CapturePermissionStatus
}

public final class PermissionService: PermissionChecking, @unchecked Sendable {
    private let screenAccess: @Sendable () -> Bool
    private let requestScreenAccess: @Sendable () -> Void
    private let microphoneStatus: @Sendable () -> MicrophoneAuthorizationStatus
    private let requestMicrophoneAccess: @Sendable () async -> Void

    public init() {
        screenAccess = { CGPreflightScreenCaptureAccess() }
        requestScreenAccess = { _ = CGRequestScreenCaptureAccess() }
        microphoneStatus = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .authorized
            @unknown default: .denied
            }
        }
        requestMicrophoneAccess = { _ = await AVCaptureDevice.requestAccess(for: .audio) }
    }

    public init(
        screenAccess: @escaping @Sendable () -> Bool,
        requestScreenAccess: @escaping @Sendable () -> Void,
        microphoneStatus: @escaping @Sendable () -> MicrophoneAuthorizationStatus,
        requestMicrophoneAccess: @escaping @Sendable () async -> Void
    ) {
        self.screenAccess = screenAccess
        self.requestScreenAccess = requestScreenAccess
        self.microphoneStatus = microphoneStatus
        self.requestMicrophoneAccess = requestMicrophoneAccess
    }

    public func currentStatus() async -> CapturePermissionStatus {
        status()
    }

    public func requestMissingPermissions() async -> CapturePermissionStatus {
        let missing = status().missing
        if missing.contains(.systemAudio) {
            requestScreenAccess()
        }
        if missing.contains(.microphone) {
            await requestMicrophoneAccess()
        }
        return status()
    }

    private func status() -> CapturePermissionStatus {
        var missing: [CapturePermission] = []
        if !screenAccess() { missing.append(.systemAudio) }
        if !microphoneStatus().isAuthorized { missing.append(.microphone) }
        return CapturePermissionStatus(missing: missing)
    }
}
