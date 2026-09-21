import AppKit
import PagedNavigationCore
import XCTest
@testable import ScreenSwitcherApp

final class WorkspaceInteractionTests: XCTestCase {
    func testDirectTabSelectionIsDeterministic() {
        var state = makeState(tab: .switch)

        XCTAssertEqual(state.reduce(.selectTab(.agents)), [
            .selectTab(.agents),
        ])
        XCTAssertEqual(state.workspace.selectedTab, .agents)
        XCTAssertEqual(state.reduce(.selectTab(.agents)), [])
    }

    func testDisplayRailPagesFourItemsAndSelectionOwnsTheVisiblePage() {
        for count in 2...4 {
            let ids = (1...count).map { "display-\($0)" }
            let state = makeState(displayIDs: ids)
            XCTAssertEqual(state.displayPageCount, 1)
            XCTAssertEqual(state.visibleDisplayIDs, ids)
        }

        for (count, expectedPageCount) in [(5, 2), (8, 2), (9, 3)] {
            let ids = (1...count).map { "display-\($0)" }
            var state = makeState(displayIDs: ids)

            XCTAssertEqual(state.displayPageCount, expectedPageCount)
            XCTAssertEqual(state.selectedDisplayPage, 0)
            XCTAssertEqual(state.visibleDisplayIDs, Array(ids.prefix(4)))

            XCTAssertEqual(state.reduce(.selectDisplayPage(expectedPageCount - 1)), [
                .selectDisplay(ids[(expectedPageCount - 1) * 4]),
            ])
            XCTAssertEqual(state.selectedDisplayPage, expectedPageCount - 1)
            XCTAssertEqual(
                state.visibleDisplayIDs,
                Array(ids.dropFirst((expectedPageCount - 1) * 4).prefix(4))
            )
            XCTAssertEqual(state.reduce(.selectDisplayPage(expectedPageCount)), [])
        }
    }

    func testDisplayRailPageFollowsSelectionAcrossRemoveReorderAndClamp() {
        let original = (1...9).map { "display-\($0)" }
        var state = makeState(displayIDs: original)
        _ = state.reduce(.selectDisplay("display-9"))
        XCTAssertEqual(state.selectedDisplayPage, 2)

        let reordered = ["display-9", "display-1", "display-2", "display-3", "display-4"]
        _ = state.reduce(.synchronize(WorkspaceInteractionData(
            displayIDs: reordered,
            selectedDisplayID: "display-9",
            appPagesByDisplayID: appPages(for: reordered),
            agentsCardCount: 2,
            focusCardCount: 2
        )))
        XCTAssertEqual(state.selectedDisplayPage, 0)
        XCTAssertEqual(state.visibleDisplayIDs, Array(reordered.prefix(4)))

        let removed = ["display-1", "display-2", "display-3", "display-4", "display-5"]
        _ = state.reduce(.synchronize(WorkspaceInteractionData(
            displayIDs: removed,
            selectedDisplayID: nil,
            appPagesByDisplayID: appPages(for: removed),
            agentsCardCount: 2,
            focusCardCount: 2
        )))
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-1")
        XCTAssertEqual(state.selectedDisplayPage, 0)
        XCTAssertEqual(state.displayPageCount, 2)
    }

    func testHorizontalTrackpadGesturePagesOneTabAtExactTwentyTwoPercent() {
        var state = makeState(tab: .switch)
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: -22, dy: 2, velocityX: 0, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(state.lockedAxis, .horizontal)
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: session))), [
            .selectTab(.agents),
        ])
        XCTAssertEqual(state.workspace.selectedTab, .agents)
    }

    func testPassiveContentRefreshDoesNotCancelActiveTrackpadGesture() {
        var state = makeState(tab: .switch)
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: -22, dy: 2, velocityX: 0, velocityY: 0
            ))),
            []
        )

        state.synchronizePassiveContent(WorkspaceInteractionData(
            displayIDs: ["display-1"],
            selectedDisplayID: "display-1",
            appPagesByDisplayID: ["display-1": [["app-1"]]],
            agentsCardCount: 0,
            focusCardCount: 0
        ))

        XCTAssertEqual(
            state.reduce(.gesture(.ended(sessionID: session))),
            [.selectTab(.agents)],
            "Passive AX content refresh must not discard the user's active gesture"
        )
        XCTAssertEqual(state.workspace.selectedTab, .agents)
    }

    func testPassiveContentRefreshCancelsVerticalGestureWhenItsCardCountChanges() {
        var state = makeState(tab: .agents, agentsCards: 3)
        let session = WorkspaceGestureSessionID(rawValue: 2)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
            ))),
            []
        )

        state.synchronizePassiveContent(WorkspaceInteractionData(
            displayIDs: ["display-1"],
            selectedDisplayID: "display-1",
            appPagesByDisplayID: ["display-1": [["app-1"]]],
            agentsCardCount: 1,
            focusCardCount: 0
        ))

        XCTAssertNil(state.lockedAxis)
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: session))), [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
    }

    func testPassiveContentRefreshCancelsSwitchVerticalGestureWhenDisplayIdentityOrderChanges() {
        var state = makeState(tab: .switch)
        let session = WorkspaceGestureSessionID(rawValue: 3)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
            ))),
            []
        )

        let reorderedDisplayIDs = ["display-1", "display-3", "display-2"]
        state.synchronizePassiveContent(WorkspaceInteractionData(
            displayIDs: reorderedDisplayIDs,
            selectedDisplayID: "display-1",
            appPagesByDisplayID: appPages(for: reorderedDisplayIDs),
            agentsCardCount: 2,
            focusCardCount: 2
        ))

        XCTAssertNil(state.lockedAxis)
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-1")
        let terminal = state.handle(.gesture(.ended(sessionID: session)))
        XCTAssertFalse(terminal.handled)
        XCTAssertEqual(terminal.effects, [])
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-1")
    }

    func testPassiveContentRefreshPreservesSwitchVerticalGestureWhenDisplayIdentitiesAreUnchanged() {
        var state = makeState(tab: .switch)
        let session = WorkspaceGestureSessionID(rawValue: 4)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
            ))),
            []
        )

        let unchangedDisplayIDs = ["display-1", "display-2", "display-3"]
        state.synchronizePassiveContent(WorkspaceInteractionData(
            displayIDs: unchangedDisplayIDs,
            selectedDisplayID: "display-1",
            appPagesByDisplayID: appPages(for: unchangedDisplayIDs),
            agentsCardCount: 2,
            focusCardCount: 2
        ))

        XCTAssertEqual(state.lockedAxis, .vertical)
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: session))), [
            .selectDisplay("display-2"),
        ])
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-2")
    }

    func testHorizontalVelocityCommitsBelowProgressThreshold() {
        var state = makeState(tab: .agents)
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: -9, dy: 1, velocityX: -720, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: session))), [
            .selectTab(.focus),
        ])
    }

    func testCancelledHorizontalGestureDoesNotSelectTab() {
        var state = makeState(tab: .agents)
        let session = WorkspaceGestureSessionID(rawValue: 1)
        _ = state.reduce(.gesture(.began(
            sessionID: session, dx: -30, dy: 0, velocityX: 0, velocityY: 0
        )))

        XCTAssertEqual(
            state.reduce(.gesture(.cancelled(sessionID: session))),
            []
        )
        XCTAssertEqual(state.workspace.selectedTab, .agents)
        XCTAssertNil(state.lockedAxis)
    }

    func testFirstTabEdgeUsesCoreEdgeResistanceWithoutWrapping() {
        var state = makeState(tab: .switch)
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: 20, dy: 0, velocityX: 900, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(state.presentationOffset, 6.4, accuracy: 0.000_001)
        XCTAssertEqual(
            state.reduce(.gesture(.ended(sessionID: session))),
            []
        )
        XCTAssertEqual(state.workspace.selectedTab, .switch)
    }

    func testLastTabEdgeUsesCoreEdgeResistanceWithoutWrapping() {
        var state = makeState(tab: .focus)
        let session = WorkspaceGestureSessionID(rawValue: 1)

        _ = state.reduce(.gesture(.began(
            sessionID: session, dx: -20, dy: 0, velocityX: -900, velocityY: 0
        )))
        XCTAssertEqual(state.presentationOffset, -6.4, accuracy: 0.000_001)
        _ = state.reduce(.gesture(.ended(sessionID: session)))
        XCTAssertEqual(state.workspace.selectedTab, .focus)
    }

    func testVerticalGesturePagesAgentsCardAndAxisCannotChangeMidGesture() {
        var state = makeState(tab: .agents, agentsCards: 3)
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: 2, dy: -12, velocityX: 0, velocityY: -40
            ))),
            []
        )
        XCTAssertEqual(state.lockedAxis, .vertical)
        XCTAssertEqual(
            state.reduce(.gesture(.changed(
                sessionID: session, dx: -60, dy: -24, velocityX: -900, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(state.lockedAxis, .vertical)
        XCTAssertEqual(
            state.reduce(.gesture(.ended(sessionID: session))),
            []
        )
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 1)
        XCTAssertEqual(state.workspace.selectedTab, .agents)
    }

    func testVerticalGesturePagesFocusCard() {
        var focus = makeState(tab: .focus, focusCards: 3)
        let focusSession = WorkspaceGestureSessionID(rawValue: 1)
        _ = focus.reduce(.gesture(.began(
            sessionID: focusSession, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        )))
        _ = focus.reduce(.gesture(.ended(sessionID: focusSession)))
        XCTAssertEqual(focus.selectedCardIndex(for: .focus), 1)
    }

    func testVerticalGesturePagesSwitchDisplayInBothDirections() {
        var switchState = makeState(tab: .switch)
        let switchSession = WorkspaceGestureSessionID(rawValue: 1)
        XCTAssertEqual(
            switchState.reduce(.gesture(.began(
                sessionID: switchSession, dx: 0, dy: -30, velocityX: 0, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(
            switchState.reduce(.gesture(.changed(
                sessionID: switchSession, dx: 0, dy: -60, velocityX: 0, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(switchState.reduce(.gesture(.ended(sessionID: switchSession))), [
            .selectDisplay("display-2"),
        ])
        XCTAssertEqual(switchState.workspace.displayPages.selectedDisplayID, "display-2")

        let previousSession = WorkspaceGestureSessionID(rawValue: 2)
        XCTAssertEqual(
            switchState.reduce(.gesture(.began(
                sessionID: previousSession, dx: 0, dy: 30, velocityX: 0, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(switchState.reduce(.gesture(.ended(sessionID: previousSession))), [
            .selectDisplay("display-1"),
        ])
        XCTAssertEqual(switchState.workspace.displayPages.selectedDisplayID, "display-1")
    }

    func testGestureThresholdDoesNotEmitAProductEffect() {
        var state = makeState(tab: .agents, agentsCards: 4)
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(
            state.reduce(.gesture(.changed(
                sessionID: session, dx: 0, dy: -80, velocityX: 0, velocityY: 0
            ))),
            []
        )
        XCTAssertEqual(
            state.reduce(.gesture(.ended(sessionID: session))),
            []
        )
    }

    func testBracketsPageOnlySelectedDisplaysAppGrid() {
        var state = makeState()

        XCTAssertEqual(state.reduce(.key(.nextAppPage)), [
            .selectAppPage(1),
        ])
        XCTAssertEqual(state.workspace.displayPages.selectedPage, 1)
        XCTAssertEqual(state.reduce(.key(.previousAppPage)), [
            .selectAppPage(0),
        ])
        XCTAssertEqual(state.reduce(.key(.previousAppPage)), [])

        XCTAssertEqual(state.reduce(.key(.displayIndex(2))), [
            .selectDisplay("display-2"),
        ])
        XCTAssertEqual(state.reduce(.key(.nextAppPage)), [])
        XCTAssertEqual(state.workspace.displayPages.pageByDisplayID["display-1"], 0)
        XCTAssertEqual(state.workspace.displayPages.pageByDisplayID["display-2"], 0)
    }

    func testDisplayNumberUsesStableDisplayedIndexAndInvalidNumberIsNoOp() {
        var state = makeState()

        XCTAssertEqual(state.reduce(.key(.displayIndex(3))), [
            .selectDisplay("display-3"),
        ])
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-3")
        XCTAssertEqual(state.reduce(.key(.displayIndex(4))), [])
        XCTAssertEqual(state.reduce(.key(.displayIndex(0))), [])
    }

    func testPageLocalLetterExecutesSelectedDisplaysApp() {
        var state = makeState()
        _ = state.reduce(.key(.nextAppPage))

        XCTAssertEqual(state.reduce(.key(.appLetter(0))), [
            .executionRequested(.init(
                id: .init(rawValue: 1),
                target: .app(displayID: "display-1", appID: "app-c")
            )),
        ])
        XCTAssertEqual(state.reduce(.key(.appLetter(25))), [])
        XCTAssertEqual(state.reduce(.key(.appLetter(-1))), [])
    }

    func testReturnExecutesSelectedDisplayAndEscapeCloses() {
        var state = makeState()

        XCTAssertEqual(state.reduce(.key(.returnKey)), [
            .executionRequested(.init(
                id: .init(rawValue: 1),
                target: .display("display-1")
            )),
        ])
        XCTAssertEqual(state.reduce(.key(.escape)), [.close(.escape)])
    }

    func testBackgroundSynchronizationEmitsNoAction() {
        var state = makeState(tab: .agents, agentsCards: 3)

        XCTAssertEqual(
            state.reduce(.synchronize(.init(
                displayIDs: ["display-3", "display-2"],
                selectedDisplayID: "display-2",
                appPagesByDisplayID: ["display-2": [["new-app"]]],
                agentsCardCount: 1,
                focusCardCount: 2
            ))),
            []
        )
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-2")
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
    }

    func testSynchronizationPreservesPagesAcrossReorderAddRemoveAndExplicitSelection() {
        var state = makeState()
        _ = state.reduce(.key(.nextAppPage))

        XCTAssertEqual(
            state.reduce(.synchronize(.init(
                displayIDs: ["display-3", "display-1", "display-4"],
                selectedDisplayID: nil,
                appPagesByDisplayID: [
                    "display-3": [["app-e"]],
                    "display-1": [["app-a"], ["app-c"]],
                    "display-4": [["app-new"]],
                ],
                agentsCardCount: 2,
                focusCardCount: 2
            ))),
            []
        )
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-1")
        XCTAssertEqual(state.workspace.displayPages.pageByDisplayID, [
            "display-3": 0,
            "display-1": 1,
            "display-4": 0,
        ])

        _ = state.reduce(.synchronize(.init(
            displayIDs: ["display-4", "display-1"],
            selectedDisplayID: "display-4",
            appPagesByDisplayID: [
                "display-4": [["app-new"]],
                "display-1": [["app-a"], ["app-c"]],
            ],
            agentsCardCount: 2,
            focusCardCount: 2
        )))
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-4")
        XCTAssertNil(state.workspace.displayPages.pageByDisplayID["display-3"])
    }

    func testSynchronizationFallsBackWhenSelectionIsRemovedAndClampsShrunkOrEmptyPages() {
        var state = WorkspaceInteractionState(
            workspace: WorkspaceState(
                displayIDs: ["display-1", "display-2"],
                pointerDisplayID: "display-1"
            ),
            appPagesByDisplayID: [
                "display-1": [["a"], ["b"], ["c"]],
                "display-2": [["d"]],
            ],
            agentsCardCount: 1,
            focusCardCount: 1
        )
        _ = state.reduce(.key(.nextAppPage))
        _ = state.reduce(.key(.nextAppPage))
        XCTAssertEqual(state.workspace.displayPages.selectedPage, 2)

        _ = state.reduce(.synchronize(.init(
            displayIDs: ["display-2", "display-1"],
            selectedDisplayID: "missing-display",
            appPagesByDisplayID: [
                "display-1": [["a"], ["b"]],
                "display-2": [["d"]],
            ],
            agentsCardCount: 1,
            focusCardCount: 1
        )))
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-1")
        XCTAssertEqual(state.workspace.displayPages.pageByDisplayID["display-1"], 1)

        _ = state.reduce(.synchronize(.init(
            displayIDs: ["display-2", "display-1"],
            selectedDisplayID: nil,
            appPagesByDisplayID: [
                "display-1": [],
                "display-2": [["d"]],
            ],
            agentsCardCount: 1,
            focusCardCount: 1
        )))
        XCTAssertEqual(state.workspace.displayPages.pageByDisplayID["display-1"], 0)

        _ = state.reduce(.synchronize(.init(
            displayIDs: ["display-2"],
            selectedDisplayID: nil,
            appPagesByDisplayID: ["display-2": [["d"]]],
            agentsCardCount: 1,
            focusCardCount: 1
        )))
        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-2")
        XCTAssertEqual(state.workspace.displayPages.pageByDisplayID, ["display-2": 0])
    }

    func testSynchronizationCancelsActiveGestureWithoutAction() {
        var state = makeState(tab: .agents, agentsCards: 3)
        let session = WorkspaceGestureSessionID(rawValue: 1)
        XCTAssertEqual(
            state.reduce(.gesture(.began(
                sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
            ))),
            []
        )

        XCTAssertEqual(state.reduce(.synchronize(.init(
            displayIDs: ["display-1"],
            selectedDisplayID: nil,
            appPagesByDisplayID: ["display-1": [["app-a"]]],
            agentsCardCount: 3,
            focusCardCount: 1
        ))), [])
        XCTAssertNil(state.lockedAxis)
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: session))), [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
    }

    func testStandardMotionUsesOneSegmentedSpringFamilyWithTunedCardSettle() {
        let motion = StandardWorkspaceMotion()

        XCTAssertEqual(motion.tab, motion.appPage)
        XCTAssertEqual(motion.tab.kind, .spring)
        XCTAssertEqual(motion.card.kind, .spring)
        XCTAssertEqual(motion.card.duration, 0.23)
        XCTAssertEqual(motion.card.springResponse, 0.23)
        XCTAssertEqual(motion.card.dampingFraction, motion.tab.dampingFraction)
        XCTAssertTrue((0.18...0.26).contains(motion.tab.duration))
        XCTAssertTrue((0.18...0.26).contains(motion.card.duration))
        XCTAssertTrue(motion.tab.hasSpatialTravel)
        XCTAssertTrue(motion.card.hasSpatialTravel)
        XCTAssertEqual(motion.overlay.kind, .spring)
        XCTAssertEqual(motion.confirmation.kind, .spring)
    }

    func testReducedMotionPreservesSemanticSlotsWithoutSpatialTravel() {
        let motion = ReducedWorkspaceMotion()

        XCTAssertEqual(motion.tab.kind, .opacity)
        XCTAssertEqual(motion.card.kind, .opacity)
        XCTAssertEqual(motion.appPage.kind, .opacity)
        XCTAssertFalse(motion.overlay.hasSpatialTravel)
        XCTAssertFalse(motion.tab.hasSpatialTravel)
        XCTAssertLessThan(motion.tab.duration, StandardWorkspaceMotion().tab.duration)
    }

    @MainActor
    func testInputMonitorInstallsOnlyForActiveSessionAndTearsDownDeterministically() {
        let source = RecordingInputSource()
        let monitor = WorkspaceInputMonitor(source: source)
        var received: [WorkspaceInteractionInput] = []

        XCTAssertEqual(source.startCount, 0)
        XCTAssertFalse(source.send(.key(character: "a", keyCode: 0, modifiers: .none)))

        monitor.activate { input in
            received.append(input)
            return true
        }
        XCTAssertEqual(source.startCount, 1)
        XCTAssertTrue(source.send(.key(character: "a", keyCode: 0, modifiers: .none)))
        XCTAssertEqual(received, [.key(.appLetter(0))])

        monitor.deactivate()
        monitor.deactivate()
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(source.send(.key(character: "b", keyCode: 11, modifiers: .none)))
        XCTAssertEqual(received, [.key(.appLetter(0)), .interruptInputSession])
    }

    @MainActor
    func testInputMonitorTranslatesKeyboardAndTrackpadWithoutGlobalConstructionSideEffects() {
        let source = RecordingInputSource()
        let monitor = WorkspaceInputMonitor(source: source)
        var received: [WorkspaceInteractionInput] = []
        monitor.activate {
            received.append($0)
            return true
        }

        XCTAssertTrue(source.send(.key(character: "]", keyCode: 30, modifiers: .none)))
        XCTAssertTrue(source.send(.key(character: "2", keyCode: 19, modifiers: .none)))
        XCTAssertTrue(source.send(.key(character: "\r", keyCode: 36, modifiers: .none)))
        XCTAssertTrue(source.send(.key(character: "", keyCode: 53, modifiers: .none)))
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: -12,
            deltaY: 2,
            timestamp: 1,
            phase: .began,
            momentumPhase: .none
        ))))

        XCTAssertEqual(received, [
            .key(.nextAppPage),
            .key(.displayIndex(2)),
            .key(.returnKey),
            .key(.escape),
            .gesture(.began(
                sessionID: WorkspaceGestureSessionID(rawValue: 1),
                dx: -12,
                dy: 2,
                velocityX: 0,
                velocityY: 0
            )),
        ])
    }

    func testScrollReducerSuppressesMomentumAfterOneFingerTerminal() {
        var reducer = WorkspaceScrollInputReducer()
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(reducer.reduce(.init(
            deltaX: -4, deltaY: 1, timestamp: 1,
            phase: .began, momentumPhase: .none
        )), .began(sessionID: session, dx: -4, dy: 1, velocityX: 0, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: -18, deltaY: 0, timestamp: 1.125,
            phase: .changed, momentumPhase: .none
        )), .changed(sessionID: session, dx: -22, dy: 1, velocityX: -144, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.02,
            phase: .ended, momentumPhase: .none
        )), .ended(sessionID: session))

        XCTAssertNil(reducer.reduce(.init(
            deltaX: -10, deltaY: 0, timestamp: 1.03,
            phase: .none, momentumPhase: .began
        )))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: -20, deltaY: 0, timestamp: 1.04,
            phase: .none, momentumPhase: .changed
        )))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.05,
            phase: .none, momentumPhase: .ended
        )))
    }

    func testFingerEndedIsAuthoritativeWhenMomentumBeginsInSameEvent() {
        var reducer = WorkspaceScrollInputReducer()
        let session = WorkspaceGestureSessionID(rawValue: 1)
        _ = reducer.reduce(.init(
            deltaX: -12, deltaY: 0, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))

        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.1,
            phase: .ended, momentumPhase: .began
        )), .ended(sessionID: session))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: -20, deltaY: 0, timestamp: 1.2,
            phase: .none, momentumPhase: .changed
        )))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.3,
            phase: .none, momentumPhase: .ended
        )))
    }

    func testFingerBeganIsAuthoritativeWhenMomentumEndsInSameEvent() {
        var reducer = WorkspaceScrollInputReducer()
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertEqual(reducer.reduce(.init(
            deltaX: -14, deltaY: 3, timestamp: 2,
            phase: .began, momentumPhase: .ended
        )), .began(sessionID: session, dx: -14, dy: 3, velocityX: 0, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: -8, deltaY: 0, timestamp: 2.125,
            phase: .changed, momentumPhase: .changed
        )), .changed(sessionID: session, dx: -22, dy: 3, velocityX: -64, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 2.25,
            phase: .ended, momentumPhase: .none
        )), .ended(sessionID: session))
    }

    func testCombinedFingerCancellationSuppressesTrailingMomentumAndSecondTerminal() {
        var reducer = WorkspaceScrollInputReducer()
        let session = WorkspaceGestureSessionID(rawValue: 1)
        _ = reducer.reduce(.init(
            deltaX: 0, deltaY: -16, timestamp: 3,
            phase: .began, momentumPhase: .none
        ))

        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 3.1,
            phase: .cancelled, momentumPhase: .began
        )), .cancelled(sessionID: session))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: 0, deltaY: -30, timestamp: 3.2,
            phase: .none, momentumPhase: .changed
        )))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 3.3,
            phase: .ended, momentumPhase: .ended
        )))
    }

    func testScrollReducerSuppressesMomentumAfterCancellationAndAllowsNextFingerGesture() {
        var reducer = WorkspaceScrollInputReducer()
        let first = WorkspaceGestureSessionID(rawValue: 1)
        let second = WorkspaceGestureSessionID(rawValue: 2)
        _ = reducer.reduce(.init(
            deltaX: 0, deltaY: -12, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.01,
            phase: .cancelled, momentumPhase: .none
        )), .cancelled(sessionID: first))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: 0, deltaY: -20, timestamp: 1.02,
            phase: .none, momentumPhase: .changed
        )))

        XCTAssertEqual(reducer.reduce(.init(
            deltaX: -8, deltaY: 0, timestamp: 2,
            phase: .began, momentumPhase: .none
        )), .began(sessionID: second, dx: -8, dy: 0, velocityX: 0, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 2.01,
            phase: .ended, momentumPhase: .none
        )), .ended(sessionID: second))
    }

    func testScrollReducerHandlesTwoGenuineAndMissingPhaseGesturesDeterministically() {
        var reducer = WorkspaceScrollInputReducer()
        let first = WorkspaceGestureSessionID(rawValue: 1)
        let second = WorkspaceGestureSessionID(rawValue: 2)

        XCTAssertNil(reducer.reduce(.init(
            deltaX: -30, deltaY: 0, timestamp: 0,
            phase: .none, momentumPhase: .changed
        )))
        XCTAssertNil(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 0.1,
            phase: .ended, momentumPhase: .none
        )))

        XCTAssertEqual(reducer.reduce(.init(
            deltaX: -5, deltaY: 0, timestamp: 1,
            phase: .changed, momentumPhase: .none
        )), .began(sessionID: first, dx: -5, dy: 0, velocityX: 0, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.1,
            phase: .ended, momentumPhase: .none
        )), .ended(sessionID: first))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 6, deltaY: 0, timestamp: 2,
            phase: .began, momentumPhase: .none
        )), .began(sessionID: second, dx: 6, dy: 0, velocityX: 0, velocityY: 0))
        XCTAssertEqual(reducer.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 2.1,
            phase: .ended, momentumPhase: .none
        )), .ended(sessionID: second))
    }

    func testExplicitScrollResetRequiresPhysicalBeginButColdStartAllowsMissingPhaseChanged() {
        var coldStart = WorkspaceScrollInputReducer()
        XCTAssertEqual(coldStart.reduce(.init(
            deltaX: -9, deltaY: 0, timestamp: 1,
            phase: .changed, momentumPhase: .none
        )), .began(
            sessionID: WorkspaceGestureSessionID(rawValue: 1),
            dx: -9,
            dy: 0,
            velocityX: 0,
            velocityY: 0
        ))

        var interrupted = WorkspaceScrollInputReducer()
        _ = interrupted.reduce(.init(
            deltaX: 0, deltaY: -10, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))
        interrupted.reset()

        XCTAssertNil(interrupted.reduce(.init(
            deltaX: 0, deltaY: -80, timestamp: 1.1,
            phase: .changed, momentumPhase: .none
        )))
        XCTAssertNil(interrupted.reduce(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.2,
            phase: .ended, momentumPhase: .none
        )))
        XCTAssertEqual(interrupted.reduce(.init(
            deltaX: 0, deltaY: -30, timestamp: 2,
            phase: .began, momentumPhase: .none
        )), .began(
            sessionID: WorkspaceGestureSessionID(rawValue: 2),
            dx: 0,
            dy: -30,
            velocityX: 0,
            velocityY: 0
        ))
    }

    @MainActor
    func testMonitorStopResetsPartialScrollGesture() {
        let source = RecordingInputSource()
        let monitor = WorkspaceInputMonitor(source: source)
        var received: [WorkspaceInteractionInput] = []
        monitor.activate {
            received.append($0)
            return true
        }
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: -10, deltaY: 0, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))))
        monitor.deactivate()
        received.removeAll()

        monitor.activate {
            received.append($0)
            return true
        }
        XCTAssertFalse(source.send(.scroll(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.1,
            phase: .ended, momentumPhase: .none
        ))))
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: -9, deltaY: 0, timestamp: 2,
            phase: .began, momentumPhase: .none
        ))))
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: 0, timestamp: 2.1,
            phase: .ended, momentumPhase: .none
        ))))
        XCTAssertEqual(received, [
            .gesture(.began(
                sessionID: WorkspaceGestureSessionID(rawValue: 2),
                dx: -9,
                dy: 0,
                velocityX: 0,
                velocityY: 0
            )),
            .gesture(.ended(sessionID: WorkspaceGestureSessionID(rawValue: 2))),
        ])
    }

    @MainActor
    func testModifiedCommandsAreRejectedWithoutSwallowingAndShiftCapsLettersWork() {
        let source = RecordingInputSource()
        let monitor = WorkspaceInputMonitor(source: source)
        var received: [WorkspaceInteractionInput] = []
        monitor.activate {
            received.append($0)
            return true
        }

        XCTAssertFalse(source.send(.key(character: "a", keyCode: 0, modifiers: .command)))
        XCTAssertFalse(source.send(.key(character: "1", keyCode: 18, modifiers: .control)))
        XCTAssertFalse(source.send(.key(character: "[", keyCode: 33, modifiers: .option)))
        XCTAssertFalse(source.send(.key(character: "\r", keyCode: 36, modifiers: .function)))
        XCTAssertFalse(source.send(.key(
            character: "A", keyCode: 0, modifiers: [.command, .shift]
        )))
        XCTAssertTrue(received.isEmpty)

        XCTAssertTrue(source.send(.key(character: "A", keyCode: 0, modifiers: .shift)))
        XCTAssertTrue(source.send(.key(character: "A", keyCode: 0, modifiers: .capsLock)))
        XCTAssertEqual(received, [.key(.appLetter(0)), .key(.appLetter(0))])
    }

    func testAppKitModifierMappingPreservesOnlySemanticFlags() {
        XCTAssertEqual(
            WorkspaceInputModifiers(appKitFlags: [
                .command, .control, .option, .function, .shift, .capsLock, .numericPad,
            ]),
            [.command, .control, .option, .function, .shift, .capsLock]
        )
    }

    func testDirectTabInterruptsGestureSessionAndSuppressesStaleTerminalAction() {
        var state = makeState(tab: .agents, agentsCards: 3)
        let first = WorkspaceGestureSessionID(rawValue: 41)
        XCTAssertEqual(state.reduce(.gesture(.began(
            sessionID: first, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        ))), [])

        XCTAssertEqual(state.reduce(.selectTab(.focus)), [
            .selectTab(.focus),
        ])
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: first))), [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
    }

    func testSelectingCurrentTabStillInterruptsItsGestureWithoutEffects() {
        var state = makeState(tab: .agents, agentsCards: 3)
        let session = WorkspaceGestureSessionID(rawValue: 42)
        XCTAssertEqual(state.reduce(.gesture(.began(
            sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        ))), [])

        XCTAssertFalse(state.handle(.selectTab(.agents)).handled)
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: session))), [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
    }

    func testSynchronizeAndCloseInterruptSessionsUntilNewIdentityBegins() {
        var state = makeState(tab: .agents, agentsCards: 3)
        let first = WorkspaceGestureSessionID(rawValue: 51)
        _ = state.reduce(.gesture(.began(
            sessionID: first, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        )))
        _ = state.reduce(.synchronize(.init(
            displayIDs: ["display-1"],
            selectedDisplayID: nil,
            appPagesByDisplayID: ["display-1": [["app-a"]]],
            agentsCardCount: 3,
            focusCardCount: 2
        )))
        XCTAssertEqual(state.reduce(.gesture(.changed(
            sessionID: first, dx: 0, dy: -80, velocityX: 0, velocityY: 0
        ))), [])
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: first))), [])

        let second = WorkspaceGestureSessionID(rawValue: 52)
        XCTAssertEqual(state.reduce(.gesture(.began(
            sessionID: second, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        ))), [])
        XCTAssertEqual(state.reduce(.key(.escape)), [.close(.escape)])
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: second))), [])
    }

    func testNewBeganReplacesOldSessionAndStaleTerminalCannotCommitIt() {
        var state = makeState(tab: .agents, agentsCards: 3)
        let old = WorkspaceGestureSessionID(rawValue: 61)
        let current = WorkspaceGestureSessionID(rawValue: 62)
        XCTAssertEqual(state.reduce(.gesture(.began(
            sessionID: old, dx: 0, dy: -10, velocityX: 0, velocityY: 0
        ))), [])
        XCTAssertEqual(state.reduce(.gesture(.began(
            sessionID: current, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        ))), [])

        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: old))), [])
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: current))), [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 1)
    }

    @MainActor
    func testDeactivateReactivationCoordinatesSemanticGestureInterruption() {
        let source = RecordingInputSource()
        let monitor = WorkspaceInputMonitor(source: source)
        var state = makeState(tab: .agents, agentsCards: 3)
        var effects: [WorkspaceInteractionEffect] = []

        monitor.activate { input in
            let result = state.handle(input)
            effects.append(contentsOf: result.effects)
            return result.handled
        }
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: -30, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))))
        XCTAssertEqual(effects, [])
        monitor.deactivate()
        effects.removeAll()

        monitor.activate { input in
            let result = state.handle(input)
            effects.append(contentsOf: result.effects)
            return result.handled
        }
        XCTAssertFalse(source.send(.scroll(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.1,
            phase: .ended, momentumPhase: .none
        ))))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: -30, timestamp: 2,
            phase: .began, momentumPhase: .none
        ))))
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: 0, timestamp: 2.1,
            phase: .ended, momentumPhase: .none
        ))))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 1)
    }

    @MainActor
    func testDeactivateRequiresNewPhysicalBeginBeforeMonitorAndStateResumeGesture() {
        let source = RecordingInputSource()
        let monitor = WorkspaceInputMonitor(source: source)
        var state = makeState(tab: .agents, agentsCards: 3)
        var effects: [WorkspaceInteractionEffect] = []

        monitor.activate { input in
            let result = state.handle(input)
            effects.append(contentsOf: result.effects)
            return result.handled
        }
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: -10, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))))
        monitor.deactivate()
        effects.removeAll()

        monitor.activate { input in
            let result = state.handle(input)
            effects.append(contentsOf: result.effects)
            return result.handled
        }
        XCTAssertFalse(source.send(.scroll(.init(
            deltaX: 0, deltaY: -80, timestamp: 1.1,
            phase: .changed, momentumPhase: .none
        ))))
        XCTAssertFalse(source.send(.scroll(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.2,
            phase: .ended, momentumPhase: .none
        ))))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.workspace.selectedTab, .agents)
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
        XCTAssertEqual(state.workspace.displayPages.selectedPage, 0)

        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: -30, timestamp: 2,
            phase: .began, momentumPhase: .none
        ))))
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: 0, timestamp: 2.1,
            phase: .ended, momentumPhase: .none
        ))))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.workspace.selectedTab, .agents)
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 1)
        XCTAssertEqual(state.workspace.displayPages.selectedPage, 0)
    }

    @MainActor
    func testContextualNoOpsAreNotConsumedButValidCommandsAndGesturesAre() {
        let source = RecordingInputSource()
        let monitor = WorkspaceInputMonitor(source: source)
        var state = makeState(tab: .agents, agentsCards: 2)
        monitor.activate { state.handle($0).handled }

        XCTAssertFalse(source.send(.key(character: "a", keyCode: 0, modifiers: .none)))
        XCTAssertFalse(source.send(.key(character: "\r", keyCode: 36, modifiers: .none)))
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: -10, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))))
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: 0, timestamp: 1.1,
            phase: .ended, momentumPhase: .none
        ))))

        _ = state.reduce(.selectTab(.switch))
        XCTAssertFalse(source.send(.key(character: "1", keyCode: 18, modifiers: .none)))
        XCTAssertFalse(source.send(.key(character: "[", keyCode: 33, modifiers: .none)))
        XCTAssertTrue(source.send(.key(character: "]", keyCode: 30, modifiers: .none)))
        XCTAssertTrue(source.send(.key(character: "2", keyCode: 19, modifiers: .none)))

        _ = state.reduce(.selectTab(.focus))
        XCTAssertFalse(source.send(.key(character: "a", keyCode: 0, modifiers: .none)))
        XCTAssertFalse(source.send(.key(character: "\r", keyCode: 36, modifiers: .none)))
    }

    func testExecutionConfirmationOccursOnlyAfterMatchingSuccessfulCompletion() {
        var state = makeState()

        XCTAssertEqual(state.reduce(.key(.appLetter(0))), [
            .executionRequested(.init(
                id: .init(rawValue: 1),
                target: .app(displayID: "display-1", appID: "app-a")
            )),
        ])
        let pending = try! XCTUnwrap(state.pendingExecution)
        XCTAssertEqual(state.reduce(.key(.appLetter(1))), [])
        XCTAssertEqual(state.reduce(.executionCompleted(.init(
            id: pending.id,
            target: pending.target,
            outcome: .success
        ))), [.close(.programmatic)])
        XCTAssertNil(state.pendingExecution)
        XCTAssertEqual(state.reduce(.executionCompleted(.init(
            id: pending.id,
            target: pending.target,
            outcome: .success
        ))), [])
    }

    func testExecutionFailureMismatchStaleCompletionAndInterruptionAreSilent() {
        var state = makeState()
        _ = state.reduce(.key(.returnKey))
        let first = try! XCTUnwrap(state.pendingExecution)
        XCTAssertEqual(state.reduce(.executionCompleted(.init(
            id: first.id,
            target: .display("display-2"),
            outcome: .success
        ))), [])
        XCTAssertEqual(state.reduce(.executionCompleted(.init(
            id: first.id,
            target: first.target,
            outcome: .failure(.appActivationFailed)
        ))), [])
        XCTAssertNil(state.pendingExecution)
        XCTAssertEqual(state.executionFailure, .appActivationFailed)

        _ = state.reduce(.key(.returnKey))
        let second = try! XCTUnwrap(state.pendingExecution)
        XCTAssertNotEqual(first.id, second.id)
        _ = state.reduce(.selectTab(.agents))
        XCTAssertNil(state.pendingExecution)
        XCTAssertEqual(state.reduce(.executionCompleted(.init(
            id: second.id,
            target: second.target,
            outcome: .success
        ))), [])
    }

    @MainActor
    func testModelHandsOffFullRequestsAndAcceptsOnlyMatchingCompletion() throws {
        var requests: [WorkspaceExecutionRequest] = []
        let model = makeInteractionModel { requests.append($0) }

        XCTAssertTrue(model.send(.activateApp("app-a")))
        let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first.target, .app(displayID: "display-1", appID: "app-a"))
        XCTAssertEqual(model.pendingExecutionRequest, first)
        XCTAssertFalse(model.completeExecution(.init(
            id: first.id,
            target: .display("display-1"),
            outcome: .success
        )))
        XCTAssertEqual(model.pendingExecutionRequest, first)
        XCTAssertTrue(model.completeExecution(.init(
            id: first.id,
            target: first.target,
            outcome: .failure(.appWindowActivationTimedOut)
        )))
        XCTAssertNil(model.pendingExecutionRequest)
        XCTAssertEqual(model.presentation.executionFailure, .appWindowActivationTimedOut)

        XCTAssertTrue(model.send(.activateApp("app-a")))
        let second = try XCTUnwrap(requests.last)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(model.completeExecution(.init(
            id: first.id,
            target: first.target,
            outcome: .success
        )))
        XCTAssertEqual(model.pendingExecutionRequest, second)
        XCTAssertNil(model.presentation.executionFailure, "a retry clears the recoverable error")
    }

    @MainActor
    func testModelWithoutExecutorImmediatelyFailsAndAllowsConsecutiveActivation() {
        let model = makeInteractionModel(executionRequestHandler: nil)

        XCTAssertTrue(model.send(.activateApp("app-a")))
        XCTAssertNil(model.pendingExecutionRequest)
        XCTAssertTrue(model.send(.activateApp("app-a")))
        XCTAssertNil(model.pendingExecutionRequest)
    }

    @MainActor
    func testDisplayRailPagingPublishesThroughTheSingleInteractionModel() {
        let model = makeInteractionModel(
            executionRequestHandler: nil,
            displayCount: 9
        )

        XCTAssertEqual(model.presentation.selectedDisplayPage, 0)
        XCTAssertEqual(model.presentation.visibleDisplayIDs, [
            "display-1", "display-2", "display-3", "display-4"
        ])
        XCTAssertTrue(model.send(.selectDisplayPage(2)))
        XCTAssertEqual(model.presentation.selectedDisplayID, "display-9")
        XCTAssertEqual(model.presentation.selectedDisplayPage, 2)
        XCTAssertEqual(model.presentation.displayPageCount, 3)
        XCTAssertEqual(model.presentation.visibleDisplayIDs, ["display-9"])
    }

    @MainActor
    func testSwitchVerticalGesturePublishesSelectionThroughInteractionModel() {
        let model = makeInteractionModel(
            executionRequestHandler: nil,
            displayCount: 3
        )
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertTrue(model.send(.gesture(.began(
            sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        ))))
        XCTAssertEqual(model.presentation.selectedDisplayID, "display-1")

        XCTAssertTrue(model.send(.gesture(.ended(sessionID: session))))
        XCTAssertEqual(model.presentation.selectedDisplayID, "display-2")
        XCTAssertEqual(model.presentation.displayTransitionDirection, .next)
    }

    @MainActor
    func testPresentationSeparatesHorizontalTabGestureFromDisplayCardMotion() {
        let model = makeInteractionModel(
            executionRequestHandler: nil,
            displayCount: 3
        )
        let session = WorkspaceGestureSessionID(rawValue: 1)

        XCTAssertTrue(model.send(.gesture(.began(
            sessionID: session, dx: -30, dy: 0, velocityX: 0, velocityY: 0
        ))))
        XCTAssertEqual(model.presentation.gestureAxis, .horizontal)
        XCTAssertNotEqual(model.presentation.motionOffset, 0)
        XCTAssertNil(model.presentation.displayTransitionDirection)

        XCTAssertTrue(model.send(.gesture(.ended(sessionID: session))))
        XCTAssertEqual(model.presentation.selectedTab, .agents)
        XCTAssertEqual(model.presentation.selectedDisplayID, "display-1")
        XCTAssertNil(model.presentation.displayTransitionDirection)
    }

    @MainActor
    func testSwitchCardAnimationIdentityAdvancesOnlyForVerticalTerminalEvents() {
        let cancelled = makeInteractionModel(executionRequestHandler: nil, displayCount: 3)
        let cancelledSession = WorkspaceGestureSessionID(rawValue: 1)
        let cancelledInitialIdentity = cancelled.presentation.displayCardAnimationIdentity

        XCTAssertTrue(cancelled.send(.gesture(.began(
            sessionID: cancelledSession, dx: 0, dy: -18, velocityX: 0, velocityY: 0
        ))))
        let cancelledDragIdentity = cancelled.presentation.displayCardAnimationIdentity
        XCTAssertEqual(cancelledDragIdentity, cancelledInitialIdentity, "Live drag must remain direct")
        XCTAssertTrue(cancelled.send(.gesture(.cancelled(sessionID: cancelledSession))))
        XCTAssertNotEqual(cancelled.presentation.displayCardAnimationIdentity, cancelledDragIdentity)
        XCTAssertEqual(cancelled.presentation.selectedDisplayID, "display-1")

        let belowThreshold = makeInteractionModel(executionRequestHandler: nil, displayCount: 3)
        let belowThresholdSession = WorkspaceGestureSessionID(rawValue: 1)
        _ = belowThreshold.send(.gesture(.began(
            sessionID: belowThresholdSession, dx: 0, dy: -12, velocityX: 0, velocityY: 0
        )))
        let belowThresholdDragIdentity = belowThreshold.presentation.displayCardAnimationIdentity
        XCTAssertTrue(belowThreshold.send(.gesture(.ended(sessionID: belowThresholdSession))))
        XCTAssertNotEqual(
            belowThreshold.presentation.displayCardAnimationIdentity,
            belowThresholdDragIdentity
        )
        XCTAssertEqual(belowThreshold.presentation.selectedDisplayID, "display-1")

        let resistedEdge = makeInteractionModel(executionRequestHandler: nil, displayCount: 3)
        let resistedEdgeSession = WorkspaceGestureSessionID(rawValue: 1)
        _ = resistedEdge.send(.gesture(.began(
            sessionID: resistedEdgeSession, dx: 0, dy: 30, velocityX: 0, velocityY: 0
        )))
        let resistedEdgeDragIdentity = resistedEdge.presentation.displayCardAnimationIdentity
        XCTAssertTrue(resistedEdge.send(.gesture(.ended(sessionID: resistedEdgeSession))))
        XCTAssertNotEqual(
            resistedEdge.presentation.displayCardAnimationIdentity,
            resistedEdgeDragIdentity
        )
        XCTAssertEqual(resistedEdge.presentation.selectedDisplayID, "display-1")

        let committed = makeInteractionModel(executionRequestHandler: nil, displayCount: 3)
        let committedSession = WorkspaceGestureSessionID(rawValue: 1)
        _ = committed.send(.gesture(.began(
            sessionID: committedSession, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        )))
        let committedDragIdentity = committed.presentation.displayCardAnimationIdentity
        XCTAssertTrue(committed.send(.gesture(.ended(sessionID: committedSession))))
        XCTAssertNotEqual(committed.presentation.displayCardAnimationIdentity, committedDragIdentity)
        XCTAssertEqual(committed.presentation.selectedDisplayID, "display-2")
        XCTAssertEqual(committed.presentation.displayTransitionDirection, .next)

        let horizontal = makeInteractionModel(executionRequestHandler: nil, displayCount: 3)
        let horizontalSession = WorkspaceGestureSessionID(rawValue: 1)
        let horizontalInitialIdentity = horizontal.presentation.displayCardAnimationIdentity
        _ = horizontal.send(.gesture(.began(
            sessionID: horizontalSession, dx: -30, dy: 0, velocityX: 0, velocityY: 0
        )))
        XCTAssertEqual(horizontal.presentation.displayCardAnimationIdentity, horizontalInitialIdentity)
        XCTAssertTrue(horizontal.send(.gesture(.ended(sessionID: horizontalSession))))
        XCTAssertEqual(horizontal.presentation.selectedTab, .agents)
        XCTAssertEqual(horizontal.presentation.displayCardAnimationIdentity, horizontalInitialIdentity)
    }

    @MainActor
    func testPresentationSettlementRevisionsRejectStaleAnimationCallbacks() {
        let model = makeInteractionModel(executionRequestHandler: nil, displayCount: 3)

        XCTAssertEqual(model.presentation.tabTransitionRevision, 0)
        XCTAssertEqual(model.presentation.tabSettledRevision, 0)
        XCTAssertTrue(model.send(.selectTab(.agents)))
        let firstTabRevision = model.presentation.tabTransitionRevision
        XCTAssertEqual(firstTabRevision, 1)
        XCTAssertEqual(model.presentation.tabSettledRevision, 0)

        XCTAssertTrue(model.send(.selectTab(.switch)))
        let currentTabRevision = model.presentation.tabTransitionRevision
        XCTAssertEqual(currentTabRevision, 2)
        model.markTabTransitionSettled(revision: firstTabRevision)
        XCTAssertEqual(model.presentation.tabSettledRevision, 0)
        model.markTabTransitionSettled(revision: currentTabRevision)
        XCTAssertEqual(model.presentation.tabSettledRevision, currentTabRevision)

        XCTAssertTrue(model.send(.selectDisplay("display-2")))
        let firstCardRevision = model.presentation.displayCardAnimationIdentity.terminalRevision
        XCTAssertGreaterThan(firstCardRevision, 0)
        XCTAssertEqual(model.presentation.displayCardSettledRevision, 0)
        XCTAssertTrue(model.send(.selectDisplay("display-3")))
        let currentCardRevision = model.presentation.displayCardAnimationIdentity.terminalRevision
        XCTAssertGreaterThan(currentCardRevision, firstCardRevision)
        model.markDisplayCardTransitionSettled(revision: firstCardRevision)
        XCTAssertEqual(model.presentation.displayCardSettledRevision, 0)
        model.markDisplayCardTransitionSettled(revision: currentCardRevision)
        XCTAssertEqual(model.presentation.displayCardSettledRevision, currentCardRevision)
    }

    @MainActor
    func testDirectDisplaySelectionPublishesDirectionFromOrderedDisplayIndices() {
        let model = makeInteractionModel(
            executionRequestHandler: nil,
            displayCount: 3
        )

        XCTAssertTrue(model.send(.selectDisplay("display-3")))
        XCTAssertEqual(model.presentation.displayTransitionDirection, .next)
        XCTAssertTrue(model.send(.selectDisplay("display-1")))
        XCTAssertEqual(model.presentation.displayTransitionDirection, .previous)
    }

    func testKeyboardDisplayAndAppPageSnapEmitExactlyOneAlignment() {
        var state = makeState()

        XCTAssertEqual(state.reduce(.key(.nextAppPage)), [
            .selectAppPage(1),
        ])
        XCTAssertEqual(state.reduce(.key(.nextAppPage)), [])
        XCTAssertEqual(state.reduce(.key(.displayIndex(2))), [
            .selectDisplay("display-2"),
        ])
        XCTAssertEqual(state.reduce(.key(.displayIndex(2))), [])
        XCTAssertEqual(state.reduce(.key(.displayIndex(Int.max))), [])
    }

    func testInitialStateClampsPagesAndNormalizesAppIdentityAcrossPages() {
        var workspace = WorkspaceState(
            displayIDs: ["display-1", "display-2"],
            pointerDisplayID: "display-1"
        )
        workspace.displayPages = DisplayAppPageState(
            selectedDisplayID: "missing",
            pageByDisplayID: ["display-1": Int.max, "display-2": -3, "ghost": 4]
        )
        var state = WorkspaceInteractionState(
            workspace: workspace,
            appPagesByDisplayID: [
                "display-1": [["", "app-a", "app-a", "app-b"], ["app-b", "app-c"], []],
                "display-2": [],
                "ghost": [["ghost-app"]],
            ],
            agentsCardCount: Int.min,
            focusCardCount: Int.max
        )

        XCTAssertEqual(state.workspace.displayPages.selectedDisplayID, "display-1")
        XCTAssertEqual(state.workspace.displayPages.pageByDisplayID, [
            "display-1": 1, "display-2": 0,
        ])
        XCTAssertEqual(state.reduce(.key(.appLetter(0))), [
            .executionRequested(.init(
                id: .init(rawValue: 1),
                target: .app(displayID: "display-1", appID: "app-c")
            )),
        ])
        _ = state.reduce(.executionCompleted(.init(
            id: state.pendingExecution!.id,
            target: state.pendingExecution!.target,
            outcome: .failure(.targetAppWindowUnavailable)
        )))
        XCTAssertEqual(state.reduce(.key(.appLetter(1))), [])

        _ = state.reduce(.selectTab(.agents))
        let session = WorkspaceGestureSessionID(rawValue: 91)
        XCTAssertEqual(state.reduce(.gesture(.began(
            sessionID: session, dx: 0, dy: -30, velocityX: 0, velocityY: 0
        ))), [])
        XCTAssertEqual(state.reduce(.gesture(.ended(sessionID: session))), [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
    }

    func testMalformedMotionTransitionIsSanitized() {
        let opacity = WorkspaceMotionTransition(
            kind: .opacity,
            duration: .nan,
            springResponse: .infinity,
            dampingFraction: -1,
            hasSpatialTravel: true
        )
        XCTAssertEqual(opacity.duration, 0)
        XCTAssertNil(opacity.springResponse)
        XCTAssertNil(opacity.dampingFraction)
        XCTAssertFalse(opacity.hasSpatialTravel)

        let spring = WorkspaceMotionTransition(
            kind: .spring,
            duration: -1,
            springResponse: 0,
            dampingFraction: 2,
            hasSpatialTravel: true
        )
        XCTAssertEqual(spring.duration, 0)
        XCTAssertNil(spring.springResponse)
        XCTAssertNil(spring.dampingFraction)
        XCTAssertTrue(spring.hasSpatialTravel)
    }

    @MainActor
    func testDirectAppKitSourceReleaseRemovesMonitorAndHandlerExactlyOnce() async {
        let registrar = RecordingLocalMonitorRegistrar()
        var source: AppKitWorkspaceInputEventSource? = AppKitWorkspaceInputEventSource(
            registrar: registrar
        )
        var lifetime: InputHandlerLifetime? = InputHandlerLifetime()
        weak var weakLifetime = lifetime
        source?.start { [lifetime] _ in
            _ = lifetime
            return false
        }
        lifetime = nil

        source = nil
        await Task.yield()

        XCTAssertEqual(registrar.removeCount, 1)
        XCTAssertNil(weakLifetime)
    }

    @MainActor
    func testExplicitAppKitSourceStopAndReleaseAreIdempotent() async {
        let registrar = RecordingLocalMonitorRegistrar()
        var source: AppKitWorkspaceInputEventSource? = AppKitWorkspaceInputEventSource(
            registrar: registrar
        )
        source?.start { _ in false }
        source?.stop()
        source?.stop()
        source = nil
        await Task.yield()

        XCTAssertEqual(registrar.removeCount, 1)
    }

    @MainActor
    func testReleasingActiveInputMonitorStopsItsSession() async {
        let source = RecordingInputSource()
        var monitor: WorkspaceInputMonitor? = WorkspaceInputMonitor(source: source)
        var state = makeState(tab: .agents, agentsCards: 3)
        monitor?.activate { state.handle($0).handled }
        XCTAssertTrue(source.send(.scroll(.init(
            deltaX: 0, deltaY: -30, timestamp: 1,
            phase: .began, momentumPhase: .none
        ))))

        monitor = nil
        await Task.yield()

        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(source.send(.key(character: "a", keyCode: 0, modifiers: .none)))
        XCTAssertEqual(state.reduce(.gesture(.ended(
            sessionID: WorkspaceGestureSessionID(rawValue: 1)
        ))), [])
        XCTAssertEqual(state.selectedCardIndex(for: .agents), 0)
    }

    private func makeState(
        tab: WorkspaceTab = .switch,
        agentsCards: Int = 2,
        focusCards: Int = 2,
        displayIDs: [String] = ["display-1", "display-2", "display-3"]
    ) -> WorkspaceInteractionState {
        WorkspaceInteractionState(
            workspace: WorkspaceState(
                displayIDs: displayIDs,
                pointerDisplayID: displayIDs.first,
                selectedTab: tab
            ),
            appPagesByDisplayID: displayIDs == ["display-1", "display-2", "display-3"]
                ? [
                    "display-1": [["app-a", "app-b"], ["app-c"]],
                    "display-2": [["app-d"]],
                    "display-3": [["app-e"]],
                ]
                : appPages(for: displayIDs),
            agentsCardCount: agentsCards,
            focusCardCount: focusCards
        )
    }

    private func appPages(for displayIDs: [String]) -> [String: [[String]]] {
        Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, [["app-\($0)"]]) })
    }

    @MainActor
    private func makeInteractionModel(
        executionRequestHandler: (@MainActor (WorkspaceExecutionRequest) -> Void)?,
        displayCount: Int = 1
    ) -> WorkspaceInteractionModel {
        let workspaces = (1...displayCount).map { index in
            let display = DisplayDescriptor(
                id: "display-\(index)",
                frame: try! RectDescriptor(
                    x: Double((index - 1) * 1_512),
                    y: 0,
                    width: 1_512,
                    height: 982
                ),
                isCurrent: index == 1
            )
            return DisplayWorkspaceSnapshot(
                display: display,
                apps: index == 1 ? [RunningAppDescriptor(
                    id: "app-a",
                    displayName: "App A",
                    mostRecentWindow: nil
                )] : [],
                previewAvailability: .schematicFallback
            )
        }
        let content = SwitchWorkspaceContent(
            workspaces: workspaces,
            selectedDisplayID: workspaces.first?.display.id
        )
        return WorkspaceInteractionModel(
            content: content,
            selectedTab: .switch,
            executionRequestHandler: executionRequestHandler
        )
    }
}

@MainActor
private final class RecordingInputSource: WorkspaceInputEventSourcing {
    private var handler: ((WorkspaceInputEvent) -> Bool)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(handler: @escaping (WorkspaceInputEvent) -> Bool) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        guard handler != nil else { return }
        stopCount += 1
        handler = nil
    }

    func send(_ event: WorkspaceInputEvent) -> Bool {
        handler?(event) ?? false
    }
}

@MainActor
private final class RecordingLocalMonitorRegistrar: WorkspaceLocalMonitorRegistering {
    private var handler: ((NSEvent) -> NSEvent?)?
    private(set) var removeCount = 0

    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        self.handler = handler
        return NSObject()
    }

    func removeMonitor(_ monitor: Any) {
        guard handler != nil else { return }
        removeCount += 1
        handler = nil
    }
}

private final class InputHandlerLifetime {}
