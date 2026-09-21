import AppKit
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class Task4AsyncActionAndGenerationTests: XCTestCase {
    func testBlockedAXActionDoesNotBlockMainActorAndReturnsTypedTimeoutAfterCompletion() async throws {
        let performer = BlockingAXActionPerformer()
        let resolver = AccessibilityWindowActivationResolver(
            permissionService: asyncActionPermissions(),
            actionPerformer: performer,
            actionExecutor: BoundedAXActionExecutor(maxConcurrentOperations: 1),
            actionBudget: 0.05
        )
        let descriptor = WindowDescriptor(
            id: "accessibility-ax-0",
            frame: try asyncActionRect(x: 0, y: 0),
            isOnScreen: true,
            isMain: true
        )

        let action = Task { @MainActor in
            await resolver.resolveAndRaise(window: descriptor, processIdentifier: 42)
        }
        await fulfillment(of: [performer.started], timeout: 1)

        // Reaching this assertion while the worker is held proves AX work is
        // not executing synchronously on MainActor.
        XCTAssertTrue(Thread.isMainThread)
        performer.release.signal()
        let outcome = await action.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(performer.budgets, [0.05])
    }

    func testAXPerformerUsesRemainingTimeoutForApplicationAndEveryChild() throws {
        let clock = ControlledActionClock()
        let system = RecordingAXWindowActionSystem(clock: clock)
        let performer = AXAccessibilityWindowActionPerformer(
            system: system,
            clock: clock,
            appKitMainDisplayMaxY: 100
        )
        let descriptor = WindowDescriptor(
            id: "accessibility-ax-1",
            frame: try asyncActionRect(x: 30, y: 20, width: 20, height: 20),
            isOnScreen: true,
            isMain: true
        )

        let outcome = performer.resolveAndRaise(
            window: descriptor,
            processIdentifier: 42,
            budget: 1
        )

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(system.applicationPIDs, [42])
        XCTAssertEqual(system.timeoutElementIDs, [0, 1, 2, 2])
        XCTAssertEqual(system.timeouts.count, 4)
        XCTAssertEqual(system.timeouts[0], 1, accuracy: 0.0001)
        XCTAssertEqual(system.timeouts[1], 0.8, accuracy: 0.0001)
        XCTAssertEqual(system.timeouts[2], 0.6, accuracy: 0.0001)
        XCTAssertEqual(system.timeouts[3], 0.4, accuracy: 0.0001)
        XCTAssertEqual(system.raisedElementIDs, [2])
    }

    func testBoundedAXActionExecutorCapsWorkerConcurrency() async {
        let executor = BoundedAXActionExecutor(maxConcurrentOperations: 2)
        let tracker = ActionConcurrencyTracker(expectedStarts: 2)

        let tasks = (0..<6).map { _ in
            Task {
                await executor.execute { _ in
                    tracker.enterAndWait()
                    return .unavailable
                }
            }
        }

        await fulfillment(of: [tracker.started], timeout: 1)
        XCTAssertEqual(tracker.maxActiveCount, 2)
        for _ in 0..<6 { tracker.release.signal() }
        for task in tasks {
            let outcome = await task.value
            XCTAssertEqual(outcome, .unavailable)
        }
        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertEqual(tracker.maxActiveCount, 2)
    }

    func testCancellingQueuedAXFocusPreventsRaiseAfterQueueResumes() async throws {
        let queue = OperationQueue()
        queue.isSuspended = true
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            operationQueue: queue
        )
        let system = CancellationRecordingAXWindowActionSystem()
        let resolver = AccessibilityWindowActivationResolver(
            permissionService: asyncActionPermissions(),
            actionPerformer: AXAccessibilityWindowActionPerformer(
                system: system,
                appKitMainDisplayMaxY: 100
            ),
            actionExecutor: executor
        )
        let descriptor = WindowDescriptor(
            id: "accessibility-window",
            frame: try asyncActionRect(x: 30, y: 20, width: 20, height: 20),
            isOnScreen: true,
            isMain: true
        )

        let focus = Task { @MainActor in
            await resolver.resolveAndRaise(window: descriptor, processIdentifier: 42)
        }
        for _ in 0..<1_000 where queue.operationCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(queue.operationCount, 1, "focus must be queued before cancellation")

        focus.cancel()
        queue.isSuspended = false
        let outcome = await focus.value

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(system.raiseCount, 0)
    }

    func testCancellingRunningAXFocusImmediatelyBeforeRaisePreventsRaise() async throws {
        let executor = BoundedAXActionExecutor(maxConcurrentOperations: 1)
        let system = PreRaiseBlockingAXWindowActionSystem()
        let resolver = AccessibilityWindowActivationResolver(
            permissionService: asyncActionPermissions(),
            actionPerformer: AXAccessibilityWindowActionPerformer(
                system: system,
                appKitMainDisplayMaxY: 100
            ),
            actionExecutor: executor
        )
        let descriptor = WindowDescriptor(
            id: "accessibility-window",
            frame: try asyncActionRect(x: 30, y: 20, width: 20, height: 20),
            isOnScreen: true,
            isMain: true
        )

        let focus = Task { @MainActor in
            await resolver.resolveAndRaise(window: descriptor, processIdentifier: 42)
        }
        await fulfillment(of: [system.beforeRaise], timeout: 1)
        focus.cancel()
        system.release.signal()
        let outcome = await focus.value
        _ = await executor.execute { _ in .unavailable }

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(system.raiseCount, 0)
    }

    func testPIDReuseRejectsLateOldGenerationAndPublishesOnlyCurrentLaunch() async throws {
        let oldGeneration = RunningAppProcessGeneration(
            bundleIdentifier: "com.example.editor",
            processIdentifier: 42,
            launchIdentity: "launch-1"
        )
        let newGeneration = RunningAppProcessGeneration(
            bundleIdentifier: "com.example.editor",
            processIdentifier: 42,
            launchIdentity: "launch-2"
        )
        let processProvider = MutableGenerationProcessProvider(generation: oldGeneration)
        let scheduler = GenerationManualScheduler()
        let candidateReader = SequencedGenerationCandidateReader(candidateBatches: [
            [AXWindowMetadataCandidate(
                id: "old",
                axFrame: try asyncActionRect(x: 10, y: 70, width: 20, height: 20),
                isFocused: true,
                isMain: true,
                isMinimized: false
            )],
            [AXWindowMetadataCandidate(
                id: "new",
                axFrame: try asyncActionRect(x: 60, y: 70, width: 20, height: 20),
                isFocused: true,
                isMain: true,
                isMinimized: false
            )]
        ])
        let reader = AppKitWindowMetadataReader(
            permissionService: asyncActionPermissions(),
            processIdentifierProvider: processProvider,
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100,
            refreshScheduler: scheduler
        )

        XCTAssertEqual(
            reader.mostRecentWindows(for: ["com.example.editor"], displays: []),
            [:]
        )
        processProvider.generation = newGeneration
        XCTAssertEqual(
            reader.mostRecentWindows(for: ["com.example.editor"], displays: []),
            [:]
        )
        XCTAssertEqual(scheduler.pendingCount, 2)

        await scheduler.runNext()
        XCTAssertEqual(
            reader.mostRecentWindows(for: ["com.example.editor"], displays: []),
            [:],
            "late completion from launch-1 must not attach to launch-2"
        )

        await scheduler.runNext()
        let refreshed = reader.mostRecentWindows(
            for: ["com.example.editor"],
            displays: []
        )
        XCTAssertEqual(refreshed["com.example.editor"]?.id, "accessibility-new")
        XCTAssertEqual(refreshed["com.example.editor"]?.frame.x, 60)
        XCTAssertEqual(
            refreshed["com.example.editor"]?.runtimeIdentity?.ownerProcessIdentifier,
            42
        )
    }

    func testAuthoritativeSnapshotEvictsTerminatedAppBeforeSameGenerationReturns() async throws {
        let generation = RunningAppProcessGeneration(
            bundleIdentifier: "com.example.editor",
            processIdentifier: 42,
            launchIdentity: "launch-1"
        )
        let processProvider = MutableAuthoritativeGenerationProvider(
            activeGenerations: [generation]
        )
        let scheduler = GenerationManualScheduler()
        let candidateReader = SequencedGenerationCandidateReader(candidateBatches: [
            [generationCandidate(id: "first", x: 10)],
            [generationCandidate(id: "second", x: 60)]
        ])
        let reader = generationReader(
            processProvider: processProvider,
            candidateReader: candidateReader,
            scheduler: scheduler
        )

        XCTAssertEqual(reader.mostRecentWindows(for: [generation.bundleIdentifier], displays: []), [:])
        await scheduler.runNext()
        let first = reader.mostRecentWindows(
            for: [generation.bundleIdentifier],
            displays: []
        )
        XCTAssertEqual(first[generation.bundleIdentifier]?.id, "accessibility-first")

        processProvider.activeGenerations = []
        XCTAssertEqual(reader.mostRecentWindows(for: ["com.example.other"], displays: []), [:])

        processProvider.activeGenerations = [generation]
        XCTAssertEqual(
            reader.mostRecentWindows(for: [generation.bundleIdentifier], displays: []),
            [:],
            "a terminated generation must not retain a replayable cache entry"
        )
        XCTAssertEqual(scheduler.pendingCount, 1)
        await scheduler.runNext()
        let second = reader.mostRecentWindows(
            for: [generation.bundleIdentifier],
            displays: []
        )
        XCTAssertEqual(second[generation.bundleIdentifier]?.id, "accessibility-second")
    }

    func testAuthoritativeSnapshotRejectsLateCompletionAfterCrossBundlePIDReuse() async throws {
        let oldGeneration = RunningAppProcessGeneration(
            bundleIdentifier: "com.example.old",
            processIdentifier: 42,
            launchIdentity: "old-launch"
        )
        let newGeneration = RunningAppProcessGeneration(
            bundleIdentifier: "com.example.new",
            processIdentifier: 42,
            launchIdentity: "new-launch"
        )
        let processProvider = MutableAuthoritativeGenerationProvider(
            activeGenerations: [oldGeneration]
        )
        let scheduler = GenerationManualScheduler()
        let candidateReader = SequencedGenerationCandidateReader(candidateBatches: [
            [generationCandidate(id: "old", x: 10)],
            [generationCandidate(id: "new", x: 70)]
        ])
        let reader = generationReader(
            processProvider: processProvider,
            candidateReader: candidateReader,
            scheduler: scheduler
        )

        XCTAssertEqual(reader.mostRecentWindows(for: [oldGeneration.bundleIdentifier], displays: []), [:])
        processProvider.activeGenerations = [newGeneration]
        XCTAssertEqual(reader.mostRecentWindows(for: [newGeneration.bundleIdentifier], displays: []), [:])
        XCTAssertEqual(scheduler.pendingCount, 2)

        await scheduler.runNext()
        XCTAssertEqual(
            reader.mostRecentWindows(for: [newGeneration.bundleIdentifier], displays: []),
            [:],
            "the old bundle completion must not attach after cross-bundle PID reuse"
        )

        await scheduler.runNext()
        let refreshed = reader.mostRecentWindows(
            for: [newGeneration.bundleIdentifier],
            displays: []
        )
        XCTAssertEqual(refreshed[newGeneration.bundleIdentifier]?.id, "accessibility-new")
    }

    func testAuthoritativeReconciliationKeepsCacheBoundedToActiveGenerations() async throws {
        let processProvider = MutableAuthoritativeGenerationProvider(activeGenerations: [])
        let scheduler = GenerationManualScheduler()
        let candidateReader = SequencedGenerationCandidateReader(candidateBatches: (0..<8).map {
            [generationCandidate(id: "generation-\($0)", x: Double($0 * 10))]
        })
        let reader = generationReader(
            processProvider: processProvider,
            candidateReader: candidateReader,
            scheduler: scheduler,
            cacheFreshnessInterval: 60
        )
        var retired: [RunningAppProcessGeneration] = []

        for index in 0..<8 {
            let generation = RunningAppProcessGeneration(
                bundleIdentifier: "com.example.editor",
                processIdentifier: 42,
                launchIdentity: "launch-\(index)"
            )
            retired.append(generation)
            processProvider.activeGenerations = [generation]
            XCTAssertEqual(reader.mostRecentWindows(for: [generation.bundleIdentifier], displays: []), [:])
            await scheduler.runNext()
            let refreshed = reader.mostRecentWindows(
                for: [generation.bundleIdentifier],
                displays: []
            )
            XCTAssertNotNil(refreshed[generation.bundleIdentifier])
        }

        processProvider.activeGenerations = [retired[0]]
        XCTAssertEqual(
            reader.mostRecentWindows(for: [retired[0].bundleIdentifier], displays: []),
            [:],
            "retired generations must be evicted instead of accumulating in cache"
        )
        XCTAssertEqual(scheduler.pendingCount, 1)
    }

    func testPIDOnlyProviderIsNonCacheableAndNeverSchedulesReusableGeneration() {
        let processProvider = MutablePIDOnlyProcessProvider(values: [
            "com.example.old": [42]
        ])
        let scheduler = GenerationManualScheduler()
        let candidateReader = SequencedGenerationCandidateReader(candidateBatches: [
            [generationCandidate(id: "must-not-cache", x: 10)]
        ])
        let reader = generationReader(
            processProvider: processProvider,
            candidateReader: candidateReader,
            scheduler: scheduler
        )

        XCTAssertEqual(reader.mostRecentWindows(for: ["com.example.old"], displays: []), [:])
        processProvider.values = ["com.example.new": [42]]
        XCTAssertEqual(reader.mostRecentWindows(for: ["com.example.new"], displays: []), [:])
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(candidateReader.readCount, 0)
    }

    func testHeadlessSessionAtomicallyClaimsOneOpenSessionAndRejectsConcurrentOrReplayExecution() async {
        let activator = FirstCallBlockingAppActivator()
        let controller = makeAtomicExecutionSession(activator: activator)
        controller.open(snapshot: controller.runtimeState!.liveSnapshot())
        XCTAssertTrue(controller.select(itemID: "com.example.editor"))

        let first = Task { @MainActor in await controller.executeSelected() }
        await fulfillment(of: [activator.firstCallStarted], timeout: 1)

        let concurrent = await controller.executeSelected()
        guard case .failure(.actionInProgress) = concurrent else {
            return XCTFail("the concurrent execution must be rejected as in progress")
        }
        XCTAssertEqual(activator.callCount, 1)

        activator.releaseFirstCall()
        let firstResult = await first.value
        guard case .success = firstResult else {
            return XCTFail("the claimed execution should complete successfully")
        }
        XCTAssertFalse(controller.isOpen)
        XCTAssertNil(controller.selectedItemID)

        let replay = await controller.executeSelected()
        guard case .failure(.panelNotOpen) = replay else {
            return XCTFail("a closed session must not be replayable")
        }
        XCTAssertEqual(activator.callCount, 1)
    }

    func testHeadlessSessionExecutionRequiresAnExplicitlyOpenedSessionAndDoesNotCallInput() async {
        let activator = FirstCallBlockingAppActivator()
        let controller = makeAtomicExecutionSession(activator: activator)

        let result = await controller.executeSelected()

        guard case .failure(.panelNotOpen) = result else {
            return XCTFail("execution requires an explicitly opened panel session")
        }
        XCTAssertEqual(activator.callCount, 0)
    }

    func testLegacyAuthenticatedExecuteCommandIsRejectedWithoutInputProviderCalls() async {
        let activator = FirstCallBlockingAppActivator()
        let controller = makeAtomicExecutionSession(activator: activator)
        controller.open(snapshot: controller.runtimeState!.liveSnapshot())
        XCTAssertTrue(controller.select(itemID: "com.example.editor"))
        let runtime = SwitcherRuntimeSemanticAdapter(
            runtimeState: controller.runtimeState!,
            sessionProvider: { controller },
            openPanel: { controller.open(snapshot: controller.runtimeState!.liveSnapshot()) },
            closePanel: { controller.close(reason: .programmatic) }
        )
        let server = SemanticAdapterServer(
            runtime: runtime,
            mode: .devTest,
            token: "atomic-token",
            executionPolicy: ExecutionPolicy(
                mode: .execute,
                environment: ["CS_DIAG_ALLOW_INPUT": "1"]
            )
        )
        let response = await server.handle(
            jsonLine: #"{"command":"executeSelected","token":"atomic-token"}"#
        )

        XCTAssertEqual(response.schemaVersion, 2)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unknownCommand)
        XCTAssertEqual(activator.callCount, 0)
        XCTAssertTrue(controller.isOpen)
    }

    func testWorkspaceExecuteDryRunUsesOpenSessionAndNeverCallsInputProvider() async {
        let activator = FirstCallBlockingAppActivator()
        let controller = makeAtomicExecutionSession(activator: activator)
        controller.open(snapshot: controller.runtimeState!.liveSnapshot())
        XCTAssertTrue(controller.select(itemID: "com.example.editor"))
        let runtime = SwitcherRuntimeSemanticAdapter(
            runtimeState: controller.runtimeState!,
            sessionProvider: { controller },
            openPanel: { controller.open(snapshot: controller.runtimeState!.liveSnapshot()) },
            closePanel: { controller.close(reason: .programmatic) }
        )
        let server = SemanticAdapterServer(
            runtime: runtime,
            mode: .devTest,
            token: "atomic-token",
            executionPolicy: ExecutionPolicy(
                mode: .execute,
                environment: ["CS_DIAG_ALLOW_INPUT": "1"]
            )
        )
        let request = #"{"command":"workspace.executeDryRun","token":"atomic-token"}"#

        let openResponse = await server.handle(jsonLine: request)
        XCTAssertEqual(openResponse.schemaVersion, 2)
        XCTAssertTrue(openResponse.ok)
        XCTAssertEqual(activator.callCount, 0)
        XCTAssertTrue(controller.isOpen)

        _ = await server.handle(
            jsonLine: #"{"command":"workspace.close","token":"atomic-token"}"#
        )
        let closedResponse = await server.handle(jsonLine: request)
        XCTAssertEqual(closedResponse.schemaVersion, 2)
        XCTAssertEqual(closedResponse.error?.code, .panelNotOpen)
        XCTAssertEqual(activator.callCount, 0)
    }

    func testBoundedAXExecutorRejectsBeyondAdmissionCapacityWithoutEnqueueing() async {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let blocker = AdmissionBlockingOperation()
        let rejected = LockedInvocationCounter()

        let first = Task { () -> WindowActivationOutcome in
            await executor.execute { _ in
                blocker.run()
                return WindowActivationOutcome.unavailable
            }
        }
        await fulfillment(of: [blocker.started], timeout: 1)

        let overflow: WindowActivationOutcome = await executor.execute { _ in
            rejected.increment()
            return WindowActivationOutcome.unavailable
        }

        XCTAssertEqual(overflow, .busy)
        XCTAssertEqual(rejected.value, 0)
        blocker.release.signal()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .unavailable)
    }

    func testSaturatedAdmissionRejectsDisplayBeforePointerOrAXWork() async throws {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let heldReservation = try XCTUnwrap(executor.reserveInputTransaction())
        defer { heldReservation.release() }
        let snapshot = try realInputSnapshot()
        let liveProvider = RealInputLiveSnapshotProvider(snapshot: snapshot)
        let pointer = RealInputPointerMover()
        let resolver = RealInputDisplayResolver()
        let activator = RealInputDisplayActivator()
        let service = SwitcherActionService(
            policy: ExecutionPolicy(mode: .interactive),
            liveSnapshotProvider: liveProvider,
            permissionService: asyncActionPermissions(),
            pointerMover: pointer,
            displayWindowResolver: resolver,
            displayWindowActivator: activator,
            appActivator: RealInputAppActivator(outcomes: [.activated(windowActivated: false)]),
            inputAdmission: executor
        )

        let result = await service.perform(
            target: .display(id: "display-1", window: snapshot.runningApps[0].mostRecentWindow),
            snapshot: snapshot
        )

        XCTAssertEqual(result, .failure(.actionOverloaded))
        XCTAssertEqual(liveProvider.callCount, 0)
        XCTAssertEqual(pointer.callCount, 0)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertEqual(activator.callCount, 0)
    }

    func testSaturatedAdmissionRejectsAppBeforeActivationOrAXWork() async throws {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let heldReservation = try XCTUnwrap(executor.reserveInputTransaction())
        defer { heldReservation.release() }
        let snapshot = try realInputSnapshot()
        let liveProvider = RealInputLiveSnapshotProvider(snapshot: snapshot)
        let activator = RealInputAppActivator(outcomes: [.activated(windowActivated: true)])
        let service = SwitcherActionService(
            policy: ExecutionPolicy(mode: .interactive),
            liveSnapshotProvider: liveProvider,
            permissionService: asyncActionPermissions(),
            appActivator: activator,
            inputAdmission: executor
        )

        let result = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: snapshot
        )

        XCTAssertEqual(result, .failure(.actionOverloaded))
        XCTAssertEqual(liveProvider.callCount, 0)
        XCTAssertEqual(activator.activationCallCount, 0)
        XCTAssertEqual(activator.axCallCount, 0)
    }

    func testDryRunDoesNotConsumeOrRequireRealInputAdmission() async throws {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let heldReservation = try XCTUnwrap(executor.reserveInputTransaction())
        defer { heldReservation.release() }
        let snapshot = try realInputSnapshot()
        let liveProvider = RealInputLiveSnapshotProvider(snapshot: snapshot)
        let activator = RealInputAppActivator(outcomes: [.activated(windowActivated: true)])
        let service = SwitcherActionService(
            policy: ExecutionPolicy(mode: .dryRun),
            liveSnapshotProvider: liveProvider,
            permissionService: asyncActionPermissions(),
            appActivator: activator,
            inputAdmission: executor
        )

        let result = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: snapshot
        )

        guard case .success(.preview) = result else {
            return XCTFail("dry-run must remain available when real-input admission is full")
        }
        XCTAssertEqual(liveProvider.callCount, 0)
        XCTAssertEqual(activator.activationCallCount, 0)
    }

    func testRealInputAdmissionReleasesAfterFailureSoCapacityRecovers() async throws {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let snapshot = try realInputSnapshot()
        let activator = RealInputAppActivator(outcomes: [
            .failed,
            .activated(windowActivated: false)
        ])
        let service = SwitcherActionService(
            policy: ExecutionPolicy(mode: .interactive),
            liveSnapshotProvider: RealInputLiveSnapshotProvider(snapshot: snapshot),
            permissionService: asyncActionPermissions(),
            appActivator: activator,
            inputAdmission: executor
        )

        let first = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: snapshot
        )
        let second = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: snapshot
        )

        XCTAssertEqual(first, .failure(.appActivationFailed))
        guard case .success(.executed) = second else {
            return XCTFail("capacity must recover after a failed transaction")
        }
        XCTAssertEqual(activator.activationCallCount, 2)
    }

    func testRealInputAdmissionReleasesAfterCancellationSoCapacityRecovers() async throws {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let snapshot = try realInputSnapshot()
        let activator = CancellationAwareRealInputAppActivator()
        let service = SwitcherActionService(
            policy: ExecutionPolicy(mode: .interactive),
            liveSnapshotProvider: RealInputLiveSnapshotProvider(snapshot: snapshot),
            permissionService: asyncActionPermissions(),
            appActivator: activator,
            inputAdmission: executor
        )

        let first = Task { @MainActor in
            await service.perform(
                target: .app(id: "com.example.editor"),
                snapshot: snapshot
            )
        }
        await fulfillment(of: [activator.firstCallStarted], timeout: 1)
        first.cancel()
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .failure(.appActivationFailed))

        let recovered = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: snapshot
        )
        guard case .success(.executed) = recovered else {
            return XCTFail("capacity must recover after a cancelled transaction exits")
        }
        XCTAssertEqual(activator.callCount, 2)
    }

    func testReservedAppTransactionReusesAdmissionForAXRaise() async throws {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let snapshot = try realInputSnapshot()
        let activation = RealInputApplicationActivationCounter()
        let performer = ImmediateAXActionPerformer()
        let windowResolver = AccessibilityWindowActivationResolver(
            permissionService: asyncActionPermissions(),
            actionPerformer: performer,
            actionExecutor: executor
        )
        let appActivator = NSWorkspaceRunningAppActivator(
            windowResolver: windowResolver,
            applicationLookup: { _, _ in
                RunningApplicationActivation(
                    processIdentifier: 42,
                    activate: { activation.activate() }
                )
            }
        )
        let service = SwitcherActionService(
            policy: ExecutionPolicy(mode: .interactive),
            liveSnapshotProvider: RealInputLiveSnapshotProvider(snapshot: snapshot),
            permissionService: asyncActionPermissions(),
            appActivator: appActivator,
            inputAdmission: executor
        )

        let result = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: snapshot
        )

        guard case let .success(.executed(execution)) = result else {
            return XCTFail("the admitted transaction must reach AX without reserving twice")
        }
        XCTAssertTrue(execution.appActivated)
        XCTAssertTrue(execution.windowActivated)
        XCTAssertEqual(activation.callCount, 1)
        XCTAssertEqual(performer.callCount, 1)
    }

    func testAdmissionReservationReleaseIsIdempotent() throws {
        let executor = BoundedAXActionExecutor(
            maxConcurrentOperations: 1,
            maxPendingOperations: 1
        )
        let first = try XCTUnwrap(executor.reserveInputTransaction())
        first.release()
        first.release()

        let second = try XCTUnwrap(executor.reserveInputTransaction())
        defer { second.release() }
        XCTAssertNil(
            executor.reserveInputTransaction(),
            "releasing one token twice must not create extra capacity"
        )
    }

    private func generationReader(
        processProvider: RunningAppProcessIdentifierProviding,
        candidateReader: AXWindowMetadataCandidateReading,
        scheduler: WindowMetadataRefreshScheduling,
        cacheFreshnessInterval: TimeInterval = 0.25
    ) -> AppKitWindowMetadataReader {
        AppKitWindowMetadataReader(
            permissionService: asyncActionPermissions(),
            processIdentifierProvider: processProvider,
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100,
            refreshScheduler: scheduler,
            cacheFreshnessInterval: cacheFreshnessInterval
        )
    }

    private func makeAtomicExecutionSession(
        activator: RunningAppActivating
    ) -> SwitcherHeadlessSession {
        let pointer = AtomicPointerProvider()
        let permissions = PermissionService(
            accessibilityChecker: AsyncActionAccessibilityChecker(),
            settingsOpener: AsyncActionSettingsOpener()
        )
        let runtime = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: AtomicDisplayDiscovery(),
                pointerLocation: pointer
            ),
            runningAppCatalog: RunningAppCatalog(
                discovery: AtomicRunningAppDiscovery(),
                windowReader: AtomicWindowReader(),
                activationObserver: AtomicActivationObserver(),
                permissionService: permissions
            ),
            pointerLocation: pointer,
            frontmostState: AtomicFrontmostProvider()
        )
        let actionService = SwitcherActionService(
            policy: ExecutionPolicy(mode: .interactive),
            liveSnapshotProvider: runtime,
            permissionService: permissions,
            appActivator: activator
        )
        return SwitcherHeadlessSession(
            runtimeState: runtime,
            actionService: actionService
        )
    }

    private func realInputSnapshot() throws -> SwitcherSnapshot {
        let frame = try asyncActionRect(x: 0, y: 0, width: 100, height: 100)
        let window = WindowDescriptor(
            id: "accessibility-window",
            frame: frame,
            isOnScreen: true,
            isMain: true,
            runtimeIdentity: WindowRuntimeIdentity(
                ownerProcessIdentifier: 42,
                captureWindowID: nil
            )
        )
        return SwitcherSnapshot(
            displays: [DisplayDescriptor(id: "display-1", frame: frame, isCurrent: true)],
            runningApps: [RunningAppDescriptor(
                id: "com.example.editor",
                displayName: "Editor",
                mostRecentWindow: window
            )],
            pointerLocation: nil,
            frontmostAppID: nil
        )
    }
}

private final class BlockingAXActionPerformer: @unchecked Sendable,
    AXWindowActionPerforming {
    let started = XCTestExpectation(description: "AX action worker started")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedBudgets: [TimeInterval] = []

    var budgets: [TimeInterval] { lock.withLock { recordedBudgets } }

    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t,
        budget: TimeInterval,
        cancellation: any AXActionCancellationChecking
    ) -> WindowActivationOutcome {
        lock.withLock { recordedBudgets.append(budget) }
        started.fulfill()
        release.wait()
        return .timedOut
    }
}

private final class ControlledActionClock: @unchecked Sendable, ActionDeadlineClock {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value += interval } }
}

private final class RecordingAXWindowActionSystem: @unchecked Sendable,
    AXWindowActionSystem {
    private let clock: ControlledActionClock
    private let lock = NSLock()
    private var pids: [pid_t] = []
    private var timeoutIDs: [Int] = []
    private var timeoutValues: [TimeInterval] = []
    private var raisedIDs: [Int] = []

    init(clock: ControlledActionClock) { self.clock = clock }

    var applicationPIDs: [pid_t] { lock.withLock { pids } }
    var timeoutElementIDs: [Int] { lock.withLock { timeoutIDs } }
    var timeouts: [TimeInterval] { lock.withLock { timeoutValues } }
    var raisedElementIDs: [Int] { lock.withLock { raisedIDs } }

    func applicationElement(for processIdentifier: pid_t) -> AXWindowActionElement {
        lock.withLock { pids.append(processIdentifier) }
        return AXWindowActionElement(testIdentifier: 0)
    }

    func setMessagingTimeout(_ timeout: TimeInterval, for element: AXWindowActionElement) {
        lock.withLock {
            timeoutIDs.append(element.testIdentifier)
            timeoutValues.append(timeout)
        }
    }

    func windowElements(
        for application: AXWindowActionElement
    ) -> AXWindowActionReadResult<[AXWindowActionElement]> {
        clock.advance(by: 0.2)
        return .success([
            AXWindowActionElement(testIdentifier: 1),
            AXWindowActionElement(testIdentifier: 2)
        ])
    }

    func topLeftFrame(
        of window: AXWindowActionElement
    ) -> AXWindowActionReadResult<RectDescriptor> {
        clock.advance(by: 0.2)
        if window.testIdentifier == 1 {
            return .success(try! asyncActionRect(x: 0, y: 0, width: 10, height: 10))
        }
        return .success(try! asyncActionRect(x: 30, y: 60, width: 20, height: 20))
    }

    func raise(_ window: AXWindowActionElement) -> AXWindowActionOperationResult {
        lock.withLock { raisedIDs.append(window.testIdentifier) }
        return .timedOut
    }
}

private final class CancellationRecordingAXWindowActionSystem: @unchecked Sendable,
    AXWindowActionSystem {
    private let lock = NSLock()
    private var raises = 0

    var raiseCount: Int { lock.withLock { raises } }

    func applicationElement(for processIdentifier: pid_t) -> AXWindowActionElement {
        AXWindowActionElement(testIdentifier: 0)
    }

    func setMessagingTimeout(_ timeout: TimeInterval, for element: AXWindowActionElement) {}

    func windowElements(
        for application: AXWindowActionElement
    ) -> AXWindowActionReadResult<[AXWindowActionElement]> {
        .success([AXWindowActionElement(testIdentifier: 1)])
    }

    func topLeftFrame(
        of window: AXWindowActionElement
    ) -> AXWindowActionReadResult<RectDescriptor> {
        .success(try! asyncActionRect(x: 30, y: 60, width: 20, height: 20))
    }

    func raise(_ window: AXWindowActionElement) -> AXWindowActionOperationResult {
        lock.withLock { raises += 1 }
        return .success
    }
}

private final class PreRaiseBlockingAXWindowActionSystem: @unchecked Sendable,
    AXWindowActionSystem {
    let beforeRaise = XCTestExpectation(description: "AX query reached pre-raise window")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var raises = 0

    var raiseCount: Int { lock.withLock { raises } }

    func applicationElement(for processIdentifier: pid_t) -> AXWindowActionElement {
        AXWindowActionElement(testIdentifier: 0)
    }

    func setMessagingTimeout(_ timeout: TimeInterval, for element: AXWindowActionElement) {}

    func windowElements(
        for application: AXWindowActionElement
    ) -> AXWindowActionReadResult<[AXWindowActionElement]> {
        .success([AXWindowActionElement(testIdentifier: 1)])
    }

    func topLeftFrame(
        of window: AXWindowActionElement
    ) -> AXWindowActionReadResult<RectDescriptor> {
        beforeRaise.fulfill()
        release.wait()
        return .success(try! asyncActionRect(x: 30, y: 60, width: 20, height: 20))
    }

    func raise(_ window: AXWindowActionElement) -> AXWindowActionOperationResult {
        lock.withLock { raises += 1 }
        return .success
    }
}

private final class ActionConcurrencyTracker: @unchecked Sendable {
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    init(expectedStarts: Int) {
        started = XCTestExpectation(description: "bounded AX workers started")
        started.expectedFulfillmentCount = expectedStarts
    }

    var activeCount: Int { lock.withLock { active } }
    var maxActiveCount: Int { lock.withLock { maximum } }

    func enterAndWait() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
        started.fulfill()
        release.wait()
        lock.withLock { active -= 1 }
    }
}

@MainActor
private final class MutableGenerationProcessProvider:
    RunningAppProcessIdentifierProviding,
    RunningAppProcessGenerationProviding {
    var generation: RunningAppProcessGeneration

    init(generation: RunningAppProcessGeneration) { self.generation = generation }

    func processIdentifier(for appID: String) -> pid_t? { generation.processIdentifier }

    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        Dictionary(uniqueKeysWithValues: stableUnique(appIDs).map {
            ($0, $0 == generation.bundleIdentifier ? [generation.processIdentifier] : [])
        })
    }

    func processGenerations(
        for appIDs: [String]
    ) -> [String: [RunningAppProcessGeneration]] {
        Dictionary(uniqueKeysWithValues: stableUnique(appIDs).map {
            ($0, $0 == generation.bundleIdentifier ? [generation] : [])
        })
    }

    func activeProcessGenerations() -> [RunningAppProcessGeneration] {
        [generation]
    }
}

@MainActor
private final class MutableAuthoritativeGenerationProvider:
    RunningAppProcessIdentifierProviding,
    RunningAppProcessGenerationProviding {
    var activeGenerations: [RunningAppProcessGeneration]

    init(activeGenerations: [RunningAppProcessGeneration]) {
        self.activeGenerations = activeGenerations
    }

    func processIdentifier(for appID: String) -> pid_t? {
        activeGenerations.first { $0.bundleIdentifier == appID }?.processIdentifier
    }

    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        Dictionary(uniqueKeysWithValues: stableUnique(appIDs).map { appID in
            (appID, activeGenerations.filter { $0.bundleIdentifier == appID }.map(\.processIdentifier))
        })
    }

    func processGenerations(
        for appIDs: [String]
    ) -> [String: [RunningAppProcessGeneration]] {
        Dictionary(uniqueKeysWithValues: stableUnique(appIDs).map { appID in
            (appID, activeGenerations.filter { $0.bundleIdentifier == appID })
        })
    }

    func activeProcessGenerations() -> [RunningAppProcessGeneration] {
        activeGenerations
    }
}

@MainActor
private final class MutablePIDOnlyProcessProvider: RunningAppProcessIdentifierProviding {
    var values: [String: [pid_t]]

    init(values: [String: [pid_t]]) { self.values = values }

    func processIdentifier(for appID: String) -> pid_t? { values[appID]?.first }

    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        Dictionary(uniqueKeysWithValues: stableUnique(appIDs).map { ($0, values[$0] ?? []) })
    }
}

private final class SequencedGenerationCandidateReader: @unchecked Sendable,
    AXWindowMetadataCandidateReading {
    private let lock = NSLock()
    private var batches: [[AXWindowMetadataCandidate]]
    private var reads = 0

    init(candidateBatches: [[AXWindowMetadataCandidate]]) { self.batches = candidateBatches }

    var readCount: Int { lock.withLock { reads } }

    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        lock.withLock {
            reads += 1
            guard !batches.isEmpty else { return [] }
            return batches.removeFirst()
        }
    }
}

private final class GenerationManualScheduler: @unchecked Sendable,
    WindowMetadataRefreshScheduling {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { operations.count } }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    func runNext() async {
        let operation = lock.withLock { operations.removeFirst() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                operation()
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class FirstCallBlockingAppActivator: RunningAppActivating {
    let firstCallStarted = XCTestExpectation(description: "first input call started")
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?
    ) async -> AppActivationOutcome {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
                firstCallStarted.fulfill()
            }
        }
        return .activated(windowActivated: false)
    }

    func releaseFirstCall() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume()
    }
}

private final class AdmissionBlockingOperation: @unchecked Sendable {
    let started = XCTestExpectation(description: "admitted AX operation started")
    let release = DispatchSemaphore(value: 0)

    func run() {
        started.fulfill()
        release.wait()
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ImmediateAXActionPerformer: @unchecked Sendable,
    AXWindowActionPerforming {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t,
        budget: TimeInterval,
        cancellation: any AXActionCancellationChecking
    ) -> WindowActivationOutcome {
        lock.withLock { calls += 1 }
        return .activated
    }
}

@MainActor
private final class RealInputApplicationActivationCounter {
    private(set) var callCount = 0

    func activate() -> Bool {
        callCount += 1
        return true
    }
}

@MainActor
private final class RealInputLiveSnapshotProvider: LiveSnapshotProviding {
    private let snapshot: SwitcherSnapshot
    private(set) var callCount = 0

    init(snapshot: SwitcherSnapshot) { self.snapshot = snapshot }

    func liveSnapshot() -> SwitcherSnapshot {
        callCount += 1
        return snapshot
    }
}

@MainActor
private final class RealInputPointerMover: PointerMoving {
    private(set) var callCount = 0

    func movePointer(to point: PointSnapshot) -> Bool {
        callCount += 1
        return true
    }
}

@MainActor
private final class RealInputDisplayResolver: DisplayWindowResolving {
    private(set) var callCount = 0

    func resolveDisplayWindow(
        display: DisplayDescriptor,
        requestedWindow: WindowDescriptor
    ) -> DisplayWindowResolution {
        callCount += 1
        return .resolved(requestedWindow)
    }
}

@MainActor
private final class RealInputDisplayActivator: DisplayWindowActivating {
    private(set) var callCount = 0

    func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor
    ) async -> DisplayWindowActivationResult {
        callCount += 1
        return .activated
    }
}

@MainActor
private final class RealInputAppActivator: RunningAppActivating {
    private var outcomes: [AppActivationOutcome]
    private(set) var activationCallCount = 0
    private(set) var axCallCount = 0

    init(outcomes: [AppActivationOutcome]) { self.outcomes = outcomes }

    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?
    ) async -> AppActivationOutcome {
        activationCallCount += 1
        if mostRecentWindow != nil { axCallCount += 1 }
        return outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }
}

@MainActor
private final class CancellationAwareRealInputAppActivator: RunningAppActivating {
    let firstCallStarted = XCTestExpectation(description: "cancellable input started")
    private(set) var callCount = 0

    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?
    ) async -> AppActivationOutcome {
        callCount += 1
        guard callCount == 1 else { return .activated(windowActivated: false) }
        firstCallStarted.fulfill()
        while !Task.isCancelled {
            await Task.yield()
        }
        return .failed
    }
}

@MainActor
private struct AtomicDisplayDiscovery: DisplayDiscovering {
    func discoverDisplays() -> [DisplaySource] { [] }
}

@MainActor
private struct AtomicRunningAppDiscovery: RunningAppDiscovering {
    func discoverRunningApps() -> [RunningAppSource] {
        [RunningAppSource(
            id: "com.example.editor",
            displayName: "Editor",
            activationPolicy: .regular
        )]
    }
}

@MainActor
private struct AtomicWindowReader: WindowMetadataReading {
    func mostRecentWindow(for appID: String) -> WindowDescriptor? { nil }
}

@MainActor
private final class AtomicActivationObservation: RunningAppActivationObservation {
    func cancel() {}
}

@MainActor
private struct AtomicActivationObserver: RunningAppActivationObserving {
    func startObserving(
        _ handler: @escaping @MainActor (String) -> Void
    ) -> RunningAppActivationObservation {
        AtomicActivationObservation()
    }
}

@MainActor
private struct AtomicPointerProvider: PointerLocationProviding {
    func currentPointerLocation() -> PointSnapshot? { nil }
}

@MainActor
private struct AtomicFrontmostProvider: FrontmostStateProviding {
    func frontmostApplicationID() -> String? { nil }
}

@MainActor
private final class AsyncActionAccessibilityChecker: AccessibilityChecking {
    func isAccessibilityTrusted() -> Bool { true }
    func requestAccessibilityAccess() -> Bool { true }
}

@MainActor
private final class AsyncActionScreenRecordingChecker {
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
}

@MainActor
private struct AsyncActionSettingsOpener: PermissionSettingsOpening {
    func openSettings(for kind: PermissionKind) -> Bool { true }
}

@MainActor
private func asyncActionPermissions() -> PermissionService {
    PermissionService(
        accessibilityChecker: AsyncActionAccessibilityChecker(),
        settingsOpener: AsyncActionSettingsOpener()
    )
}

private func asyncActionRect(
    x: Double,
    y: Double,
    width: Double = 100,
    height: Double = 100
) throws -> RectDescriptor {
    try RectDescriptor(x: x, y: y, width: width, height: height)
}

private func generationCandidate(id: String, x: Double) -> AXWindowMetadataCandidate {
    AXWindowMetadataCandidate(
        id: id,
        axFrame: try! asyncActionRect(x: x, y: 70, width: 20, height: 20),
        isFocused: true,
        isMain: true,
        isMinimized: false
    )
}
