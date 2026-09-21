import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class QuickCloseCoordinatorTests: XCTestCase {
    // MARK: - Owned windows are closed; the sole Screen is protected

    func testSoleScreenCannotCloseAndDoesNotInvokeAnyWindowClose() async {
        // The domain reducer forbids closing the only Screen. The coordinator must
        // surface this gracefully and never touch a window.
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-1",
            screenCount: 1
        )
        let commands = fixture.commands
        let initialState = coordinator.state

        let result = await coordinator.quickClose(screenID: "screen-1")

        XCTAssertEqual(result, .soleScreenProtected)
        // State is untouched: beginClosing threw before any mutation.
        XCTAssertEqual(coordinator.state, initialState)
        XCTAssertFalse(commands.events.contains { $0.windowID.hasPrefix("w-") })
    }

    // MARK: - Close for owned windows only; no app-quit / terminate

    func testQuickCloseAsksEveryOwnedWindowToCloseAndCommitsWhenAllClosed() async {
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2
        )
        let commands = fixture.commands

        let result = await coordinator.quickClose(screenID: "screen-A")

        XCTAssertEqual(result, .closed)
        // Every owned compatible window received exactly one close request.
        let closeEvents = commands.events.filter {
            if case .close = $0 { return true }
            return false
        }
        XCTAssertEqual(closeEvents.count, 2)
        XCTAssertTrue(closeEvents.contains(.close("w-A1")))
        XCTAssertTrue(closeEvents.contains(.close("w-A2")))
        XCTAssertNil(coordinator.state.screen(id: "screen-A"))
    }

    func testQuickCloseNeverInvokesAnyTerminateAPI() async {
        // Quick Close must close windows only — never quit the application.
        // The fake records any "terminate" probe via a dedicated event so a
        // future regression (e.g. NSRunningApplication.terminate) is observable.
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2
        )
        let commands = fixture.commands

        _ = await coordinator.quickClose(screenID: "screen-A")

        XCTAssertFalse(
            commands.terminateInvoked,
            "Quick Close must never call an app-terminate API; window-level close only"
        )
    }

    // MARK: - Preserve same-App windows owned by another Screen

    func testQuickClosePreservesSameAppWindowOwnedByAnotherScreen() async {
        // w-shared has the SAME appID as w-A1 but is owned by screen-B.
        // Closing screen-A must NOT close w-shared, even though they share an app.
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2,
            sharedAppWindowID: "w-shared",
            sharedAppWindowScreen: "screen-B"
        )
        let commands = fixture.commands

        let result = await coordinator.quickClose(screenID: "screen-A")

        XCTAssertEqual(result, .closed)
        XCTAssertFalse(commands.events.contains(.close("w-shared")))
        XCTAssertNotNil(coordinator.state.windows["w-shared"])
    }

    // MARK: - Cancelled close (e.g. unsaved-work prompt rejected)

    func testCancelledNativeCloseReturnsRemainingWindowIDsAndCancelsClosingState() async {
        // The user dismisses an unsaved-close prompt for w-A2, so the window stays
        // alive. The coordinator must report the remaining window IDs and roll the
        // Screen back to a live (non-closing) state — windows already closed are
        // NOT fabricated or silently recreated.
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2
        )
        // w-A2's native close is rejected: AX close returns .applied but the window
        // is still alive on readback (unsaved-close-cancel).
        fixture.commands.closeRejectedAliveWindowIDs = ["w-A2"]

        let result = await coordinator.quickClose(screenID: "screen-A")

        guard case let .cancelled(remaining) = result else {
            XCTFail("expected .cancelled, got \(result)")
            return
        }
        XCTAssertEqual(remaining, ["w-A2"])
        // The Screen is back to a live lifecycle (closing rolled back).
        let screen = coordinator.state.screen(id: "screen-A")
        XCTAssertNotNil(screen)
        XCTAssertNotEqual(screen?.lifecycle, .closing)
        // w-A1 was closed at the AX layer (state removed in fake); it is NOT
        // recreated by the cancel path.
        // w-A2 is still present.
        XCTAssertNotNil(coordinator.state.windows["w-A2"])
    }

    // MARK: - Close only completes after all owned windows actually closed

    func testQuickCloseDoesNotReportClosedWhenAWindowSurvives() async {
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2
        )
        // Both windows reject close and stay alive -> cancelled with both IDs.
        fixture.commands.closeRejectedAliveWindowIDs = ["w-A1", "w-A2"]

        let result = await coordinator.quickClose(screenID: "screen-A")

        guard case let .cancelled(remaining) = result else {
            XCTFail("expected .cancelled, got \(result)")
            return
        }
        XCTAssertEqual(Set(remaining), Set(["w-A1", "w-A2"]))
    }

    // MARK: - Liveness readback retry narrows the mid-close race

    func testFirstSnapshotNilThenRetryAliveReportsCancelled() async {
        // w-A2's first readback returns nil (mid-close timeout/AX blip), but the
        // bounded retry observes the window still alive. The coordinator must NOT
        // falsely conclude the window is gone: it reports .cancelled with w-A2.
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2
        )
        fixture.commands.snapshotFirstNilWindowIDs = ["w-A2"]

        let result = await coordinator.quickClose(screenID: "screen-A")

        guard case let .cancelled(remaining) = result else {
            XCTFail("expected .cancelled, got \(result)")
            return
        }
        XCTAssertEqual(remaining, ["w-A2"])
        // w-A2 was snapshotted exactly twice (first nil + retry alive).
        XCTAssertEqual(fixture.commands.snapshotCallCounts["w-A2"], 2)
        // The Screen was rolled back to a live (non-closing) state.
        let screen = coordinator.state.screen(id: "screen-A")
        XCTAssertNotEqual(screen?.lifecycle, .closing)
    }

    func testTwoConsecutiveNilSnapshotsReportsClosed() async {
        // A normally-closed window is removed from the fake's `states`, so both
        // the first snapshot and the retry return nil. Two consecutive nils are
        // taken as destruction -> .closed. Asserts the retry happens and still
        // concludes the window is gone.
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2
        )

        let result = await coordinator.quickClose(screenID: "screen-A")

        XCTAssertEqual(result, .closed)
        // Each window was snapshotted exactly twice (first nil + retry nil),
        // proving the bounded retry fired and still reached .closed.
        XCTAssertEqual(fixture.commands.snapshotCallCounts["w-A1"], 2)
        XCTAssertEqual(fixture.commands.snapshotCallCounts["w-A2"], 2)
        XCTAssertNil(coordinator.state.screen(id: "screen-A"))
    }

    // MARK: - Hard command failure surfaces a typed failure

    func testHardCommandFailureSurfacesTypedFailureWithoutFabricatingClose() async {
        // A genuine AX failure (not a rejected prompt) for one window must surface
        // as .failed with the offending window + result, and must NOT silently
        // complete as .closed.
        let fixture = QuickCloseFixture()
        let coordinator = fixture.makeCoordinator(
            screenID: "screen-A",
            screenCount: 2
        )
        fixture.commands.oneShotResults[.init(event: .close("w-A1"))] = .timedOut

        let result = await coordinator.quickClose(screenID: "screen-A")

        guard case let .failed(windowID, commandResult) = result else {
            XCTFail("expected .failed, got \(result)")
            return
        }
        XCTAssertEqual(windowID, "w-A1")
        XCTAssertEqual(commandResult, WindowCommandResult.timedOut)
        // Closing state rolled back.
        let screen = coordinator.state.screen(id: "screen-A")
        XCTAssertNotEqual(screen?.lifecycle, .closing)
    }
}

// MARK: - Fixture

@MainActor
private final class QuickCloseFixture {
    let commands = QuickCloseCommandService()

    func makeCoordinator(
        screenID: FocusScreenID,
        screenCount: Int,
        sharedAppWindowID: ManagedWindowID? = nil,
        sharedAppWindowScreen: FocusScreenID? = nil
    ) -> QuickCloseCoordinator {
        let built = QuickCloseFixture.build(
            screenCount: screenCount,
            sharedAppWindowID: sharedAppWindowID,
            sharedAppWindowScreen: sharedAppWindowScreen
        )
        commands.states = built.snapshots
        commands.idByBinding = built.idByBinding
        return QuickCloseCoordinator(
            state: built.state,
            bindings: built.bindings,
            commandService: commands,
            closeTimeout: 0.05,
            livenessTimeout: 0.05
        )
    }

    private static func build(
        screenCount: Int,
        sharedAppWindowID: ManagedWindowID?,
        sharedAppWindowScreen: FocusScreenID?
    ) -> (state: FocusScreenState,
          bindings: [ManagedWindowID: WindowRuntimeBinding],
          snapshots: [ManagedWindowID: WindowCommandSnapshot],
          idByBinding: [WindowRuntimeBinding: ManagedWindowID]) {
        // Two screens, each with two windows. screen-A's w-A1 and screen-B's
        // optional w-shared share appID "app-shared" to exercise same-app preservation.
        var windows: [ManagedWindowID: ManagedWindow] = [
            "w-A1": ManagedWindow(id: "w-A1", appID: "app-shared", canonicalFrame: CanvasRect(x: 0, y: 0, width: 400, height: 300)),
            "w-A2": ManagedWindow(id: "w-A2", appID: "app-A2", canonicalFrame: CanvasRect(x: 500, y: 0, width: 400, height: 300)),
            "w-B1": ManagedWindow(id: "w-B1", appID: "app-B1", canonicalFrame: CanvasRect(x: 0, y: 0, width: 400, height: 300)),
            "w-B2": ManagedWindow(id: "w-B2", appID: "app-B2", canonicalFrame: CanvasRect(x: 500, y: 0, width: 400, height: 300))
        ]
        var screenAWindows = ["w-A1", "w-A2"]
        var screenBWindows = ["w-B1", "w-B2"]
        if let shared = sharedAppWindowID, let sharedScreen = sharedAppWindowScreen {
            windows[shared] = ManagedWindow(
                id: shared,
                appID: "app-shared",
                canonicalFrame: CanvasRect(x: 1_000, y: 0, width: 400, height: 300)
            )
            switch sharedScreen {
            case "screen-A": screenAWindows.append(shared)
            default: screenBWindows.append(shared)
            }
        }

        let screens: [FocusScreen]
        if screenCount == 1 {
            screens = [
                FocusScreen(id: "screen-1", number: 1, lifecycle: .active, windowIDs: screenAWindows, lastActiveWindowID: screenAWindows.last)
            ]
        } else {
            screens = [
                FocusScreen(id: "screen-A", number: 1, lifecycle: .active, windowIDs: screenAWindows, lastActiveWindowID: screenAWindows.last),
                FocusScreen(id: "screen-B", number: 2, lifecycle: .background, windowIDs: screenBWindows, lastActiveWindowID: screenBWindows.last)
            ]
        }
        let state = FocusScreenState(
            screens: screens,
            windows: windows,
            activeScreenID: screens.first { $0.lifecycle == .active }!.id,
            inspectedScreenID: screens.first { $0.lifecycle == .active }!.id,
            revision: 1
        )

        let ids = Array(windows.keys).sorted()
        var bindings: [ManagedWindowID: WindowRuntimeBinding] = [:]
        var idByBinding: [WindowRuntimeBinding: ManagedWindowID] = [:]
        var snapshots: [ManagedWindowID: WindowCommandSnapshot] = [:]
        for id in ids {
            let binding = WindowRuntimeBinding(
                launchGeneration: "launch-\(id)",
                processIdentifier: pid_t(abs(id.hashValue) % 32_000 + 100),
                element: .injected(id)
            )
            bindings[id] = binding
            idByBinding[binding] = id
            snapshots[id] = WindowCommandSnapshot(
                frame: windows[id]!.canonicalFrame,
                isMinimized: false,
                isFocused: false
            )
        }
        return (state, bindings, snapshots, idByBinding)
    }
}

// MARK: - Fake command service for Quick Close

private enum QuickCloseCommandEvent: Equatable {
    case close(ManagedWindowID)
    case snapshot(ManagedWindowID)

    var windowID: ManagedWindowID {
        switch self {
        case let .close(id), let .snapshot(id):
            return id
        }
    }
}

private struct QuickCloseCommandKey: Hashable {
    let event: QuickCloseCommandEvent

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.event == rhs.event
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: event))
    }
}

/// Window-command fake dedicated to Quick Close semantics.
///
/// Unlike the transaction fake, close() distinguishes:
///   - a normal close (window removed from `states`)
///   - a *rejected* close (AX returns .applied, but the window is still alive on
///     readback — modelling an unsaved-close-cancel prompt)
///   - a hard failure via `oneShotResults`
@MainActor
private final class QuickCloseCommandService: WindowCommandService {
    var states: [ManagedWindowID: WindowCommandSnapshot] = [:]
    var idByBinding: [WindowRuntimeBinding: ManagedWindowID] = [:]
    var oneShotResults: [QuickCloseCommandKey: WindowCommandResult] = [:]
    /// Windows whose close is "applied" but which stay alive on readback
    /// (unsaved-close-cancel). Stored as a set so the test reads naturally.
    var closeRejectedAliveWindowIDs: Set<ManagedWindowID> = []
    /// Windows whose FIRST snapshot readback returns nil (modelling a mid-close
    /// timeout) even though the window is still alive. The retry then returns the
    /// live snapshot. Exercises the single bounded retry -> still-alive path.
    var snapshotFirstNilWindowIDs: Set<ManagedWindowID> = []
    /// Number of snapshot calls observed per window ID.
    private(set) var snapshotCallCounts: [ManagedWindowID: Int] = [:]
    private(set) var events: [QuickCloseCommandEvent] = []
    /// Set if any terminate/quit API is ever invoked. Quick Close must never do this.
    private(set) var terminateInvoked = false

    func setFrame(
        _ frame: CanvasRect,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult { .unsupported }

    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult { .unsupported }

    func setMinimized(
        _ minimized: Bool,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult { .unsupported }

    func close(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        let id = self.id(binding)
        events.append(.close(id))
        if let result = oneShotResults.removeValue(forKey: .init(event: .close(id))) {
            return result
        }
        if closeRejectedAliveWindowIDs.contains(id) {
            // AX close accepted the press, but the unsaved-close prompt was
            // dismissed, so the window is NOT removed from `states`.
            return .applied
        }
        if snapshotFirstNilWindowIDs.contains(id) {
            // Window stays alive (transient first-readback blip modelled in
            // snapshot); do NOT remove from `states` so the retry observes it.
            return .applied
        }
        states.removeValue(forKey: id)
        return .applied
    }

    func snapshot(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandSnapshot? {
        let id = self.id(binding)
        events.append(.snapshot(id))
        snapshotCallCounts[id, default: 0] += 1
        // First readback returns nil for windows flagged as mid-close-timing-out,
        // modelling a transient readback failure rather than destruction. The
        // coordinator's single bounded retry will re-probe and observe the window.
        if snapshotFirstNilWindowIDs.contains(id), snapshotCallCounts[id, default: 0] == 1 {
            return nil
        }
        return states[id]
    }

    /// Probe that would invoke NSRunningApplication.terminate() / Quit App.
    /// Quick Close must NEVER call this. Exposed for the no-terminate assertion.
    func terminateApp(_: String) {
        terminateInvoked = true
    }

    private func id(_ binding: WindowRuntimeBinding) -> ManagedWindowID {
        if case let .injected(id) = binding.axElement { return id }
        return idByBinding[binding] ?? ""
    }
}
