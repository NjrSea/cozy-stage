public typealias FocusScreenID = String
public typealias ManagedWindowID = String

public struct CanvasPoint: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        precondition(x.isFinite, "CanvasPoint.x must be finite")
        precondition(y.isFinite, "CanvasPoint.y must be finite")
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        guard x.isFinite, y.isFinite else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "CanvasPoint requires finite coordinates"
                )
            )
        }
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
    }
}

public struct CanvasRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var center: CanvasPoint {
        CanvasPoint(x: x + width / 2, y: y + height / 2)
    }

    /// Half-open point containment: `[x, x+width) x [y, y+height)`.
    ///
    /// The lower bounds are inclusive (the rect's own origin is contained) and
    /// the upper bounds are exclusive (a point exactly on the far edge belongs to
    /// an adjacent region, not this one). This keeps stitched canvas regions
    /// disjoint at their shared borders.
    ///
    /// `CanvasRect` is always finite and well-formed by construction (the
    /// initializer rejects non-finite values and non-positive dimensions), so the
    /// derived bounds used here are always finite.
    public func contains(_ point: CanvasPoint) -> Bool {
        point.x >= x
            && point.x < x + width
            && point.y >= y
            && point.y < y + height
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(
            Self.hasValidGeometry(x: x, y: y, width: width, height: height),
            "CanvasRect requires finite geometry, positive dimensions, and finite derived extents"
        )
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard Self.hasValidGeometry(x: x, y: y, width: width, height: height) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "CanvasRect requires finite geometry, positive dimensions, and finite derived extents"
                )
            )
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private static func hasValidGeometry(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> Bool {
        guard x.isFinite,
              y.isFinite,
              width.isFinite,
              width > 0,
              height.isFinite,
              height > 0
        else {
            return false
        }
        return (x + width).isFinite
            && (y + height).isFinite
            && (x + width / 2).isFinite
            && (y + height / 2).isFinite
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case width
        case height
    }
}

public struct ManagedWindow: Equatable, Sendable {
    public let id: ManagedWindowID
    public let appID: String
    public var canonicalFrame: CanvasRect
    public var isCompatible: Bool

    public init(
        id: ManagedWindowID,
        appID: String,
        canonicalFrame: CanvasRect,
        isCompatible: Bool = true
    ) {
        self.id = id
        self.appID = appID
        self.canonicalFrame = canonicalFrame
        self.isCompatible = isCompatible
    }
}

public enum FocusScreenLifecycle: String, Codable, Equatable, Sendable {
    case active
    case background
    case closing
    case closed
}

public struct FocusScreen: Equatable, Sendable {
    public let id: FocusScreenID
    public var number: Int
    public var name: String?
    public var lifecycle: FocusScreenLifecycle
    public var windowIDs: [ManagedWindowID]
    public var lastActiveWindowID: ManagedWindowID?
    /// The Saved Space this Screen is bound to, or `nil` for a temporary Screen
    /// that has not been saved yet. One Space may have at most one
    /// open Screen.
    public var spaceID: SavedSpaceID?
    /// The Pane/Tab Layout, or `nil` for As Is (normal macOS geometry).
    /// Phase 1C: when non-nil, the Screen uses a Tabs Layout.
    public var layout: FocusLayout?

    public init(
        id: FocusScreenID,
        number: Int,
        name: String? = nil,
        lifecycle: FocusScreenLifecycle,
        windowIDs: [ManagedWindowID] = [],
        lastActiveWindowID: ManagedWindowID? = nil,
        spaceID: SavedSpaceID? = nil,
        layout: FocusLayout? = nil
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.lifecycle = lifecycle
        self.windowIDs = windowIDs
        self.lastActiveWindowID = lastActiveWindowID
        self.spaceID = spaceID
        self.layout = layout
    }
}

public struct FocusScreenState: Equatable, Sendable {
    public var screens: [FocusScreen]
    public var windows: [ManagedWindowID: ManagedWindow]
    public var activeScreenID: FocusScreenID
    public var inspectedScreenID: FocusScreenID
    public var revision: Int
    /// Saved Spaces. Empty by default in Phase 1A; populated by Phase 1B
    /// `FocusSpaceReducer` transitions.
    public var savedSpaces: [SavedSpace]

    public init(
        screens: [FocusScreen],
        windows: [ManagedWindowID: ManagedWindow],
        activeScreenID: FocusScreenID,
        inspectedScreenID: FocusScreenID,
        revision: Int,
        savedSpaces: [SavedSpace] = []
    ) {
        self.screens = screens
        self.windows = windows
        self.activeScreenID = activeScreenID
        self.inspectedScreenID = inspectedScreenID
        self.revision = revision
        self.savedSpaces = savedSpaces
    }

    public func screen(id: FocusScreenID) -> FocusScreen? {
        screens.first { $0.id == id }
    }

    public func space(id: SavedSpaceID) -> SavedSpace? {
        savedSpaces.first { $0.id == id }
    }
}

public enum FocusScreenDomainError: Error, Equatable {
    case screenLimitReached
    case screenMissing(FocusScreenID)
    case windowMissing(ManagedWindowID)
    case windowAlreadyOwned(ManagedWindowID)
    case soleScreenCannotClose
    case invalidLifecycle(FocusScreenID)
}
