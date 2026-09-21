import XCTest
@testable import ScreenDomainCore

final class FocusPaneReducerTests: XCTestCase {

    // MARK: - Helpers

    private func makeState() throws -> FocusScreenState {
        try FocusScreenReducer.bootstrap(currentWindows: [
            ManagedWindow(id: "w1", appID: "com.editor", canonicalFrame: CanvasRect(x: 0, y: 0, width: 400, height: 600)),
            ManagedWindow(id: "w2", appID: "com.browser", canonicalFrame: CanvasRect(x: 400, y: 0, width: 400, height: 600))
        ])
    }

    private func stateWithSplitLayout() throws -> FocusScreenState {
        var state = try makeState()
        state = try FocusPaneReducer.setLayout(.split, for: "screen-1", in: state)

        // Add tabs to both panes.
        state.screens[0].layout!.tabs["tab-1"] = FocusTab(id: "tab-1", windowID: "w1", state: .active)
        state.screens[0].layout!.panes[0].tabIDs = ["tab-1"]
        state.screens[0].layout!.panes[0].activeTabID = "tab-1"

        state.screens[0].layout!.tabs["tab-2"] = FocusTab(id: "tab-2", windowID: "w2", state: .active)
        state.screens[0].layout!.panes[1].tabIDs = ["tab-2"]
        state.screens[0].layout!.panes[1].activeTabID = "tab-2"

        return state
    }

    // MARK: - setLayout

    func testSetLayoutSplitCreatesTwoPanes() throws {
        let state = try makeState()
        let result = try FocusPaneReducer.setLayout(.split, for: "screen-1", in: state)

        let layout = try XCTUnwrap(result.screen(id: "screen-1")?.layout)
        XCTAssertEqual(layout.kind, .split)
        XCTAssertEqual(layout.panes.count, 2)
        XCTAssertEqual(layout.panes[0].id, "pane-1")
        XCTAssertEqual(layout.panes[1].id, "pane-2")
    }

    func testSetLayoutFocusStackCreatesThreePanes() throws {
        let state = try makeState()
        let result = try FocusPaneReducer.setLayout(.focusStack, for: "screen-1", in: state)

        let layout = try XCTUnwrap(result.screen(id: "screen-1")?.layout)
        XCTAssertEqual(layout.kind, .focusStack)
        XCTAssertEqual(layout.panes.count, 3)
    }

    func testSetLayoutAsIsClearsLayout() throws {
        var state = try makeState()
        state = try FocusPaneReducer.setLayout(.split, for: "screen-1", in: state)
        XCTAssertNotNil(state.screen(id: "screen-1")?.layout)

        state = try FocusPaneReducer.setLayout(.asIs, for: "screen-1", in: state)
        XCTAssertNil(state.screen(id: "screen-1")?.layout)
    }

    // MARK: - activateTab

    func testActivateTabSetsActiveAndDeactivatesOthers() throws {
        var state = try stateWithSplitLayout()
        // Add a second tab to pane-1.
        state.screens[0].layout!.tabs["tab-3"] = FocusTab(id: "tab-3", windowID: "w1", state: .inactive)
        state.screens[0].layout!.panes[0].tabIDs.append("tab-3")

        state = try FocusPaneReducer.activateTab("tab-3", in: "pane-1", screenID: "screen-1", state: state)

        let layout = state.screens[0].layout!
        XCTAssertEqual(layout.panes[0].activeTabID, "tab-3")
        XCTAssertEqual(layout.tabs["tab-3"]?.state, .active)
        XCTAssertEqual(layout.tabs["tab-1"]?.state, .inactive)
    }

    // MARK: - closeTab (right-neighbor-first rule)

    func testCloseActiveTabPrefersRightNeighbor() throws {
        var state = try stateWithSplitLayout()
        // Add tab-1 (active), tab-3 (right), tab-4 (further right) to pane-1.
        state.screens[0].layout!.tabs["tab-3"] = FocusTab(id: "tab-3", windowID: "w1", state: .inactive)
        state.screens[0].layout!.panes[0].tabIDs = ["tab-1", "tab-3"]

        // Close tab-1 (the active tab). Should prefer tab-3 (right neighbor).
        state = try FocusPaneReducer.closeTab("tab-1", in: "pane-1", screenID: "screen-1", state: state)

        let layout = state.screens[0].layout!
        XCTAssertFalse(layout.panes[0].tabIDs.contains("tab-1"))
        XCTAssertNil(layout.tabs["tab-1"])
        XCTAssertEqual(layout.panes[0].activeTabID, "tab-3")
        XCTAssertEqual(layout.tabs["tab-3"]?.state, .active)
    }

    func testCloseActiveTabFallsBackToLeftWhenNoRight() throws {
        var state = try stateWithSplitLayout()
        // pane-1: [tab-3, tab-1], tab-1 active.
        state.screens[0].layout!.tabs["tab-3"] = FocusTab(id: "tab-3", windowID: "w1", state: .inactive)
        state.screens[0].layout!.panes[0].tabIDs = ["tab-3", "tab-1"]

        state = try FocusPaneReducer.closeTab("tab-1", in: "pane-1", screenID: "screen-1", state: state)

        let layout = state.screens[0].layout!
        XCTAssertEqual(layout.panes[0].activeTabID, "tab-3")
        XCTAssertEqual(layout.tabs["tab-3"]?.state, .active)
    }

    func testCloseInactiveTabRemovesImmediately() throws {
        var state = try stateWithSplitLayout()
        state.screens[0].layout!.tabs["tab-3"] = FocusTab(id: "tab-3", windowID: "w1", state: .inactive)
        state.screens[0].layout!.panes[0].tabIDs = ["tab-1", "tab-3"]

        // Close inactive tab-3.
        state = try FocusPaneReducer.closeTab("tab-3", in: "pane-1", screenID: "screen-1", state: state)

        let layout = state.screens[0].layout!
        XCTAssertFalse(layout.panes[0].tabIDs.contains("tab-3"))
        // Active tab unchanged.
        XCTAssertEqual(layout.panes[0].activeTabID, "tab-1")
    }

    // MARK: - moveTab

    func testMoveTabToAnotherPane() throws {
        let state = try stateWithSplitLayout()
        // Move tab-1 from pane-1 to pane-2.
        let result = try FocusPaneReducer.moveTab("tab-1", to: "pane-2", screenID: "screen-1", state: state)

        let layout = result.screens[0].layout!
        XCTAssertFalse(layout.panes[0].tabIDs.contains("tab-1"))
        XCTAssertTrue(layout.panes[1].tabIDs.contains("tab-1"))
    }

    // MARK: - setPaneRatio

    func testSetPaneRatioUpdatesNormalizedRatio() throws {
        let state = try stateWithSplitLayout()
        let result = try FocusPaneReducer.setPaneRatio("pane-1", ratio: PaneRatio(primary: 0.7), screenID: "screen-1", state: state)

        let layout = result.screens[0].layout!
        XCTAssertEqual(layout.panes[0].ratio.primary, 0.7, accuracy: 0.0001)
    }

    // MARK: - downgradeToAsIs

    func testDowngradeToAsIsClearsLayout() throws {
        let state = try stateWithSplitLayout()
        let result = try FocusPaneReducer.downgradeToAsIs(screenID: "screen-1", in: state)
        XCTAssertNil(result.screen(id: "screen-1")?.layout)
    }

    // MARK: - Revision monotonicity

    func testPaneTransitionsBumpRevision() throws {
        let state = try makeState()
        let withLayout = try FocusPaneReducer.setLayout(.split, for: "screen-1", in: state)
        XCTAssertGreaterThan(withLayout.revision, state.revision)

        let withRatio = try FocusPaneReducer.setPaneRatio("pane-1", ratio: PaneRatio(primary: 0.7), screenID: "screen-1", state: withLayout)
        XCTAssertGreaterThan(withRatio.revision, withLayout.revision)
    }

    // MARK: - Errors

    func testActivateTabRejectsMissingPane() throws {
        let state = try stateWithSplitLayout()
        XCTAssertThrowsError(
            try FocusPaneReducer.activateTab("tab-1", in: "nonexistent", screenID: "screen-1", state: state)
        ) { error in
            XCTAssertEqual(error as? FocusPaneDomainError, .paneMissing("nonexistent"))
        }
    }

    func testMutateRejectsWhenLayoutNotSet() throws {
        let state = try makeState()  // no layout set
        XCTAssertThrowsError(
            try FocusPaneReducer.activateTab("tab-1", in: "pane-1", screenID: "screen-1", state: state)
        ) { error in
            XCTAssertEqual(error as? FocusPaneDomainError, .layoutNotSet)
        }
    }
}
