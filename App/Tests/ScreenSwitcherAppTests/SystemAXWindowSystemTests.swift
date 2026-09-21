import AppKit
import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class SystemAXWindowSystemTests: XCTestCase {
    func testNilLaunchDateGenerationIsStableUntilTerminationAndExplicitRelaunchReplacesPID() {
        let startIdentity = FakeProcessStartIdentityProvider()
        var nextGeneration = 0
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: startIdentity,
            generationGenerator: {
                nextGeneration += 1
                return "generated-\(nextGeneration)"
            }
        )
        let nilLaunch = nativeApplication(pid: 42, launchDate: nil)

        let first = registry.reconcileRunning([nilLaunch])
        let repeated = registry.reconcileRunning([nilLaunch])
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.first?.launchGeneration, "generated-1")

        let terminated = registry.terminated(nilLaunch)
        XCTAssertEqual(terminated, first.first)
        XCTAssertEqual(registry.terminated(nilLaunch), nil)

        let afterTermination = registry.reconcileRunning([nilLaunch])
        XCTAssertEqual(afterTermination.first?.launchGeneration, "generated-2")
        let replacement = registry.launched(nilLaunch)
        XCTAssertEqual(replacement.replaced, afterTermination.first)
        XCTAssertEqual(replacement.current?.launchGeneration, "generated-3")
    }

    func testStableStartIdentityReusesScanAndReplacesSamePIDOnNewLaunch() {
        let startIdentity = FakeProcessStartIdentityProvider(values: [
            "old": "start-old",
            "new": "start-new"
        ])
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: startIdentity,
            generationGenerator: { "fallback" }
        )
        let old = nativeApplication(name: "old", pid: 42, launchDate: nil)
        let new = nativeApplication(name: "new", pid: 42, launchDate: nil)

        let initial = registry.reconcileRunning([old]).first
        XCTAssertEqual(registry.reconcileRunning([old]).first, initial)
        let replacement = registry.launched(new)

        XCTAssertEqual(replacement.replaced, initial)
        XCTAssertEqual(replacement.current?.launchGeneration, "start-new")
    }

    func testStaleStableTerminationCannotRemoveSamePIDReplacement() {
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: FakeProcessStartIdentityProvider(values: [
                "old": "start-old",
                "new": "start-new"
            ]),
            generationGenerator: { "fallback" }
        )
        let old = nativeApplication(name: "old", pid: 42, launchDate: nil)
        let new = nativeApplication(name: "new", pid: 42, launchDate: nil)
        _ = registry.reconcileRunning([old])
        let replacement = registry.launched(new).current

        XCTAssertNil(registry.terminated(old))
        XCTAssertEqual(registry.terminated(new), replacement)
        XCTAssertNil(registry.terminated(new))
    }

    func testNilIdentityTerminationRequiresCurrentObservedInstance() {
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: FakeProcessStartIdentityProvider(),
            generationGenerator: {
                UUID().uuidString
            }
        )
        let old = nativeApplication(name: "old", pid: 42, launchDate: nil)
        let new = nativeApplication(name: "new", pid: 42, launchDate: nil)
        _ = registry.reconcileRunning([old])
        let replacement = registry.launched(new).current

        XCTAssertNil(registry.terminated(old))
        XCTAssertEqual(registry.terminated(new), replacement)
        XCTAssertNil(registry.terminated(new))
    }

    func testNilIdentityObservationSetIsBoundedToCurrentGeneration() {
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: FakeProcessStartIdentityProvider(),
            generationGenerator: { "generation" }
        )
        let observations = (0..<10).map { index in
            nativeApplication(name: "scan-\(index)", pid: 42, launchDate: nil)
        }
        var current: AXObservedApplication?
        for observation in observations {
            current = registry.reconcileRunning([observation]).first
        }

        XCTAssertNil(registry.terminated(observations[0]))
        XCTAssertEqual(registry.terminated(observations[9]), current)
    }

    func testStateReadUsesOneClosedBatchAndDoesNotBlockMainActor() async throws {
        let primitives = BlockingNativeAXReadPrimitives()
        let system = SystemAXWindowSystem(
            currentProcessIdentifier: 999,
            readPrimitives: primitives,
            readExecutor: NativeAXReadExecutor(label: "test.native-ax-read"),
            messagingTimeout: 0.04,
            perWindowBudget: 0.08
        )
        let app = AXObservedApplication(
            appID: "com.example.Editor",
            appName: "Editor",
            processIdentifier: 42,
            launchGeneration: "launch"
        )
        let element = AXElement.injected("window")
        let read = Task { @MainActor in
            try await system.state(of: element, in: app)
        }

        await fulfillment(of: [primitives.started], timeout: 1)
        XCTAssertTrue(Thread.isMainThread, "AX read must yield the MainActor while blocked")
        primitives.release.signal()
        let state = try await read.value

        XCTAssertEqual(state.title, "Window")
        XCTAssertEqual(primitives.batchReadCount, 1)
        XCTAssertEqual(primitives.settableReadCount, 2)
        XCTAssertEqual(primitives.messagingTimeouts, [0.04])
        XCTAssertEqual(primitives.budgets, [0.08])
        XCTAssertEqual(primitives.batchAttributes, [NativeAXWindowStateBatch.attributes])
        XCTAssertEqual(primitives.mainThreadValues, [false])
    }

    func testSystemReadPrimitivesParseTheClosedBatchThroughInjectedSyscalls() throws {
        let syscalls = FakeNativeAXReadSyscalls()
        var position = CGPoint(x: 10, y: 20)
        var size = CGSize(width: 50, height: 40)
        let positionValue = try XCTUnwrap(AXValueCreate(.cgPoint, &position))
        let sizeValue = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        syscalls.multipleValue = [
            "Window",
            positionValue,
            sizeValue,
            NSNumber(value: true),
            NSNumber(value: false),
            "AXWindow",
            "AXStandardWindow",
            syscalls.element,
            NSNumber(value: false),
            NSNumber(value: true)
        ]
        syscalls.settableResults = [(.success, true), (.success, false)]
        let primitives = SystemNativeAXReadPrimitives(syscalls: syscalls.table)

        let batch = try primitives.windowState(
            element: .system(NativeAXElementBox(syscalls.element)),
            messagingTimeout: 0.04,
            budget: 0.08,
            attributes: NativeAXWindowStateBatch.attributes
        )

        XCTAssertEqual(batch.title, "Window")
        XCTAssertEqual(batch.frame, CanvasRect(x: 10, y: 20, width: 50, height: 40))
        XCTAssertTrue(batch.isFocused)
        XCTAssertFalse(batch.isMinimized)
        XCTAssertTrue(batch.isPositionSettable)
        XCTAssertFalse(batch.isSizeSettable)
        XCTAssertEqual(batch.role, "AXWindow")
        XCTAssertEqual(batch.subrole, "AXStandardWindow")
        XCTAssertFalse(batch.isModal)
        XCTAssertTrue(batch.isTransient)
        XCTAssertEqual(syscalls.timeoutCallCount, 3)
        XCTAssertEqual(syscalls.settableAttributes, [kAXPositionAttribute, kAXSizeAttribute])
    }

    func testSystemReadPrimitivesMapTimeoutSetterErrorsAndStopBeforeCopying() {
        let timedOut = FakeNativeAXReadSyscalls()
        timedOut.timeoutErrors = [.cannotComplete]
        let timedOutPrimitives = SystemNativeAXReadPrimitives(syscalls: timedOut.table)

        XCTAssertThrowsError(try timedOutPrimitives.windows(
            processIdentifier: 42,
            messagingTimeout: 0.04,
            budget: 0.08
        )) { error in
            XCTAssertEqual(error as? SystemNativeAXReadPrimitives.ReadError, .timedOut)
        }
        XCTAssertEqual(timedOut.copyAttributeCallCount, 0)

        let inaccessible = FakeNativeAXReadSyscalls()
        inaccessible.timeoutErrors = [.apiDisabled]
        let inaccessiblePrimitives = SystemNativeAXReadPrimitives(syscalls: inaccessible.table)
        XCTAssertThrowsError(try inaccessiblePrimitives.windowState(
            element: .system(NativeAXElementBox(inaccessible.element)),
            messagingTimeout: 0.04,
            budget: 0.08,
            attributes: NativeAXWindowStateBatch.attributes
        )) { error in
            XCTAssertEqual(error as? SystemNativeAXReadPrimitives.ReadError, .inaccessible)
        }
        XCTAssertEqual(inaccessible.copyMultipleCallCount, 0)
    }

    func testSystemReadPrimitivesMapSettableErrorsWithoutContinuing() throws {
        let timedOut = FakeNativeAXReadSyscalls()
        timedOut.multipleValue = try nativeWindowStateValues(parent: timedOut.element)
        timedOut.settableResults = [(.cannotComplete, false), (.success, true)]
        let timedOutPrimitives = SystemNativeAXReadPrimitives(syscalls: timedOut.table)

        XCTAssertThrowsError(try timedOutPrimitives.windowState(
            element: .system(NativeAXElementBox(timedOut.element)),
            messagingTimeout: 0.04,
            budget: 0.08,
            attributes: NativeAXWindowStateBatch.attributes
        )) { error in
            XCTAssertEqual(error as? SystemNativeAXReadPrimitives.ReadError, .timedOut)
        }
        XCTAssertEqual(timedOut.settableAttributes, [kAXPositionAttribute])

        let inaccessible = FakeNativeAXReadSyscalls()
        inaccessible.multipleValue = try nativeWindowStateValues(parent: inaccessible.element)
        inaccessible.settableResults = [(.apiDisabled, false)]
        let inaccessiblePrimitives = SystemNativeAXReadPrimitives(syscalls: inaccessible.table)
        XCTAssertThrowsError(try inaccessiblePrimitives.windowState(
            element: .system(NativeAXElementBox(inaccessible.element)),
            messagingTimeout: 0.04,
            budget: 0.08,
            attributes: NativeAXWindowStateBatch.attributes
        )) { error in
            XCTAssertEqual(error as? SystemNativeAXReadPrimitives.ReadError, .inaccessible)
        }
    }

    func testKernelProcessIdentityIsPrimaryForPIDReuseWhenLaunchDateIsMissing() {
        let provider = KernelProcessStartIdentityProvider { application in
            ["old": "kernel-old", "new": "kernel-new"][application.appName]
        }
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: provider,
            generationGenerator: { "fallback" }
        )
        let old = nativeApplication(name: "old", pid: 42, launchDate: nil)
        let new = nativeApplication(name: "new", pid: 42, launchDate: nil)
        let original = registry.reconcileRunning([old]).first
        let replacement = registry.launched(new).current

        XCTAssertEqual(original?.launchGeneration, "kernel-old")
        XCTAssertEqual(replacement?.launchGeneration, "kernel-new")
        XCTAssertNil(registry.terminated(old))
        XCTAssertEqual(registry.terminated(new), replacement)
    }

    func testUnrecognizedStaleTerminationCannotRemoveReplacementWhenKernelIdentityUnavailable() {
        let values = [
            "old": "kernel-old",
            "new": "kernel-new"
        ]
        let current = MutableProcessIdentity()
        let provider = KernelProcessStartIdentityProvider(
            { application in
                current.payloadIdentitiesAvailable ? values[application.appName] : nil
            },
            currentIdentityReader: { _ in current.value }
        )
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: provider,
            generationGenerator: { "fallback" }
        )
        let old = nativeApplication(name: "old", pid: 42, launchDate: nil)
        let new = nativeApplication(name: "new", pid: 42, launchDate: nil)
        _ = registry.reconcileRunning([old])
        let replacement = registry.launched(new).current

        current.payloadIdentitiesAvailable = false
        current.value = nil
        let staleTermination = nativeApplication(
            name: "new",
            pid: 42,
            launchDate: nil,
            isTerminated: true
        )
        XCTAssertNil(registry.terminated(staleTermination))

        XCTAssertEqual(registry.terminated(new), replacement)
    }

    func testKernelPrimaryAcceptsObservedCurrentTerminationAfterExitAndRejectsLiveMismatch() {
        let current = MutableProcessIdentity()
        let provider = KernelProcessStartIdentityProvider(
            { application in
                current.payloadIdentitiesAvailable ? "kernel-new" : nil
            },
            currentIdentityReader: { _ in current.value }
        )
        let registry = NativeProcessGenerationRegistry(
            startIdentityProvider: provider,
            generationGenerator: { "fallback" }
        )
        let observedCurrent = nativeApplication(name: "new", pid: 42, launchDate: nil)
        let replacement = registry.reconcileRunning([observedCurrent]).first
        current.payloadIdentitiesAvailable = false

        current.value = "kernel-other"
        XCTAssertNil(registry.terminated(observedCurrent))

        current.value = nil
        XCTAssertEqual(registry.terminated(observedCurrent), replacement)
    }

    func testObserverOwnerRollsBackPartialRegistrationAndReleasesCallbackBox() throws {
        let primitives = FakeNativeAXObserverPrimitives()
        let owner = NativeAXObserverOwner(primitives: primitives)
        let element = AXElement.injected("window")
        primitives.failAddCall = 3

        XCTAssertThrowsError(try owner.register(
            processIdentifier: 42,
            element: element,
            notifications: ["created", "focused", "destroyed"]
        ) { _, _ in })

        XCTAssertEqual(primitives.addedNotifications, ["created", "focused", "destroyed"])
        XCTAssertEqual(primitives.removedNotifications, ["focused", "created"])
        XCTAssertEqual(primitives.addRunLoopSourceCount, 0)
        XCTAssertNil(primitives.lastCallbackBox)

        primitives.failAddCall = nil
        var registration: NativeAXObserverRegistration? = try owner.register(
            processIdentifier: 42,
            element: element,
            notifications: ["created", "focused"]
        ) { _, _ in }
        XCTAssertNotNil(primitives.lastCallbackBox)
        XCTAssertEqual(primitives.addRunLoopSourceCount, 1)

        owner.remove(try XCTUnwrap(registration))
        registration = nil
        XCTAssertEqual(primitives.removeRunLoopSourceCount, 1)
        XCTAssertEqual(Array(primitives.removedNotifications.suffix(2)), ["focused", "created"])
        XCTAssertNil(primitives.lastCallbackBox)
    }

    func testSystemObserverTrampolineRetainsThenSuppressesCallbackDuringRemoval() async throws {
        let nativeElement = AXUIElementCreateApplication(42)
        var callbackReference: UnsafeMutableRawPointer?
        var removeNotificationCount = 0
        let syscalls = NativeAXObserverSyscalls(
            createObserver: { _ in
                (.success, NativeAXObserverHandle(storage: NSObject()))
            },
            addNotification: { _, _, _, reference in
                callbackReference = reference
                return .success
            },
            removeNotification: { _, _, notification in
                removeNotificationCount += 1
                SystemNativeAXObserverPrimitives.deliver(
                    element: nativeElement,
                    notification: notification,
                    reference: callbackReference
                )
            },
            addRunLoopSource: { _ in },
            removeRunLoopSource: { _ in }
        )
        let owner = NativeAXObserverOwner(
            primitives: SystemNativeAXObserverPrimitives(syscalls: syscalls)
        )
        var callbackCount = 0
        var registration: NativeAXObserverRegistration? = try owner.register(
            processIdentifier: 42,
            element: .system(NativeAXElementBox(nativeElement)),
            notifications: [kAXMovedNotification]
        ) { _, _ in callbackCount += 1 }
        weak var callbackBox = registration?.callbackBox

        SystemNativeAXObserverPrimitives.deliver(
            element: nativeElement,
            notification: kAXMovedNotification,
            reference: callbackReference
        )
        await Task.yield()
        XCTAssertEqual(callbackCount, 1)

        owner.remove(try XCTUnwrap(registration))
        await Task.yield()
        XCTAssertEqual(removeNotificationCount, 1)
        XCTAssertEqual(callbackCount, 1)
        registration = nil
        XCTAssertNil(callbackBox)
    }

    func testWorkspaceOwnerRemovesLaunchAndTerminationTokensExactlyOnce() {
        let primitives = FakeNativeWorkspaceObservationPrimitives()
        let owner = NativeWorkspaceObservationOwner(primitives: primitives)
        let registration = owner.observe { _ in }

        XCTAssertEqual(primitives.addedKinds, [.launched, .terminated])
        owner.remove(registration)
        owner.remove(registration)

        XCTAssertEqual(primitives.removedTokenIDs, [1, 2])
    }

    func testWorkspaceProjectionIgnoresStaleTerminationAfterPIDReuse() async throws {
        let workspace = FakeNativeWorkspaceObservationPrimitives()
        let system = SystemAXWindowSystem(
            currentProcessIdentifier: 999,
            startIdentityProvider: FakeProcessStartIdentityProvider(values: [
                "old": "start-old",
                "new": "start-new"
            ]),
            workspacePrimitives: workspace
        )
        let old = nativeApplication(name: "old", pid: 42, launchDate: nil)
        let new = nativeApplication(name: "new", pid: 42, launchDate: nil)
        var events: [AXWorkspaceNotification] = []
        _ = try system.observeWorkspace { events.append($0) }

        workspace.trigger(.launched, application: old)
        workspace.trigger(.launched, application: new)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(events.observedApplications, [
            "launched:start-old",
            "launched:start-new"
        ])

        workspace.trigger(.terminated, application: old)
        await Task.yield()
        XCTAssertEqual(events.observedApplications.count, 2)

        workspace.trigger(.terminated, application: new)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(events.observedApplications, [
            "launched:start-old",
            "launched:start-new",
            "terminated:start-new"
        ])
    }

    private func nativeApplication(
        name: String = "Editor",
        pid: pid_t,
        launchDate: Date?,
        isTerminated: Bool = false
    ) -> NativeRunningApplication {
        NativeRunningApplication(
            appID: "com.example.Editor",
            appName: name,
            processIdentifier: pid,
            launchDate: launchDate,
            activationPolicy: .regular,
            isTerminated: isTerminated
        )
    }

    private func nativeWindowStateValues(parent: AXUIElement) throws -> [Any] {
        var position = CGPoint(x: 10, y: 20)
        var size = CGSize(width: 50, height: 40)
        return [
            "Window",
            try XCTUnwrap(AXValueCreate(.cgPoint, &position)),
            try XCTUnwrap(AXValueCreate(.cgSize, &size)),
            NSNumber(value: false),
            NSNumber(value: false),
            "AXWindow",
            "AXStandardWindow",
            parent,
            NSNumber(value: false),
            NSNumber(value: false)
        ]
    }
}

private extension Array where Element == AXWorkspaceNotification {
    var observedApplications: [String] {
        map {
            switch $0 {
            case let .launched(app): "launched:\(app.launchGeneration)"
            case let .terminated(app): "terminated:\(app.launchGeneration)"
            }
        }
    }
}

private final class FakeProcessStartIdentityProvider: ProcessStartIdentityProvider {
    private let values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func identity(for application: NativeRunningApplication) -> String? {
        values[application.appName]
    }
}

private final class MutableProcessIdentity: @unchecked Sendable {
    var value: String?
    var payloadIdentitiesAvailable = true
}

private final class FakeNativeAXReadSyscalls: @unchecked Sendable {
    let element = AXUIElementCreateApplication(42)
    var timeoutErrors: [AXError] = []
    var attributeValue: Any?
    var multipleValue: [Any]?
    var attributeError: AXError = .success
    var multipleError: AXError = .success
    var settableResults: [(AXError, Bool)] = []
    private(set) var timeoutCallCount = 0
    private(set) var copyAttributeCallCount = 0
    private(set) var copyMultipleCallCount = 0
    private(set) var settableAttributes: [String] = []

    var table: NativeAXReadSyscalls {
        NativeAXReadSyscalls(
            createApplication: { [unowned self] _ in self.element },
            setMessagingTimeout: { [unowned self] _, _ in
                self.timeoutCallCount += 1
                return self.timeoutErrors.isEmpty ? .success : self.timeoutErrors.removeFirst()
            },
            copyAttributeValue: { [unowned self] _, _ in
                self.copyAttributeCallCount += 1
                return (self.attributeError, self.attributeValue)
            },
            copyMultipleAttributeValues: { [unowned self] _, _ in
                self.copyMultipleCallCount += 1
                return (self.multipleError, self.multipleValue)
            },
            isAttributeSettable: { [unowned self] _, attribute in
                self.settableAttributes.append(attribute)
                return self.settableResults.isEmpty
                    ? (.success, false)
                    : self.settableResults.removeFirst()
            },
            currentTime: { 0 }
        )
    }
}

private final class BlockingNativeAXReadPrimitives: @unchecked Sendable,
    NativeAXReadPrimitives {
    let started = XCTestExpectation(description: "native AX read started")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storageBatchReadCount = 0
    private var storageSettableReadCount = 0
    private var storageMessagingTimeouts: [TimeInterval] = []
    private var storageBudgets: [TimeInterval] = []
    private var storageBatchAttributes: [[String]] = []
    private var storageMainThreadValues: [Bool] = []

    var batchReadCount: Int { lock.withLock { storageBatchReadCount } }
    var settableReadCount: Int { lock.withLock { storageSettableReadCount } }
    var messagingTimeouts: [TimeInterval] { lock.withLock { storageMessagingTimeouts } }
    var budgets: [TimeInterval] { lock.withLock { storageBudgets } }
    var batchAttributes: [[String]] { lock.withLock { storageBatchAttributes } }
    var mainThreadValues: [Bool] { lock.withLock { storageMainThreadValues } }

    func applicationElement(processIdentifier: pid_t) -> AXElement {
        .injected("application-\(processIdentifier)")
    }

    func windows(
        processIdentifier: pid_t,
        messagingTimeout: TimeInterval,
        budget: TimeInterval
    ) throws -> [AXElement] {
        []
    }

    func windowState(
        element: AXElement,
        messagingTimeout: TimeInterval,
        budget: TimeInterval,
        attributes: [String]
    ) throws -> NativeAXWindowStateBatch {
        lock.withLock {
            storageBatchReadCount += 1
            storageSettableReadCount += 2
            storageMessagingTimeouts.append(messagingTimeout)
            storageBudgets.append(budget)
            storageBatchAttributes.append(attributes)
            storageMainThreadValues.append(Thread.isMainThread)
        }
        started.fulfill()
        _ = release.wait(timeout: .now() + 1)
        return NativeAXWindowStateBatch(
            title: "Window",
            frame: CanvasRect(x: 10, y: 20, width: 50, height: 40),
            isFocused: false,
            isMinimized: false,
            isPositionSettable: true,
            isSizeSettable: true,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parent: .injected("application-42"),
            isModal: false,
            isTransient: false
        )
    }
}

@MainActor
private final class FakeNativeAXObserverPrimitives: NativeAXObserverPrimitives {
    var failAddCall: Int?
    private var addCall = 0
    private(set) var addedNotifications: [String] = []
    private(set) var removedNotifications: [String] = []
    private(set) var addRunLoopSourceCount = 0
    private(set) var removeRunLoopSourceCount = 0
    weak var lastCallbackBox: NativeAXCallbackBox?

    func createObserver(
        processIdentifier: pid_t,
        callbackBox: NativeAXCallbackBox
    ) throws -> NativeAXObserverHandle {
        lastCallbackBox = callbackBox
        return NativeAXObserverHandle(storage: NSObject())
    }

    func addNotification(
        observer: NativeAXObserverHandle,
        element: AXElement,
        notification: String,
        callbackBox: NativeAXCallbackBox
    ) throws {
        addCall += 1
        addedNotifications.append(notification)
        if addCall == failAddCall {
            throw NativeAXObservationError.notificationRegistrationFailed
        }
    }

    func removeNotification(
        observer: NativeAXObserverHandle,
        element: AXElement,
        notification: String
    ) {
        removedNotifications.append(notification)
    }

    func addRunLoopSource(observer: NativeAXObserverHandle) {
        addRunLoopSourceCount += 1
    }

    func removeRunLoopSource(observer: NativeAXObserverHandle) {
        removeRunLoopSourceCount += 1
    }
}

@MainActor
private final class FakeNativeWorkspaceObservationPrimitives:
    NativeWorkspaceObservationPrimitives {
    private(set) var addedKinds: [NativeWorkspaceNotificationKind] = []
    private(set) var removedTokenIDs: [Int] = []
    private var handlers: [
        NativeWorkspaceNotificationKind: @MainActor @Sendable (NativeRunningApplication) -> Void
    ] = [:]

    func addObserver(
        kind: NativeWorkspaceNotificationKind,
        handler: @escaping @MainActor @Sendable (NativeRunningApplication) -> Void
    ) -> NativeWorkspaceObservationToken {
        addedKinds.append(kind)
        handlers[kind] = handler
        return NativeWorkspaceObservationToken(id: addedKinds.count, storage: NSObject())
    }

    func removeObserver(_ token: NativeWorkspaceObservationToken) {
        removedTokenIDs.append(token.id)
    }

    func trigger(
        _ kind: NativeWorkspaceNotificationKind,
        application: NativeRunningApplication
    ) {
        handlers[kind]?(application)
    }
}
