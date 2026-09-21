import XCTest
@testable import ScreenDomainCore

final class CanvasLayoutEngineTests: XCTestCase {

    private let region = CanvasRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - defaultRatio

    func testDefaultRatioForSplit() {
        let r = CanvasLayoutEngine.defaultRatio(for: .split)
        XCTAssertEqual(r.primary, 0.5, accuracy: 0.0001)
        XCTAssertNil(r.secondary)
    }

    func testDefaultRatioForFocusStack() {
        let r = CanvasLayoutEngine.defaultRatio(for: .focusStack)
        XCTAssertEqual(r.primary, 0.6, accuracy: 0.0001)
        XCTAssertEqual(r.secondary ?? -1, 0.5, accuracy: 0.0001)
    }

    // MARK: - Split layout computation

    func testSplitLayoutProducesTwoSideBySidePanes() {
        let result = CanvasLayoutEngine.compute(
            kind: .split,
            ratios: ["pane-1": PaneRatio(primary: 0.5), "pane-2": PaneRatio(primary: 0.5)],
            availableRegion: region
        )
        let left = result.paneFrames["pane-1"]!
        let right = result.paneFrames["pane-2"]!
        XCTAssertEqual(left.width, 500, accuracy: 1)
        XCTAssertEqual(right.width, 500, accuracy: 1)
        XCTAssertEqual(right.x, 500, accuracy: 1)
        XCTAssertEqual(left.height, 800, accuracy: 1)
        XCTAssertFalse(result.clamped)
    }

    func testSplitLayoutClampsToMinSize() {
        let result = CanvasLayoutEngine.compute(
            kind: .split,
            ratios: ["pane-1": PaneRatio(primary: 0.01), "pane-2": PaneRatio(primary: 0.99)],
            availableRegion: region,
            minSizes: ["pane-1": CGSize(width: 200, height: 100), "pane-2": CGSize(width: 200, height: 100)]
        )
        // The requested 1% left pane is below the 200px minimum, so it clamps.
        let left = result.paneFrames["pane-1"]!
        XCTAssertGreaterThanOrEqual(left.width, 199)
        XCTAssertTrue(result.clamped)
    }

    // MARK: - Focus+Stack layout computation

    func testFocusStackProducesThreePanes() {
        let result = CanvasLayoutEngine.compute(
            kind: .focusStack,
            ratios: [
                "pane-1": PaneRatio(primary: 0.6, secondary: 0.5),
                "pane-2": PaneRatio(primary: 0.4),
                "pane-3": PaneRatio(primary: 0.4)
            ],
            availableRegion: region
        )
        XCTAssertEqual(result.paneFrames.count, 3)
        let primary = result.paneFrames["pane-1"]!
        let top = result.paneFrames["pane-2"]!
        let bottom = result.paneFrames["pane-3"]!
        XCTAssertEqual(primary.width, 600, accuracy: 1)
        XCTAssertEqual(top.width, 400, accuracy: 1)
        XCTAssertEqual(bottom.width, 400, accuracy: 1)
        XCTAssertEqual(top.height, 400, accuracy: 1)
        XCTAssertEqual(bottom.height, 400, accuracy: 1)
    }

    // MARK: - No-oscillation settling

    func testSettleConflictingMinSizesAtMidpoint() {
        // leftMin=600, rightMin=600, total=1000 → conflict (1200 > 1000).
        let settled = CanvasLayoutEngine.settleConflictingMinSizes(
            leftMin: 600, rightMin: 600, total: 1000
        )
        XCTAssertEqual(settled, 500, accuracy: 0.01)
    }

    func testSettleNonConflictingMinSizesUsesLeftMin() {
        let settled = CanvasLayoutEngine.settleConflictingMinSizes(
            leftMin: 200, rightMin: 200, total: 1000
        )
        XCTAssertEqual(settled, 200, accuracy: 0.01)
    }

    // MARK: - clampToContinuousRegion delegates

    func testClampToContinuousRegion() {
        let regions = [CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 500, height: 800))]
        let frame = CanvasRect(x: 100, y: 100, width: 300, height: 400)
        let clamped = CanvasLayoutEngine.clampToContinuousRegion(frame, across: regions)
        // Frame already fits in r1 → unchanged.
        XCTAssertEqual(clamped, frame)
    }
}

final class GeometryNormalizationCoordinatorTests: XCTestCase {

    // MARK: - Resize normalization

    func testMatchingFrameNeedsNoRestoration() {
        let paneFrame = CanvasRect(x: 0, y: 0, width: 500, height: 400)
        let result = GeometryNormalizationCoordinator.normalize(
            observedFrame: paneFrame,
            paneFrame: paneFrame,
            resistanceCount: 0
        )
        XCTAssertNil(result.restoredFrame)
        XCTAssertFalse(result.declaredIncompatible)
    }

    func testMismatchedFrameRestoresCanonical() {
        let paneFrame = CanvasRect(x: 0, y: 0, width: 500, height: 400)
        let observed = CanvasRect(x: 0, y: 0, width: 300, height: 200)
        let result = GeometryNormalizationCoordinator.normalize(
            observedFrame: observed,
            paneFrame: paneFrame,
            resistanceCount: 0
        )
        XCTAssertEqual(result.restoredFrame, paneFrame)
        XCTAssertFalse(result.declaredIncompatible)
    }

    func testRepeatedResistanceDeclaresIncompatible() {
        let paneFrame = CanvasRect(x: 0, y: 0, width: 500, height: 400)
        let observed = CanvasRect(x: 0, y: 0, width: 300, height: 200)
        let result = GeometryNormalizationCoordinator.normalize(
            observedFrame: observed,
            paneFrame: paneFrame,
            resistanceCount: 3,
            threshold: 3
        )
        XCTAssertNil(result.restoredFrame)
        XCTAssertTrue(result.declaredIncompatible)
    }

    // MARK: - Minimized normalization

    func testMinimizedReturnsTargetFrame() {
        let paneFrame = CanvasRect(x: 0, y: 0, width: 500, height: 400)
        let result = GeometryNormalizationCoordinator.normalizeMinimized(
            observedMinimized: true,
            paneFrame: paneFrame
        )
        XCTAssertEqual(result, paneFrame)
    }

    func testNotMinimizedReturnsNil() {
        let paneFrame = CanvasRect(x: 0, y: 0, width: 500, height: 400)
        let result = GeometryNormalizationCoordinator.normalizeMinimized(
            observedMinimized: false,
            paneFrame: paneFrame
        )
        XCTAssertNil(result)
    }

    // MARK: - Special window detection

    func testPanelIsSpecialWindow() {
        XCTAssertTrue(GeometryNormalizationCoordinator.isSpecialWindow(
            isResizable: true, isPanel: true, isTransient: false, level: .floating
        ))
    }

    func testNonResizableIsSpecialWindow() {
        XCTAssertTrue(GeometryNormalizationCoordinator.isSpecialWindow(
            isResizable: false, isPanel: false, isTransient: false, level: .normal
        ))
    }

    func testNormalWindowIsNotSpecial() {
        XCTAssertFalse(GeometryNormalizationCoordinator.isSpecialWindow(
            isResizable: true, isPanel: false, isTransient: false, level: .normal
        ))
    }

    func testFloatingLevelIsSpecial() {
        XCTAssertTrue(GeometryNormalizationCoordinator.isSpecialWindow(
            isResizable: true, isPanel: false, isTransient: false, level: .floating
        ))
    }
}
