import AppKit
import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class FocusHUDViewModelTests: XCTestCase {
    private var metadata: FixtureWindowMetadataProvider!
    private var dispatched: [FocusHUDOverviewIntent] = []

    override func setUp() {
        super.setUp()
        metadata = FixtureWindowMetadataProvider()
        dispatched = []
    }

    func testSnapshotKeepsEveryWorkspaceInStateOrderAndMarksOnlyActive() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", number: 7, windows: ["w1"]), screen("two", number: 2, windows: []), screen("three", number: 9, windows: ["w2"])], active: "two"))
        try present(viewModel)
        // Empty workspaces are filtered out of the snapshot
        XCTAssertEqual(viewModel.snapshot?.sections.map(\.id), ["one", "three"])
        XCTAssertEqual(viewModel.snapshot?.sections.map(\.ordinal), [7, 9])
        XCTAssertEqual(viewModel.snapshot?.sections.map(\.isCurrent), [false, false])
    }

    func testGlobalLowercaseShortcutsCrossWorkspaceBoundary() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1", "w2"]), screen("two", windows: ["w3"])], active: "one"))
        try present(viewModel)
        XCTAssertEqual(viewModel.snapshot?.sections.flatMap(\.apps).map { $0.shortcut?.label }, ["a", "b", "c"])
    }

    func testAppCollapsesPerWorkspaceUsingLastActiveButNotAcrossWorkspaces() throws {
        var first = screen("one", windows: ["w1", "w2", "w3"])
        first.lastActiveWindowID = "w2"
        let viewModel = makeViewModel(state: state(screens: [first, screen("two", windows: ["w4"])], active: "one", windows: [window("w1", app: "a"), window("w2", app: "a"), window("w3", app: "b"), window("w4", app: "a")]))
        try present(viewModel)
        XCTAssertEqual(viewModel.snapshot?.sections[0].apps.map(\.id), ["w2", "w3"])
        XCTAssertEqual(viewModel.snapshot?.sections[1].apps.map(\.id), ["w4"])
    }

    func testStaleLastActiveFromAnotherWorkspaceDoesNotReplaceRepresentative() throws {
        var first = screen("one", windows: ["w1"])
        first.lastActiveWindowID = "w2"
        let viewModel = makeViewModel(state: state(
            screens: [first, screen("two", windows: ["w2"])], active: "one",
            windows: [window("w1", app: "app.x"), window("w2", app: "app.x")]
        ))
        try present(viewModel)

        XCTAssertEqual(viewModel.snapshot?.sections[0].apps.map(\.id), ["w1"])
        XCTAssertEqual(viewModel.snapshot?.sections[1].apps.map(\.id), ["w2"])
    }

    func testVisibleUpdateFreezesSnapshotAndDismissReopenConsumesPendingState() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1"])], active: "one", revision: 4))
        try present(viewModel, inventoryRevision: 40)
        let frozen = try XCTUnwrap(viewModel.snapshot)
        viewModel.update(state: state(screens: [screen("later", windows: ["w2"])], active: "later", revision: 5))
        XCTAssertEqual(viewModel.snapshot, frozen)
        XCTAssertEqual(viewModel.focusedWindowID, "w1")
        viewModel.dismiss()
        try present(viewModel, inventoryRevision: 50)
        XCTAssertEqual(viewModel.snapshot?.sections.map(\.id), ["later"])
        XCTAssertEqual(viewModel.snapshot?.inventoryRevision, 50)
        XCTAssertEqual(viewModel.snapshot?.keyAssignmentRevision, frozen.keyAssignmentRevision + 1)
        XCTAssertEqual(viewModel.snapshot?.presentationRevision, frozen.presentationRevision + 1)
    }

    func testActiveWorkspaceChangeDoesNotReorderSections() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1"]), screen("two", windows: ["w2"])], active: "one"))
        try present(viewModel)
        viewModel.dismiss()
        viewModel.update(state: state(screens: [screen("one", windows: ["w1"]), screen("two", windows: ["w2"])], active: "two"))
        try present(viewModel)
        XCTAssertEqual(viewModel.snapshot?.sections.map(\.id), ["one", "two"])
        XCTAssertEqual(viewModel.snapshot?.sections.map(\.isCurrent), [false, true])
    }

    func testAppOrderStaysFixedAcrossWindowIdentityReplacement() throws {
        let viewModel = makeViewModel(state: state(
            screens: [screen("one", windows: ["b1", "a1"])],
            active: "one",
            windows: [window("b1", app: "app.b"), window("a1", app: "app.a")]
        ))
        try present(viewModel)
        XCTAssertEqual(
            viewModel.snapshot?.sections[0].apps.map(\.appIdentityHash),
            ["hash:app.a", "hash:app.b"]
        )

        viewModel.dismiss()
        viewModel.update(state: state(
            screens: [screen("one", windows: ["a2", "b2"])],
            active: "one",
            windows: [window("a2", app: "app.a"), window("b2", app: "app.b")]
        ))
        try present(viewModel)

        XCTAssertEqual(
            viewModel.snapshot?.sections[0].apps.map(\.appIdentityHash),
            ["hash:app.a", "hash:app.b"]
        )
    }

    func testLayoutRowsFreezeAndJaggedNavigationOnlyMovesLocalFocus() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1", "w2"]), screen("two", windows: ["w3"])], active: "one"))
        try present(viewModel)
        let frozen = try XCTUnwrap(viewModel.snapshot)
        XCTAssertEqual(viewModel.handle(key: .down), .focusWindow("w3"))
        XCTAssertEqual(viewModel.focusedWindowID, "w3")
        XCTAssertTrue(dispatched.isEmpty)
        viewModel.update(state: state(screens: [screen("changed", windows: ["w4"])], active: "changed"))
        XCTAssertEqual(viewModel.snapshot, frozen)
    }

    func testDirectionalNavigationStartsFromTheVisibleCurrentWindow() throws {
        let viewModel = makeViewModel(state: state(screens: [
            screen("ordinary", number: 1, windows: ["ordinary-window"]),
            screen("fullscreen", number: 2, windows: ["fullscreen-window"]),
            screen("unrelated", number: 3, windows: ["unrelated-window"]),
        ], active: "ordinary"))
        try present(viewModel)

        XCTAssertEqual(viewModel.focusedWindowID, "ordinary-window")
        XCTAssertEqual(viewModel.handle(key: .down), .focusWindow("fullscreen-window"))
        XCTAssertEqual(viewModel.handle(key: .returnKey), .activateWindow("fullscreen-window"))
        XCTAssertEqual(dispatched, [.activateWindow("fullscreen-window")])
    }

    func testInteractionRevisionAdvancesOnlyWhenFocusedIdentityActuallyChanges() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1", "w2"])], active: "one"))
        try present(viewModel)
        XCTAssertEqual(viewModel.interactionRevision, 0)

        XCTAssertEqual(viewModel.handle(key: .left), .focusWindow("w1"))
        XCTAssertEqual(viewModel.interactionRevision, 1)
        _ = viewModel.handle(key: .left)
        XCTAssertEqual(viewModel.interactionRevision, 1, "same focus identity is a no-op")

        viewModel.dismiss()
        try present(viewModel)
        XCTAssertEqual(viewModel.interactionRevision, 1, "presentation lifecycle must not fabricate interaction")
    }

    func testInteractionRevisionExhaustionNeverWrapsOrCrashes() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1", "w2"])], active: "one"))
        try present(viewModel)
        viewModel.setInteractionRevisionForTest(.max)

        XCTAssertEqual(viewModel.handle(key: .left), .none)
        XCTAssertEqual(viewModel.interactionRevision, .max)
        XCTAssertEqual(viewModel.focusedWindowID, "w2")
    }

    func testPointerHoverPublishesContentFreeVisibleNameTruthWithMonotonicRevision() throws {
        let viewModel = makeViewModel(state: state(
            screens: [screen("one", windows: ["w1"])],
            active: "one"
        ))
        try present(viewModel)

        XCTAssertEqual(viewModel.hoverRevision, 0)
        XCTAssertEqual(viewModel.visibleNameCount, 1)
        XCTAssertEqual(viewModel.nameFocusSource, .keyboardFocus)

        viewModel.setHoveredWindowID("w1")

        XCTAssertEqual(viewModel.hoverRevision, 1)
        XCTAssertEqual(viewModel.visibleNameCount, 1)
        XCTAssertEqual(viewModel.nameFocusSource, .pointerHover)
        XCTAssertEqual(viewModel.renderedHoverRevision, 0, "state delivery is not render acknowledgement")
        viewModel.acknowledgeRenderedHover(
            presentationRevision: 999,
            hoverRevision: 1
        )
        XCTAssertEqual(viewModel.renderedHoverRevision, 0)
        viewModel.acknowledgeRenderedHover(
            presentationRevision: try XCTUnwrap(viewModel.snapshot?.presentationRevision),
            hoverRevision: 1
        )
        XCTAssertEqual(viewModel.renderedHoverRevision, 1)
        viewModel.setHoveredWindowID("w1")
        XCTAssertEqual(viewModel.hoverRevision, 1, "same delivered hover is a no-op")

        viewModel.setHoveredWindowID(nil)
        XCTAssertEqual(viewModel.hoverRevision, 2)
        XCTAssertEqual(viewModel.visibleNameCount, 1)
        XCTAssertEqual(viewModel.nameFocusSource, .keyboardFocus)
    }

    func testRenderedHUDStateAcknowledgesOnlyCurrentPresentationAndInteraction() throws {
        let viewModel = makeViewModel(state: state(
            screens: [screen("one", windows: ["w1"]), screen("empty", windows: [])],
            active: "one"
        ))
        try present(viewModel, constraints: .init(
            safeWidth: 100,
            safeHeight: 200,
            outerMargin: 0,
            relaxedCellSize: 40,
            minimumCellSize: 40,
            horizontalGap: 4,
            verticalGap: 4,
            groupHeaderHeight: 24,
            emptyWorkspaceHeight: 24,
            groupGap: 8,
            minimumPanelWidth: 0,
            contentInset: 0
        ))
        let presentationRevision = try XCTUnwrap(viewModel.snapshot?.presentationRevision)
        let state = FocusHUDRenderedState(
            layoutState: .overview,
            cellSize: 40,
            visibleIconSize: 32,
            nameFontSize: 8,
            badgeSize: 16,
            badgeFontSize: 10,
            appTargetCount: 1,
            dismissTargetCount: 0,
            emptyWorkspaceCount: 1
        )

        viewModel.acknowledgeRenderedHUD(
            presentationRevision: presentationRevision + 1,
            interactionRevision: 0,
            state: state
        )
        XCTAssertEqual(viewModel.renderedPresentationRevision, 0)
        viewModel.acknowledgeRenderedHUD(
            presentationRevision: presentationRevision,
            interactionRevision: 1,
            state: state
        )
        XCTAssertEqual(viewModel.renderedPresentationRevision, 0)

        viewModel.acknowledgeRenderedHUD(
            presentationRevision: presentationRevision,
            interactionRevision: 0,
            state: state
        )
        XCTAssertEqual(viewModel.renderedPresentationRevision, presentationRevision)
        XCTAssertEqual(viewModel.renderedInteractionRevision, 0)
        XCTAssertEqual(viewModel.renderedState, state)

        viewModel.setFocusedWindowID(nil)
        _ = viewModel.handle(key: .right)
        XCTAssertEqual(viewModel.interactionRevision, 1)
        viewModel.acknowledgeRenderedHUD(
            presentationRevision: presentationRevision,
            interactionRevision: 1,
            state: state
        )
        XCTAssertEqual(viewModel.renderedInteractionRevision, 1)
    }

    func testPointerAndShortcutActivateExactOpaqueTargetOnceAndDismiss() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["opaque-A", "opaque-B"])], active: "one"))
        try present(viewModel)
        XCTAssertEqual(viewModel.activateApp(windowID: "opaque-B"), .activateWindow("opaque-B"))
        XCTAssertEqual(dispatched, [.activateWindow("opaque-B")])
        XCTAssertFalse(viewModel.isPresented)
        try present(viewModel)
        XCTAssertEqual(viewModel.handle(key: .shortcut(.letter("a"), shifted: false)), .activateWindow("opaque-A"))
        XCTAssertEqual(dispatched, [.activateWindow("opaque-B"), .activateWindow("opaque-A")])
        XCTAssertFalse(viewModel.isPresented)
    }

    func testStalePointerFailsClosed() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1"])], active: "one"))
        try present(viewModel)
        XCTAssertEqual(viewModel.activateApp(windowID: "stale"), .none)
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertTrue(dispatched.isEmpty)
    }

    func testUnassignedAppRemainsReachableThroughFocusAndReturn() throws {
        let windows = (0..<73).map { window("w\($0)", app: "app\($0)") }
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: windows.map(\.id))], active: "one", windows: windows))
        try present(viewModel, constraints: roomyConstraints)
        let entry = try XCTUnwrap(viewModel.snapshot?.sections[0].apps.last)
        XCTAssertNil(entry.shortcut)
        for _ in 0..<windows.count where viewModel.focusedWindowID != entry.id {
            _ = viewModel.handle(key: .right)
        }
        XCTAssertEqual(viewModel.focusedWindowID, entry.id)
        XCTAssertEqual(viewModel.handle(key: .returnKey), .activateWindow(entry.id))
    }

    func testUnavailableLayoutOnlyAllowsEscape() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1"])], active: "one"))
        try present(viewModel, constraints: .init(safeWidth: 1, safeHeight: 1, outerMargin: 0, relaxedCellSize: 100, minimumCellSize: 100, horizontalGap: 0, verticalGap: 0, groupHeaderHeight: 10, emptyWorkspaceHeight: 0, groupGap: 0))
        XCTAssertNil(viewModel.snapshot?.layout.availableLayout)
        XCTAssertEqual(viewModel.activateApp(windowID: "w1"), .none)
        XCTAssertEqual(viewModel.handle(key: .shortcut(.letter("a"), shifted: false)), .none)
        XCTAssertEqual(viewModel.handle(key: .returnKey), .none)
        XCTAssertEqual(viewModel.handle(key: .right), .none)
        XCTAssertEqual(viewModel.handle(key: .tab), .none)
        XCTAssertEqual(viewModel.handle(key: .escape), .cancel)
        XCTAssertEqual(dispatched, [.cancel])
    }

    func testInvalidSymbolsLeaveHUDHiddenWithoutSnapshot() {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1"])], active: "one"))
        XCTAssertThrowsError(try viewModel.present(constraints: roomyConstraints, shiftedDigitSymbols: ["!"], inventoryRevision: 1))
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertNil(viewModel.snapshot)
    }

    func testPermissionStatusAndExplicitAccessibilityRequestRemain() throws {
        var requests = 0
        let viewModel = FocusHUDViewModel(state: state(screens: [screen("empty", windows: [])], active: "empty"), metadataProvider: metadata, intentHandler: { _ in }, accessibilityRequestHandler: { requests += 1 }, appIdentityHasher: { "hash:\($0)" })
        viewModel.setWindowDiscoveryStatus(.accessibilityRequired)
        viewModel.requestAccessibilityAccess()
        try present(viewModel)
        XCTAssertEqual(viewModel.windowDiscoveryStatus, .accessibilityRequired)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertTrue(viewModel.windowEntries.isEmpty)
    }

    func testLoadingAndUnavailablePresentationShowStatusWithoutSnapshot() throws {
        for status in [FocusHUDWindowDiscoveryStatus.loading, .unavailable] {
            let viewModel = FocusHUDViewModel(
                state: state(screens: [screen("one", windows: ["w1"])], active: "one"),
                metadataProvider: metadata,
                intentHandler: { _ in },
                appIdentityHasher: { "hash:\($0)" }
            )
            viewModel.setWindowDiscoveryStatus(status)

            try present(viewModel)

            XCTAssertTrue(viewModel.isPresented)
            XCTAssertEqual(viewModel.windowDiscoveryStatus, status)
            XCTAssertNil(viewModel.snapshot)
            XCTAssertEqual(viewModel.maximumAppCount, 0)

            viewModel.dismiss()
            viewModel.setWindowDiscoveryStatus(.ready)
            try present(viewModel)
            XCTAssertEqual(viewModel.snapshot?.keyAssignmentRevision, 1)
            XCTAssertEqual(viewModel.snapshot?.presentationRevision, 1)
        }
    }

    func testPresentationGivesEmptyWorkspaceMinimumPanelWidth() throws {
        let viewModel = makeViewModel(
            state: state(screens: [screen("empty", windows: [])], active: "empty")
        )

        try present(viewModel)

        XCTAssertGreaterThanOrEqual(viewModel.snapshot?.layout.availableLayout?.panelWidth ?? 0, 390)
    }

    func testPresentationDoesNotCapCompleteStackAtFourHundredPoints() throws {
        let screens = (1...5).map {
            screen("workspace-\($0)", number: $0, windows: ["w\($0)"])
        }
        let viewModel = makeViewModel(
            state: state(screens: screens, active: "workspace-1")
        )

        try present(viewModel)

        let layout = try XCTUnwrap(viewModel.snapshot?.layout.availableLayout)
        XCTAssertGreaterThan(layout.panelHeight, 400)
    }

    func testNonReadyPresentationAlwaysLetsEscapeCancel() throws {
        for status in [FocusHUDWindowDiscoveryStatus.loading, .accessibilityRequired, .unavailable] {
            let viewModel = FocusHUDViewModel(
                state: state(screens: [screen("one", windows: ["w1"])], active: "one"),
                metadataProvider: metadata,
                intentHandler: { [weak self] in self?.dispatched.append($0) },
                appIdentityHasher: { "hash:\($0)" }
            )
            viewModel.setWindowDiscoveryStatus(status)
            try present(viewModel)

            XCTAssertNil(viewModel.snapshot)
            XCTAssertEqual(viewModel.handle(key: .escape), .cancel)
            XCTAssertFalse(viewModel.isPresented)
            XCTAssertEqual(dispatched, [.cancel])
            dispatched = []
        }
    }

    func testDiscoveryDowngradeFailsAllActivationInputsClosedButEscapeCancels() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1"])], active: "one"))
        try present(viewModel)
        XCTAssertEqual(viewModel.handle(key: .right), .none)
        viewModel.setWindowDiscoveryStatus(.accessibilityRequired)

        XCTAssertEqual(viewModel.handle(key: .shortcut(.letter("a"), shifted: false)), .none)
        XCTAssertEqual(viewModel.handle(key: .returnKey), .none)
        XCTAssertEqual(viewModel.handle(key: .tab), .none)
        XCTAssertEqual(viewModel.focusedWindowID, "w1")
        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertEqual(viewModel.handle(key: .escape), .cancel)
        XCTAssertEqual(dispatched, [.cancel])
        XCTAssertFalse(viewModel.isPresented)
    }

    func testRevisionExhaustionFailsBeforeInstallingPresentationState() {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["w1"])], active: "one"))
        viewModel.setPresentationRevisionForTest(.max)

        XCTAssertThrowsError(try present(viewModel)) {
            XCTAssertEqual($0 as? FocusHUDPresentationError, .revisionExhausted)
        }
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertNil(viewModel.focusedWindowID)
    }

    func testOverviewKeysResolveDigitAndShiftDigitToExactTargets() throws {
        let windows = (0..<63).map { window("w\($0)", app: "app\($0)") }
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: windows.map(\.id))], active: "one", windows: windows))
        try present(viewModel, constraints: roomyConstraints)
        XCTAssertNotNil(viewModel.snapshot?.layout.availableLayout)
        let entries = try XCTUnwrap(viewModel.snapshot).sections.flatMap(\.apps)
        let digitEntry = entries[52]
        let symbolEntry = entries[62]

        XCTAssertEqual(digitEntry.shortcut?.label, "0")
        XCTAssertEqual(symbolEntry.shortcut?.label, ")")
        XCTAssertEqual(viewModel.handle(key: .shortcut(.digit(0), shifted: false)), .activateWindow(digitEntry.id))
        XCTAssertEqual(dispatched, [.activateWindow(digitEntry.id)])
        try present(viewModel, constraints: roomyConstraints)
        XCTAssertEqual(viewModel.handle(key: .shortcut(.digit(0), shifted: true)), .activateWindow(symbolEntry.id))
        XCTAssertEqual(dispatched, [.activateWindow(digitEntry.id), .activateWindow(symbolEntry.id)])
    }

    func testEntriesHashAppIdentityAndIntentsCarryOnlyWindowIDs() throws {
        let viewModel = makeViewModel(state: state(screens: [screen("one", windows: ["opaque-window"])], active: "one", windows: [window("opaque-window", app: "com.example.a")]))
        try present(viewModel)
        XCTAssertEqual(viewModel.snapshot?.sections[0].apps[0].appIdentityHash, "hash:com.example.a")
        XCTAssertEqual(viewModel.handle(key: .shortcut(.letter("a"), shifted: false)), .activateWindow("opaque-window"))
        XCTAssertEqual(dispatched, [.activateWindow("opaque-window")])
    }

    private func makeViewModel(state: FocusScreenState) -> FocusHUDViewModel {
        let viewModel = FocusHUDViewModel(state: state, metadataProvider: metadata, intentHandler: { [weak self] in self?.dispatched.append($0) }, appIdentityHasher: { "hash:\($0)" })
        viewModel.setWindowDiscoveryStatus(.ready)
        return viewModel
    }

    private func present(_ viewModel: FocusHUDViewModel, constraints: FocusHUDOverviewLayoutConstraints? = nil, inventoryRevision: UInt64 = 1) throws {
        try viewModel.present(constraints: constraints ?? roomyConstraints, shiftedDigitSymbols: Array(")!@#$%^&*("), inventoryRevision: inventoryRevision)
    }

    private var roomyConstraints: FocusHUDOverviewLayoutConstraints {
        .init(safeWidth: 12_000, safeHeight: 12_000, outerMargin: 0, relaxedCellSize: 100, minimumCellSize: 20, horizontalGap: 4, verticalGap: 4, groupHeaderHeight: 20, emptyWorkspaceHeight: 20, groupGap: 8, minimumPanelWidth: 390)
    }

    private func state(screens: [FocusScreen], active: FocusScreenID, windows: [ManagedWindow]? = nil, revision: Int = 1) -> FocusScreenState {
        let resolvedWindows = windows ?? screens.flatMap(\.windowIDs).map { window($0, app: "com.example.\($0)") }
        return FocusScreenState(screens: screens, windows: Dictionary(uniqueKeysWithValues: resolvedWindows.map { ($0.id, $0) }), activeScreenID: active, inspectedScreenID: active, revision: revision)
    }

    private func screen(_ id: FocusScreenID, number: Int = 1, windows: [ManagedWindowID]) -> FocusScreen {
        FocusScreen(id: id, number: number, lifecycle: .background, windowIDs: windows, lastActiveWindowID: windows.last)
    }

    private func window(_ id: ManagedWindowID, app: String) -> ManagedWindow {
        ManagedWindow(id: id, appID: app, canonicalFrame: CanvasRect(x: 0, y: 0, width: 100, height: 100))
    }
}

@MainActor
private final class FixtureWindowMetadataProvider: FocusHUDWindowMetadataProviding {
    func metadata(for window: ManagedWindow) -> FocusHUDWindowMetadata {
        FocusHUDWindowMetadata(appName: "App \(window.appID)", appIcon: nil, windowTitle: "Title \(window.id)")
    }
}
