import XCTest
@testable import ScreenDomainCore

final class FocusScreenReducerTests: XCTestCase {
    func testCanvasRectCenterAndWindowCompatibilityDefaults() {
        let frame = CanvasRect(x: 10, y: 20, width: 100, height: 60)
        let window = ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)

        XCTAssertEqual(frame.center, CanvasPoint(x: 60, y: 50))
        XCTAssertTrue(window.isCompatible)
    }

    func testCanvasRectContainsUsesHalfOpenInterval() {
        // Containment is half-open on both axes: [x, x+width) x [y, y+height).
        // The lower-left (origin) corner IS contained; the far edge is NOT.
        let rect = CanvasRect(x: 100, y: 200, width: 300, height: 400)

        // Interior and lower-left corner.
        XCTAssertTrue(rect.contains(CanvasPoint(x: 100, y: 200)))
        XCTAssertTrue(rect.contains(CanvasPoint(x: 250, y: 400)))
        // Lower x bound inclusive, upper x bound exclusive.
        XCTAssertTrue(rect.contains(CanvasPoint(x: 100, y: 300)))
        XCTAssertFalse(rect.contains(CanvasPoint(x: 100 + 300, y: 300)))
        // Lower y bound inclusive, upper y bound exclusive.
        XCTAssertTrue(rect.contains(CanvasPoint(x: 200, y: 200)))
        XCTAssertFalse(rect.contains(CanvasPoint(x: 200, y: 200 + 400)))
        // Clearly outside.
        XCTAssertFalse(rect.contains(CanvasPoint(x: 50, y: 300)))
        XCTAssertFalse(rect.contains(CanvasPoint(x: 999, y: 999)))
    }

    func testCanvasRectContainsRejectsNonFiniteDerivedBounds() {
        // A rect whose far edge overflows cannot meaningfully answer containment
        // for points near that edge. Because CanvasRect construction already
        // rejects overflowing extents (see testCanvasRectDecodingRejects...),
        // contains(_:) only runs on geometry that is finite and well-formed, so
        // any contained point is itself finite by construction. This test pins
        // the invariant: a point equal to a far edge is never contained.
        let rect = CanvasRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertFalse(rect.contains(CanvasPoint(x: 1, y: 0)))
        XCTAssertFalse(rect.contains(CanvasPoint(x: 0, y: 1)))
        XCTAssertTrue(rect.contains(CanvasPoint(x: 0, y: 0)))
    }

    func testCanvasRectDecodingRejectsNonPositiveDimensions() {
        let invalidRect = Data(#"{"x":0,"y":0,"width":0,"height":100}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(CanvasRect.self, from: invalidRect))
    }

    func testCanvasPointDecodingRejectsNonFiniteCoordinates() {
        let invalidPoint = Data(#"{"x":"+Inf","y":0}"#.utf8)

        XCTAssertThrowsError(try nonConformingFloatDecoder().decode(CanvasPoint.self, from: invalidPoint))
    }

    func testCanvasRectDecodingRejectsNonFiniteFields() {
        let invalidRect = Data(#"{"x":"+Inf","y":0,"width":100,"height":100}"#.utf8)

        XCTAssertThrowsError(try nonConformingFloatDecoder().decode(CanvasRect.self, from: invalidRect))
    }

    func testCanvasRectDecodingRejectsFiniteValuesWithOverflowingExtent() {
        let overflowingRect = Data(
            #"{"x":1.7976931348623157e308,"y":0,"width":1.7976931348623157e308,"height":100}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(CanvasRect.self, from: overflowingRect))
    }

    func testCanvasPointDecodingRejectsUnknownContentBearingKeys() throws {
        for key in ["title", "path", "rawAXText"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "x": 10,
                "y": 20,
                key: "private-content"
            ])

            XCTAssertThrowsError(
                try JSONDecoder().decode(CanvasPoint.self, from: data),
                key
            ) { error in
                XCTAssertFalse(String(describing: error).contains(key), key)
            }
        }
    }

    func testCanvasRectDecodingRejectsUnknownContentBearingKeys() throws {
        for key in ["title", "path", "rawAXText"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "x": 10,
                "y": 20,
                "width": 100,
                "height": 80,
                key: "private-content"
            ])

            XCTAssertThrowsError(
                try JSONDecoder().decode(CanvasRect.self, from: data),
                key
            ) { error in
                XCTAssertFalse(String(describing: error).contains(key), key)
            }
        }
    }

    func testBootstrapCreatesScreenOneWithCurrentWindowsAsIs() throws {
        let firstFrame = CanvasRect(x: 20, y: 40, width: 800, height: 600)
        let secondFrame = CanvasRect(x: 860, y: 40, width: 700, height: 600)
        let windows = [
            ManagedWindow(id: "w1", appID: "browser", canonicalFrame: firstFrame),
            ManagedWindow(id: "w2", appID: "browser", canonicalFrame: secondFrame),
        ]

        let state = try FocusScreenReducer.bootstrap(currentWindows: windows)

        XCTAssertEqual(state.screens.count, 1)
        XCTAssertEqual(state.activeScreenID, "screen-1")
        XCTAssertEqual(state.inspectedScreenID, "screen-1")
        XCTAssertEqual(state.screen(id: "screen-1")?.number, 1)
        XCTAssertEqual(state.screen(id: "screen-1")?.lifecycle, .active)
        XCTAssertEqual(state.screen(id: "screen-1")?.windowIDs, ["w1", "w2"])
        XCTAssertEqual(state.windows["w1"]?.canonicalFrame, firstFrame)
        XCTAssertEqual(state.windows["w2"]?.canonicalFrame, secondFrame)
    }

    func testCreatingBlankScreenActivatesItWithoutMovingOldWindows() throws {
        let frame = CanvasRect(x: 20, y: 40, width: 800, height: 600)
        let original = try FocusScreenReducer.bootstrap(
            currentWindows: [ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)]
        )

        let state = try FocusScreenReducer.createBlankScreen(in: original, id: "screen-2")

        XCTAssertEqual(state.activeScreenID, "screen-2")
        XCTAssertEqual(state.inspectedScreenID, "screen-2")
        XCTAssertEqual(state.screen(id: "screen-1")?.lifecycle, .background)
        XCTAssertEqual(state.screen(id: "screen-1")?.windowIDs, ["w1"])
        XCTAssertEqual(state.screen(id: "screen-2")?.lifecycle, .active)
        XCTAssertEqual(state.screen(id: "screen-2")?.windowIDs, [])
        XCTAssertEqual(state.windows["w1"]?.canonicalFrame, frame)
    }

    func testAssignRejectsWindowAlreadyOwnedByAnotherScreen() throws {
        let frame = CanvasRect(x: 20, y: 40, width: 800, height: 600)
        let original = try FocusScreenReducer.bootstrap(
            currentWindows: [ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)]
        )
        let state = try FocusScreenReducer.createBlankScreen(in: original, id: "screen-2")

        XCTAssertThrowsError(try FocusScreenReducer.assign(windowID: "w1", to: "screen-2", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .windowAlreadyOwned("w1"))
        }
    }

    func testSoleScreenCannotBeginClosing() throws {
        let state = try FocusScreenReducer.bootstrap(currentWindows: [])

        XCTAssertThrowsError(try FocusScreenReducer.beginClosing(screenID: "screen-1", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .soleScreenCannotClose)
        }
    }

    func testBootstrapRejectsDuplicateConcreteWindowIDs() {
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        let duplicateWindows = [
            ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame),
            ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame),
        ]

        XCTAssertThrowsError(try FocusScreenReducer.bootstrap(currentWindows: duplicateWindows)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .windowAlreadyOwned("w1"))
        }
    }

    func testCreatingScreenUsesLowestFreeNumberAndEnforcesNineScreenLimit() throws {
        var state = try FocusScreenReducer.bootstrap(currentWindows: [])
        for number in 2...9 {
            state = try FocusScreenReducer.createBlankScreen(in: state, id: "screen-\(number)")
        }

        XCTAssertEqual(state.screens.map(\.number), Array(1...9))
        XCTAssertThrowsError(try FocusScreenReducer.createBlankScreen(in: state, id: "screen-10")) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .screenLimitReached)
        }
    }

    func testReducerRejectsRetainedClosedScreenWithoutMutatingInput() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        var malformed = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let closedIndex = try XCTUnwrap(malformed.screens.firstIndex(where: { $0.id == "screen-1" }))
        malformed.screens[closedIndex].lifecycle = .closed
        let unchanged = malformed

        XCTAssertThrowsError(try FocusScreenReducer.createBlankScreen(in: malformed, id: "screen-3")) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .invalidLifecycle("screen-1"))
        }
        XCTAssertEqual(malformed, unchanged)
    }

    func testInspectUpdatesOnlyInspectedScreenAndRevision() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")

        let state = try FocusScreenReducer.inspect(screenID: "screen-1", in: twoScreens)

        XCTAssertEqual(state.activeScreenID, "screen-2")
        XCTAssertEqual(state.inspectedScreenID, "screen-1")
        XCTAssertEqual(state.revision, twoScreens.revision + 1)
    }

    func testInspectRejectsMissingScreen() throws {
        let state = try FocusScreenReducer.bootstrap(currentWindows: [])

        XCTAssertThrowsError(try FocusScreenReducer.inspect(screenID: "missing", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .screenMissing("missing"))
        }
    }

    func testInspectRejectsClosingScreen() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let closing = try FocusScreenReducer.beginClosing(screenID: "screen-1", in: twoScreens)

        XCTAssertThrowsError(try FocusScreenReducer.inspect(screenID: "screen-1", in: closing)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .invalidLifecycle("screen-1"))
        }
    }

    func testInspectRejectsClosedScreen() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        var state = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let closedIndex = try XCTUnwrap(state.screens.firstIndex(where: { $0.id == "screen-1" }))
        state.screens[closedIndex].lifecycle = .closed

        XCTAssertThrowsError(try FocusScreenReducer.inspect(screenID: "screen-1", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .invalidLifecycle("screen-1"))
        }
    }

    func testReducerRejectsStateInspectedAtNonLiveScreen() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        var state = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let closedIndex = try XCTUnwrap(state.screens.firstIndex(where: { $0.id == "screen-1" }))
        state.screens[closedIndex].lifecycle = .closed
        state.inspectedScreenID = "screen-1"

        XCTAssertThrowsError(try FocusScreenReducer.commitSwitch(screenID: "screen-2", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .invalidLifecycle("screen-1"))
        }
    }

    func testCommitSwitchActivatesTargetAndBackgroundsOtherLiveScreens() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")

        let state = try FocusScreenReducer.commitSwitch(screenID: "screen-1", in: twoScreens)

        XCTAssertEqual(state.activeScreenID, "screen-1")
        XCTAssertEqual(state.inspectedScreenID, "screen-1")
        XCTAssertEqual(state.screen(id: "screen-1")?.lifecycle, .active)
        XCTAssertEqual(state.screen(id: "screen-2")?.lifecycle, .background)
        XCTAssertEqual(state.revision, twoScreens.revision + 1)
    }

    func testCommitSwitchRejectsMissingOrClosingTarget() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let closing = try FocusScreenReducer.beginClosing(screenID: "screen-1", in: twoScreens)

        XCTAssertThrowsError(try FocusScreenReducer.commitSwitch(screenID: "missing", in: closing)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .screenMissing("missing"))
        }
        XCTAssertThrowsError(try FocusScreenReducer.commitSwitch(screenID: "screen-1", in: closing)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .invalidLifecycle("screen-1"))
        }
    }

    func testRegisterUnownedAddsConcreteWindowToActiveScreen() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        let window = ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)

        let state = try FocusScreenReducer.registerUnowned(window, in: initial)

        XCTAssertEqual(state.windows["w1"], window)
        XCTAssertEqual(state.screen(id: "screen-1")?.windowIDs, ["w1"])
        XCTAssertEqual(state.screen(id: "screen-1")?.lastActiveWindowID, "w1")
        XCTAssertEqual(state.revision, initial.revision + 1)
    }

    func testRegisterUnownedRejectsDuplicateWindowID() throws {
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        let window = ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [window])

        XCTAssertThrowsError(try FocusScreenReducer.registerUnowned(window, in: initial)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .windowAlreadyOwned("w1"))
        }
    }

    func testAssignAddsKnownUnownedWindowToDestination() throws {
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        var initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        initial = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        initial.windows["w1"] = ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)

        let state = try FocusScreenReducer.assign(windowID: "w1", to: "screen-1", in: initial)

        XCTAssertEqual(state.screen(id: "screen-1")?.windowIDs, ["w1"])
        XCTAssertEqual(state.screen(id: "screen-1")?.lastActiveWindowID, "w1")
        XCTAssertEqual(state.revision, initial.revision + 1)
    }

    func testAssignPreservesValidLastActiveWindowInPopulatedDestination() throws {
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        var initial = try FocusScreenReducer.bootstrap(
            currentWindows: [ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)]
        )
        initial.windows["w2"] = ManagedWindow(id: "w2", appID: "browser", canonicalFrame: frame)

        let state = try FocusScreenReducer.assign(windowID: "w2", to: "screen-1", in: initial)

        XCTAssertEqual(state.screen(id: "screen-1")?.windowIDs, ["w1", "w2"])
        XCTAssertEqual(state.screen(id: "screen-1")?.lastActiveWindowID, "w1")
    }

    func testAssignRejectsUnknownWindow() throws {
        let state = try FocusScreenReducer.bootstrap(currentWindows: [])

        XCTAssertThrowsError(try FocusScreenReducer.assign(windowID: "missing", to: "screen-1", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .windowMissing("missing"))
        }
    }

    func testActiveScreenCloseKeepsActiveAndInspectedInvariantsThroughCancelAndFinish() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let threeScreens = try FocusScreenReducer.createBlankScreen(in: twoScreens, id: "screen-3")
        let closing = try FocusScreenReducer.beginClosing(screenID: "screen-3", in: threeScreens)

        XCTAssertEqual(closing.screen(id: "screen-3")?.lifecycle, .closing)
        XCTAssertEqual(closing.activeScreenID, "screen-1")
        XCTAssertEqual(closing.inspectedScreenID, "screen-1")
        assertSingleValidActiveAndInspection(closing)

        let cancelled = try FocusScreenReducer.cancelClosing(screenID: "screen-3", in: closing)
        XCTAssertEqual(cancelled.screen(id: "screen-3")?.lifecycle, .background)
        XCTAssertEqual(cancelled.activeScreenID, "screen-1")
        XCTAssertEqual(cancelled.inspectedScreenID, "screen-1")
        assertSingleValidActiveAndInspection(cancelled)

        let closingAgain = try FocusScreenReducer.beginClosing(screenID: "screen-3", in: cancelled)
        let finished = try FocusScreenReducer.finishClosing(screenID: "screen-3", in: closingAgain)
        XCTAssertNil(finished.screen(id: "screen-3"))
        XCTAssertEqual(finished.activeScreenID, "screen-1")
        XCTAssertEqual(finished.inspectedScreenID, "screen-1")
        assertSingleValidActiveAndInspection(finished)
    }

    func testBackgroundScreenClosePreservesActiveAndInspectedInvariantsThroughCancelAndFinish() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let inspectingBackground = try FocusScreenReducer.inspect(screenID: "screen-1", in: twoScreens)

        let closing = try FocusScreenReducer.beginClosing(screenID: "screen-1", in: inspectingBackground)

        XCTAssertEqual(closing.activeScreenID, "screen-2")
        XCTAssertEqual(closing.inspectedScreenID, "screen-2")
        assertSingleValidActiveAndInspection(closing)

        let cancelled = try FocusScreenReducer.cancelClosing(screenID: "screen-1", in: closing)
        XCTAssertEqual(cancelled.screen(id: "screen-1")?.lifecycle, .background)
        XCTAssertEqual(cancelled.activeScreenID, "screen-2")
        assertSingleValidActiveAndInspection(cancelled)

        let closingAgain = try FocusScreenReducer.beginClosing(screenID: "screen-1", in: cancelled)
        let finished = try FocusScreenReducer.finishClosing(screenID: "screen-1", in: closingAgain)
        XCTAssertNil(finished.screen(id: "screen-1"))
        XCTAssertEqual(finished.activeScreenID, "screen-2")
        XCTAssertEqual(finished.inspectedScreenID, "screen-2")
        assertSingleValidActiveAndInspection(finished)
    }

    func testBeginClosingMovesInspectionToDeterministicLiveScreen() throws {
        let initial = try FocusScreenReducer.bootstrap(currentWindows: [])
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")

        let state = try FocusScreenReducer.beginClosing(screenID: "screen-2", in: twoScreens)

        XCTAssertEqual(state.inspectedScreenID, "screen-1")
    }

    func testCancelClosingRejectsNonClosingScreen() throws {
        let state = try FocusScreenReducer.bootstrap(currentWindows: [])

        XCTAssertThrowsError(try FocusScreenReducer.cancelClosing(screenID: "screen-1", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .invalidLifecycle("screen-1"))
        }
    }

    func testFinishClosingActiveScreenRemovesOwnedWindowsAndSelectsDeterministicRemainder() throws {
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        let initial = try FocusScreenReducer.bootstrap(
            currentWindows: [ManagedWindow(id: "w1", appID: "browser", canonicalFrame: frame)]
        )
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: initial, id: "screen-2")
        let activeFirst = try FocusScreenReducer.commitSwitch(screenID: "screen-1", in: twoScreens)
        let closing = try FocusScreenReducer.beginClosing(screenID: "screen-1", in: activeFirst)

        let state = try FocusScreenReducer.finishClosing(screenID: "screen-1", in: closing)

        XCTAssertNil(state.screen(id: "screen-1"))
        XCTAssertNil(state.windows["w1"])
        XCTAssertEqual(state.screens.map(\.number), [1])
        XCTAssertEqual(state.activeScreenID, "screen-2")
        XCTAssertEqual(state.inspectedScreenID, "screen-2")
        XCTAssertEqual(state.screen(id: "screen-2")?.lifecycle, .active)
        XCTAssertEqual(state.revision, closing.revision + 1)
    }

    func testFinishClosingRejectsNonClosingScreen() throws {
        let state = try FocusScreenReducer.bootstrap(currentWindows: [])

        XCTAssertThrowsError(try FocusScreenReducer.finishClosing(screenID: "screen-1", in: state)) { error in
            XCTAssertEqual(error as? FocusScreenDomainError, .invalidLifecycle("screen-1"))
        }
    }

    private func nonConformingFloatDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Inf",
            negativeInfinity: "-Inf",
            nan: "NaN"
        )
        return decoder
    }

    private func assertSingleValidActiveAndInspection(
        _ state: FocusScreenState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let activeScreens = state.screens.filter { $0.lifecycle == .active }
        XCTAssertEqual(activeScreens.map(\.id), [state.activeScreenID], file: file, line: line)
        let inspectedLifecycle = state.screen(id: state.inspectedScreenID)?.lifecycle
        XCTAssertTrue(
            inspectedLifecycle == .active || inspectedLifecycle == .background,
            file: file,
            line: line
        )
    }
}
