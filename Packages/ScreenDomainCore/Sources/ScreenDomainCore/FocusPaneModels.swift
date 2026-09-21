import Foundation

// MARK: - Phase 1C: Pane, Tab, Layout, and PaneRatio domain model

/// Layout kind for a Screen.
///
/// - `asIs`: normal macOS geometry; no Pane/Tab Rail
/// - `focus`: one Pane within a continuous Canvas region
/// - `split`: two side-by-side Panes
/// - `focusStack`: one primary Pane + two stacked secondary Panes
public enum LayoutKind: String, Codable, Equatable, Sendable, CaseIterable {
    case asIs
    case focus
    case split
    case focusStack
}

public typealias PaneID = String
public typealias TabID = String

/// Normalized split ratio (0.0–1.0), NOT absolute pixels.
public struct PaneRatio: Equatable, Sendable {
    /// Primary ratio (e.g., left pane width in a Split). Range 0.0–1.0.
    public var primary: Double
    /// Secondary ratio for Focus+Stack (vertical stack split). Nil for Split/Focus.
    public var secondary: Double?

    public init(primary: Double, secondary: Double? = nil) {
        self.primary = Self.clamp(primary)
        self.secondary = secondary.map { Self.clamp($0) }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// A Tab is one concrete top-level App window assigned to a Pane.
public struct FocusTab: Equatable, Sendable {
    public let id: TabID
    public var windowID: ManagedWindowID
    public var state: TabState

    public init(id: TabID, windowID: ManagedWindowID, state: TabState = .inactive) {
        self.id = id
        self.windowID = windowID
        self.state = state
    }
}

/// Tab lifecycle states.
public enum TabState: String, Codable, Equatable, Sendable {
    case active
    case inactive
    case loading
    case unavailable
}

/// A Pane is a stable visible region.
/// One Pane shows one active Tab at a time. Empty Panes remain reserved.
public struct FocusPane: Equatable, Sendable {
    public let id: PaneID
    public var role: String?
    public var ratio: PaneRatio
    public var tabIDs: [TabID]
    public var activeTabID: TabID?
    public var frame: CanvasRect

    public init(
        id: PaneID,
        role: String? = nil,
        ratio: PaneRatio = PaneRatio(primary: 0.5),
        tabIDs: [TabID] = [],
        activeTabID: TabID? = nil,
        frame: CanvasRect = CanvasRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.id = id
        self.role = role
        self.ratio = ratio
        self.tabIDs = tabIDs
        self.activeTabID = activeTabID
        self.frame = frame
    }
}

/// A Screen's layout: the Pane/Tab structure above the flat `windowIDs`.
///
/// When `FocusScreen.layout` is nil, the Screen uses As Is (normal macOS
/// geometry). When non-nil, it uses the specified Tabs Layout kind.
public struct FocusLayout: Equatable, Sendable {
    public var kind: LayoutKind
    public var panes: [FocusPane]
    public var tabs: [TabID: FocusTab]
    public var revision: UInt64

    public init(
        kind: LayoutKind,
        panes: [FocusPane] = [],
        tabs: [TabID: FocusTab] = [:],
        revision: UInt64 = 1
    ) {
        self.kind = kind
        self.panes = panes
        self.tabs = tabs
        self.revision = revision
    }
}

// MARK: - Domain errors

public enum FocusPaneDomainError: Error, Equatable {
    case paneMissing(PaneID)
    case tabMissing(TabID)
    case paneLimitReached
    case incompatibleLayoutKind
    case windowAlreadyTabbed(ManagedWindowID)
    case layoutNotSet
}

// MARK: - Codable conformance with closed decoding

extension PaneRatio: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case primary
        case secondary
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try container.decode(Double.self, forKey: .primary)
        let secondary = try container.decodeIfPresent(Double.self, forKey: .secondary)
        self.init(primary: primary, secondary: secondary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(primary, forKey: .primary)
        try container.encodeIfPresent(secondary, forKey: .secondary)
    }
}

extension FocusTab: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case windowID = "windowId"
        case state
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            windowID: try container.decode(String.self, forKey: .windowID),
            state: try container.decode(TabState.self, forKey: .state)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(state, forKey: .state)
    }
}

extension FocusPane: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case role
        case ratio
        case tabIDs = "tabIds"
        case activeTabID = "activeTabId"
        case frame
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            role: try container.decodeIfPresent(String.self, forKey: .role),
            ratio: try container.decode(PaneRatio.self, forKey: .ratio),
            tabIDs: try container.decode([String].self, forKey: .tabIDs),
            activeTabID: try container.decodeIfPresent(String.self, forKey: .activeTabID),
            frame: try container.decode(CanvasRect.self, forKey: .frame)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(tabIDs, forKey: .tabIDs)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try container.encode(frame, forKey: .frame)
    }
}

extension FocusLayout: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case panes
        case tabs
        case revision
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(LayoutKind.self, forKey: .kind),
            panes: try container.decode([FocusPane].self, forKey: .panes),
            tabs: try container.decode([String: FocusTab].self, forKey: .tabs),
            revision: try container.decode(UInt64.self, forKey: .revision)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(panes, forKey: .panes)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(revision, forKey: .revision)
    }
}
