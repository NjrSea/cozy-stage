import ApplicationServices
import AppKit
import CoreGraphics

public enum PermissionKind: Equatable, Sendable {
    case accessibility
}

public enum PermissionState: Equatable, Sendable {
    case granted
    case accessibilityMissing
}

public enum AccessibilityPermissionStatus: Equatable, Sendable {
    case granted
    case missing
}

public enum PermissionFailure: Error, Equatable, Sendable {
    case accessibilityMissing
    case settingsOpenFailed(PermissionKind)
}

@MainActor
public protocol AccessibilityChecking {
    func isAccessibilityTrusted() -> Bool
    @discardableResult
    func requestAccessibilityAccess() -> Bool
}

@MainActor
public protocol PermissionSettingsOpening {
    func openSettings(for kind: PermissionKind) -> Bool
}

@MainActor
public final class PermissionService {
    private let accessibilityChecker: AccessibilityChecking
    private let settingsOpener: PermissionSettingsOpening

    public init(
        accessibilityChecker: AccessibilityChecking? = nil,
        settingsOpener: PermissionSettingsOpening? = nil
    ) {
        self.accessibilityChecker = accessibilityChecker ?? AXAccessibilityChecker()
        self.settingsOpener = settingsOpener ?? SystemSettingsOpener()
    }

    public func state() -> PermissionState {
        guard accessibilityChecker.isAccessibilityTrusted() else {
            return .accessibilityMissing
        }
        return .granted
    }

    public func requireAll() throws {
        switch state() {
        case .granted:
            return
        case .accessibilityMissing:
            throw PermissionFailure.accessibilityMissing
        }
    }

    public func requireAccessibility() throws {
        guard accessibilityChecker.isAccessibilityTrusted() else {
            throw PermissionFailure.accessibilityMissing
        }
    }

    public func isAccessibilityGranted() -> Bool {
        accessibilityChecker.isAccessibilityTrusted()
    }

    public func accessibilityStatus() -> AccessibilityPermissionStatus {
        isAccessibilityGranted() ? .granted : .missing
    }

    /// Settings are opened only when the caller explicitly requests this action.
    public func openSettings(for kind: PermissionKind) throws {
        guard settingsOpener.openSettings(for: kind) else {
            throw PermissionFailure.settingsOpenFailed(kind)
        }
    }

    /// Requests access first, then always attempts to open the matching Privacy pane.
    /// A denied request is not a reason to hide the settings path from the user.
    public func requestAndOpenSettings(for kind: PermissionKind) throws {
        switch kind {
        case .accessibility:
            _ = accessibilityChecker.requestAccessibilityAccess()
        }
        try openSettings(for: kind)
    }
}

@MainActor
public struct AXAccessibilityChecker: AccessibilityChecking {
    public init() {}

    public func isAccessibilityTrusted() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
public struct SystemSettingsOpener: PermissionSettingsOpening {
    public init() {}

    public static func url(for kind: PermissionKind) -> URL? {
        let anchor: String
        switch kind {
        case .accessibility:
            anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    public func openSettings(for kind: PermissionKind) -> Bool {
        guard let url = Self.url(for: kind) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
