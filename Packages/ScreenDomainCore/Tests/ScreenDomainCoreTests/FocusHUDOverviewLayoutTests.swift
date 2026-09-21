import XCTest
@testable import ScreenDomainCore

final class FocusHUDOverviewLayoutTests: XCTestCase {
    func testRelaxedSparseLayoutStaysAtRelaxedMetricAndOneRow() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [3],
            constraints: constraints()
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.cellSize, 64)
        XCTAssertEqual(layout.workspaceLayouts, [workspace(appCount: 3, columns: 3, rows: 1, cellSize: 64)])
    }

    func testWidthPressureUsesTwoThenThreeRowsWithoutFourRows() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [4, 7],
            constraints: constraints(safeWidth: 264, safeHeight: 700, relaxedCellSize: 60, minimumCellSize: 60, horizontalGap: 10)
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.workspaceLayouts, [
            workspace(appCount: 4, columns: 2, rows: 2, cellSize: 60),
            workspace(appCount: 7, columns: 3, rows: 3, cellSize: 60)
        ])
    }

    func testMultipleWorkspacesShareCellSizeAndPreserveOrder() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [5, 0, 2],
            constraints: constraints()
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.workspaceLayouts.map(\.appCount), [5, 0, 2])
        XCTAssertEqual(Set(layout.workspaceLayouts.map(\.cellSize)), [layout.cellSize])
    }

    func testShrinksToLargestIntermediateSizeThatFits() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [7],
            constraints: constraints(safeWidth: 214, safeHeight: 700, relaxedCellSize: 70, minimumCellSize: 40, horizontalGap: 10)
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.cellSize, 43)
        XCTAssertEqual(layout.workspaceLayouts, [workspace(appCount: 7, columns: 3, rows: 3, cellSize: 43)])
    }

    func testCompleteStackDimensionsStayWithinPanelBounds() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [3, 4],
            constraints: constraints(safeWidth: 400, safeHeight: 600, relaxedCellSize: 60, minimumCellSize: 40)
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.panelWidth, 276)
        XCTAssertEqual(layout.panelHeight, 184)
    }

    func testUniformContentInsetIsIncludedInFinalPanelSizeAndSafeFit() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [3],
            constraints: constraints(
                safeWidth: 248,
                safeHeight: 132,
                outerMargin: 0,
                relaxedCellSize: 60,
                minimumCellSize: 60,
                horizontalGap: 10,
                groupHeaderHeight: 24,
                contentInset: 24
            )
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.contentInset, 24)
        XCTAssertEqual(layout.contentWidth, 200)
        XCTAssertEqual(layout.contentHeight, 84)
        XCTAssertEqual(layout.panelWidth, 248)
        XCTAssertEqual(layout.panelHeight, 132)
        XCTAssertEqual(layout.workspaceLayouts, [
            workspace(appCount: 3, columns: 3, rows: 1, cellSize: 60)
        ])
    }

    func testContentInsetThatCannotFitAtMinimumMetricFailsClosed() {
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(
                appCounts: [3],
                constraints: constraints(
                    safeWidth: 247,
                    safeHeight: 132,
                    outerMargin: 0,
                    relaxedCellSize: 60,
                    minimumCellSize: 60,
                    horizontalGap: 10,
                    groupHeaderHeight: 24,
                    contentInset: 24
                )
            ),
            .unavailable(.layoutUnavailable)
        )
    }

    func testEmptyWorkspaceHasNoFakeGridAndConsumesEmptyHeight() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [0],
            constraints: constraints(groupHeaderHeight: 24, emptyWorkspaceHeight: 88)
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.workspaceLayouts, [workspace(appCount: 0, columns: 0, rows: 0, cellSize: 64)])
        XCTAssertEqual(layout.panelHeight, 112)
        XCTAssertEqual(layout.panelWidth, 0)
    }

    func testEmptyWorkspaceUsesMinimumPanelWidth() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [0],
            constraints: constraints(minimumPanelWidth: 390)
        )

        XCTAssertEqual(try! XCTUnwrap(result.availableLayout).panelWidth, 390)
    }

    func testMinimumPanelWidthFailsClosedWhenSafeWidthCannotFitIt() {
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(
                appCounts: [0],
                constraints: constraints(safeWidth: 389, outerMargin: 0, minimumPanelWidth: 390)
            ),
            .unavailable(.layoutUnavailable)
        )
    }

    func testWiderAppGridWinsOverMinimumPanelWidth() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [3],
            constraints: constraints(minimumPanelWidth: 100)
        )

        XCTAssertEqual(try! XCTUnwrap(result.availableLayout).panelWidth, 216)
    }

    func testImpossibleBoundsOrExcessiveCountReturnsTypedUnavailable() {
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(
                appCounts: [1],
                constraints: constraints(safeWidth: 100, relaxedCellSize: 60, minimumCellSize: 60)
            ),
            .unavailable(.layoutUnavailable)
        )
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(
                appCounts: [1],
                constraints: constraints(safeHeight: 80, relaxedCellSize: 60, minimumCellSize: 60)
            ),
            .unavailable(.layoutUnavailable)
        )
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(
                appCounts: [10],
                constraints: constraints(safeWidth: 264, safeHeight: 700, relaxedCellSize: 60, minimumCellSize: 60, horizontalGap: 10)
            ),
            .unavailable(.layoutUnavailable)
        )
    }

    func testInvalidConstraintsAndNegativeCountsFailClosed() {
        let invalidConstraints = [
            constraints(safeWidth: .nan),
            constraints(safeHeight: .infinity),
            constraints(outerMargin: -1),
            constraints(horizontalGap: -1),
            constraints(verticalGap: -1),
            constraints(groupHeaderHeight: -1),
            constraints(emptyWorkspaceHeight: -1),
            constraints(groupGap: -1),
            constraints(minimumPanelWidth: -1),
            constraints(minimumPanelWidth: .infinity),
            constraints(contentInset: -1),
            constraints(contentInset: .infinity),
            constraints(relaxedCellSize: 40, minimumCellSize: 41)
        ]

        for invalid in invalidConstraints {
            XCTAssertEqual(
                FocusHUDOverviewLayoutEngine.compute(appCounts: [1], constraints: invalid),
                .unavailable(.layoutUnavailable)
            )
        }
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(appCounts: [-1], constraints: constraints()),
            .unavailable(.layoutUnavailable)
        )
    }

    func testIntMaxAppCountDoesNotTrapAndReturnsUnavailable() {
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(appCounts: [Int.max], constraints: constraints()),
            .unavailable(.layoutUnavailable)
        )
    }

    func testHugeRelaxedMetricStillEvaluatesExactMinimum() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [4],
            constraints: constraints(
                safeWidth: 194,
                safeHeight: 700,
                relaxedCellSize: 1e16,
                minimumCellSize: 60,
                horizontalGap: 10
            )
        )

        XCTAssertEqual(try! XCTUnwrap(result.availableLayout).cellSize, 60)
    }

    func testHugeLooseBoundsFindLargestOnePointPhaseCandidate() {
        let result = FocusHUDOverviewLayoutEngine.compute(
            appCounts: [3],
            constraints: constraints(
                safeWidth: 1e16,
                safeHeight: 1e16,
                outerMargin: 0,
                relaxedCellSize: 1e16,
                minimumCellSize: 1,
                horizontalGap: 0,
                verticalGap: 0,
                groupHeaderHeight: 0,
                emptyWorkspaceHeight: 0,
                groupGap: 0
            )
        )

        let layout = try! XCTUnwrap(result.availableLayout)
        XCTAssertEqual(layout.cellSize, 5_000_000_000_000_000)
        XCTAssertNotEqual(layout.cellSize, 1)
        XCTAssertEqual(
            FocusHUDOverviewLayoutEngine.compute(
                appCounts: [3],
                constraints: constraints(
                    safeWidth: 1e16,
                    safeHeight: 1e16,
                    outerMargin: 0,
                    relaxedCellSize: layout.cellSize + 1,
                    minimumCellSize: layout.cellSize + 1,
                    horizontalGap: 0,
                    verticalGap: 0,
                    groupHeaderHeight: 0,
                    emptyWorkspaceHeight: 0,
                    groupGap: 0
                )
            ),
            .unavailable(.layoutUnavailable)
        )
    }

    func testAvailableLayoutOnlyReturnsAvailableValue() {
        let available = FocusHUDOverviewLayoutEngine.compute(appCounts: [], constraints: constraints())
        XCTAssertNotNil(available.availableLayout)
        XCTAssertNil(FocusHUDOverviewLayoutResult.unavailable(.layoutUnavailable).availableLayout)
    }

    private func constraints(
        safeWidth: Double = 800,
        safeHeight: Double = 500,
        outerMargin: Double = 32,
        relaxedCellSize: Double = 64,
        minimumCellSize: Double = 40,
        horizontalGap: Double = 12,
        verticalGap: Double = 10,
        groupHeaderHeight: Double = 24,
        emptyWorkspaceHeight: Double = 80,
        groupGap: Double = 16,
        minimumPanelWidth: Double = 0,
        contentInset: Double = 0
    ) -> FocusHUDOverviewLayoutConstraints {
        FocusHUDOverviewLayoutConstraints(
            safeWidth: safeWidth,
            safeHeight: safeHeight,
            outerMargin: outerMargin,
            relaxedCellSize: relaxedCellSize,
            minimumCellSize: minimumCellSize,
            horizontalGap: horizontalGap,
            verticalGap: verticalGap,
            groupHeaderHeight: groupHeaderHeight,
            emptyWorkspaceHeight: emptyWorkspaceHeight,
            groupGap: groupGap,
            minimumPanelWidth: minimumPanelWidth,
            contentInset: contentInset
        )
    }

    private func workspace(appCount: Int, columns: Int, rows: Int, cellSize: Double) -> FocusHUDWorkspaceLayout {
        FocusHUDWorkspaceLayout(appCount: appCount, columnCount: columns, rowCount: rows, cellSize: cellSize)
    }
}
