import XCTest
@testable import ScreenDomainCore

final class FocusWindowRouterTests: XCTestCase {

    // MARK: - Helpers

    private func makeState(
        screens: [(FocusScreenID, Int, FocusScreenLifecycle, [ManagedWindowID])] = [],
        windows: [(ManagedWindowID, String)] = [],  // (id, appID)
        savedSpaces: [SavedSpace] = []
    ) throws -> FocusScreenState {
        let windowMap = windows.reduce(into: [ManagedWindowID: ManagedWindow]()) { acc, pair in
            acc[pair.0] = ManagedWindow(
                id: pair.0,
                appID: pair.1,
                canonicalFrame: CanvasRect(x: 0, y: 0, width: 100, height: 100)
            )
        }
        let screenModels = screens.map { FocusScreen(id: $0.0, number: $0.1, lifecycle: $0.2, windowIDs: $0.3) }
        let activeID = screens.first(where: { $0.2 == .active })?.0 ?? screens[0].0
        return FocusScreenState(
            screens: screenModels,
            windows: windowMap,
            activeScreenID: activeID,
            inspectedScreenID: activeID,
            revision: 1,
            savedSpaces: savedSpaces
        )
    }

    // MARK: - Priority 1: explicit Pane intent

    func testExplicitPaneOverridesEverything() throws {
        let state = try makeState(
            screens: [("screen-1", 1, .active, ["w1"]), ("screen-2", 2, .background, [])],
            windows: [("w1", "com.editor")]
        )
        let decision = FocusWindowRouter.route(
            bundleID: "com.new",
            state: state,
            explicitScreenID: "screen-2"
        )
        XCTAssertEqual(decision?.targetScreenID, "screen-2")
        XCTAssertEqual(decision?.reason, .explicitPane)
    }

    // MARK: - Priority 2: pending Saved Space slot

    func testPendingSlotRoutesToOpenSpace() throws {
        let space = SavedSpace(
            id: "space-1",
            number: 1,
            lifecycle: .open,
            appSlots: [LogicalWindowSlot(id: "slot-1", bundleID: "com.new", status: .unresolved)],
            boundScreenID: "screen-2"
        )
        let state = try makeState(
            screens: [("screen-1", 1, .active, []), ("screen-2", 2, .background, [])],
            savedSpaces: [space]
        )
        let decision = FocusWindowRouter.route(
            bundleID: "com.new",
            state: state,
            pendingSlotID: "slot-1"
        )
        XCTAssertEqual(decision?.targetScreenID, "screen-2")
        XCTAssertEqual(decision?.reason, .pendingSlot)
    }

    // MARK: - Priority 3: App route

    func testAppRouteRoutesToOpenSpaceScreen() throws {
        let space = SavedSpace(
            id: "space-1",
            number: 1,
            lifecycle: .open,
            routingRules: [RoutingRule(bundleID: "com.new", spaceID: "space-1")],
            boundScreenID: "screen-2"
        )
        let state = try makeState(
            screens: [("screen-1", 1, .active, []), ("screen-2", 2, .background, [])],
            savedSpaces: [space]
        )
        let decision = FocusWindowRouter.route(bundleID: "com.new", state: state)
        XCTAssertEqual(decision?.targetScreenID, "screen-2")
        XCTAssertEqual(decision?.reason, .appRoute)
    }

    func testAppRouteDoesNotSilentlyRestoreClosedSpace() throws {
        let space = SavedSpace(
            id: "space-1",
            number: 1,
            lifecycle: .restorable,
            routingRules: [RoutingRule(bundleID: "com.new", spaceID: "space-1")]
        )
        let state = try makeState(
            screens: [("screen-1", 1, .active, [])],
            savedSpaces: [space]
        )
        let decision = FocusWindowRouter.route(bundleID: "com.new", state: state)
        // Falls back to active Screen, carrying the closed Space ID for a notice.
        XCTAssertEqual(decision?.targetScreenID, "screen-1")
        XCTAssertEqual(decision?.reason, .activeScreenDefault)
        XCTAssertEqual(decision?.closedSpaceFallbackID, "space-1")
    }

    // MARK: - Priority 4: same-App in Active Screen

    func testSameAppActiveScreenRoutesToActive() throws {
        let state = try makeState(
            screens: [("screen-1", 1, .active, ["w1"])],
            windows: [("w1", "com.editor")]
        )
        let decision = FocusWindowRouter.route(bundleID: "com.editor", state: state)
        XCTAssertEqual(decision?.targetScreenID, "screen-1")
        XCTAssertEqual(decision?.reason, .sameAppActiveScreen)
    }

    // MARK: - Priority 5: App's only open Screen

    func testAppOnlyOpenScreenRoutesThere() throws {
        let state = try makeState(
            screens: [("screen-1", 1, .active, []), ("screen-2", 2, .background, ["w1"])],
            windows: [("w1", "com.editor")]
        )
        let decision = FocusWindowRouter.route(bundleID: "com.editor", state: state)
        XCTAssertEqual(decision?.targetScreenID, "screen-2")
        XCTAssertEqual(decision?.reason, .appOnlyOpenScreen)
    }

    // MARK: - Priority 6: active Screen default

    func testAmbiguousWindowJoinsActiveDefault() throws {
        let state = try makeState(
            screens: [("screen-1", 1, .active, ["w1"]), ("screen-2", 2, .background, ["w2"])],
            windows: [("w1", "com.a"), ("w2", "com.b")]
        )
        // com.new doesn't match any rule, isn't in any screen, isn't routed.
        let decision = FocusWindowRouter.route(bundleID: "com.new", state: state)
        XCTAssertEqual(decision?.targetScreenID, "screen-1")
        XCTAssertEqual(decision?.reason, .activeScreenDefault)
        XCTAssertNil(decision?.closedSpaceFallbackID)
    }

    // MARK: - Returns nil without active Screen

    func testReturnsNilWithoutActiveScreen() throws {
        // A state with no screens — routing can't decide.
        let state = FocusScreenState(
            screens: [],
            windows: [:],
            activeScreenID: "screen-1",
            inspectedScreenID: "screen-1",
            revision: 1
        )
        XCTAssertNil(FocusWindowRouter.route(bundleID: "com.x", state: state))
    }

    // MARK: - Precedence ordering

    func testExplicitPaneBeatsAppRoute() throws {
        let space = SavedSpace(
            id: "space-1",
            number: 1,
            lifecycle: .open,
            routingRules: [RoutingRule(bundleID: "com.new", spaceID: "space-1")],
            boundScreenID: "screen-2"
        )
        let state = try makeState(
            screens: [("screen-1", 1, .active, []), ("screen-2", 2, .background, []), ("screen-3", 3, .background, [])],
            savedSpaces: [space]
        )
        let decision = FocusWindowRouter.route(
            bundleID: "com.new",
            state: state,
            explicitScreenID: "screen-3"
        )
        XCTAssertEqual(decision?.reason, .explicitPane)
        XCTAssertEqual(decision?.targetScreenID, "screen-3")
    }

    func testAppRouteBeatsSameAppActiveScreen() throws {
        let space = SavedSpace(
            id: "space-1",
            number: 1,
            lifecycle: .open,
            routingRules: [RoutingRule(bundleID: "com.editor", spaceID: "space-1")],
            boundScreenID: "screen-2"
        )
        let state = try makeState(
            screens: [("screen-1", 1, .active, ["w1"]), ("screen-2", 2, .background, [])],
            windows: [("w1", "com.editor")],
            savedSpaces: [space]
        )
        let decision = FocusWindowRouter.route(bundleID: "com.editor", state: state)
        XCTAssertEqual(decision?.reason, .appRoute)
        XCTAssertEqual(decision?.targetScreenID, "screen-2")
    }
}
