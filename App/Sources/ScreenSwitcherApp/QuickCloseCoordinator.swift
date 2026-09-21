import Foundation
import ScreenDomainCore

/// The outcome of a bounded Quick Close transaction.
///
/// Quick Close asks every owned ordinary window to close via window-level AX
/// (the close button). It never calls Quit App / `NSRunningApplication.terminate()`.
/// Native unsaved-work prompts remain owned by their App: if the user cancels
/// one, the Screen returns to a live state and the still-alive window IDs are
/// reported. At least one Screen always remains (the sole Screen cannot close).
enum QuickCloseResult: Equatable {
    /// Every owned window actually closed; the Screen was removed from the state.
    case closed
    /// One or more owned windows are still alive after the close attempt (e.g. an
    /// unsaved-close-cancel prompt was dismissed). The Screen's closing state was
    /// rolled back; the listed windows remain.
    case cancelled(remainingWindowIDs: [ManagedWindowID])
    /// The Screen is the only one; the domain reducer forbids closing it.
    case soleScreenProtected
    /// A hard command failure (timeout / unsupported / vanished / failed) occurred
    /// for one window. The closing state was rolled back.
    case failed(windowID: ManagedWindowID, result: WindowCommandResult)
    /// The transaction could not proceed because the Focus state was inconsistent
    /// (e.g. a reducer guard rejected a transition that should have been valid, or
    /// a Screen vanished mid-transaction). This is a corrupt-state / validation
    /// signal, not a per-window command failure; it carries no window ID.
    case invalidState
}

/// Closes a Screen's owned ordinary windows without quitting any application.
///
/// Lifecycle (per spec section 3.1):
///   1. `FocusScreenReducer.beginClosing` enters the Closing state. For the sole
///      Screen this throws `soleScreenCannotClose`, surfaced as `.soleScreenProtected`.
///   2. Each owned **compatible** window is asked to close via the injected
///      `WindowCommandService.close` (window-level AX close-button press).
///      Incompatible windows are left as-is, exactly as in presentation.
///      A same-App window owned by a *different* Screen is never touched here,
///      because it is not in this Screen's `windowIDs`.
///   3. Each closed window is verified via a bounded liveness readback
///      (`snapshot`). A window that returns `.applied` but is still alive on
///      readback models a rejected unsaved-close prompt.
///   4. If every owned window closed, `finishClosing` removes the Screen.
///   5. Otherwise `cancelClosing` rolls the Screen back to a live state and the
///      still-alive window IDs are returned as `.cancelled(remainingWindowIDs:)`.
///
/// Bounded timeouts ensure a hung App cannot block closing unrelated windows.
@MainActor
final class QuickCloseCoordinator {
    /// Fixed delay before the single bounded liveness-readback retry (50ms). Kept
    /// small so a hung app cannot block closing unrelated windows; bounded so the
    /// overall readback stays within a predictable budget.
    private static let readbackRetryDelayNs: UInt64 = 50_000_000

    private(set) var state: FocusScreenState
    private let bindings: [ManagedWindowID: WindowRuntimeBinding]
    private let commandService: any WindowCommandService
    private let closeTimeout: TimeInterval
    private let livenessTimeout: TimeInterval

    init(
        state: FocusScreenState,
        bindings: [ManagedWindowID: WindowRuntimeBinding],
        commandService: any WindowCommandService,
        closeTimeout: TimeInterval,
        livenessTimeout: TimeInterval
    ) {
        self.state = state
        self.bindings = bindings
        self.commandService = commandService
        self.closeTimeout = closeTimeout
        self.livenessTimeout = livenessTimeout
    }

    func quickClose(screenID: FocusScreenID) async -> QuickCloseResult {
        // Step 1: enter the Closing state. The sole Screen is protected by the
        // domain reducer and surfaced gracefully.
        do {
            state = try FocusScreenReducer.beginClosing(screenID: screenID, in: state)
        } catch FocusScreenDomainError.soleScreenCannotClose {
            return .soleScreenProtected
        } catch {
            // Any other reducer rejection (missing/invalid screen) rolls back to
            // the original state by leaving `state` untouched (beginClosing is
            // throwing-and-pure). Surface as a corrupt-state signal rather than
            // a per-window failure: there is no offending window.
            return .invalidState
        }

        guard let screen = state.screen(id: screenID) else {
            // Logically unreachable immediately after a successful beginClosing;
            // if it ever fires it indicates a corrupt state, not a window failure.
            return .invalidState
        }

        // Step 2: close every owned compatible window. Incompatible windows are
        // left as-is (mirrors presentation). Only this Screen's owned windows are
        // touched — a same-App window owned by another Screen is not in this list.
        let ownedWindowIDs = screen.windowIDs
        for windowID in ownedWindowIDs {
            guard state.windows[windowID]?.isCompatible == true else { continue }
            guard let binding = bindings[windowID] else {
                return rollback(screenID: screenID, result: .failed(windowID: windowID, result: .failed))
            }
            let result = await commandService.close(binding, timeout: closeTimeout)
            guard result == .applied else {
                return rollback(screenID: screenID, result: .failed(windowID: windowID, result: result))
            }
        }

        // Step 3: bounded liveness readback. A window that returned `.applied`
        // but is still observable models a rejected unsaved-close prompt.
        //
        // `snapshot` returns nil for ANY failure (timeout, vanished, AX error), not
        // only genuine destruction. To avoid a false-`.closed` when a readback times
        // out mid-close, a nil first attempt is retried once after a short bounded
        // delay; only two consecutive nils are taken as "gone".
        //
        // This is an INTENTIONAL asymmetry with the missing-binding case above: when
        // there is no binding to verify against we conservatively keep the window
        // alive, but once `close()` returned `.applied` we treat a persistently-nil
        // snapshot as destruction (Quick Close's intent is to remove the window), so
        // we accept the residual race rather than blocking `.closed` indefinitely.
        // The retry narrows — but cannot eliminate — the mid-close race window.
        //
        // Both the retry delay and the per-snapshot timeout are bounded so a hung
        // app cannot block closing unrelated windows indefinitely.
        var remainingWindowIDs: [ManagedWindowID] = []
        for windowID in ownedWindowIDs where state.windows[windowID]?.isCompatible == true {
            // A window with no binding cannot be read back; treat as still alive
            // so we never report a close we could not verify.
            guard let binding = bindings[windowID] else {
                remainingWindowIDs.append(windowID)
                continue
            }
            let firstSnapshot = await commandService.snapshot(binding, timeout: livenessTimeout)
            if firstSnapshot != nil {
                remainingWindowIDs.append(windowID)
                continue
            }
            // One bounded retry: a single nil can be a mid-close timeout, not
            // destruction. Re-probe after a short fixed delay; if the window is
            // still observable it survived the close (e.g. dismissed prompt).
            try? await Task.sleep(nanoseconds: Self.readbackRetryDelayNs)
            let retrySnapshot = await commandService.snapshot(binding, timeout: livenessTimeout)
            if retrySnapshot != nil {
                remainingWindowIDs.append(windowID)
            }
        }

        // Step 4 / 5: finish or cancel based on verified liveness.
        if remainingWindowIDs.isEmpty {
            do {
                state = try FocusScreenReducer.finishClosing(screenID: screenID, in: state)
                return .closed
            } catch {
                // finishClosing should not throw here; if it does the state is
                // inconsistent, not a per-window command failure.
                return rollback(screenID: screenID, result: .invalidState)
            }
        } else {
            return rollback(
                screenID: screenID,
                result: .cancelled(remainingWindowIDs: remainingWindowIDs)
            )
        }
    }

    /// Rolls the Screen back to a live (non-closing) state via
    /// `cancelClosing`, then returns the supplied result. Used for both the
    /// cancelled (windows still alive) and hard-failure paths so the Screen is
    /// never left in the Closing state after the coordinator returns.
    @discardableResult
    private func rollback(
        screenID: FocusScreenID,
        result: QuickCloseResult
    ) -> QuickCloseResult {
        if let rolled = try? FocusScreenReducer.cancelClosing(screenID: screenID, in: state) {
            state = rolled
        }
        return result
    }
}
