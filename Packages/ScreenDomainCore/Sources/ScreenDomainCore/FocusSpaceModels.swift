import Foundation

// MARK: - Phase 1B: Saved Space, Routing, and Canvas Topology domain model

/// A saved working environment that persists Canvas-relative structure and can
/// be restored into a Screen. A Saved Space stores layout geometry, Pane roles,
/// normalized split ratios, logical window slots, routing rules, and the last
/// confirmed Canvas-topology mapping. It NEVER stores screenshots, document
/// bodies, browser contents, terminal jobs, passwords, or user input.
public typealias SavedSpaceID = String

/// Space lifecycle: `restorable` (closed, can be restored) or `open` (bound to
/// exactly one Screen). While open, the management action is `Switch · Screen N`;
/// `Restore` is not shown or enabled.
public enum SavedSpaceLifecycle: String, Codable, Equatable, Sendable {
    case restorable
    case open
}

/// A logical window slot for restore matching. Uses Bundle ID, Pane role, and
/// Tab order — durable identity — rather than PID/AX window identity which is
/// not stable across restarts. Title matching is best-effort only.
public struct LogicalWindowSlot: Equatable, Sendable {
    public let id: String
    public let bundleID: String
    public var paneRole: String?
    public var tabOrder: Int
    public var boundWindowID: ManagedWindowID?
    public var status: LogicalSlotStatus

    public init(
        id: String,
        bundleID: String,
        paneRole: String? = nil,
        tabOrder: Int = 0,
        boundWindowID: ManagedWindowID? = nil,
        status: LogicalSlotStatus = .unresolved
    ) {
        self.id = id
        self.bundleID = bundleID
        self.paneRole = paneRole
        self.tabOrder = tabOrder
        self.boundWindowID = boundWindowID
        self.status = status
    }
}

/// Slot restore status ( restoration priority):
/// - `resolved`: a window matched or was launched for this slot
/// - `unresolved`: no window found; slot remains visible with `Retry`
/// - `unavailable`: the App is unavailable or the slot cannot be fulfilled
public enum LogicalSlotStatus: String, Codable, Equatable, Sendable {
    case resolved
    case unresolved
    case unavailable
}

/// App routing rule. Targets a Saved Space and optional Pane role — NOT a
/// transient Screen number — so routing persists into the Space.
public struct RoutingRule: Equatable, Sendable {
    public let bundleID: String
    public let spaceID: SavedSpaceID
    public var paneRole: String?

    public init(bundleID: String, spaceID: SavedSpaceID, paneRole: String? = nil) {
        self.bundleID = bundleID
        self.spaceID = spaceID
        self.paneRole = paneRole
    }
}

/// Canvas-relative layout geometry snapshot. Window frames are stored relative
/// to the stitched Canvas (NOT absolute pixels) and re-mapped when the connected
/// topology changes.
public struct SavedCanvasLayout: Equatable, Sendable {
    /// Slot ID → Canvas-relative frame. This is structure geometry only.
    public var windowFrames: [String: CanvasRect]
    /// Normalized Pane split ratios. Stub for Phase 1C; empty in Phase 1B.
    public var paneRatios: [PaneRatioEntry]

    public init(
        windowFrames: [String: CanvasRect] = [:],
        paneRatios: [PaneRatioEntry] = []
    ) {
        self.windowFrames = windowFrames
        self.paneRatios = paneRatios
    }
}

/// A normalized Pane split ratio entry. `PaneRatio` is the authoritative type
/// in Phase 1C; this struct provides a persistence-ready entry for the saved
/// layout.
public struct PaneRatioEntry: Equatable, Sendable {
    public let paneID: String
    public var primary: Double
    public var secondary: Double?

    public init(paneID: String, primary: Double, secondary: Double? = nil) {
        self.paneID = paneID
        self.primary = Self.clamp(primary)
        self.secondary = secondary.map { Self.clamp($0) }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// A persistent stable identity for a Canvas region. Physical display names and
/// roles are absent from the product hierarchy; this logical ID lets topology
/// changes be detected without binding to hardware identity.
public struct CanvasRegionIdentity: Equatable, Hashable, Sendable {
    public let id: String
    public var frame: CanvasRect
    public var scale: Double

    public init(id: String, frame: CanvasRect, scale: Double = 1) {
        precondition(scale > 0, "CanvasRegionIdentity.scale must be positive")
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

/// A seam between two adjacent Canvas regions. A Pane may not cross a physical
/// bezel — seam positions are used by the remapping engine to enforce
/// continuous-region constraints.
public enum SeamEdge: String, Codable, Equatable, Sendable {
    case vertical
    case horizontal
}

public struct CanvasSeam: Equatable, Sendable {
    /// The two adjacent region IDs. Always exactly two.
    public let regionIDs: [String]
    public let edge: SeamEdge
    public var position: Double

    public init(regionIDs: [String], edge: SeamEdge, position: Double) {
        precondition(regionIDs.count == 2, "CanvasSeam requires exactly two region IDs")
        precondition(position.isFinite, "CanvasSeam.position must be finite")
        self.regionIDs = regionIDs
        self.edge = edge
        self.position = position
    }
}

/// The confirmed Canvas-topology mapping associated with a Saved Space. When the
/// physical topology changes, the remapping engine produces a new temporary
/// mapping that the user must confirm before it replaces this one.
public struct CanvasTopologyMapping: Equatable, Sendable {
    public var regions: [CanvasRegionIdentity]
    public var seams: [CanvasSeam]
    public var revision: UInt64

    public init(
        regions: [CanvasRegionIdentity],
        seams: [CanvasSeam] = [],
        revision: UInt64 = 1
    ) {
        self.regions = regions
        self.seams = seams
        self.revision = revision
    }
}

/// A saved working environment. See `SavedSpaceLifecycle` for the lifecycle
/// contract and , for the full persistence model.
public struct SavedSpace: Equatable, Sendable {
    public let id: SavedSpaceID
    public var number: Int
    public var name: String?
    public var lifecycle: SavedSpaceLifecycle
    public var layoutRevision: UInt64
    public var canvasLayout: SavedCanvasLayout
    public var appSlots: [LogicalWindowSlot]
    public var defaultSlotID: String?
    public var routingRules: [RoutingRule]
    public var canvasTopologyMapping: CanvasTopologyMapping?
    public var autoSaveSuspended: Bool
    public var boundScreenID: FocusScreenID?

    public init(
        id: SavedSpaceID,
        number: Int,
        name: String? = nil,
        lifecycle: SavedSpaceLifecycle = .restorable,
        layoutRevision: UInt64 = 1,
        canvasLayout: SavedCanvasLayout = SavedCanvasLayout(),
        appSlots: [LogicalWindowSlot] = [],
        defaultSlotID: String? = nil,
        routingRules: [RoutingRule] = [],
        canvasTopologyMapping: CanvasTopologyMapping? = nil,
        autoSaveSuspended: Bool = false,
        boundScreenID: FocusScreenID? = nil
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.lifecycle = lifecycle
        self.layoutRevision = layoutRevision
        self.canvasLayout = canvasLayout
        self.appSlots = appSlots
        self.defaultSlotID = defaultSlotID
        self.routingRules = routingRules
        self.canvasTopologyMapping = canvasTopologyMapping
        self.autoSaveSuspended = autoSaveSuspended
        self.boundScreenID = boundScreenID
    }
}

// MARK: - Codable conformance with closed decoding

extension LogicalWindowSlot: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case bundleID = "bundleId"
        case paneRole
        case tabOrder
        case boundWindowID = "boundWindowId"
        case status
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            bundleID: try container.decode(String.self, forKey: .bundleID),
            paneRole: try container.decodeIfPresent(String.self, forKey: .paneRole),
            tabOrder: try container.decode(Int.self, forKey: .tabOrder),
            boundWindowID: try container.decodeIfPresent(String.self, forKey: .boundWindowID),
            status: try container.decode(LogicalSlotStatus.self, forKey: .status)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encodeIfPresent(paneRole, forKey: .paneRole)
        try container.encode(tabOrder, forKey: .tabOrder)
        try container.encodeIfPresent(boundWindowID, forKey: .boundWindowID)
        try container.encode(status, forKey: .status)
    }
}

extension RoutingRule: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bundleID = "bundleId"
        case spaceID = "spaceId"
        case paneRole
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleID: try container.decode(String.self, forKey: .bundleID),
            spaceID: try container.decode(String.self, forKey: .spaceID),
            paneRole: try container.decodeIfPresent(String.self, forKey: .paneRole)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(spaceID, forKey: .spaceID)
        try container.encodeIfPresent(paneRole, forKey: .paneRole)
    }
}

extension PaneRatioEntry: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case paneID = "paneId"
        case primary
        case secondary
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let paneID = try container.decode(String.self, forKey: .paneID)
        let primary = try container.decode(Double.self, forKey: .primary)
        let secondary = try container.decodeIfPresent(Double.self, forKey: .secondary)
        self.init(paneID: paneID, primary: primary, secondary: secondary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneID, forKey: .paneID)
        try container.encode(primary, forKey: .primary)
        try container.encodeIfPresent(secondary, forKey: .secondary)
    }
}

extension SavedCanvasLayout: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case windowFrames
        case paneRatios
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            windowFrames: try container.decode([String: CanvasRect].self, forKey: .windowFrames),
            paneRatios: try container.decodeIfPresent([PaneRatioEntry].self, forKey: .paneRatios) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowFrames, forKey: .windowFrames)
        try container.encode(paneRatios, forKey: .paneRatios)
    }
}

extension CanvasRegionIdentity: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case frame
        case scale
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let frame = try container.decode(CanvasRect.self, forKey: .frame)
        let scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        self.init(id: id, frame: frame, scale: scale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frame, forKey: .frame)
        try container.encode(scale, forKey: .scale)
    }
}

extension CanvasSeam: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case regionIDs = "regionIds"
        case edge
        case position
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let regionIDs = try container.decode([String].self, forKey: .regionIDs)
        guard regionIDs.count == 2 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "CanvasSeam.regionIds must have exactly two entries"
            ))
        }
        let edge = try container.decode(SeamEdge.self, forKey: .edge)
        let position = try container.decode(Double.self, forKey: .position)
        guard position.isFinite else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "CanvasSeam.position must be finite"
            ))
        }
        self.init(regionIDs: regionIDs, edge: edge, position: position)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(regionIDs, forKey: .regionIDs)
        try container.encode(edge, forKey: .edge)
        try container.encode(position, forKey: .position)
    }
}

extension CanvasTopologyMapping: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case regions
        case seams
        case revision
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regions: try container.decode([CanvasRegionIdentity].self, forKey: .regions),
            seams: try container.decodeIfPresent([CanvasSeam].self, forKey: .seams) ?? [],
            revision: try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(regions, forKey: .regions)
        try container.encode(seams, forKey: .seams)
        try container.encode(revision, forKey: .revision)
    }
}

extension SavedSpace: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case number
        case name
        case lifecycle
        case layoutRevision
        case canvasLayout
        case appSlots
        case defaultSlotID = "defaultSlotId"
        case routingRules
        case canvasTopologyMapping
        case autoSaveSuspended
        case boundScreenID = "boundScreenId"
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            number: try container.decode(Int.self, forKey: .number),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            lifecycle: try container.decode(SavedSpaceLifecycle.self, forKey: .lifecycle),
            layoutRevision: try container.decode(UInt64.self, forKey: .layoutRevision),
            canvasLayout: try container.decode(SavedCanvasLayout.self, forKey: .canvasLayout),
            appSlots: try container.decode([LogicalWindowSlot].self, forKey: .appSlots),
            defaultSlotID: try container.decodeIfPresent(String.self, forKey: .defaultSlotID),
            routingRules: try container.decodeIfPresent([RoutingRule].self, forKey: .routingRules) ?? [],
            canvasTopologyMapping: try container.decodeIfPresent(CanvasTopologyMapping.self, forKey: .canvasTopologyMapping),
            autoSaveSuspended: try container.decodeIfPresent(Bool.self, forKey: .autoSaveSuspended) ?? false,
            boundScreenID: try container.decodeIfPresent(String.self, forKey: .boundScreenID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(number, forKey: .number)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(layoutRevision, forKey: .layoutRevision)
        try container.encode(canvasLayout, forKey: .canvasLayout)
        try container.encode(appSlots, forKey: .appSlots)
        try container.encodeIfPresent(defaultSlotID, forKey: .defaultSlotID)
        try container.encode(routingRules, forKey: .routingRules)
        try container.encodeIfPresent(canvasTopologyMapping, forKey: .canvasTopologyMapping)
        try container.encode(autoSaveSuspended, forKey: .autoSaveSuspended)
        try container.encodeIfPresent(boundScreenID, forKey: .boundScreenID)
    }
}

// MARK: - Domain errors

public enum FocusSpaceDomainError: Error, Equatable {
    case spaceLimitReached
    case spaceMissing(SavedSpaceID)
    case spaceAlreadyOpen(SavedSpaceID)
    case screenAlreadyBound(FocusScreenID)
    case screenNotBound(FocusScreenID)
    case autoSaveSuspended(SavedSpaceID)
}
