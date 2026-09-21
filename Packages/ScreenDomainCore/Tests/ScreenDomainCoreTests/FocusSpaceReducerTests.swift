import XCTest
@testable import ScreenDomainCore

final class FocusSpaceReducerTests: XCTestCase {

    // MARK: - Helpers

    private func makeState() throws -> FocusScreenState {
        let windows = [
            ManagedWindow(id: "w1", appID: "com.example.editor", canonicalFrame: CanvasRect(x: 0, y: 0, width: 800, height: 600)),
            ManagedWindow(id: "w2", appID: "com.example.browser", canonicalFrame: CanvasRect(x: 800, y: 0, width: 800, height: 600))
        ]
        return try FocusScreenReducer.bootstrap(currentWindows: windows)
    }

    // MARK: - saveSpace

    func testSaveSpaceCreatesNewSpaceFromActiveScreen() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")

        XCTAssertEqual(saved.savedSpaces.count, 1)
        let space = try XCTUnwrap(saved.space(id: "space-1"))
        XCTAssertEqual(space.lifecycle, .open)
        XCTAssertEqual(space.boundScreenID, "screen-1")
        XCTAssertEqual(space.appSlots.count, 2)
        XCTAssertEqual(space.appSlots[0].bundleID, "com.example.editor")
        XCTAssertEqual(space.appSlots[1].bundleID, "com.example.browser")
        XCTAssertEqual(space.defaultSlotID, "slot-1")

        // Screen is bound to the Space.
        let screen = try XCTUnwrap(saved.screen(id: "screen-1"))
        XCTAssertEqual(screen.spaceID, "space-1")

        // Revision bumped.
        XCTAssertGreaterThan(saved.revision, state.revision)
    }

    func testSaveSpaceRejectsAlreadyOpenSpace() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")

        // Trying to save the same ID from a different Screen should reject.
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: saved, id: "screen-2")
        XCTAssertThrowsError(
            try FocusSpaceReducer.saveSpace(from: twoScreens, id: "space-1")
        ) { error in
            XCTAssertEqual(error as? FocusSpaceDomainError, .spaceAlreadyOpen("space-1"))
        }
    }

    func testSaveSpaceEnforcesMaxCount() throws {
        // The max is 9 Saved Spaces. Create 9 spaces by saving, closing, and
        // re-saving on the same screen (so we don't exhaust the 9-screen limit).
        var state = try makeState()
        for n in 1...9 {
            state = try FocusSpaceReducer.saveSpace(from: state, id: "space-\(n)")
            // Close the space so the screen is free for the next save.
            state = try FocusSpaceReducer.closeSpace("space-\(n)", in: state)
        }
        XCTAssertEqual(state.savedSpaces.count, 9)

        // The 10th space should fail (screen-1 is free after close, but space limit is hit).
        XCTAssertThrowsError(
            try FocusSpaceReducer.saveSpace(from: state, id: "space-10")
        ) { error in
            XCTAssertEqual(error as? FocusSpaceDomainError, .spaceLimitReached)
        }
    }

    // MARK: - saveAsNewSpace

    func testSaveAsNewSpaceCopiesAndRebinds() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")
        let copied = try FocusSpaceReducer.saveAsNewSpace(from: saved, newID: "space-2")

        XCTAssertEqual(copied.savedSpaces.count, 2)
        // The new Space is open and bound to the active screen.
        let newSpace = try XCTUnwrap(copied.space(id: "space-2"))
        XCTAssertEqual(newSpace.lifecycle, .open)
        XCTAssertEqual(newSpace.boundScreenID, "screen-1")
        // The old Space is now restorable (no longer bound).
        let oldSpace = try XCTUnwrap(copied.space(id: "space-1"))
        // Actually, saveAsNewSpace rebinds; the old space stays in whatever state
        // it was. Since we bound screen-1 → space-1, then copied to space-2 and
        // rebound screen-1 → space-2, space-1 should now be unbound.
        XCTAssertNil(oldSpace.boundScreenID)
    }

    // MARK: - restoreSpace

    func testRestoreSpaceRebuildsAndBinds() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")
        // Close the Space so it becomes restorable.
        let closed = try FocusSpaceReducer.closeSpace("space-1", in: saved)
        let restorableSpace = try XCTUnwrap(closed.space(id: "space-1"))
        XCTAssertEqual(restorableSpace.lifecycle, .restorable)

        // Restore into the active screen.
        let restored = try FocusSpaceReducer.restoreSpace("space-1", into: "screen-1", in: closed)
        let restoredSpace = try XCTUnwrap(restored.space(id: "space-1"))
        XCTAssertEqual(restoredSpace.lifecycle, .open)
        XCTAssertEqual(restoredSpace.boundScreenID, "screen-1")
        XCTAssertFalse(restoredSpace.autoSaveSuspended)
    }

    func testRestoreSpaceRejectsAlreadyOpen() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")

        // Space is already open — restore should reject.
        XCTAssertThrowsError(
            try FocusSpaceReducer.restoreSpace("space-1", into: "screen-1", in: saved)
        ) { error in
            XCTAssertEqual(error as? FocusSpaceDomainError, .spaceAlreadyOpen("space-1"))
        }
    }

    func testRestoreSpaceRejectsScreenBoundElsewhere() throws {
        let state = try makeState()
        // Save + close space-1 so it's restorable.
        let savedSpace1 = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")
        let closedSpace1 = try FocusSpaceReducer.closeSpace("space-1", in: savedSpace1)

        // Create a second screen and bind it to space-2.
        let twoScreens = try FocusScreenReducer.createBlankScreen(in: closedSpace1, id: "screen-2")
        let savedSpace2 = try FocusSpaceReducer.saveSpace(from: twoScreens, id: "space-2")

        // screen-2 is bound to space-2; trying to restore space-1 into it should reject.
        XCTAssertThrowsError(
            try FocusSpaceReducer.restoreSpace("space-1", into: "screen-2", in: savedSpace2)
        ) { error in
            XCTAssertEqual(error as? FocusSpaceDomainError, .screenAlreadyBound("screen-2"))
        }
    }

    // MARK: - suspendAutoSave / resumeAutoSave

    func testSuspendAutoSaveBlocksUpdates() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")
        let suspended = try FocusSpaceReducer.suspendAutoSave("space-1", in: saved)

        let space = try XCTUnwrap(suspended.space(id: "space-1"))
        XCTAssertTrue(space.autoSaveSuspended)

        // Trying to save (auto-save path) while suspended should reject.
        XCTAssertThrowsError(
            try FocusSpaceReducer.saveSpace(from: suspended, id: "space-1")
        ) { error in
            XCTAssertEqual(error as? FocusSpaceDomainError, .autoSaveSuspended("space-1"))
        }
    }

    func testResumeAutoSaveAllowsUpdates() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")
        let suspended = try FocusSpaceReducer.suspendAutoSave("space-1", in: saved)
        let resumed = try FocusSpaceReducer.resumeAutoSave("space-1", in: suspended)

        let space = try XCTUnwrap(resumed.space(id: "space-1"))
        XCTAssertFalse(space.autoSaveSuspended)

        // Now saving should succeed.
        let reSaved = try FocusSpaceReducer.saveSpace(from: resumed, id: "space-1")
        let reSavedSpace = try XCTUnwrap(reSaved.space(id: "space-1"))
        XCTAssertEqual(reSavedSpace.lifecycle, .open)
    }

    // MARK: - closeSpace

    func testCloseSpaceReturnsToRestorable() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")
        let closed = try FocusSpaceReducer.closeSpace("space-1", in: saved)

        let space = try XCTUnwrap(closed.space(id: "space-1"))
        XCTAssertEqual(space.lifecycle, .restorable)
        XCTAssertNil(space.boundScreenID)
        XCTAssertFalse(space.autoSaveSuspended)

        // Screen is unbound.
        let screen = try XCTUnwrap(closed.screen(id: "screen-1"))
        XCTAssertNil(screen.spaceID)
    }

    // MARK: - deleteSpace

    func testDeleteSpaceOnlyRestorable() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")

        // Cannot delete an open Space.
        XCTAssertThrowsError(
            try FocusSpaceReducer.deleteSpace("space-1", in: saved)
        ) { error in
            XCTAssertEqual(error as? FocusSpaceDomainError, .spaceAlreadyOpen("space-1"))
        }

        // Close first, then delete.
        let closed = try FocusSpaceReducer.closeSpace("space-1", in: saved)
        let deleted = try FocusSpaceReducer.deleteSpace("space-1", in: closed)
        XCTAssertTrue(deleted.savedSpaces.isEmpty)
    }

    // MARK: - Revision monotonicity

    func testSpaceTransitionsBumpRevision() throws {
        let state = try makeState()
        let saved = try FocusSpaceReducer.saveSpace(from: state, id: "space-1")
        XCTAssertGreaterThan(saved.revision, state.revision)

        let suspended = try FocusSpaceReducer.suspendAutoSave("space-1", in: saved)
        XCTAssertGreaterThan(suspended.revision, saved.revision)

        let closed = try FocusSpaceReducer.closeSpace("space-1", in: suspended)
        XCTAssertGreaterThan(closed.revision, suspended.revision)
    }
}
