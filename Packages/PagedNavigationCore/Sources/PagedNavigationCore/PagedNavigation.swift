public enum NavigationAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum PageDirection: String, Codable, Sendable {
    case previous
    case next
}

/// Gesture translations and velocities are cumulative values in points for the
/// current gesture. The reducer never reads view, window, or display geometry.
/// When displacement and velocity both qualify in opposite directions,
/// displacement determines the candidate direction.
public enum PageGestureInput: Equatable, Sendable {
    case changed(dx: Double, dy: Double, velocityX: Double, velocityY: Double)
    case ended
    case cancelled
}

public enum PageGestureEffect: Equatable, Sendable {
    case locked(NavigationAxis)
    case thresholdCrossed(PageDirection)
    case committed(index: Int)
    case cancelled(index: Int)
    case snapped(index: Int)
}

public struct PageGestureConfiguration: Equatable, Sendable {
    /// Distance that must be exceeded before an axis locks. Negative and
    /// non-finite values fall back to zero.
    public let axisLockDistance: Double

    /// Fraction of a fixed 100-point semantic gesture unit required to commit.
    /// This never depends on UI dimensions. Non-finite values and values outside
    /// `0...1` fall back to `1`.
    public let commitProgress: Double

    /// Absolute velocity threshold in points per second. Negative and non-finite
    /// values fall back to `Double.greatestFiniteMagnitude`.
    public let commitVelocity: Double

    /// Multiplier applied only to outward edge displacement. Non-finite values
    /// and values outside `0...1` fall back to zero, fully suppressing unsafe
    /// outward presentation movement.
    public let edgeResistance: Double

    public init(
        axisLockDistance: Double,
        commitProgress: Double,
        commitVelocity: Double,
        edgeResistance: Double
    ) {
        self.axisLockDistance = Self.nonnegativeFinite(axisLockDistance, fallback: 0)
        self.commitProgress = Self.unitIntervalOrFallback(commitProgress, fallback: 1)
        self.commitVelocity = Self.nonnegativeFinite(
            commitVelocity,
            fallback: .greatestFiniteMagnitude
        )
        self.edgeResistance = Self.unitIntervalOrFallback(edgeResistance, fallback: 0)
    }

    private static func nonnegativeFinite(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value >= 0 else {
            return fallback
        }
        return value
    }

    private static func unitIntervalOrFallback(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, (0...1).contains(value) else {
            return fallback
        }
        return value
    }
}

/// A deterministic single-page gesture reducer. The first valid threshold
/// direction in a gesture owns that gesture: returning below threshold disarms
/// the candidate, returning to the same direction rearms it without another
/// threshold effect, and crossing the opposite direction cancels the candidate.
public struct PageGestureReducer: Sendable {
    /// `commitProgress` is measured against this fixed semantic gesture unit.
    /// For example, `0.22` commits at 22 cumulative points. This is deliberately
    /// independent of viewport and page dimensions.
    private static let semanticGestureDistance = 100.0

    public private(set) var selectedIndex: Int
    public private(set) var lockedAxis: NavigationAxis?
    public private(set) var presentationOffset: Double = 0

    private let pageCount: Int
    private let configuration: PageGestureConfiguration
    private var pendingDirection: PageDirection?
    private var firstThresholdDirection: PageDirection?
    private var isGestureActive = false

    public init(
        pageCount: Int,
        selectedIndex: Int,
        configuration: PageGestureConfiguration
    ) {
        let safePageCount = max(pageCount, 0)
        self.pageCount = safePageCount
        self.selectedIndex = min(max(selectedIndex, 0), max(safePageCount - 1, 0))
        self.configuration = configuration
    }

    public mutating func reduce(_ input: PageGestureInput) -> [PageGestureEffect] {
        switch input {
        case let .changed(dx, dy, velocityX, velocityY):
            return reduceChanged(dx: dx, dy: dy, velocityX: velocityX, velocityY: velocityY)
        case .ended:
            return finishGesture(allowCommit: true)
        case .cancelled:
            return finishGesture(allowCommit: false)
        }
    }

    private mutating func reduceChanged(
        dx: Double,
        dy: Double,
        velocityX: Double,
        velocityY: Double
    ) -> [PageGestureEffect] {
        guard dx.isFinite, dy.isFinite, velocityX.isFinite, velocityY.isFinite else {
            return []
        }

        isGestureActive = true
        pendingDirection = nil

        var effects: [PageGestureEffect] = []
        if lockedAxis == nil {
            let horizontalDistance = abs(dx)
            let verticalDistance = abs(dy)
            guard max(horizontalDistance, verticalDistance) > configuration.axisLockDistance else {
                return effects
            }

            // Horizontal wins an exact tie so identical traces are deterministic.
            let axis: NavigationAxis = horizontalDistance >= verticalDistance ? .horizontal : .vertical
            lockedAxis = axis
            effects.append(.locked(axis))
        }

        guard let lockedAxis else {
            return effects
        }

        let displacement = lockedAxis == .horizontal ? dx : dy
        let velocity = lockedAxis == .horizontal ? velocityX : velocityY
        presentationOffset = resisted(displacement)

        guard let direction = thresholdDirection(displacement: displacement, velocity: velocity),
              canCommit(direction) else {
            return effects
        }

        if let firstThresholdDirection {
            if direction == firstThresholdDirection {
                pendingDirection = direction
            }
            return effects
        }

        firstThresholdDirection = direction
        pendingDirection = direction
        effects.append(.thresholdCrossed(direction))
        return effects
    }

    private func thresholdDirection(displacement: Double, velocity: Double) -> PageDirection? {
        let commitDistance = configuration.commitProgress * Self.semanticGestureDistance
        // Displacement is evaluated first so conflicting qualified signals have
        // one stable, documented precedence rule.
        if abs(displacement) >= commitDistance, displacement != 0 {
            return displacement > 0 ? .previous : .next
        }
        if abs(velocity) >= configuration.commitVelocity, velocity != 0 {
            return velocity > 0 ? .previous : .next
        }
        return nil
    }

    private func canCommit(_ direction: PageDirection) -> Bool {
        guard pageCount > 1 else {
            return false
        }
        switch direction {
        case .previous:
            return selectedIndex > 0
        case .next:
            return selectedIndex < pageCount - 1
        }
    }

    private func resisted(_ displacement: Double) -> Double {
        let movingBeforeFirst = displacement > 0 && selectedIndex == 0
        let movingAfterLast = displacement < 0 && selectedIndex == max(pageCount - 1, 0)
        let hasNoNavigableEdge = pageCount <= 1 && displacement != 0

        if movingBeforeFirst || movingAfterLast || hasNoNavigableEdge {
            return displacement * configuration.edgeResistance
        }
        return displacement
    }

    private mutating func finishGesture(allowCommit: Bool) -> [PageGestureEffect] {
        guard isGestureActive else {
            return []
        }

        let effects: [PageGestureEffect]
        if allowCommit, let pendingDirection, canCommit(pendingDirection) {
            switch pendingDirection {
            case .previous:
                selectedIndex -= 1
            case .next:
                selectedIndex += 1
            }
            effects = [.committed(index: selectedIndex), .snapped(index: selectedIndex)]
        } else {
            effects = [.cancelled(index: selectedIndex), .snapped(index: selectedIndex)]
        }

        resetTransientState()
        return effects
    }

    private mutating func resetTransientState() {
        lockedAxis = nil
        presentationOffset = 0
        pendingDirection = nil
        firstThresholdDirection = nil
        isGestureActive = false
    }
}
