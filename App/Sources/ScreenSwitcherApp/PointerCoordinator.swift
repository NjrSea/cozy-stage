import Foundation
import ScreenDomainCore

/// The outcome of an exact-window pointer landing attempt.
///
/// Landing is advisory: a `.degraded` or `.skipped` result never invalidates an
/// otherwise-successful focus. It only signals whether the pointer was actually
/// relocated to the target window's center.
enum PointerLandingResult: Equatable {
    /// The pointer already shares a region with the target; no move was required.
    case unchanged
    /// The pointer was relocated to the target window's exact center.
    case moved(CanvasPoint)
    /// Required geometry was unavailable, so landing could not be decided.
    case skipped
    /// A move was required and attempted, but the platform reported failure.
    /// The preceding focus result is preserved.
    case degraded
}

/// Moves the pointer to the focused window's exact center when the target lives
/// in a different canvas region than the pointer's current position.
///
/// This is the "exact-window pointer landing" half of the focus contract: when a
/// screen switch targets a specific window, the pointer must follow into that
/// window's region so subsequent clicks land on the right surface. The decision
/// is driven entirely by `FocusSemanticCanvasRegion` membership — stitched
/// canvas regions are disjoint at their borders (half-open `CanvasRect.contains`),
/// so each point resolves to at most one region.
@MainActor
final class PointerCoordinator {
    private let location: () -> CanvasPoint?
    private let move: (CanvasPoint) -> Bool

    init(location: @escaping () -> CanvasPoint?, move: @escaping (CanvasPoint) -> Bool) {
        self.location = location
        self.move = move
    }

    func landIfRequired(
        targetFrame: CanvasRect?,
        regions: [FocusSemanticCanvasRegion]
    ) -> PointerLandingResult {
        guard let targetFrame,
              let current = location(),
              let currentRegion = regions.first(where: { $0.frame.contains(current) }),
              let targetRegion = regions.first(where: { $0.frame.contains(targetFrame.center) })
        else { return .skipped }
        guard currentRegion.id != targetRegion.id else { return .unchanged }
        return move(targetFrame.center) ? .moved(targetFrame.center) : .degraded
    }
}
