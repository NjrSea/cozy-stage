import AppKit
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class Task4WindowRuntimeSafetyTests: XCTestCase {
    func testAXOrdinalNeverBecomesCaptureHandle() throws {
        let descriptor = WindowDescriptor(
            id: "pid-42-ax-7",
            frame: try runtimeSafetyRect(x: 0, y: 0),
            isOnScreen: true,
            isMain: true
        )
        XCTAssertNil(descriptor.runtimeIdentity)
        let encoded = try JSONEncoder().encode(descriptor)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("captureWindowID"))
    }

    func testValidatedCaptureIdentityWorksButNeverEntersCodableOrSemanticEquality() throws {
        let frame = try runtimeSafetyRect(x: 10, y: 20)
        let runtimeDescriptor = WindowDescriptor(
            id: "accessibility-window-0",
            frame: frame,
            isOnScreen: true,
            isMain: true,
            runtimeIdentity: WindowRuntimeIdentity(
                ownerProcessIdentifier: 42,
                captureWindowID: 9_999
            )
        )
        let semanticDescriptor = WindowDescriptor(
            id: "accessibility-window-0",
            frame: frame,
            isOnScreen: true,
            isMain: true
        )

        XCTAssertEqual(runtimeDescriptor, semanticDescriptor)
        XCTAssertEqual(runtimeDescriptor.hashValue, semanticDescriptor.hashValue)

        let encoded = try JSONEncoder().encode(runtimeDescriptor)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["frame", "id", "isMain", "isOnScreen"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("9999"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("ownerProcessIdentifier"))
        XCTAssertNil(try JSONDecoder().decode(WindowDescriptor.self, from: encoded).runtimeIdentity)

    }

    func testActionResolverUsesAppKitCoordinatesForVerticallyStackedDisplay() async throws {
        let normalizer = TopLeftToAppKitCoordinateNormalizer(mainDisplayMaxY: 100)
        let requestedFrame = try XCTUnwrap(normalizer.normalize(
            try RectDescriptor(x: 20, y: -80, width: 40, height: 20)
        ))
        XCTAssertEqual(requestedFrame.y, 160)

        let performer = RuntimeSafetyRecordingActionPerformer()
        let resolver = AccessibilityWindowActivationResolver(
            permissionService: runtimeSafetyPermissions(),
            actionPerformer: performer,
            actionExecutor: RuntimeSafetyImmediateActionExecutor()
        )
        let descriptor = WindowDescriptor(
            id: "accessibility-window-0",
            frame: requestedFrame,
            isOnScreen: true,
            isMain: true,
            runtimeIdentity: WindowRuntimeIdentity(
                ownerProcessIdentifier: 42,
                captureWindowID: nil
            )
        )

        let outcome = await resolver.resolveAndRaise(window: descriptor, processIdentifier: 42)
        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(performer.frames, [requestedFrame])
    }

    func testActionResolverUsesAppKitCoordinatesForNegativeDisplay() async throws {
        let normalizer = TopLeftToAppKitCoordinateNormalizer(mainDisplayMaxY: 100)
        let requestedFrame = try XCTUnwrap(normalizer.normalize(
            try RectDescriptor(x: -80, y: 120, width: 20, height: 20)
        ))
        XCTAssertEqual(requestedFrame.x, -80)
        XCTAssertEqual(requestedFrame.y, -40)

        let performer = RuntimeSafetyRecordingActionPerformer()
        let resolver = AccessibilityWindowActivationResolver(
            permissionService: runtimeSafetyPermissions(),
            actionPerformer: performer,
            actionExecutor: RuntimeSafetyImmediateActionExecutor()
        )
        let descriptor = WindowDescriptor(
            id: "accessibility-window-0",
            frame: requestedFrame,
            isOnScreen: true,
            isMain: true,
            runtimeIdentity: WindowRuntimeIdentity(
                ownerProcessIdentifier: 42,
                captureWindowID: nil
            )
        )

        let outcome = await resolver.resolveAndRaise(window: descriptor, processIdentifier: 42)
        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(performer.frames, [requestedFrame])
    }

    func testCacheMissReturnsImmediatelyThenPublishesImmutableRefresh() throws {
        let scheduler = RuntimeSafetyManualScheduler()
        let candidateReader = RuntimeSafetyBlockingCandidateReader(candidates: [
            AXWindowMetadataCandidate(
                id: "ax-0",
                axFrame: try RectDescriptor(x: 10, y: 70, width: 20, height: 20),
                isFocused: true,
                isMain: true,
                isMinimized: false
            )
        ])
        let reader = AppKitWindowMetadataReader(
            permissionService: runtimeSafetyPermissions(),
            processIdentifierProvider: RuntimeSafetyProcessProvider(values: [
                "com.example.editor": [42]
            ]),
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100,
            globalBudget: 0.05,
            refreshScheduler: scheduler
        )
        let displays = [
            DisplayDescriptor(
                id: "display-main",
                frame: try runtimeSafetyRect(x: 0, y: 0),
                isCurrent: true
            )
        ]

        let first = reader.mostRecentWindows(
            for: ["com.example.editor"],
            displays: displays
        )

        XCTAssertEqual(first, [:])
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(candidateReader.callCount, 0)

        // Repeated panel reads while the same PID is in flight must coalesce.
        for _ in 0..<20 {
            _ = reader.mostRecentWindows(
                for: ["com.example.editor", "com.example.editor"],
                displays: displays
            )
        }
        XCTAssertEqual(scheduler.pendingCount, 1)

        let completion = expectation(description: "refresh completed")
        scheduler.runAllOffMain { completion.fulfill() }
        wait(for: [completion], timeout: 1)

        let second = reader.mostRecentWindows(
            for: ["com.example.editor"],
            displays: displays
        )
        let window = try XCTUnwrap(second["com.example.editor"])
        XCTAssertEqual(window.frame.y, 10)
        XCTAssertEqual(window.runtimeIdentity?.ownerProcessIdentifier, 42)
        XCTAssertNil(window.runtimeIdentity?.captureWindowID)
        XCTAssertEqual(candidateReader.callCount, 1)
        XCTAssertEqual(candidateReader.mainThreadValues, [false])
    }

    func testBoundedRefreshSchedulerCapsConcurrencyAndFinishesWorkers() {
        let scheduler = BoundedWindowMetadataRefreshScheduler(maxConcurrentOperations: 2)
        let tracker = RuntimeSafetyConcurrencyTracker(expectedStarts: 2, expectedFinishes: 6)

        for _ in 0..<6 {
            scheduler.schedule {
                tracker.enterAndWait()
            }
        }

        wait(for: [tracker.started], timeout: 1)
        XCTAssertEqual(tracker.maxActiveCount, 2)
        for _ in 0..<6 { tracker.release.signal() }
        wait(for: [tracker.finished], timeout: 1)
        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertEqual(tracker.maxActiveCount, 2)
    }

    func testRepeatedTimedOutRefreshesCompleteAndRemainCoalesced() {
        let scheduler = RuntimeSafetyManualScheduler()
        let candidateReader = RuntimeSafetyTimeoutCandidateReader()
        let reader = AppKitWindowMetadataReader(
            permissionService: runtimeSafetyPermissions(),
            processIdentifierProvider: RuntimeSafetyProcessProvider(values: [
                "com.example.editor": [42]
            ]),
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100,
            globalBudget: 0.02,
            refreshScheduler: scheduler,
            cacheFreshnessInterval: 0
        )

        for _ in 0..<10 {
            XCTAssertEqual(
                reader.mostRecentWindows(for: ["com.example.editor"], displays: []),
                [:]
            )
        }
        XCTAssertEqual(scheduler.pendingCount, 1)

        let firstCompletion = expectation(description: "first timeout refresh completed")
        scheduler.runAllOffMain { firstCompletion.fulfill() }
        wait(for: [firstCompletion], timeout: 1)
        XCTAssertEqual(candidateReader.callCount, 1)
        XCTAssertEqual(candidateReader.messagingTimeouts, [0.02])

        for _ in 0..<10 {
            _ = reader.mostRecentWindows(for: ["com.example.editor"], displays: [])
        }
        XCTAssertEqual(scheduler.pendingCount, 1)

        let secondCompletion = expectation(description: "second timeout refresh completed")
        scheduler.runAllOffMain { secondCompletion.fulfill() }
        wait(for: [secondCompletion], timeout: 1)
        XCTAssertEqual(candidateReader.callCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testMultiProcessActivationUsesSelectedOwnerPID() async throws {
        let resolver = RuntimeSafetyWindowActivationResolver()
        let lookup = RuntimeSafetyApplicationLookup(availablePIDs: [41, 42])
        let activator = NSWorkspaceRunningAppActivator(
            windowResolver: resolver,
            applicationLookup: lookup.lookup
        )
        let window = WindowDescriptor(
            id: "accessibility-window-1",
            frame: try runtimeSafetyRect(x: 0, y: 0),
            isOnScreen: true,
            isMain: true,
            runtimeIdentity: WindowRuntimeIdentity(
                ownerProcessIdentifier: 42,
                captureWindowID: nil
            )
        )

        let outcome = await activator.activateApp(
            appID: "com.example.editor",
            mostRecentWindow: window
        )
        XCTAssertEqual(outcome, .activated(windowActivated: true))
        XCTAssertEqual(lookup.requestedPreferredPIDs, [42])
        XCTAssertEqual(lookup.activatedPIDs, [42])
        XCTAssertEqual(resolver.processIdentifiers, [42])
    }

    func testProcessIconAndWindowBatchesDeduplicateByFirstOccurrence() throws {
        let process = RuntimeSafetySingleProcessProvider()
        XCTAssertEqual(
            process.processIdentifiers(for: ["a", "a", "b", "a"]),
            ["a": [11], "b": [22]]
        )
        XCTAssertEqual(process.requestedIDs, ["a", "b"])

        let icon = RuntimeSafetyIconProvider()
        XCTAssertEqual(
            icon.iconAvailability(for: ["a", "a", "b", "a"]),
            ["a": .available, "b": .fallback]
        )
        XCTAssertEqual(icon.requestedIDs, ["a", "b"])

        let scheduler = RuntimeSafetyManualScheduler()
        let reader = AppKitWindowMetadataReader(
            permissionService: runtimeSafetyPermissions(),
            processIdentifierProvider: RuntimeSafetyProcessProvider(values: ["a": [11], "b": [22]]),
            candidateReader: RuntimeSafetyBlockingCandidateReader(candidates: []),
            appKitMainDisplayMaxY: 100,
            refreshScheduler: scheduler
        )
        XCTAssertEqual(
            reader.mostRecentWindows(for: ["a", "a", "b", "a"], displays: []),
            [:]
        )
        XCTAssertEqual(scheduler.pendingCount, 2)
    }
}

@MainActor
private final class RuntimeSafetyProcessProvider:
    RunningAppProcessIdentifierProviding,
    RunningAppProcessGenerationProviding {
    let values: [String: [pid_t]]

    init(values: [String: [pid_t]]) {
        self.values = values
    }

    func processIdentifier(for appID: String) -> pid_t? { values[appID]?.first }

    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        var result: [String: [pid_t]] = [:]
        for id in appIDs where result[id] == nil { result[id] = values[id, default: []] }
        return result
    }

    func activeProcessGenerations() -> [RunningAppProcessGeneration] {
        values.flatMap { appID, processIdentifiers in
            processIdentifiers.map { processIdentifier in
                RunningAppProcessGeneration(
                    bundleIdentifier: appID,
                    processIdentifier: processIdentifier,
                    launchIdentity: "test-launch-\(appID)-\(processIdentifier)"
                )
            }
        }
    }
}

private final class RuntimeSafetyBlockingCandidateReader: @unchecked Sendable,
    AXWindowMetadataCandidateReading {
    private let lock = NSLock()
    private let candidatesValue: [AXWindowMetadataCandidate]
    private var calls = 0
    private var mainThreads: [Bool] = []

    init(candidates: [AXWindowMetadataCandidate]) {
        self.candidatesValue = candidates
    }

    var callCount: Int { lock.withLock { calls } }
    var mainThreadValues: [Bool] { lock.withLock { mainThreads } }

    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        lock.withLock {
            calls += 1
            mainThreads.append(Thread.isMainThread)
        }
        return candidatesValue
    }
}

private final class RuntimeSafetyTimeoutCandidateReader: @unchecked Sendable,
    AXWindowMetadataCandidateReading {
    private let lock = NSLock()
    private var calls = 0
    private var timeouts: [TimeInterval] = []

    var callCount: Int { lock.withLock { calls } }
    var messagingTimeouts: [TimeInterval] { lock.withLock { timeouts } }

    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        lock.withLock {
            calls += 1
            timeouts.append(messagingTimeout)
        }
        // An empty result is the production reader's safe output for AX timeout.
        return []
    }
}

private final class RuntimeSafetyManualScheduler: @unchecked Sendable,
    WindowMetadataRefreshScheduling {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { operations.count } }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    func runAllOffMain(completion: @escaping @Sendable () -> Void) {
        let pending = lock.withLock {
            defer { operations.removeAll() }
            return operations
        }
        DispatchQueue.global(qos: .userInitiated).async {
            pending.forEach { $0() }
            completion()
        }
    }
}

private final class RuntimeSafetyConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    let started: XCTestExpectation
    let finished: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private var active = 0
    private var maximum = 0

    init(expectedStarts: Int, expectedFinishes: Int) {
        started = XCTestExpectation(description: "bounded operations started")
        started.expectedFulfillmentCount = expectedStarts
        finished = XCTestExpectation(description: "all operations finished")
        finished.expectedFulfillmentCount = expectedFinishes
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
        finished.fulfill()
    }
}

@MainActor
private final class RuntimeSafetySingleProcessProvider: RunningAppProcessIdentifierProviding {
    private(set) var requestedIDs: [String] = []

    func processIdentifier(for appID: String) -> pid_t? {
        requestedIDs.append(appID)
        return appID == "a" ? 11 : 22
    }
}

@MainActor
private final class RuntimeSafetyIconProvider: RunningAppIconProviding {
    private(set) var requestedIDs: [String] = []

    func icon(for bundleIdentifier: String) -> NSImage? {
        requestedIDs.append(bundleIdentifier)
        return bundleIdentifier == "a" ? NSImage(size: NSSize(width: 1, height: 1)) : nil
    }
}

@MainActor
private final class RuntimeSafetyWindowCandidateResolver: WindowCandidateResolving {
    let candidates: [WindowCandidate]

    init(candidates: [WindowCandidate]) { self.candidates = candidates }
    func windowCandidates() -> [WindowCandidate] { candidates }
}

@MainActor
private final class RuntimeSafetyWindowActivationResolver: WindowActivationResolving {
    private(set) var processIdentifiers: [pid_t] = []

    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t
    ) async -> WindowActivationOutcome {
        processIdentifiers.append(processIdentifier)
        return .activated
    }
}

private final class RuntimeSafetyRecordingActionPerformer: @unchecked Sendable,
    AXWindowActionPerforming {
    private let lock = NSLock()
    private var recordedFrames: [RectDescriptor] = []

    var frames: [RectDescriptor] { lock.withLock { recordedFrames } }

    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t,
        budget: TimeInterval,
        cancellation: any AXActionCancellationChecking
    ) -> WindowActivationOutcome {
        lock.withLock { recordedFrames.append(window.frame) }
        return .activated
    }
}

private struct RuntimeSafetyImmediateActionExecutor: AXActionExecuting {
    func execute(
        _ operation: @escaping @Sendable (
            any AXActionCancellationChecking
        ) -> WindowActivationOutcome
    ) async -> WindowActivationOutcome {
        operation(AXActionOperationControl())
    }
}

@MainActor
private final class RuntimeSafetyApplicationLookup {
    let availablePIDs: Set<pid_t>
    private(set) var requestedPreferredPIDs: [pid_t?] = []
    private(set) var activatedPIDs: [pid_t] = []

    init(availablePIDs: Set<pid_t>) { self.availablePIDs = availablePIDs }

    func lookup(appID: String, preferredProcessIdentifier: pid_t?) -> RunningApplicationActivation? {
        requestedPreferredPIDs.append(preferredProcessIdentifier)
        guard let pid = preferredProcessIdentifier, availablePIDs.contains(pid) else { return nil }
        return RunningApplicationActivation(processIdentifier: pid) { [weak self] in
            self?.activatedPIDs.append(pid)
            return true
        }
    }
}

@MainActor
private final class RuntimeSafetyAccessibilityChecker: AccessibilityChecking {
    func isAccessibilityTrusted() -> Bool { true }
    func requestAccessibilityAccess() -> Bool { true }
}

@MainActor
private final class RuntimeSafetyScreenRecordingChecker {
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
}

@MainActor
private struct RuntimeSafetySettingsOpener: PermissionSettingsOpening {
    func openSettings(for kind: PermissionKind) -> Bool { true }
}

@MainActor
private func runtimeSafetyPermissions() -> PermissionService {
    PermissionService(
        accessibilityChecker: RuntimeSafetyAccessibilityChecker(),
        settingsOpener: RuntimeSafetySettingsOpener()
    )
}

private func runtimeSafetyRect(x: Double, y: Double) throws -> RectDescriptor {
    try RectDescriptor(x: x, y: y, width: 100, height: 100)
}
