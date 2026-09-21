import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class SafetyRecoveryCoordinatorTests: XCTestCase {
    func testRevealAllRestoresAndUnminimizesEveryLiveWindowIndependently() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let canonicalFrames = recoveryFrames()
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        let commands = TransactionCommandService(
            states: canonicalFrames.reduce(into: [:]) { result, entry in
                result[entry.key] = WindowCommandSnapshot(
                    frame: CanvasRect(x: 2_000, y: entry.value.y, width: entry.value.width, height: entry.value.height),
                    isMinimized: true
                )
            }
        )
        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        XCTAssertEqual(result, .complete)
        XCTAssertTrue(recovery.incompatibleWindowIDs.isEmpty)
        for (id, frame) in canonicalFrames {
            XCTAssertEqual(commands.states[id], WindowCommandSnapshot(frame: frame, isMinimized: false))
        }
    }

    func testRevealAllReturnsTypedIncompleteIDsWhenOwnedWindowIsNeitherVisibleNorClosed() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let canonicalFrames = recoveryFrames()
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        let commands = TransactionCommandService(
            states: canonicalFrames.reduce(into: [:]) { result, entry in
                result[entry.key] = WindowCommandSnapshot(frame: entry.value, isMinimized: false)
            }
        )
        commands.snapshotOverrides["window-a"] = .value(WindowCommandSnapshot(
            frame: CanvasRect(x: 2_000, y: 20, width: 300, height: 240),
            isMinimized: false
        ))
        commands.snapshotOverrides["window-b"] = .unreadable
        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        // window-b's restore commands SUCCEEDED (TransactionCommandService returns .applied)
        // and snapshot is nil afterwards -> safely vanished, so only window-a is incomplete.
        XCTAssertEqual(result, .incomplete(windowIDs: ["window-a"]))
        XCTAssertEqual(result.failureCode, .revealAllIncomplete)
        XCTAssertEqual(recovery.incompatibleWindowIDs, ["window-a"])
        XCTAssertTrue(commands.events.contains(.setFrame("window-b", canonicalFrames["window-b"]!)))
        XCTAssertTrue(commands.events.contains(.setMinimized("window-b", false)))
        XCTAssertTrue(commands.events.contains(.snapshot("window-b")))
    }

    // MARK: - Risk #1: nil snapshot after a FAILED restore command is NOT a safe vanish

    func testNilSnapshotAfterFailedRestoreCommandIsReportedIncompleteNotSkipped() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let canonicalFrames = recoveryFrames()
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        let commands = TransactionCommandService(
            states: canonicalFrames.reduce(into: [:]) { result, entry in
                result[entry.key] = WindowCommandSnapshot(frame: entry.value, isMinimized: false)
            }
        )
        // window-a's setFrame fails (e.g. AX timeout / accessibility loss) AND its
        // post-restore snapshot is nil. The window may still be alive off-Canvas and
        // unreadable -- it MUST be reported incomplete, not silently skipped as vanished.
        commands.oneShotResults[.setFrame("window-a", canonicalFrames["window-a"]!)] = .timedOut
        commands.snapshotOverrides["window-a"] = .unreadable

        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        XCTAssertEqual(result, .incomplete(windowIDs: ["window-a"]))
        XCTAssertEqual(result.failureCode, .revealAllIncomplete)
        XCTAssertEqual(recovery.incompatibleWindowIDs, ["window-a"])
    }

    func testNilSnapshotAfterSuccessfulRestoreCommandIsTreatedAsSafeVanish() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let canonicalFrames = recoveryFrames()
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        let commands = TransactionCommandService(
            states: canonicalFrames.reduce(into: [:]) { result, entry in
                result[entry.key] = WindowCommandSnapshot(frame: entry.value, isMinimized: false)
            }
        )
        // Restore commands succeed for both windows; window-a then reports nil snapshot.
        // After a SUCCESSFUL restore, a nil snapshot reasonably means the window vanished
        // on its own -> safe to skip (complete), not incomplete.
        commands.snapshotOverrides["window-a"] = .unreadable

        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(recovery.incompatibleWindowIDs, [])
    }

    // MARK: - A hung window must not block other windows' recovery

    func testHungWindowDoesNotBlockOtherWindowsRecovery() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let canonicalFrames = [
            "hung": CanvasRect(x: 20, y: 20, width: 300, height: 240),
            "healthy-a": CanvasRect(x: 400, y: 80, width: 360, height: 300),
            "healthy-b": CanvasRect(x: 800, y: 120, width: 320, height: 260)
        ]
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        let commands = TransactionCommandService(
            states: canonicalFrames.reduce(into: [:]) { result, entry in
                result[entry.key] = WindowCommandSnapshot(frame: entry.value, isMinimized: false)
            }
        )
        // The hung window's setFrame times out and it is genuinely unreadable afterwards
        // (nil snapshot). Recovery is independent per window, so the healthy windows must
        // STILL be restored + unminimized despite the hung one failing.
        commands.oneShotResults[.setFrame("hung", canonicalFrames["hung"]!)] = .timedOut
        commands.snapshotOverrides["hung"] = .unreadable

        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        XCTAssertEqual(result, .incomplete(windowIDs: ["hung"]))
        XCTAssertEqual(result.failureCode, .revealAllIncomplete)
        XCTAssertEqual(recovery.incompatibleWindowIDs, ["hung"])
        // Healthy windows still get restored + unminimized despite the hung window.
        XCTAssertTrue(commands.events.contains(.setFrame("healthy-a", canonicalFrames["healthy-a"]!)))
        XCTAssertTrue(commands.events.contains(.setMinimized("healthy-a", false)))
        XCTAssertTrue(commands.events.contains(.setFrame("healthy-b", canonicalFrames["healthy-b"]!)))
        XCTAssertTrue(commands.events.contains(.setMinimized("healthy-b", false)))
    }

    // MARK: - Reveal All uses pre-transaction canonical frames, not post-park frames

    func testRevealAllRestoresFromPreTransactionCanonicalFramesNotPostParkFrames() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let canonical = CanvasRect(x: 100, y: 100, width: 400, height: 300)
        let canonicalFrames: [ManagedWindowID: CanvasRect] = ["window-a": canonical]
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        // The window is currently parked off-Canvas (a post-park frame). Reveal All must
        // restore to the pre-transaction canonical frame passed in, NOT leave it parked.
        let parkedFrame = CanvasRect(x: 5_000, y: 0, width: 400, height: 300)
        let commands = TransactionCommandService(
            states: ["window-a": WindowCommandSnapshot(frame: parkedFrame, isMinimized: false)]
        )

        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(commands.states["window-a"], WindowCommandSnapshot(frame: canonical, isMinimized: false))
        XCTAssertTrue(commands.events.contains(.setFrame("window-a", canonical)))
        XCTAssertFalse(commands.events.contains(.setFrame("window-a", parkedFrame)))
    }

    // MARK: - Visible-As-Is after a command failure is safe but marked incompatible

    func testVisibleAsIsAfterCommandFailureIsMarkedIncompatibleButNotIncomplete() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let canonicalFrames = recoveryFrames()
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        let commands = TransactionCommandService(
            states: canonicalFrames.reduce(into: [:]) { result, entry in
                result[entry.key] = WindowCommandSnapshot(frame: entry.value, isMinimized: false)
            }
        )
        // window-a's restore command fails, but it remains visible (snapshot shows it on canvas).
        // It is safe (visible) but must be marked incompatible; not reported incomplete.
        commands.oneShotResults[.setFrame("window-a", canonicalFrames["window-a"]!)] = .unsupported
        commands.snapshotOverrides["window-a"] = .value(WindowCommandSnapshot(
            frame: canonicalFrames["window-a"]!,
            isMinimized: false
        ))

        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(recovery.incompatibleWindowIDs, ["window-a"])
    }

    // MARK: - reveal_all_incomplete code emitted only on incomplete

    func testCompleteResultEmitsNoFailureCode() {
        XCTAssertEqual(SafetyRecoveryResult.complete.failureCode, nil)
    }

    func testIncompleteResultOrderingPreservesSortedIDs() async {
        let canvas = CanvasRect(x: 0, y: 0, width: 1_200, height: 800)
        let ids = ["zebra", "alpha", "mike"]
        let canonicalFrames = ids.reduce(into: [ManagedWindowID: CanvasRect]()) { result, id in
            result[id] = CanvasRect(x: 100, y: 100, width: 300, height: 200)
        }
        let bindings = recoveryBindings(for: canonicalFrames.keys)
        let commands = TransactionCommandService(
            states: canonicalFrames.reduce(into: [:]) { result, entry in
                result[entry.key] = WindowCommandSnapshot(frame: entry.value, isMinimized: false)
            }
        )
        // All windows park off-Canvas -> all incomplete. IDs must be reported sorted.
        for id in ids {
            commands.snapshotOverrides[id] = .value(WindowCommandSnapshot(
                frame: CanvasRect(x: 5_000, y: 0, width: 300, height: 200),
                isMinimized: false
            ))
        }

        let recovery = SafetyRecoveryCoordinator(
            commandService: commands,
            stitchedCanvasRegions: [canvas],
            commandTimeout: 0.05
        )

        let result = await recovery.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )

        XCTAssertEqual(result, .incomplete(windowIDs: ["alpha", "mike", "zebra"]))
    }
}

private func recoveryFrames() -> [ManagedWindowID: CanvasRect] {
    [
        "window-a": CanvasRect(x: 20, y: 20, width: 300, height: 240),
        "window-b": CanvasRect(x: 400, y: 80, width: 360, height: 300)
    ]
}

private func recoveryBindings<S: Sequence>(
    for IDs: S
) -> [ManagedWindowID: WindowRuntimeBinding] where S.Element == ManagedWindowID {
    IDs.sorted().enumerated().reduce(into: [:]) { result, entry in
        let (index, id) = entry
        result[id] = WindowRuntimeBinding(
            launchGeneration: "launch-\(id)",
            processIdentifier: pid_t(index + 100),
            element: .injected(id)
        )
    }
}
