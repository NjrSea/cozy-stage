import AppKit
import Foundation

public struct PointSnapshot: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum RectDescriptorError: Error, Equatable {
    case nonFiniteCoordinateOrSize
    case nonPositiveSize
    case overflowingMaxX
    case overflowingMaxY
}

/// A finite, positive-size frame whose max edges are also finite.
/// Invalid geometry is rejected at construction and again at Codable boundaries.
public struct RectDescriptor: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        try validate()
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw RectDescriptorError.nonFiniteCoordinateOrSize
        }
        guard width > 0, height > 0 else {
            throw RectDescriptorError.nonPositiveSize
        }
        guard (x + width).isFinite else {
            throw RectDescriptorError.overflowingMaxX
        }
        guard (y + height).isFinite else {
            throw RectDescriptorError.overflowingMaxY
        }
    }

    internal init(uncheckedX x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        (try? validate()) != nil
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ point: PointSnapshot) -> Bool {
        // Use half-open frames so a shared edge belongs to only the right/up display.
        isValid && point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y),
            width: container.decode(Double.self, forKey: .width),
            height: container.decode(Double.self, forKey: .height)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }
}

public enum DisplayHardwareKind: String, Codable, Equatable, Hashable, Sendable {
    case builtIn = "built-in"
    case external
    case unknown
}

public struct DisplaySource: Equatable {
    public let id: String
    public let frame: RectDescriptor
    public let hardwareKind: DisplayHardwareKind

    public init(
        id: String,
        frame: RectDescriptor,
        hardwareKind: DisplayHardwareKind = .unknown
    ) {
        self.id = id
        self.frame = frame
        self.hardwareKind = hardwareKind
    }
}

public struct DisplayDescriptor: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let frame: RectDescriptor
    public let isCurrent: Bool
    public let hardwareKind: DisplayHardwareKind

    public init(
        id: String,
        frame: RectDescriptor,
        isCurrent: Bool,
        hardwareKind: DisplayHardwareKind = .unknown
    ) {
        self.id = id
        self.frame = frame
        self.isCurrent = isCurrent
        self.hardwareKind = hardwareKind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case frame
        case isCurrent
        case hardwareKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            frame: try container.decode(RectDescriptor.self, forKey: .frame),
            isCurrent: try container.decode(Bool.self, forKey: .isCurrent),
            hardwareKind: (try? container.decode(DisplayHardwareKind.self, forKey: .hardwareKind)) ?? .unknown
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frame, forKey: .frame)
        try container.encode(isCurrent, forKey: .isCurrent)
        try container.encode(hardwareKind, forKey: .hardwareKind)
    }
}

public enum AppActivationPolicy: Equatable {
    case regular
    case accessory
    case prohibited
}

public struct RunningAppSource: Equatable {
    public let id: String
    public let displayName: String
    public let activationPolicy: AppActivationPolicy

    public init(
        id: String,
        displayName: String,
        activationPolicy: AppActivationPolicy
    ) {
        self.id = id
        self.displayName = displayName
        self.activationPolicy = activationPolicy
    }
}

/// Process-local handles used to safely reconnect a semantic window snapshot to
/// the exact owning process and, when independently validated, a CG capture
/// handle. This value must never cross Codable/evidence boundaries.
struct WindowRuntimeIdentity: Equatable, Sendable {
    let ownerProcessIdentifier: pid_t
    let captureWindowID: CGWindowID?
}

/// Converts AX/CG top-left-relative screen rectangles into AppKit's global
/// bottom-left screen coordinate space.
struct TopLeftToAppKitCoordinateNormalizer: Sendable {
    let mainDisplayMaxY: Double

    func normalize(_ topLeftFrame: RectDescriptor) -> RectDescriptor? {
        try? RectDescriptor(
            x: topLeftFrame.x,
            y: mainDisplayMaxY - topLeftFrame.y - topLeftFrame.height,
            width: topLeftFrame.width,
            height: topLeftFrame.height
        )
    }
}

/// A sanitized window snapshot. `frame` always uses AppKit global bottom-left
/// screen coordinates. Runtime PID/capture metadata deliberately does not
/// participate in Codable, Equatable, or Hashable semantics.
public struct WindowDescriptor: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let frame: RectDescriptor
    public let isOnScreen: Bool
    public let isMain: Bool
    let runtimeIdentity: WindowRuntimeIdentity?

    public init(id: String, frame: RectDescriptor, isOnScreen: Bool, isMain: Bool) {
        self.init(
            id: id,
            frame: frame,
            isOnScreen: isOnScreen,
            isMain: isMain,
            runtimeIdentity: nil
        )
    }

    init(
        id: String,
        frame: RectDescriptor,
        isOnScreen: Bool,
        isMain: Bool,
        runtimeIdentity: WindowRuntimeIdentity?
    ) {
        self.id = id
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.isMain = isMain
        self.runtimeIdentity = runtimeIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case frame
        case isOnScreen
        case isMain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            frame: try container.decode(RectDescriptor.self, forKey: .frame),
            isOnScreen: try container.decode(Bool.self, forKey: .isOnScreen),
            isMain: try container.decode(Bool.self, forKey: .isMain),
            runtimeIdentity: nil
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frame, forKey: .frame)
        try container.encode(isOnScreen, forKey: .isOnScreen)
        try container.encode(isMain, forKey: .isMain)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.frame == rhs.frame
            && lhs.isOnScreen == rhs.isOnScreen
            && lhs.isMain == rhs.isMain
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(frame)
        hasher.combine(isOnScreen)
        hasher.combine(isMain)
    }
}

public struct RunningAppDescriptor: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let mostRecentWindow: WindowDescriptor?
    public let iconAvailability: RunningAppIconAvailability

    public init(
        id: String,
        displayName: String,
        mostRecentWindow: WindowDescriptor?,
        iconAvailability: RunningAppIconAvailability = .fallback
    ) {
        self.id = id
        self.displayName = displayName
        self.mostRecentWindow = mostRecentWindow
        self.iconAvailability = iconAvailability
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case mostRecentWindow
        case iconAvailability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            mostRecentWindow: try container.decodeIfPresent(WindowDescriptor.self, forKey: .mostRecentWindow),
            iconAvailability: try container.decodeIfPresent(
                RunningAppIconAvailability.self,
                forKey: .iconAvailability
            ) ?? .fallback
        )
    }
}

public enum PreviewAvailability: String, Codable, Equatable, Sendable {
    case available
    case schematicFallback
}

public struct DisplayWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let display: DisplayDescriptor
    public let apps: [RunningAppDescriptor]
    public let previewAvailability: PreviewAvailability

    public init(
        display: DisplayDescriptor,
        apps: [RunningAppDescriptor],
        previewAvailability: PreviewAvailability
    ) {
        self.display = display
        self.apps = apps
        self.previewAvailability = previewAvailability
    }
}

public struct SwitcherSnapshot: Codable, Equatable, Sendable {
    public let displays: [DisplayDescriptor]
    public let runningApps: [RunningAppDescriptor]
    public let pointerLocation: PointSnapshot?
    public let frontmostAppID: String?
    public let workspaces: [DisplayWorkspaceSnapshot]

    public init(
        displays: [DisplayDescriptor],
        runningApps: [RunningAppDescriptor],
        pointerLocation: PointSnapshot?,
        frontmostAppID: String?,
        workspaces: [DisplayWorkspaceSnapshot] = []
    ) {
        self.displays = displays
        self.runningApps = runningApps
        self.pointerLocation = pointerLocation
        self.frontmostAppID = frontmostAppID
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case displays
        case runningApps
        case pointerLocation
        case frontmostAppID
        case workspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displays: try container.decode([DisplayDescriptor].self, forKey: .displays),
            runningApps: try container.decode([RunningAppDescriptor].self, forKey: .runningApps),
            pointerLocation: try container.decodeIfPresent(PointSnapshot.self, forKey: .pointerLocation),
            frontmostAppID: try container.decodeIfPresent(String.self, forKey: .frontmostAppID),
            workspaces: try container.decodeIfPresent(
                [DisplayWorkspaceSnapshot].self,
                forKey: .workspaces
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displays, forKey: .displays)
        try container.encode(runningApps, forKey: .runningApps)
        try container.encode(pointerLocation, forKey: .pointerLocation)
        try container.encode(frontmostAppID, forKey: .frontmostAppID)
        if !workspaces.isEmpty {
            try container.encode(workspaces, forKey: .workspaces)
        }
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> SwitcherSnapshot {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

@MainActor
public protocol PointerLocationProviding {
    func currentPointerLocation() -> PointSnapshot?
}

@MainActor
public protocol FrontmostStateProviding {
    func frontmostApplicationID() -> String?
}

@MainActor
public struct NSEventPointerLocationProvider: PointerLocationProviding {
    public init() {}

    public func currentPointerLocation() -> PointSnapshot? {
        let point = NSEvent.mouseLocation
        return PointSnapshot(x: point.x, y: point.y)
    }
}

@MainActor
public struct NSWorkspaceFrontmostStateProvider: FrontmostStateProviding {
    public init() {}

    public func frontmostApplicationID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

@MainActor
public protocol SwitcherPanelSessionManaging: AnyObject {
    func beginPanelSession() -> SwitcherSnapshot
    func endPanelSession()
    func observePanelSessionSnapshots(
        _ observer: @escaping @MainActor (SwitcherSnapshot) -> Void
    ) -> SwitcherPanelSessionSnapshotObservation
}

@MainActor
public final class SwitcherPanelSessionSnapshotObservation {
    private var cancellation: (() -> Void)?

    public init(cancellation: @escaping () -> Void = {}) {
        self.cancellation = cancellation
    }

    public func cancel() {
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
    }

    deinit {
        cancellation?()
    }
}

public extension SwitcherPanelSessionManaging {
    func observePanelSessionSnapshots(
        _ observer: @escaping @MainActor (SwitcherSnapshot) -> Void
    ) -> SwitcherPanelSessionSnapshotObservation {
        SwitcherPanelSessionSnapshotObservation()
    }
}

@MainActor
/// A panel session and its cached snapshot are shared through this main-actor reference.
public final class SwitcherRuntimeState: LiveSnapshotProviding {
    public let displayCatalog: DisplayCatalog
    public let runningAppCatalog: RunningAppCatalog
    public let pointerLocation: PointerLocationProviding
    public let frontmostState: FrontmostStateProviding

    private var sessionSnapshot: SwitcherSnapshot?
    private var windowMetadataRefreshObservation: RunningAppWindowMetadataObservation?
    private var panelSessionObservers: [UUID: @MainActor (SwitcherSnapshot) -> Void] = [:]

    public init(
        displayCatalog: DisplayCatalog,
        runningAppCatalog: RunningAppCatalog,
        pointerLocation: PointerLocationProviding,
        frontmostState: FrontmostStateProviding
    ) {
        self.displayCatalog = displayCatalog
        self.runningAppCatalog = runningAppCatalog
        self.pointerLocation = pointerLocation
        self.frontmostState = frontmostState
        self.sessionSnapshot = nil
        self.windowMetadataRefreshObservation = runningAppCatalog.observeWindowMetadataRefresh {
            [weak self] in
            self?.refreshOpenPanelSession()
        }
    }

    public func beginPanelSession() -> SwitcherSnapshot {
        if let sessionSnapshot {
            return sessionSnapshot
        }

        let pointer = pointerLocation.currentPointerLocation()
        let snapshot = makeSnapshot(
            pointerLocation: pointer,
            iconAvailabilityPolicy: .deferToPresentation
        )
        sessionSnapshot = snapshot
        return snapshot
    }

    /// Returns current catalog/provider data without reusing the panel-session cache.
    public func liveSnapshot() -> SwitcherSnapshot {
        let pointer = pointerLocation.currentPointerLocation()
        return makeSnapshot(pointerLocation: pointer)
    }

    private func makeSnapshot(pointerLocation: PointSnapshot?) -> SwitcherSnapshot {
        makeSnapshot(pointerLocation: pointerLocation, iconAvailabilityPolicy: .resolve)
    }

    private func makeSnapshot(
        pointerLocation: PointSnapshot?,
        iconAvailabilityPolicy: RunningAppIconAvailabilityResolutionPolicy
    ) -> SwitcherSnapshot {
        let displays = displayCatalog.snapshot(at: pointerLocation)
        let appSnapshot = runningAppCatalog.displayScopedSnapshot(
            displays: displays,
            pointerLocation: pointerLocation,
            iconAvailabilityPolicy: iconAvailabilityPolicy
        )
        return SwitcherSnapshot(
            displays: displays,
            runningApps: appSnapshot.runningApps,
            pointerLocation: pointerLocation,
            frontmostAppID: frontmostState.frontmostApplicationID(),
            workspaces: appSnapshot.workspaces
        )
    }

    /// Explicit non-cached seam for the dev/test semantic adapter. It never
    /// exposes AppKit objects or panel-session state.
    public func semanticSnapshot() -> SwitcherSnapshot {
        liveSnapshot()
    }

    public func snapshot() -> SwitcherSnapshot {
        beginPanelSession()
    }

    public func endPanelSession() {
        sessionSnapshot = nil
    }

    public func observePanelSessionSnapshots(
        _ observer: @escaping @MainActor (SwitcherSnapshot) -> Void
    ) -> SwitcherPanelSessionSnapshotObservation {
        let id = UUID()
        panelSessionObservers[id] = observer
        if let sessionSnapshot {
            observer(sessionSnapshot)
        }
        return SwitcherPanelSessionSnapshotObservation { [weak self] in
            self?.panelSessionObservers.removeValue(forKey: id)
        }
    }

    private func refreshOpenPanelSession() {
        guard let currentSnapshot = sessionSnapshot else { return }
        // The overlay remains anchored to the pointer context captured when the
        // session opened. AX-derived windows may refine placement, but a later
        // pointer move must not move fallback apps between display workspaces.
        let refreshed = makeSnapshot(
            pointerLocation: currentSnapshot.pointerLocation,
            iconAvailabilityPolicy: .deferToPresentation
        )
        guard refreshed != currentSnapshot else { return }
        sessionSnapshot = refreshed
        panelSessionObservers.values.forEach { $0(refreshed) }
    }
}

extension SwitcherRuntimeState: SwitcherPanelSessionManaging {}
