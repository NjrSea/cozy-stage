import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class PointerCoordinatorTests: XCTestCase {
    private func makeRegions() -> [FocusSemanticCanvasRegion] {
        [
            FocusSemanticCanvasRegion(
                id: "region-left",
                frame: CanvasRect(x: 0, y: 0, width: 1_000, height: 1_000),
                scale: 1
            ),
            FocusSemanticCanvasRegion(
                id: "region-right",
                frame: CanvasRect(x: 1_000, y: 0, width: 1_000, height: 1_000),
                scale: 1
            )
        ]
    }

    func testSameRegionTargetProducesUnchanged() {
        // Pointer is already in the left region; the target's center is also in the left region.
        // No pointer move is required.
        let coordinator = PointerCoordinator(
            location: { CanvasPoint(x: 250, y: 250) },
            move: { _ in true }
        )
        let targetFrame = CanvasRect(x: 100, y: 100, width: 300, height: 200)

        let result = coordinator.landIfRequired(
            targetFrame: targetFrame,
            regions: makeRegions()
        )

        XCTAssertEqual(result, .unchanged)
    }

    func testCrossRegionTargetMovesToTargetFrameCenter() {
        // Pointer sits in the left region; the target lives in the right region.
        // The coordinator must move the pointer to the target frame's exact center.
        let targetFrame = CanvasRect(x: 1_100, y: 100, width: 300, height: 200)
        let expectedCenter = targetFrame.center
        var capturedDestination: CanvasPoint?

        let coordinator = PointerCoordinator(
            location: { CanvasPoint(x: 250, y: 250) },
            move: { destination in
                capturedDestination = destination
                return true
            }
        )

        let result = coordinator.landIfRequired(
            targetFrame: targetFrame,
            regions: makeRegions()
        )

        XCTAssertEqual(result, .moved(expectedCenter))
        XCTAssertEqual(capturedDestination, expectedCenter)
    }

    func testNilTargetFrameProducesSkipped() {
        // Missing geometry for the target window means there is no place to land.
        let coordinator = PointerCoordinator(
            location: { CanvasPoint(x: 250, y: 250) },
            move: { _ in true }
        )

        let result = coordinator.landIfRequired(
            targetFrame: nil,
            regions: makeRegions()
        )

        XCTAssertEqual(result, .skipped)
    }

    func testMissingCurrentLocationProducesSkipped() {
        // If the pointer location cannot be read, landing cannot be decided.
        let coordinator = PointerCoordinator(
            location: { nil },
            move: { _ in true }
        )
        let targetFrame = CanvasRect(x: 1_100, y: 100, width: 300, height: 200)

        let result = coordinator.landIfRequired(
            targetFrame: targetFrame,
            regions: makeRegions()
        )

        XCTAssertEqual(result, .skipped)
    }

    func testCurrentLocationOutsideAnyRegionProducesSkipped() {
        // Pointer is somewhere off-canvas (no region claims it); the policy must
        // skip rather than guess the originating region.
        let coordinator = PointerCoordinator(
            location: { CanvasPoint(x: -5_000, y: -5_000) },
            move: { _ in true }
        )
        let targetFrame = CanvasRect(x: 1_100, y: 100, width: 300, height: 200)

        let result = coordinator.landIfRequired(
            targetFrame: targetFrame,
            regions: makeRegions()
        )

        XCTAssertEqual(result, .skipped)
    }

    func testMoveFailureReturnsDegraded() {
        // The pointer move was requested but the platform reported failure. The
        // focus attempt itself is not invalidated; landing simply degrades.
        let targetFrame = CanvasRect(x: 1_100, y: 100, width: 300, height: 200)
        let coordinator = PointerCoordinator(
            location: { CanvasPoint(x: 250, y: 250) },
            move: { _ in false }
        )

        let result = coordinator.landIfRequired(
            targetFrame: targetFrame,
            regions: makeRegions()
        )

        XCTAssertEqual(result, .degraded)
    }

    func testDegradedDoesNotSuppressPriorMoveAttempt() {
        // A failed move must still have requested the correct destination, so a
        // degraded result is observable alongside the attempted center.
        let targetFrame = CanvasRect(x: 1_100, y: 100, width: 300, height: 200)
        let expectedCenter = targetFrame.center
        var attemptedDestination: CanvasPoint?
        let coordinator = PointerCoordinator(
            location: { CanvasPoint(x: 250, y: 250) },
            move: { destination in
                attemptedDestination = destination
                return false
            }
        )

        let result = coordinator.landIfRequired(
            targetFrame: targetFrame,
            regions: makeRegions()
        )

        XCTAssertEqual(result, .degraded)
        XCTAssertEqual(attemptedDestination, expectedCenter)
    }

    func testBoundaryContainmentIsHalfOpenAtFarEdge() {
        // The far edge of a region (x + width) must NOT be considered contained,
        // because containment is half-open: [x, x+width) x [y, y+height).
        // A target whose center lands exactly on the far edge belongs to the
        // next region (or none), not to this one.
        let regions = makeRegions()
        let leftRegion = regions[0]
        let farEdgePoint = CanvasPoint(
            x: leftRegion.frame.x + leftRegion.frame.width,
            y: leftRegion.frame.y
        )

        XCTAssertFalse(leftRegion.frame.contains(farEdgePoint))
    }

    func testOriginIsContained() {
        // The rect's own origin (top-left corner) IS contained (closed lower bound).
        let region = makeRegions()[0]
        let origin = CanvasPoint(x: region.frame.x, y: region.frame.y)

        XCTAssertTrue(region.frame.contains(origin))
    }
}
