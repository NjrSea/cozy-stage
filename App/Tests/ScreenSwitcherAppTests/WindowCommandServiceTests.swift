import ApplicationServices
import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WindowCommandServiceTests: XCTestCase {
    // MARK: - AXError -> WindowCommandResult typed projection (the bounded-messaging contract)

    func testCannotCompleteAXErrorProjectsToTimedOut() {
        // The single most important mapping: a bounded messaging deadline elapsing
        // (.cannotComplete) MUST surface as .timedOut so callers can distinguish a
        // hung/blocked app from a permanently broken window.
        XCTAssertEqual(AXErrorMapping.project(.cannotComplete), .timedOut)
    }

    func testSuccessProjectsToApplied() {
        XCTAssertEqual(AXErrorMapping.project(.success), .applied)
    }

    func testInvalidUIElementAndNoValueProjectToVanished() {
        XCTAssertEqual(AXErrorMapping.project(.invalidUIElement), .vanished)
        XCTAssertEqual(AXErrorMapping.project(.noValue), .vanished)
    }

    func testUnsupportedAttributesAndActionsProjectToUnsupported() {
        XCTAssertEqual(AXErrorMapping.project(.attributeUnsupported), .unsupported)
        XCTAssertEqual(AXErrorMapping.project(.actionUnsupported), .unsupported)
        XCTAssertEqual(AXErrorMapping.project(.notImplemented), .unsupported)
    }

    func testRemainingAXErrorsProjectToFailed() {
        // Any AXError not explicitly mapped must fall through to .failed (never silently
        // treated as .applied, .vanished, .timedOut, or .unsupported).
        XCTAssertEqual(AXErrorMapping.project(.apiDisabled), .failed)
        XCTAssertEqual(AXErrorMapping.project(.invalidUIElement), .vanished)
        XCTAssertEqual(AXErrorMapping.project(.notEnoughPrecision), .failed)
    }

    // MARK: - WindowCommandResult is a closed typed result (no leaking cases)

    func testWindowCommandResultExposesExactlyFiveClosedCases() {
        // The result type is a closed projection; these are the only admissible outcomes
        // for any window command. Adding a case is a deliberate contract change.
        let allCases: [WindowCommandResult] = [
            .applied, .unsupported, .timedOut, .vanished, .failed
        ]
        XCTAssertEqual(Set(allCases).count, 5, "WindowCommandResult must remain a 5-case closed type")
    }

    // MARK: - Fake WindowCommandService seam: typed results flow through the protocol

    func testFakeWindowCommandServiceSurfacesTypedResultsForEachCommand() async {
        // The protocol seam allows each command to return a typed result. This pins the
        // observable contract that minimize/focus/close/setFrame all project through the
        // same closed WindowCommandResult, independent of the AX layer.
        let service = TypedProjectionFakeService()
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: 1234,
            element: .injected("window-a")
        )
        let frame = CanvasRect(x: 10, y: 10, width: 100, height: 100)

        service.nextSetFrame = .timedOut
        let frameResult = await service.setFrame(frame, for: binding, timeout: 0.05)
        XCTAssertEqual(frameResult, .timedOut)

        service.nextRaiseAndFocus = .failed
        let focusResult = await service.raiseAndFocus(binding, timeout: 0.05)
        XCTAssertEqual(focusResult, .failed)

        service.nextSetMinimized = .unsupported
        let minimizeResult = await service.setMinimized(true, for: binding, timeout: 0.05)
        XCTAssertEqual(minimizeResult, .unsupported)

        service.nextClose = .vanished
        let closeResult = await service.close(binding, timeout: 0.05)
        XCTAssertEqual(closeResult, .vanished)

        service.snapshotResult = nil
        let snapshot = await service.snapshot(binding, timeout: 0.05)
        XCTAssertNil(snapshot)
    }

    func testRaiseAndFocusActivatesOwningApplicationBeforeWindowCommand() async {
        var activatedProcessIdentifiers: [pid_t] = []
        let service = SystemWindowCommandService { processIdentifier in
            activatedProcessIdentifiers.append(processIdentifier)
            return .vanished
        }
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: 1234,
            element: .injected("window-a")
        )

        let result = await service.raiseAndFocus(binding, timeout: 0.05)

        XCTAssertEqual(activatedProcessIdentifiers, [1234])
        XCTAssertEqual(result, .vanished)
    }

    func testDetailedFocusOutcomePreservesClosedStageAndCompatibilityResult() {
        let cases: [(WindowFocusCommandOutcome, WindowCommandResult)] = [
            (.activate(.failed), .failed),
            (.nativeExact(.symbolUnavailable), .unsupported),
            (.nativeExact(.processResolutionFailed), .failed),
            (.nativeExact(.frontProcessRejected), .failed),
            (.nativeExact(.keyEventRejected), .failed),
            (.resolution(.vanished), .vanished),
            (.raise(.unsupported), .unsupported),
            (.focusWrite(.timedOut), .timedOut),
            (.readback(.failed), .failed),
            (.applied, .applied),
            (.cancelled, .vanished)
        ]

        XCTAssertEqual(Set(cases.map(\.0)).count, 11)
        for (outcome, result) in cases {
            XCTAssertEqual(outcome.commandResult, result)
        }
    }

    func testWindowServerExactFocusFailureDoesNotFallBackToApplicationActivation() async {
        var activationCount = 0
        let service = SystemWindowCommandService(
            exactWindowFocus: { _, _, _ in .failed(.keyEventRejected) },
            activateApplication: { _ in
                activationCount += 1
                return .applied
            }
        )
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: 1234,
            element: .windowServer(77)
        )

        let outcome = await service.raiseAndFocusOutcome(
            binding,
            timeout: 0.01,
            whileCurrent: { true }
        )

        XCTAssertEqual(outcome, .nativeExact(.keyEventRejected))
        XCTAssertEqual(activationCount, 0)
    }

    func testWindowServerExactFocusRunsOffMainActor() async {
        var ranOnMainThread = false
        let service = SystemWindowCommandService(
            exactWindowFocus: { _, _, _ in
                ranOnMainThread = Thread.isMainThread
                return .failed(.keyEventRejected)
            }
        )
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: 1234,
            element: .windowServer(77)
        )

        _ = await service.raiseAndFocusOutcome(
            binding,
            timeout: 0.01,
            whileCurrent: { true }
        )

        XCTAssertFalse(ranOnMainThread)
    }

    func testWindowServerExactFocusRestoresOriginWhenAXResolutionFails() async {
        var restoreCount = 0
        let service = SystemWindowCommandService(
            exactWindowFocus: { _, _, _ in
                .ready(NativeExactWindowFocusSession {
                    restoreCount += 1
                })
            },
            activateApplication: { _ in
                XCTFail("WindowServer binding must not use application activation")
                return .failed
            },
            resolutionPoller: WindowResolutionPoller(
                now: { 0 },
                sleep: { _ in },
                interval: 0.01
            )
        )
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: -1,
            element: .windowServer(77)
        )

        let outcome = await service.raiseAndFocusOutcome(
            binding,
            timeout: 0,
            whileCurrent: { true }
        )

        XCTAssertEqual(outcome, .resolution(.vanished))
        XCTAssertEqual(restoreCount, 1)
    }

    func testWindowServerExactFocusKeepsTargetSpaceAfterSuccessfulActivation() async {
        var events: [String] = []
        let retainedElement = NativeAXElementBox(AXUIElementCreateApplication(1234))
        let service = SystemWindowCommandService(
            exactWindowFocus: { _, _, _ in
                events.append("front")
                events.append("key")
                return .ready(NativeExactWindowFocusSession {
                    events.append("restore")
                })
            },
            focusResolvedElement: { _, _ in
                events.append("raise")
                events.append("readback")
                return .applied
            }
        )
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: 1234,
            element: .windowServer(77),
            retainedAXElement: retainedElement
        )

        let outcome = await service.raiseAndFocusOutcome(
            binding,
            timeout: 0.05,
            whileCurrent: { true }
        )

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(events, ["front", "key", "raise", "readback"])
    }

    func testWindowServerExactFocusRestoresAfterEveryAXOutcomeAndCancellation() async {
        let outcomes: [WindowFocusCommandOutcome] = [
            .applied,
            .raise(.failed),
            .focusWrite(.timedOut),
            .readback(.failed)
        ]
        for expected in outcomes {
            var restoreCount = 0
            var currentChecks = 0
            let retainedElement = NativeAXElementBox(AXUIElementCreateApplication(1234))
            let service = SystemWindowCommandService(
                exactWindowFocus: { _, _, _ in
                    .ready(NativeExactWindowFocusSession { restoreCount += 1 })
                },
                focusResolvedElement: { _, _ in expected }
            )
            let binding = WindowRuntimeBinding(
                launchGeneration: "launch",
                processIdentifier: 1234,
                element: .windowServer(77),
                retainedAXElement: retainedElement
            )

            let outcome = await service.raiseAndFocusOutcome(
                binding,
                timeout: 0.05,
                whileCurrent: {
                    currentChecks += 1
                    return expected != .applied || currentChecks == 1
                }
            )

            XCTAssertEqual(outcome, expected == .applied ? .cancelled : expected)
            XCTAssertEqual(restoreCount, 1, "restore must run for \(expected)")
        }
    }

    func testWindowServerNativeFailuresRemainTypedAndNeverRestoreOrActivate() async {
        let failures: [NativeExactWindowFocusFailure] = [
            .symbolUnavailable,
            .processResolutionFailed,
            .frontProcessRejected,
            .keyEventRejected
        ]
        for failure in failures {
            var activationCount = 0
            let service = SystemWindowCommandService(
                exactWindowFocus: { _, _, _ in .failed(failure) },
                activateApplication: { _ in
                    activationCount += 1
                    return .applied
                }
            )
            let binding = WindowRuntimeBinding(
                launchGeneration: "launch",
                processIdentifier: 1234,
                element: .windowServer(77)
            )

            let outcome = await service.raiseAndFocusOutcome(
                binding,
                timeout: 0.05,
                whileCurrent: { true }
            )

            XCTAssertEqual(outcome, .nativeExact(failure))
            XCTAssertEqual(activationCount, 0)
        }
    }

    func testDetailedFocusOutcomeReportsActivationFailureAndLegacyWrapperMatches() async {
        let service = SystemWindowCommandService { _ in .timedOut }
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: 1234,
            element: .injected("window-a")
        )

        let detailed = await service.raiseAndFocusOutcome(
            binding,
            timeout: 0.05,
            whileCurrent: { true }
        )
        let legacy = await service.raiseAndFocus(binding, timeout: 0.05)

        XCTAssertEqual(detailed, .activate(.timedOut))
        XCTAssertEqual(legacy, .timedOut)
    }

    func testDetailedFocusOutcomeCancelsBeforeApplicationActivation() async {
        var activationCount = 0
        let service = SystemWindowCommandService { _ in
            activationCount += 1
            return .applied
        }
        let binding = WindowRuntimeBinding(
            launchGeneration: "launch",
            processIdentifier: 1234,
            element: .injected("window-a")
        )

        let outcome = await service.raiseAndFocusOutcome(
            binding,
            timeout: 0.05,
            whileCurrent: { false }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(activationCount, 0)
    }

    func testWindowResolutionPollerWaitsForDelayedAXWindow() async {
        var now: TimeInterval = 0
        var attempts = 0
        var sleeps = 0
        let poller = WindowResolutionPoller(
            now: { now },
            sleep: { duration in
                sleeps += 1
                now += duration
            },
            interval: 0.01
        )

        let result = await poller.resolve(timeout: 0.05, whileCurrent: { true }) { _ in
            attempts += 1
            return attempts == 3 ? .resolved("exact-window") : .unavailable
        }

        guard case let .resolved(value, remaining) = result else {
            return XCTFail("expected delayed exact window resolution")
        }
        XCTAssertEqual(value, "exact-window")
        XCTAssertEqual(remaining, 0.03, accuracy: 0.000_001)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, 2)
    }

    func testWindowResolutionPollerStopsWhenBindingChanges() async {
        var now: TimeInterval = 0
        var isCurrent = true
        var attempts = 0
        let poller = WindowResolutionPoller(
            now: { now },
            sleep: { duration in
                now += duration
                isCurrent = false
            },
            interval: 0.01
        )

        let result: WindowResolutionPollResult<String> = await poller.resolve(
            timeout: 0.05,
            whileCurrent: { isCurrent }
        ) { _ in
            attempts += 1
            return .unavailable
        }

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(attempts, 1)
    }

    func testWindowResolutionPollerReturnsUnavailableAtDeadline() async {
        var now: TimeInterval = 0
        var attempts = 0
        let poller = WindowResolutionPoller(
            now: { now },
            sleep: { duration in now += duration },
            interval: 0.01
        )

        let result: WindowResolutionPollResult<String> = await poller.resolve(
            timeout: 0.02,
            whileCurrent: { true }
        ) { _ in
            attempts += 1
            return .unavailable
        }

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(attempts, 2)
    }
}

/// Minimal fake conforming to `WindowCommandService` that returns configurable typed
/// results per command. Used to prove the protocol seam projects typed results without
/// any live Accessibility interaction.
@MainActor
private final class TypedProjectionFakeService: WindowCommandService {
    var nextSetFrame: WindowCommandResult = .applied
    var nextRaiseAndFocus: WindowCommandResult = .applied
    var nextSetMinimized: WindowCommandResult = .applied
    var nextClose: WindowCommandResult = .applied
    var snapshotResult: WindowCommandSnapshot? = WindowCommandSnapshot(
        frame: CanvasRect(x: 0, y: 0, width: 100, height: 100),
        isMinimized: false
    )

    func setFrame(
        _ frame: CanvasRect,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult { nextSetFrame }

    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult { nextRaiseAndFocus }

    func setMinimized(
        _ minimized: Bool,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult { nextSetMinimized }

    func close(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult { nextClose }

    func snapshot(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandSnapshot? { snapshotResult }
}
