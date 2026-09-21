import XCTest
@testable import PagedNavigationCore

final class PagedNavigationCoreTests: XCTestCase {
    let configuration = PageGestureConfiguration(
        axisLockDistance: 8,
        commitProgress: 0.22,
        commitVelocity: 720,
        edgeResistance: 0.32
    )

    func testHorizontalGestureLocksOnceAndCommitsOnePage() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)
        XCTAssertEqual(reducer.reduce(.changed(dx: 12, dy: 3, velocityX: 100, velocityY: 20)), [.locked(.horizontal)])
        XCTAssertEqual(reducer.reduce(.changed(dx: -30, dy: 40, velocityX: -900, velocityY: 900)), [.thresholdCrossed(.next)])
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 2), .snapped(index: 2)])
    }

    func testSubthresholdGestureCancelsAndEdgeDoesNotWrap() {
        var reducer = PageGestureReducer(pageCount: 2, selectedIndex: 0, configuration: configuration)
        _ = reducer.reduce(.changed(dx: 10, dy: 1, velocityX: 30, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.ended), [.cancelled(index: 0), .snapped(index: 0)])
        var edge = PageGestureReducer(pageCount: 2, selectedIndex: 0, configuration: configuration)
        _ = edge.reduce(.changed(dx: 20, dy: 0, velocityX: 900, velocityY: 0))
        XCTAssertEqual(edge.presentationOffset, 20 * configuration.edgeResistance)
        XCTAssertEqual(edge.reduce(.ended), [.cancelled(index: 0), .snapped(index: 0)])
    }

    func testVerticalGestureLocksAndCannotChangeAxisDuringGesture() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: 2, dy: -12, velocityX: 0, velocityY: -50)),
            [.locked(.vertical)]
        )
        XCTAssertEqual(
            reducer.reduce(.changed(dx: 40, dy: -10, velocityX: 900, velocityY: -20)),
            []
        )
        XCTAssertEqual(reducer.lockedAxis, .vertical)
        XCTAssertEqual(reducer.reduce(.ended), [.cancelled(index: 1), .snapped(index: 1)])
    }

    func testAxisTieLocksHorizontallyDeterministically() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: 9, dy: -9, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal)]
        )
    }

    func testAxisLockRequiresDistanceBeyondBoundary() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(reducer.reduce(.changed(dx: 8, dy: 0, velocityX: 0, velocityY: 0)), [])
        XCTAssertNil(reducer.lockedAxis)
        XCTAssertEqual(
            reducer.reduce(.changed(dx: 8.01, dy: 0, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal)]
        )
    }

    func testProgressAtExactBoundaryCrossesThreshold() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -22, dy: 0, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 2), .snapped(index: 2)])
    }

    func testVelocityAtExactBoundaryCommitsBelowProgressThreshold() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -9, dy: 0, velocityX: -720, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 2), .snapped(index: 2)])
    }

    func testPositiveDisplacementCommitsPreviousPage() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: 30, dy: 0, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.previous)]
        )
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 0), .snapped(index: 0)])
    }

    func testNegativeDisplacementCommitsNextPage() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -30, dy: 0, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 2), .snapped(index: 2)])
    }

    func testThresholdEventIsEmittedOnlyOnceAndGestureCommitsAtMostOnePage() {
        var reducer = PageGestureReducer(pageCount: 5, selectedIndex: 2, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -30, dy: 0, velocityX: -900, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.changed(dx: -300, dy: 0, velocityX: -2_000, velocityY: 0)), [])
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 3), .snapped(index: 3)])
    }

    func testReturningInsideThresholdDisarmsNextCommit() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -30, dy: 0, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.changed(dx: -10, dy: 0, velocityX: 0, velocityY: 0)), [])
        XCTAssertEqual(reducer.reduce(.ended), [.cancelled(index: 1), .snapped(index: 1)])
    }

    func testReversingPastPreviousThresholdCancelsFirstNextDirection() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -30, dy: 0, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.changed(dx: 30, dy: 0, velocityX: 0, velocityY: 0)), [])
        XCTAssertEqual(reducer.reduce(.ended), [.cancelled(index: 1), .snapped(index: 1)])
    }

    func testReturningToOriginalThresholdRearmsWithoutSecondThresholdEffect() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -30, dy: 0, velocityX: 0, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.changed(dx: -10, dy: 0, velocityX: 0, velocityY: 0)), [])
        XCTAssertEqual(reducer.reduce(.changed(dx: -30, dy: 0, velocityX: 0, velocityY: 0)), [])
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 2), .snapped(index: 2)])
    }

    func testDisplacementWinsWhenVelocityCrossesOppositeThreshold() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: -30, dy: 0, velocityX: 900, velocityY: 0)),
            [.locked(.horizontal), .thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 2), .snapped(index: 2)])
    }

    func testOutwardEdgeMovementCanReverseAndCommitInward() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 0, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: 30, dy: 0, velocityX: 900, velocityY: 0)),
            [.locked(.horizontal)]
        )
        XCTAssertEqual(reducer.presentationOffset, 9.6, accuracy: 0.000_001)
        XCTAssertEqual(
            reducer.reduce(.changed(dx: -30, dy: 0, velocityX: -900, velocityY: 0)),
            [.thresholdCrossed(.next)]
        )
        XCTAssertEqual(reducer.presentationOffset, -30)
        XCTAssertEqual(reducer.reduce(.ended), [.committed(index: 1), .snapped(index: 1)])
    }

    func testZeroAndOnePageCannotCommit() {
        var empty = PageGestureReducer(pageCount: 0, selectedIndex: 9, configuration: configuration)
        _ = empty.reduce(.changed(dx: -30, dy: 0, velocityX: -900, velocityY: 0))
        XCTAssertEqual(empty.selectedIndex, 0)
        XCTAssertEqual(empty.reduce(.ended), [.cancelled(index: 0), .snapped(index: 0)])

        var single = PageGestureReducer(pageCount: 1, selectedIndex: 9, configuration: configuration)
        _ = single.reduce(.changed(dx: -30, dy: 0, velocityX: -900, velocityY: 0))
        XCTAssertEqual(single.selectedIndex, 0)
        XCTAssertEqual(single.reduce(.ended), [.cancelled(index: 0), .snapped(index: 0)])
    }

    func testInitialSelectedIndexIsClampedToAvailablePages() {
        let below = PageGestureReducer(pageCount: 3, selectedIndex: -4, configuration: configuration)
        let above = PageGestureReducer(pageCount: 3, selectedIndex: 99, configuration: configuration)

        XCTAssertEqual(below.selectedIndex, 0)
        XCTAssertEqual(above.selectedIndex, 2)
    }

    func testCancelledInputDoesNotCommitAndResetsTransientState() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)
        _ = reducer.reduce(.changed(dx: -30, dy: 0, velocityX: -900, velocityY: 0))

        XCTAssertEqual(reducer.reduce(.cancelled), [.cancelled(index: 1), .snapped(index: 1)])
        XCTAssertEqual(reducer.selectedIndex, 1)
        XCTAssertNil(reducer.lockedAxis)
        XCTAssertEqual(reducer.presentationOffset, 0)
    }

    func testEndedGestureResetsStateSoNextGestureCanRelockAnotherAxis() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)
        _ = reducer.reduce(.changed(dx: 12, dy: 0, velocityX: 0, velocityY: 0))
        _ = reducer.reduce(.ended)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: 0, dy: -12, velocityX: 0, velocityY: 0)),
            [.locked(.vertical)]
        )
        XCTAssertEqual(reducer.lockedAxis, .vertical)
    }

    func testEdgeResistanceAppliesOnlyToOutwardMovement() {
        var first = PageGestureReducer(pageCount: 3, selectedIndex: 0, configuration: configuration)
        XCTAssertEqual(
            first.reduce(.changed(dx: 20, dy: 0, velocityX: 900, velocityY: 0)),
            [.locked(.horizontal)]
        )
        XCTAssertEqual(first.presentationOffset, 6.4, accuracy: 0.000_001)

        var last = PageGestureReducer(pageCount: 3, selectedIndex: 2, configuration: configuration)
        XCTAssertEqual(
            last.reduce(.changed(dx: -20, dy: 0, velocityX: -900, velocityY: 0)),
            [.locked(.horizontal)]
        )
        XCTAssertEqual(last.presentationOffset, -6.4, accuracy: 0.000_001)

        var inward = PageGestureReducer(pageCount: 3, selectedIndex: 0, configuration: configuration)
        _ = inward.reduce(.changed(dx: -20, dy: 0, velocityX: 0, velocityY: 0))
        XCTAssertEqual(inward.presentationOffset, -20)
    }

    func testInvalidConfigurationIsSanitizedDeterministically() {
        let invalid = PageGestureConfiguration(
            axisLockDistance: -.infinity,
            commitProgress: .nan,
            commitVelocity: -1,
            edgeResistance: 2
        )

        XCTAssertEqual(invalid.axisLockDistance, 0)
        XCTAssertEqual(invalid.commitProgress, 1)
        XCTAssertEqual(invalid.commitVelocity, .greatestFiniteMagnitude)
        XCTAssertEqual(invalid.edgeResistance, 0)

        let outOfRange = PageGestureConfiguration(
            axisLockDistance: -1,
            commitProgress: -0.01,
            commitVelocity: .nan,
            edgeResistance: -0.01
        )
        XCTAssertEqual(outOfRange.axisLockDistance, 0)
        XCTAssertEqual(outOfRange.commitProgress, 1)
        XCTAssertEqual(outOfRange.commitVelocity, .greatestFiniteMagnitude)
        XCTAssertEqual(outOfRange.edgeResistance, 0)

        let aboveRange = PageGestureConfiguration(
            axisLockDistance: 8,
            commitProgress: 1.01,
            commitVelocity: 720,
            edgeResistance: 1.01
        )
        XCTAssertEqual(aboveRange.commitProgress, 1)
        XCTAssertEqual(aboveRange.edgeResistance, 0)
    }

    func testNonFiniteChangedInputDoesNotActivateGesture() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(
            reducer.reduce(.changed(dx: .nan, dy: 0, velocityX: 0, velocityY: 0)),
            []
        )
        XCTAssertNil(reducer.lockedAxis)
        XCTAssertEqual(reducer.presentationOffset, 0)
        XCTAssertEqual(reducer.reduce(.ended), [])
    }

    func testRepeatedEndAndCancelAfterResetAreNoOps() {
        var reducer = PageGestureReducer(pageCount: 3, selectedIndex: 1, configuration: configuration)

        XCTAssertEqual(reducer.reduce(.ended), [])
        XCTAssertEqual(reducer.reduce(.cancelled), [])

        _ = reducer.reduce(.changed(dx: 12, dy: 0, velocityX: 0, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.ended), [.cancelled(index: 1), .snapped(index: 1)])
        XCTAssertEqual(reducer.reduce(.ended), [])
        XCTAssertEqual(reducer.reduce(.cancelled), [])
    }
}
