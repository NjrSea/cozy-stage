import XCTest
@testable import ScreenSwitcherApp

final class WorkspaceModelsTests: XCTestCase {
    func testInitialWorkspaceSelectsSwitchTabAndPointerDisplay() {
        let state = WorkspaceState(
            displayIDs: ["display-left", "display-pointer"],
            pointerDisplayID: "display-pointer"
        )

        XCTAssertEqual(state.selectedTab, .switch)
        XCTAssertEqual(state.displayPages.selectedDisplayID, "display-pointer")
    }

    func testInitialWorkspaceFallsBackToFirstDisplayWhenPointerDisplayIsUnavailable() {
        let state = WorkspaceState(
            displayIDs: ["display-left", "display-right"],
            pointerDisplayID: "display-missing"
        )

        XCTAssertEqual(state.displayPages.selectedDisplayID, "display-left")
    }

    func testOneDisplayHidesDisplayRail() {
        XCTAssertFalse(
            WorkspaceState(displayIDs: ["display-only"], pointerDisplayID: "display-only")
                .isDisplayRailVisible
        )
        XCTAssertTrue(
            WorkspaceState(displayIDs: ["display-left", "display-right"], pointerDisplayID: nil)
                .isDisplayRailVisible
        )
    }

    func testWorkspaceNormalizesDisplayIDsBeforePointerSelectionAndRailVisibility() {
        let state = WorkspaceState(
            displayIDs: ["", "display-left", "display-left", "display-right", ""],
            pointerDisplayID: "display-right"
        )

        XCTAssertEqual(state.displayIDs, ["display-left", "display-right"])
        XCTAssertEqual(state.displayPages.selectedDisplayID, "display-right")
        XCTAssertTrue(state.isDisplayRailVisible)

        let duplicateOnly = WorkspaceState(
            displayIDs: ["display-only", "display-only", ""],
            pointerDisplayID: ""
        )
        XCTAssertEqual(duplicateOnly.displayIDs, ["display-only"])
        XCTAssertEqual(duplicateOnly.displayPages.selectedDisplayID, "display-only")
        XCTAssertFalse(duplicateOnly.isDisplayRailVisible)
    }

    func testWorkspaceWithNoValidDisplayKeepsEmptySelectionWithoutSentinelPage() {
        let state = WorkspaceState(displayIDs: ["", ""], pointerDisplayID: "")

        XCTAssertEqual(state.displayIDs, [])
        XCTAssertEqual(state.displayPages.selectedDisplayID, "")
        XCTAssertEqual(state.displayPages.pageByDisplayID, [:])
        XCTAssertFalse(state.isDisplayRailVisible)
    }

    func testDisplaySelectionPreservesPageIndependentlyPerDisplay() {
        var pages = DisplayAppPageState(
            selectedDisplayID: "display-left",
            pageByDisplayID: [:]
        )

        pages.selectPage(2)
        pages.selectDisplay("display-right")
        XCTAssertEqual(pages.selectedPage, 0)
        pages.selectPage(1)
        pages.selectDisplay("display-left")
        XCTAssertEqual(pages.selectedPage, 2)
        pages.selectDisplay("display-right")
        XCTAssertEqual(pages.selectedPage, 1)
    }

    func testNegativePageSelectionUsesFirstPage() {
        var pages = DisplayAppPageState(
            selectedDisplayID: "display-left",
            pageByDisplayID: [:]
        )

        pages.selectPage(-4)

        XCTAssertEqual(pages.selectedPage, 0)
        XCTAssertEqual(pages.pageByDisplayID["display-left"], 0)
    }

    func testEmptyDisplaySelectionDoesNotCreateOrReplaceARealDisplayPage() {
        var empty = DisplayAppPageState(selectedDisplayID: "", pageByDisplayID: [:])
        XCTAssertEqual(empty.pageByDisplayID, [:])

        empty.selectDisplay("")
        empty.selectPage(4)
        XCTAssertEqual(empty.selectedDisplayID, "")
        XCTAssertEqual(empty.selectedPage, 0)
        XCTAssertEqual(empty.pageByDisplayID, [:])

        var selected = DisplayAppPageState(
            selectedDisplayID: "display-left",
            pageByDisplayID: ["display-left": 2]
        )
        selected.selectDisplay("")
        XCTAssertEqual(selected.selectedDisplayID, "display-left")
        XCTAssertEqual(selected.selectedPage, 2)
        XCTAssertEqual(selected.pageByDisplayID, ["display-left": 2])
    }

    func testGridUsesThreeRowsThenPaginatesWithPageLocalLetters() {
        let layout = AppGridLayout(availableWidth: 680, itemCount: 31)

        XCTAssertEqual(layout.columns, 10)
        XCTAssertEqual(layout.requiredRenderedWidth, 10 * 64 + 9 * 12)
        XCTAssertEqual(layout.pageCapacity, 26)
        XCTAssertEqual(layout.pageCount, 2)
        XCTAssertEqual(
            layout.items(onPage: 0).map(\.shortcut),
            Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
        )
        XCTAssertEqual(
            layout.items(onPage: 1).map(\.shortcut),
            ["A", "B", "C", "D", "E"]
        )
    }

    func testGridClampsColumnsAndPublishesStableSizingConstants() {
        let eightColumns = AppGridLayout(availableWidth: 64, itemCount: 1)
        let twelveColumns = AppGridLayout(availableWidth: 10_000, itemCount: 1)

        XCTAssertEqual(eightColumns.columns, 8)
        XCTAssertEqual(eightColumns.requiredRenderedWidth, 8 * 64 + 7 * 12)
        XCTAssertEqual(AppGridLayout(availableWidth: 576, itemCount: 1).columns, 9)
        XCTAssertEqual(twelveColumns.columns, 12)
        XCTAssertEqual(twelveColumns.requiredRenderedWidth, 12 * 64 + 11 * 12)
        XCTAssertEqual(AppGridLayout.cellSize, 64)
        XCTAssertEqual(AppGridLayout.minimumColumnGap, 12)
        XCTAssertGreaterThanOrEqual(AppGridLayout.iconSize, 48)
    }

    func testGridUsesOneToThreeRowsAndLeftAlignsLastRow() {
        let oneRow = AppGridLayout(availableWidth: 512, itemCount: 4)
        let twoRows = AppGridLayout(availableWidth: 512, itemCount: 10)
        let threeRows = AppGridLayout(availableWidth: 512, itemCount: 23)

        XCTAssertEqual(oneRow.rowCount(onPage: 0), 1)
        XCTAssertEqual(twoRows.rowCount(onPage: 0), 2)
        XCTAssertEqual(threeRows.rowCount(onPage: 0), 3)
        XCTAssertEqual(
            twoRows.items(onPage: 0).suffix(2).map(\.column),
            [0, 1]
        )
    }

    func testGridUsesRowMajorOrdering() {
        let layout = AppGridLayout(availableWidth: 512, itemCount: 10)
        let items = layout.items(onPage: 0)

        XCTAssertEqual(items.map(\.absoluteIndex), Array(0..<10))
        XCTAssertEqual(items.map(\.row), [0, 0, 0, 0, 0, 0, 0, 0, 1, 1])
        XCTAssertEqual(items.map(\.column), [0, 1, 2, 3, 4, 5, 6, 7, 0, 1])
    }

    func testEmptyAndInvalidPageRequestsAreSafe() {
        let empty = AppGridLayout(availableWidth: 680, itemCount: 0)
        let populated = AppGridLayout(availableWidth: 680, itemCount: 5)

        XCTAssertEqual(empty.pageCount, 0)
        XCTAssertEqual(empty.rowCount(onPage: 0), 0)
        XCTAssertEqual(empty.items(onPage: 0), [])
        XCTAssertEqual(populated.items(onPage: -1), [])
        XCTAssertEqual(populated.items(onPage: 1), [])
    }

    func testInvalidWidthAndNegativeItemCountUseDeterministicSafeValues() {
        for width in [Double.nan, Double.infinity, -Double.infinity, -1] {
            let layout = AppGridLayout(availableWidth: width, itemCount: -8)
            XCTAssertEqual(layout.columns, 8)
            XCTAssertEqual(layout.pageCapacity, 24)
            XCTAssertEqual(layout.pageCount, 0)
            XCTAssertEqual(layout.items(onPage: 0), [])
        }
    }

    func testVeryLargeItemCountAvoidsIntegerOverflow() {
        let layout = AppGridLayout(availableWidth: 680, itemCount: .max)
        let lastPage = layout.pageCount - 1
        let lastItems = layout.items(onPage: lastPage)

        XCTAssertEqual(layout.pageCount, 1 + (Int.max - 1) / 26)
        XCTAssertFalse(lastItems.isEmpty)
        XCTAssertLessThanOrEqual(lastItems.count, 26)
        XCTAssertEqual(lastItems.last?.absoluteIndex, Int.max - 1)
    }
}
