import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WorkspaceExecutionTests: XCTestCase {
    func testAppExecutionRefreshesLiveStateAndUsesEligibleWindowOnRequestedDisplay() async throws {
        let left = executionDisplay(id: "left", x: -1_280, y: 0, width: 1_280, height: 800)
        let right = executionDisplay(id: "right", x: 0, y: 0, width: 1_440, height: 900)
        let staleWindow = executionWindow(id: "stale", appID: "com.example.Editor", displayID: "left", rank: 0)
        let targetWindow = executionWindow(id: "target", appID: "com.example.Editor", displayID: "right", rank: 1)
        let olderTargetWindow = executionWindow(id: "older", appID: "com.example.Editor", displayID: "right", rank: 3)
        let minimizedTargetWindow = executionWindow(
            id: "minimized",
            appID: "com.example.Editor",
            displayID: "right",
            rank: 0,
            isMinimized: true
        )
        let newerWrongDisplay = executionWindow(id: "wrong", appID: "com.example.Editor", displayID: "left", rank: 0)
        let live = ExecutionLiveStateProvider(states: [
            WorkspaceExecutionLiveState(
                displays: [left, right],
                runningAppIDs: ["com.example.Editor"],
                windows: [staleWindow, targetWindow]
            ),
            WorkspaceExecutionLiveState(
                displays: [left, right],
                runningAppIDs: ["com.example.Editor"],
                windows: [newerWrongDisplay, olderTargetWindow, minimizedTargetWindow, targetWindow]
            ),
        ])
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: live,
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )
        let request = WorkspaceExecutionRequest(
            id: .init(rawValue: 7),
            target: .app(displayID: "right", appID: "com.example.Editor")
        )
        guard case .success = await executor.execute(request) else {
            return XCTFail("fresh display-scoped App execution should succeed")
        }

        XCTAssertEqual(live.readCount, 2, "execute must select, then immediately revalidate")
        XCTAssertEqual(recorder.focusedWindowIDs, ["target"])
        XCTAssertEqual(recorder.events, ["accessibility", "pointer:right", "activate:com.example.Editor", "focus:target"])
    }

    func testAppExecutionUsesChangedWindowFromImmediateRevalidation() async {
        let display = executionDisplay(id: "display", x: 0, y: 0, width: 1_000, height: 800)
        let live = ExecutionLiveStateProvider(states: [
            .init(
                displays: [display],
                runningAppIDs: ["com.example.Editor"],
                windows: [executionWindow(id: "old", appID: "com.example.Editor", displayID: "display", rank: 0)]
            ),
            .init(
                displays: [display],
                runningAppIDs: ["com.example.Editor"],
                windows: [executionWindow(id: "new", appID: "com.example.Editor", displayID: "display", rank: 0)]
            ),
        ])
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: live,
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )

        guard case .success = await executor.execute(appRequest()) else {
            return XCTFail("changed live window should be selected during immediate revalidation")
        }
        XCTAssertEqual(recorder.focusedWindowIDs, ["new"])
    }

    func testDisplayExecutionMovesPointerWithoutAccessibilityOrAppSideEffects() async {
        let display = executionDisplay(id: "display", x: -1_200, y: 900, width: 1_200, height: 800)
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: ExecutionLiveStateProvider(states: [
                .init(displays: [display], runningAppIDs: [], windows: []),
            ]),
            accessibilityGate: DeniedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )

        guard case .success = await executor.execute(.init(
            id: .init(rawValue: 9),
            target: .display("display")
        )) else {
            return XCTFail("display pointer execution must not require App/window Accessibility")
        }
        XCTAssertEqual(recorder.events, ["pointer:display"])
    }

    func testDisplayExecutionFocusesMostRecentEligibleExistingWindowAfterPointerMove() async {
        let display = executionDisplay(id: "display", x: 0, y: 0, width: 1_000, height: 800)
        let other = executionDisplay(id: "other", x: 1_000, y: 0, width: 1_000, height: 800)
        let live = ExecutionLiveStateProvider(states: [
            .init(
                displays: [display, other],
                runningAppIDs: ["com.example.Old", "com.example.Recent"],
                windows: [
                    executionWindow(id: "old", appID: "com.example.Old", displayID: "display", rank: 4),
                    executionWindow(id: "other", appID: "com.example.Recent", displayID: "other", rank: 0),
                    executionWindow(id: "recent", appID: "com.example.Recent", displayID: "display", rank: 0),
                ]
            ),
            .init(
                displays: [display, other],
                runningAppIDs: ["com.example.Old", "com.example.Recent"],
                windows: [
                    executionWindow(id: "old", appID: "com.example.Old", displayID: "display", rank: 4),
                    executionWindow(id: "recent", appID: "com.example.Recent", displayID: "display", rank: 0),
                ]
            ),
        ])
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: live,
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )

        guard case .success = await executor.execute(.init(
            id: .init(rawValue: 10),
            target: .display("display")
        )) else {
            return XCTFail("display execution should focus its best existing window")
        }
        XCTAssertEqual(recorder.events, [
            "accessibility", "pointer:display", "activate:com.example.Recent", "focus:recent",
        ])
    }

    func testFreshAXInventoryBypassesColdCacheAndReportsTypedTimeout() async throws {
        let display = DisplayDescriptor(
            id: "display",
            frame: try RectDescriptor(x: 0, y: 0, width: 1_000, height: 800),
            isCurrent: true
        )
        let processProvider = ExecutionProcessIdentifierProvider(values: [
            "com.example.Editor": [42],
        ])
        let candidate = AXWindowMetadataCandidate(
            id: "fresh",
            axFrame: try RectDescriptor(x: 100, y: 100, width: 500, height: 400),
            isFocused: true,
            isMain: true,
            isMinimized: false
        )
        let candidateReader = ExecutionCandidateReader(results: [.success([candidate])])
        let reader = AppKitWindowMetadataReader(
            permissionService: executionPermissionService(),
            processIdentifierProvider: processProvider,
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 800,
            globalBudget: 0.1,
            refreshScheduler: DormantExecutionRefreshScheduler()
        )

        XCTAssertTrue(reader.eligibleWindows(
            for: ["com.example.Editor"],
            displays: [display]
        )["com.example.Editor", default: []].isEmpty,
        "cold background cache must not satisfy execute")
        guard case let .success(windows) = await reader.freshEligibleWindows(
            for: ["com.example.Editor"],
            displays: [display]
        ) else {
            return XCTFail("fresh execution query should bypass the cold cache")
        }
        XCTAssertEqual(windows["com.example.Editor"]?.map(\.id), ["accessibility-fresh"])

        let timeoutReader = AppKitWindowMetadataReader(
            permissionService: executionPermissionService(),
            processIdentifierProvider: processProvider,
            candidateReader: ExecutionCandidateReader(results: [.timedOut]),
            appKitMainDisplayMaxY: 800,
            globalBudget: 0.1,
            refreshScheduler: DormantExecutionRefreshScheduler()
        )
        guard case .failure(.windowQueryTimedOut) = await timeoutReader.freshEligibleWindows(
            for: ["com.example.Editor"],
            displays: [display]
        ) else {
            return XCTFail("fresh AX timeout must stay typed")
        }
    }

    func testRemovedDisplayFailsBeforeAnyRealInput() async {
        let live = ExecutionLiveStateProvider(states: [
            WorkspaceExecutionLiveState(displays: [], runningAppIDs: [], windows: []),
        ])
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: live,
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )

        let result = await executor.execute(.init(
            id: .init(rawValue: 1),
            target: .display("removed")
        ))

        guard case .failure(.targetDisplayRemoved) = result else {
            return XCTFail("removed display must remain a typed failure")
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testSecondLiveQueryFailureOccursBeforeAnyInputSideEffect() async {
        let display = executionDisplay(id: "display", x: 0, y: 0, width: 1_000, height: 800)
        let state = WorkspaceExecutionLiveState(
            displays: [display],
            runningAppIDs: ["com.example.Editor"],
            windows: [
                executionWindow(
                    id: "window",
                    appID: "com.example.Editor",
                    displayID: "display",
                    rank: 0
                ),
            ]
        )
        let live = ExecutionResultLiveStateProvider(results: [
            .success(state),
            .failure(.windowQueryTimedOut),
        ])
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: live,
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )

        guard case .failure(.windowQueryTimedOut) = await executor.execute(appRequest()) else {
            return XCTFail("final query timeout must stay typed")
        }
        XCTAssertEqual(recorder.events, ["accessibility"])
    }

    func testDisplayRemovalDuringFinalRevalidationOccursBeforePointerInput() async {
        let display = executionDisplay(id: "display", x: 0, y: 0, width: 1_000, height: 800)
        let live = ExecutionResultLiveStateProvider(results: [
            .success(.init(displays: [display], runningAppIDs: [], windows: [])),
            .success(.init(displays: [], runningAppIDs: [], windows: [])),
        ])
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: live,
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )

        guard case .failure(.targetDisplayRemoved) = await executor.execute(.init(
            id: .init(rawValue: 11),
            target: .display("display")
        )) else {
            return XCTFail("final display removal must stay typed")
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testCancellationDuringFinalQueryPreventsEveryInputSideEffect() async {
        let display = executionDisplay(id: "display", x: 0, y: 0, width: 1_000, height: 800)
        let state = WorkspaceExecutionLiveState(
            displays: [display],
            runningAppIDs: ["com.example.Editor"],
            windows: [
                executionWindow(
                    id: "window",
                    appID: "com.example.Editor",
                    displayID: "display",
                    rank: 0
                ),
            ]
        )
        let secondQueryStarted = expectation(description: "second query started")
        let live = SuspendedSecondLiveStateProvider(
            state: state,
            secondQueryStarted: secondQueryStarted
        )
        let recorder = ExecutionRecorder()
        let executor = WorkspaceExecutionService(
            liveStateProvider: live,
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )

        let task = Task { await executor.execute(appRequest()) }
        await fulfillment(of: [secondQueryStarted], timeout: 1)
        task.cancel()
        live.resumeSecondQuery()

        guard case .failure(.actionOverloaded) = await task.value else {
            return XCTFail("cancelled execution must stop with a typed failure")
        }
        XCTAssertEqual(recorder.events, ["accessibility"])
    }

    func testSafePointStaysStrictlyInsideVisibleBoundsForNegativeVerticalAndTinyDisplays() throws {
        let cases = [
            (
                try RectDescriptor(x: -1_920, y: 0, width: 1_920, height: 1_080),
                try RectDescriptor(x: -1_920, y: 24, width: 1_920, height: 1_020)
            ),
            (
                try RectDescriptor(x: 0, y: 900, width: 1_200, height: 1_600),
                try RectDescriptor(x: 0, y: 930, width: 1_200, height: 1_520)
            ),
            (
                try RectDescriptor(x: -2, y: -2, width: 4, height: 4),
                try RectDescriptor(x: -1, y: -1, width: 2, height: 2)
            ),
        ]

        for (frame, safe) in cases {
            let point = try XCTUnwrap(WorkspaceSafePoint.resolve(
                displayFrame: frame,
                safeBounds: safe
            ))
            XCTAssertTrue(frame.contains(point))
            XCTAssertTrue(safe.contains(point))
            XCTAssertGreaterThan(point.x, safe.x)
            XCTAssertLessThan(point.x, safe.maxX)
            XCTAssertGreaterThan(point.y, safe.y)
            XCTAssertLessThan(point.y, safe.maxY)
        }
    }

    func testTerminationNoWindowAccessibilityAndScreenRecordingAdvisoryAreTyped() async {
        let display = executionDisplay(id: "display", x: 0, y: 0, width: 1_000, height: 800)
        let recorder = ExecutionRecorder()

        let terminated = makeExecutor(
            state: .init(displays: [display], runningAppIDs: [], windows: []),
            recorder: recorder
        )
        guard case .failure(.targetAppTerminated) = await terminated.execute(appRequest()) else {
            return XCTFail("terminated App must be typed")
        }

        let noWindow = makeExecutor(
            state: .init(displays: [display], runningAppIDs: ["com.example.Editor"], windows: []),
            recorder: recorder
        )
        guard case .failure(.targetAppWindowUnavailable) = await noWindow.execute(appRequest()) else {
            return XCTFail("missing eligible window must be typed")
        }

        let deniedRecorder = ExecutionRecorder()
        let denied = WorkspaceExecutionService(
            liveStateProvider: ExecutionLiveStateProvider(states: [
                .init(
                    displays: [display],
                    runningAppIDs: ["com.example.Editor"],
                    windows: [],
                ),
            ]),
            accessibilityGate: DeniedAccessibilityGate(recorder: deniedRecorder),
            pointerMover: RecordingPointerMover(recorder: deniedRecorder),
            appActivator: RecordingExistingAppActivator(recorder: deniedRecorder),
            windowFocuser: RecordingWindowFocuser(recorder: deniedRecorder)
        )
        guard case .failure(.accessibilityMissing) = await denied.execute(appRequest()) else {
            return XCTFail("Accessibility must gate App focus")
        }
        XCTAssertEqual(deniedRecorder.events, ["accessibility"])

        let advisoryRecorder = ExecutionRecorder()
        let advisory = makeExecutor(
            state: .init(
                displays: [display],
                runningAppIDs: ["com.example.Editor"],
                windows: [executionWindow(id: "window", appID: "com.example.Editor", displayID: "display", rank: 0)],
            ),
            recorder: advisoryRecorder
        )
        guard case .success = await advisory.execute(appRequest()) else {
            return XCTFail("Screen Recording is preview advisory only")
        }
    }

    func testPointerActivationAndWindowFocusFailuresStayTypedAndStopInOrder() async {
        let display = executionDisplay(id: "display", x: 0, y: 0, width: 1_000, height: 800)
        let state = WorkspaceExecutionLiveState(
            displays: [display],
            runningAppIDs: ["com.example.Editor"],
            windows: [executionWindow(
                id: "window",
                appID: "com.example.Editor",
                displayID: "display",
                rank: 0
            )]
        )

        let pointerRecorder = ExecutionRecorder()
        let pointerFailure = WorkspaceExecutionService(
            liveStateProvider: ExecutionLiveStateProvider(states: [state]),
            accessibilityGate: AllowedAccessibilityGate(recorder: pointerRecorder),
            pointerMover: ConfigurablePointerMover(recorder: pointerRecorder, succeeds: false),
            appActivator: RecordingExistingAppActivator(recorder: pointerRecorder),
            windowFocuser: RecordingWindowFocuser(recorder: pointerRecorder)
        )
        guard case .failure(.pointerMoveFailed) = await pointerFailure.execute(appRequest()) else {
            return XCTFail("pointer failure must stay typed")
        }
        XCTAssertEqual(pointerRecorder.events, ["accessibility", "pointer:display"])

        let activationRecorder = ExecutionRecorder()
        let activationFailure = WorkspaceExecutionService(
            liveStateProvider: ExecutionLiveStateProvider(states: [state]),
            accessibilityGate: AllowedAccessibilityGate(recorder: activationRecorder),
            pointerMover: RecordingPointerMover(recorder: activationRecorder),
            appActivator: ConfigurableExistingAppActivator(recorder: activationRecorder, succeeds: false),
            windowFocuser: RecordingWindowFocuser(recorder: activationRecorder)
        )
        guard case .failure(.appActivationFailed) = await activationFailure.execute(appRequest()) else {
            return XCTFail("existing App activation failure must stay typed")
        }
        XCTAssertEqual(activationRecorder.events, [
            "accessibility", "pointer:display", "activate:com.example.Editor",
        ])

        let focusRecorder = ExecutionRecorder()
        let focusFailure = WorkspaceExecutionService(
            liveStateProvider: ExecutionLiveStateProvider(states: [state]),
            accessibilityGate: AllowedAccessibilityGate(recorder: focusRecorder),
            pointerMover: RecordingPointerMover(recorder: focusRecorder),
            appActivator: RecordingExistingAppActivator(recorder: focusRecorder),
            windowFocuser: ConfigurableWindowFocuser(recorder: focusRecorder, outcome: .timedOut)
        )
        guard case .failure(.appWindowActivationTimedOut) = await focusFailure.execute(appRequest()) else {
            return XCTFail("window focus timeout must stay typed")
        }
        XCTAssertEqual(focusRecorder.events, [
            "accessibility", "pointer:display", "activate:com.example.Editor", "focus:window",
        ])
    }

    func testMatchingSuccessClosesWhileFailureOnlyClearsPending() async throws {
        let successOrder = ExecutionRecorder()
        let successExecutor = CompletionExecutor(result: .success(()), recorder: successOrder)
        let successCoordinator = WorkspaceExecutionCoordinator(executor: successExecutor)
        let successClosed = expectation(description: "success closes")
        var successModel: WorkspaceInteractionModel!
        successModel = executionModel(
            close: {
                successOrder.events.append("close")
                successClosed.fulfill()
            },
            request: { request in
                successCoordinator.handle(request) { completion in
                    _ = successModel.completeExecution(completion)
                }
            }
        )
        XCTAssertTrue(successModel.send(.activateApp("com.example.Editor")))
        await fulfillment(of: [successClosed], timeout: 1)
        XCTAssertEqual(successOrder.events, ["execute", "close"])

        let failureOrder = ExecutionRecorder()
        let failureExecutor = CompletionExecutor(result: .failure(.appActivationFailed), recorder: failureOrder)
        let failureCoordinator = WorkspaceExecutionCoordinator(executor: failureExecutor)
        let failureCompleted = expectation(description: "failure completion delivered")
        var failureModel: WorkspaceInteractionModel!
        failureModel = executionModel(
            close: { failureOrder.events.append("close") },
            request: { request in
                failureCoordinator.handle(request) { completion in
                    _ = failureModel.completeExecution(completion)
                    failureCompleted.fulfill()
                }
            }
        )
        XCTAssertTrue(failureModel.send(.activateApp("com.example.Editor")))
        await fulfillment(of: [failureCompleted], timeout: 1)
        XCTAssertNil(failureModel.pendingExecutionRequest)
        XCTAssertEqual(failureModel.presentation.executionFailure, .appActivationFailed)
        XCTAssertEqual(failureOrder.events, ["execute"])
    }

    private func appRequest() -> WorkspaceExecutionRequest {
        .init(
            id: .init(rawValue: 1),
            target: .app(displayID: "display", appID: "com.example.Editor")
        )
    }

    private func makeExecutor(
        state: WorkspaceExecutionLiveState,
        recorder: ExecutionRecorder
    ) -> WorkspaceExecutionService {
        WorkspaceExecutionService(
            liveStateProvider: ExecutionLiveStateProvider(states: [state]),
            accessibilityGate: AllowedAccessibilityGate(recorder: recorder),
            pointerMover: RecordingPointerMover(recorder: recorder),
            appActivator: RecordingExistingAppActivator(recorder: recorder),
            windowFocuser: RecordingWindowFocuser(recorder: recorder)
        )
    }

    private func executionModel(
        close: @escaping @MainActor () -> Void,
        request: @escaping @MainActor (WorkspaceExecutionRequest) -> Void
    ) -> WorkspaceInteractionModel {
        let display = DisplayDescriptor(
            id: "display",
            frame: try! RectDescriptor(x: 0, y: 0, width: 1_000, height: 800),
            isCurrent: true
        )
        let app = RunningAppDescriptor(
            id: "com.example.Editor",
            displayName: "Editor",
            mostRecentWindow: nil
        )
        return WorkspaceInteractionModel(
            content: .init(
                workspaces: [.init(display: display, apps: [app], previewAvailability: .available)],
                selectedDisplayID: "display"
            ),
            selectedTab: .switch,
            closeHandler: { _ in close() },
            executionRequestHandler: request
        )
    }
}

private func executionDisplay(
    id: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double
) -> WorkspaceExecutionDisplay {
    let frame = try! RectDescriptor(x: x, y: y, width: width, height: height)
    let safe = try! RectDescriptor(x: x + 8, y: y + 24, width: width - 16, height: height - 32)
    return WorkspaceExecutionDisplay(
        display: DisplayDescriptor(id: id, frame: frame, isCurrent: false),
        safeBounds: safe
    )
}

private func executionWindow(
    id: String,
    appID: String,
    displayID: String,
    rank: Int,
    isMinimized: Bool = false
) -> WorkspaceExecutionWindow {
    WorkspaceExecutionWindow(
        appID: appID,
        displayID: displayID,
        window: WindowDescriptor(
            id: id,
            frame: try! RectDescriptor(x: 100, y: 100, width: 500, height: 400),
            isOnScreen: true,
            isMain: rank == 0
        ),
        isMinimized: isMinimized,
        recencyRank: rank
    )
}

@MainActor
private final class ExecutionLiveStateProvider: WorkspaceExecutionLiveStateProviding {
    private let states: [WorkspaceExecutionLiveState]
    private(set) var readCount = 0

    init(states: [WorkspaceExecutionLiveState]) {
        self.states = states
    }

    func freshState() async -> Result<WorkspaceExecutionLiveState, SwitcherActionFailure> {
        defer { readCount += 1 }
        return .success(states[min(readCount, states.count - 1)])
    }
}

@MainActor
private final class ExecutionResultLiveStateProvider: WorkspaceExecutionLiveStateProviding {
    private var results: [Result<WorkspaceExecutionLiveState, SwitcherActionFailure>]

    init(results: [Result<WorkspaceExecutionLiveState, SwitcherActionFailure>]) {
        self.results = results
    }

    func freshState() async -> Result<WorkspaceExecutionLiveState, SwitcherActionFailure> {
        results.isEmpty ? .failure(.windowQueryUnavailable) : results.removeFirst()
    }
}

@MainActor
private final class SuspendedSecondLiveStateProvider: WorkspaceExecutionLiveStateProviding {
    private let state: WorkspaceExecutionLiveState
    private let secondQueryStarted: XCTestExpectation
    private var readCount = 0
    private var continuation: CheckedContinuation<
        Result<WorkspaceExecutionLiveState, SwitcherActionFailure>,
        Never
    >?

    init(state: WorkspaceExecutionLiveState, secondQueryStarted: XCTestExpectation) {
        self.state = state
        self.secondQueryStarted = secondQueryStarted
    }

    func freshState() async -> Result<WorkspaceExecutionLiveState, SwitcherActionFailure> {
        readCount += 1
        guard readCount > 1 else { return .success(state) }
        secondQueryStarted.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func resumeSecondQuery() {
        continuation?.resume(returning: .success(state))
        continuation = nil
    }
}

@MainActor
private struct ExecutionProcessIdentifierProvider: RunningAppProcessIdentifierProviding {
    let values: [String: [pid_t]]

    func processIdentifier(for appID: String) -> pid_t? { values[appID]?.first }
    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        Dictionary(uniqueKeysWithValues: appIDs.map { ($0, values[$0, default: []]) })
    }
}

private final class ExecutionCandidateReader: @unchecked Sendable,
    AXWindowMetadataCandidateReading,
    AXWindowMetadataCandidateQuerying {
    private let lock = NSLock()
    private var results: [AXWindowMetadataCandidateQueryResult]

    init(results: [AXWindowMetadataCandidateQueryResult]) { self.results = results }

    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        switch queryCandidates(for: processIdentifier, messagingTimeout: messagingTimeout) {
        case let .success(candidates): candidates
        case .timedOut, .unavailable: []
        }
    }

    func queryCandidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> AXWindowMetadataCandidateQueryResult {
        lock.withLock {
            results.isEmpty ? .success([]) : results.removeFirst()
        }
    }
}

private struct DormantExecutionRefreshScheduler: WindowMetadataRefreshScheduling {
    func schedule(_ operation: @escaping @Sendable () -> Void) {}
}

@MainActor
private func executionPermissionService() -> PermissionService {
    PermissionService(
        accessibilityChecker: ExecutionAccessibilityChecker(),
        settingsOpener: ExecutionSettingsOpener()
    )
}

private struct ExecutionAccessibilityChecker: AccessibilityChecking {
    func isAccessibilityTrusted() -> Bool { true }
    func requestAccessibilityAccess() -> Bool { true }
}

private struct ExecutionScreenRecordingChecker {
    func hasScreenRecordingAccess() -> Bool { false }
    func requestScreenRecordingAccess() -> Bool { false }
}

private struct ExecutionSettingsOpener: PermissionSettingsOpening {
    func openSettings(for kind: PermissionKind) -> Bool { true }
}

@MainActor
private final class ExecutionRecorder {
    var events: [String] = []
    var focusedWindowIDs: [String] = []
}

@MainActor
private struct AllowedAccessibilityGate: WorkspaceAccessibilityGating {
    let recorder: ExecutionRecorder

    func requireAccess() -> Bool {
        recorder.events.append("accessibility")
        return true
    }
}

@MainActor
private struct DeniedAccessibilityGate: WorkspaceAccessibilityGating {
    let recorder: ExecutionRecorder
    func requireAccess() -> Bool {
        recorder.events.append("accessibility")
        return false
    }
}

@MainActor
private struct RecordingPointerMover: WorkspacePointerMoving {
    let recorder: ExecutionRecorder

    func movePointer(to point: PointSnapshot, displayID: String) -> Bool {
        recorder.events.append("pointer:\(displayID)")
        return true
    }
}

@MainActor
private struct ConfigurablePointerMover: WorkspacePointerMoving {
    let recorder: ExecutionRecorder
    let succeeds: Bool

    func movePointer(to point: PointSnapshot, displayID: String) -> Bool {
        recorder.events.append("pointer:\(displayID)")
        return succeeds
    }
}

@MainActor
private struct RecordingExistingAppActivator: WorkspaceExistingAppActivating {
    let recorder: ExecutionRecorder

    func activateExistingApp(appID: String, processIdentifier: pid_t?) -> Bool {
        recorder.events.append("activate:\(appID)")
        return true
    }
}

@MainActor
private struct ConfigurableExistingAppActivator: WorkspaceExistingAppActivating {
    let recorder: ExecutionRecorder
    let succeeds: Bool

    func activateExistingApp(appID: String, processIdentifier: pid_t?) -> Bool {
        recorder.events.append("activate:\(appID)")
        return succeeds
    }
}

@MainActor
private struct RecordingWindowFocuser: WorkspaceWindowFocusing {
    let recorder: ExecutionRecorder

    func focus(window: WindowDescriptor, processIdentifier: pid_t?) async -> WindowActivationOutcome {
        recorder.events.append("focus:\(window.id)")
        recorder.focusedWindowIDs.append(window.id)
        return .activated
    }
}

@MainActor
private struct ConfigurableWindowFocuser: WorkspaceWindowFocusing {
    let recorder: ExecutionRecorder
    let outcome: WindowActivationOutcome

    func focus(window: WindowDescriptor, processIdentifier: pid_t?) async -> WindowActivationOutcome {
        recorder.events.append("focus:\(window.id)")
        return outcome
    }
}

@MainActor
private final class CompletionExecutor: WorkspaceExecutionExecuting {
    let result: Result<Void, SwitcherActionFailure>
    let recorder: ExecutionRecorder

    init(result: Result<Void, SwitcherActionFailure>, recorder: ExecutionRecorder) {
        self.result = result
        self.recorder = recorder
    }

    func execute(_ request: WorkspaceExecutionRequest) async -> Result<Void, SwitcherActionFailure> {
        recorder.events.append("execute")
        return result
    }
}
