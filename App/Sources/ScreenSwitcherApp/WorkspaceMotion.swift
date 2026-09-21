public enum WorkspaceMotionKind: Equatable, Sendable {
    case spring
    case opacity
}

public struct WorkspaceMotionTransition: Equatable, Sendable {
    public let kind: WorkspaceMotionKind
    public let duration: Double
    public let springResponse: Double?
    public let dampingFraction: Double?
    public let hasSpatialTravel: Bool

    public init(
        kind: WorkspaceMotionKind,
        duration: Double,
        springResponse: Double?,
        dampingFraction: Double?,
        hasSpatialTravel: Bool
    ) {
        self.kind = kind
        self.duration = duration.isFinite && duration >= 0 ? duration : 0
        switch kind {
        case .opacity:
            self.springResponse = nil
            self.dampingFraction = nil
            self.hasSpatialTravel = false
        case .spring:
            self.springResponse = springResponse.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            self.dampingFraction = dampingFraction.flatMap {
                $0.isFinite && (0...1).contains($0) ? $0 : nil
            }
            self.hasSpatialTravel = hasSpatialTravel
        }
    }
}

public protocol WorkspaceMotionStrategy: Sendable {
    var overlay: WorkspaceMotionTransition { get }
    var tab: WorkspaceMotionTransition { get }
    var card: WorkspaceMotionTransition { get }
    var appPage: WorkspaceMotionTransition { get }
    var confirmation: WorkspaceMotionTransition { get }
}

public struct StandardWorkspaceMotion: WorkspaceMotionStrategy {
    private static let segmented = WorkspaceMotionTransition(
        kind: .spring,
        duration: 0.24,
        springResponse: 0.24,
        dampingFraction: 0.86,
        hasSpatialTravel: true
    )

    public init() {}

    public let overlay = WorkspaceMotionTransition(
        kind: .spring,
        duration: 0.22,
        springResponse: 0.22,
        dampingFraction: 0.88,
        hasSpatialTravel: true
    )
    public let tab = Self.segmented
    public let card = WorkspaceMotionTransition(
        kind: .spring,
        duration: 0.23,
        springResponse: 0.23,
        dampingFraction: 0.86,
        hasSpatialTravel: true
    )
    public let appPage = Self.segmented
    public let confirmation = WorkspaceMotionTransition(
        kind: .spring,
        duration: 0.18,
        springResponse: 0.18,
        dampingFraction: 0.9,
        hasSpatialTravel: false
    )
}

public struct ReducedWorkspaceMotion: WorkspaceMotionStrategy {
    private static let fade = WorkspaceMotionTransition(
        kind: .opacity,
        duration: 0.12,
        springResponse: nil,
        dampingFraction: nil,
        hasSpatialTravel: false
    )

    public init() {}

    public let overlay = Self.fade
    public let tab = Self.fade
    public let card = Self.fade
    public let appPage = Self.fade
    public let confirmation = WorkspaceMotionTransition(
        kind: .opacity,
        duration: 0.1,
        springResponse: nil,
        dampingFraction: nil,
        hasSpatialTravel: false
    )
}
