import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

@MainActor
public protocol LiveSnapshotProviding {
    func liveSnapshot() -> SwitcherSnapshot
}

public enum SwitcherActionTarget: Equatable {
    case display(id: String, window: WindowDescriptor?)
    case app(id: String)
}

public enum SwitcherActionFailure: Error, Equatable, Sendable {
    case targetAppTerminated
    case targetDisplayRemoved
    case accessibilityMissing
    case executeNotAllowed
    case panelNotOpen
    case actionInProgress
    case actionOverloaded
    case pointerMoveFailed
    case displayWindowActivationFailed
    case appActivationFailed
    case appWindowActivationFailed
    case appWindowActivationTimedOut
    case targetAppWindowUnavailable
    case invalidDisplayGeometry
    case windowQueryTimedOut
    case windowQueryUnavailable
    case executorUnavailable

    public var recoveryMessage: String {
        switch self {
        case .targetAppTerminated:
            "The selected app is no longer running."
        case .targetDisplayRemoved:
            "The selected display is no longer available."
        case .accessibilityMissing:
            "Accessibility permission is required to focus this window."
        case .pointerMoveFailed:
            "The pointer could not be moved to the selected display."
        case .targetAppWindowUnavailable, .windowQueryUnavailable:
            "No eligible live window is available on the selected display."
        case .windowQueryTimedOut, .appWindowActivationTimedOut:
            "Window discovery timed out. Try again."
        case .appActivationFailed, .appWindowActivationFailed, .displayWindowActivationFailed:
            "The selected window could not be focused. Try again."
        case .invalidDisplayGeometry:
            "The selected display does not have a safe pointer location."
        case .executorUnavailable:
            "Execution is temporarily unavailable."
        case .executeNotAllowed, .panelNotOpen, .actionInProgress, .actionOverloaded:
            "The action cannot run right now. Try again."
        }
    }
}

public enum ExecutionMode: Equatable {
    case dryRun
    case interactive
    case execute
}

public struct ExecutionPolicy: Equatable {
    public let mode: ExecutionMode
    public let diagnosticsAllowsInput: Bool

    public init(
        mode: ExecutionMode = .dryRun,
        environment: [String: String]? = nil
    ) {
        self.mode = mode
        if mode == .execute {
            let values = environment ?? ProcessInfo.processInfo.environment
            self.diagnosticsAllowsInput = values["CS_DIAG_ALLOW_INPUT"] == "1"
        } else {
            self.diagnosticsAllowsInput = false
        }
    }

    public var isExecuteAllowed: Bool {
        switch mode {
        case .interactive:
            return true
        case .execute:
            return diagnosticsAllowsInput
        case .dryRun:
            return false
        }
    }
}

public struct SwitcherActionPreview: Equatable {
    public let target: SwitcherActionTarget
    public let pointerDestination: PointSnapshot?
    public let hasWindow: Bool

    public init(
        target: SwitcherActionTarget,
        pointerDestination: PointSnapshot?,
        hasWindow: Bool
    ) {
        self.target = target
        self.pointerDestination = pointerDestination
        self.hasWindow = hasWindow
    }
}

public struct SwitcherActionExecution: Equatable {
    public let target: SwitcherActionTarget
    public let pointerMoved: Bool
    public let windowActivated: Bool
    public let appActivated: Bool

    public init(
        target: SwitcherActionTarget,
        pointerMoved: Bool,
        windowActivated: Bool,
        appActivated: Bool
    ) {
        self.target = target
        self.pointerMoved = pointerMoved
        self.windowActivated = windowActivated
        self.appActivated = appActivated
    }
}

public enum SwitcherActionResult: Equatable {
    case preview(SwitcherActionPreview)
    case executed(SwitcherActionExecution)
}

public enum DisplayWindowActivationResult: Equatable {
    case activated
    case unavailable
    case timedOut
    case busy
    case failed
}

public enum AppActivationOutcome: Equatable {
    case activated(windowActivated: Bool)
    case windowUnavailable
    case windowActivationTimedOut
    case windowActivationBusy
    case windowActivationFailed
    case failed
}

public enum WindowActivationOutcome: Equatable, Sendable {
    case activated
    case unavailable
    case timedOut
    case busy
    case failed
}

public enum DisplayWindowResolution: Equatable {
    case resolved(WindowDescriptor)
    case unavailable
    case failed
}

public struct WindowCandidate: Equatable {
    public let id: String
    public let frame: RectDescriptor
    let runtimeIdentity: WindowRuntimeIdentity?

    public var processIdentifier: pid_t? {
        runtimeIdentity?.ownerProcessIdentifier
    }

    public init(id: String, frame: RectDescriptor, processIdentifier: pid_t? = nil) {
        self.init(
            id: id,
            frame: frame,
            runtimeIdentity: processIdentifier.map {
                WindowRuntimeIdentity(ownerProcessIdentifier: $0, captureWindowID: nil)
            }
        )
    }

    init(id: String, frame: RectDescriptor, runtimeIdentity: WindowRuntimeIdentity?) {
        self.id = id
        self.frame = frame
        self.runtimeIdentity = runtimeIdentity
    }
}

protocol ActionDeadlineClock: Sendable {
    func now() -> TimeInterval
}

private struct SystemActionDeadlineClock: ActionDeadlineClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

struct AXWindowActionElement: @unchecked Sendable {
    fileprivate let rawValue: AXUIElement?
    let testIdentifier: Int

    fileprivate init(rawValue: AXUIElement) {
        self.rawValue = rawValue
        self.testIdentifier = Int(bitPattern: Unmanaged.passUnretained(rawValue).toOpaque())
    }

    init(testIdentifier: Int) {
        self.rawValue = nil
        self.testIdentifier = testIdentifier
    }
}

enum AXWindowActionReadResult<Value: Sendable>: Sendable {
    case success(Value)
    case timedOut
    case failed
}

enum AXWindowActionOperationResult: Sendable {
    case success
    case timedOut
    case failed
}

protocol AXWindowActionSystem: Sendable {
    func applicationElement(for processIdentifier: pid_t) -> AXWindowActionElement
    func setMessagingTimeout(_ timeout: TimeInterval, for element: AXWindowActionElement)
    func windowElements(
        for application: AXWindowActionElement
    ) -> AXWindowActionReadResult<[AXWindowActionElement]>
    func topLeftFrame(
        of window: AXWindowActionElement
    ) -> AXWindowActionReadResult<RectDescriptor>
    func raise(_ window: AXWindowActionElement) -> AXWindowActionOperationResult
}

private struct SystemAXWindowActionSystem: AXWindowActionSystem {
    func applicationElement(for processIdentifier: pid_t) -> AXWindowActionElement {
        AXWindowActionElement(rawValue: AXUIElementCreateApplication(processIdentifier))
    }

    func setMessagingTimeout(_ timeout: TimeInterval, for element: AXWindowActionElement) {
        guard let rawValue = element.rawValue else { return }
        _ = AXUIElementSetMessagingTimeout(rawValue, Float(max(0.001, timeout)))
    }

    func windowElements(
        for application: AXWindowActionElement
    ) -> AXWindowActionReadResult<[AXWindowActionElement]> {
        guard let rawValue = application.rawValue else { return .failed }
        var windowsValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            rawValue,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        if error == .cannotComplete { return .timedOut }
        guard error == .success, let windows = windowsValue as? [AXUIElement] else {
            return .failed
        }
        return .success(windows.map(AXWindowActionElement.init(rawValue:)))
    }

    func topLeftFrame(
        of window: AXWindowActionElement
    ) -> AXWindowActionReadResult<RectDescriptor> {
        guard let rawValue = window.rawValue else { return .failed }
        let attributes: [CFString] = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString
        ]
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            rawValue,
            attributes as CFArray,
            [],
            &rawValues
        )
        if error == .cannotComplete { return .timedOut }
        guard error == .success,
              let values = rawValues as? [Any],
              values.count == attributes.count,
              let position = point(values[0]),
              let size = size(values[1]),
              let frame = try? RectDescriptor(
                  x: position.x,
                  y: position.y,
                  width: size.width,
                  height: size.height
              ) else {
            return .failed
        }
        return .success(frame)
    }

    func raise(_ window: AXWindowActionElement) -> AXWindowActionOperationResult {
        guard let rawValue = window.rawValue else { return .failed }
        let error = AXUIElementPerformAction(rawValue, kAXRaiseAction as CFString)
        if error == .cannotComplete { return .timedOut }
        return error == .success ? .success : .failed
    }

    private func point(_ rawValue: Any) -> CGPoint? {
        guard let value = axValue(rawValue) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func size(_ rawValue: Any) -> CGSize? {
        guard let value = axValue(rawValue) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func axValue(_ rawValue: Any) -> AXValue? {
        let value = rawValue as CFTypeRef
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

protocol AXActionCancellationChecking: Sendable {
    var isCancelled: Bool { get }
}

protocol AXWindowActionPerforming: Sendable {
    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t,
        budget: TimeInterval,
        cancellation: any AXActionCancellationChecking
    ) -> WindowActivationOutcome
}

extension AXWindowActionPerforming {
    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t,
        budget: TimeInterval
    ) -> WindowActivationOutcome {
        resolveAndRaise(
            window: window,
            processIdentifier: processIdentifier,
            budget: budget,
            cancellation: AXActionOperationControl()
        )
    }
}

struct AXAccessibilityWindowActionPerformer: AXWindowActionPerforming {
    private let system: AXWindowActionSystem
    private let clock: ActionDeadlineClock
    private let coordinateNormalizer: TopLeftToAppKitCoordinateNormalizer

    init(
        system: AXWindowActionSystem = SystemAXWindowActionSystem(),
        clock: ActionDeadlineClock = SystemActionDeadlineClock(),
        appKitMainDisplayMaxY: Double? = nil
    ) {
        self.system = system
        self.clock = clock
        let detected = NSScreen.screens.first?.frame.maxY ?? 0
        let requested = appKitMainDisplayMaxY ?? detected
        self.coordinateNormalizer = TopLeftToAppKitCoordinateNormalizer(
            mainDisplayMaxY: requested.isFinite ? requested : detected
        )
    }

    func resolveAndRaise(
        window requestedWindow: WindowDescriptor,
        processIdentifier: pid_t,
        budget: TimeInterval,
        cancellation: any AXActionCancellationChecking
    ) -> WindowActivationOutcome {
        guard !cancellation.isCancelled else { return .unavailable }
        let safeBudget = budget.isFinite && budget > 0 ? budget : 0.25
        let deadline = clock.now() + safeBudget
        let application = system.applicationElement(for: processIdentifier)
        system.setMessagingTimeout(safeBudget, for: application)

        let windows: [AXWindowActionElement]
        switch system.windowElements(for: application) {
        case let .success(value):
            windows = value
        case .timedOut:
            return .timedOut
        case .failed:
            return .unavailable
        }
        guard !cancellation.isCancelled else { return .unavailable }

        var matches: [(element: AXWindowActionElement, candidate: WindowCandidate)] = []
        for (index, element) in windows.enumerated() {
            guard !cancellation.isCancelled else { return .unavailable }
            guard let remaining = remainingBudget(until: deadline) else { return .timedOut }
            system.setMessagingTimeout(remaining, for: element)
            let topLeftFrame: RectDescriptor
            switch system.topLeftFrame(of: element) {
            case let .success(value):
                topLeftFrame = value
            case .timedOut:
                return .timedOut
            case .failed:
                continue
            }
            guard let frame = coordinateNormalizer.normalize(topLeftFrame) else { continue }
            matches.append((
                element,
                WindowCandidate(id: "accessibility-ax-\(index)", frame: frame)
            ))
        }

        let selectedCandidates = matches.map(\.candidate)
        guard let selected = WindowCandidateSelector().select(
            requestedWindow: requestedWindow,
            from: selectedCandidates
        ), let element = matches.first(where: { $0.candidate.id == selected.id })?.element else {
            return .unavailable
        }
        guard let remaining = remainingBudget(until: deadline) else { return .timedOut }
        system.setMessagingTimeout(remaining, for: element)
        guard !cancellation.isCancelled else { return .unavailable }
        switch system.raise(element) {
        case .success:
            return .activated
        case .timedOut:
            return .timedOut
        case .failed:
            return .failed
        }
    }

    private func remainingBudget(until deadline: TimeInterval) -> TimeInterval? {
        let remaining = deadline - clock.now()
        return remaining > 0 ? remaining : nil
    }
}

protocol AXActionExecuting: Sendable {
    func execute(
        _ operation: @escaping @Sendable (
            any AXActionCancellationChecking
        ) -> WindowActivationOutcome
    ) async -> WindowActivationOutcome
}

protocol RealInputAdmissionControlling: Sendable {
    func reserveInputTransaction() -> AXActionAdmissionReservation?
}

final class AXActionAdmissionReservation: @unchecked Sendable {
    private let lock = NSLock()
    private let ownerIdentifier: ObjectIdentifier
    private let releaseHandler: @Sendable () -> Void
    private var released = false

    fileprivate init(
        ownerIdentifier: ObjectIdentifier,
        releaseHandler: @escaping @Sendable () -> Void
    ) {
        self.ownerIdentifier = ownerIdentifier
        self.releaseHandler = releaseHandler
    }

    fileprivate func belongs(to owner: AnyObject) -> Bool {
        lock.withLock {
            !released && ownerIdentifier == ObjectIdentifier(owner)
        }
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { releaseHandler() }
    }

    deinit { release() }
}

private protocol ReservedAXActionExecuting: AXActionExecuting {
    func execute(
        reservation: AXActionAdmissionReservation,
        _ operation: @escaping @Sendable (
            any AXActionCancellationChecking
        ) -> WindowActivationOutcome
    ) async -> WindowActivationOutcome
}

final class AXActionOperationControl: @unchecked Sendable,
    AXActionCancellationChecking {
    private let lock = NSLock()
    private var cancelled = false
    private var terminalOutcome: WindowActivationOutcome?
    private var continuation: CheckedContinuation<WindowActivationOutcome, Never>?
    private weak var operation: Operation?

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(
        operation: Operation,
        continuation: CheckedContinuation<WindowActivationOutcome, Never>
    ) {
        let immediateOutcome = lock.withLock { () -> WindowActivationOutcome? in
            guard let terminalOutcome else {
                self.operation = operation
                self.continuation = continuation
                return nil
            }
            return terminalOutcome
        }
        if isCancelled { operation.cancel() }
        if let immediateOutcome {
            continuation.resume(returning: immediateOutcome)
        }
    }

    func shouldStart() -> Bool {
        lock.withLock { !cancelled && terminalOutcome == nil }
    }

    func cancel() {
        let result = lock.withLock {
            () -> (Operation?, CheckedContinuation<WindowActivationOutcome, Never>?) in
            cancelled = true
            let operation = self.operation
            guard terminalOutcome == nil else { return (operation, nil) }
            terminalOutcome = .unavailable
            let continuation = self.continuation
            self.continuation = nil
            self.operation = nil
            return (operation, continuation)
        }
        result.0?.cancel()
        result.1?.resume(returning: .unavailable)
    }

    func finish(_ outcome: WindowActivationOutcome) {
        let result = lock.withLock {
            () -> (
                CheckedContinuation<WindowActivationOutcome, Never>?,
                WindowActivationOutcome
            ) in
            let finalOutcome: WindowActivationOutcome = cancelled ? .unavailable : outcome
            guard terminalOutcome == nil else { return (nil, finalOutcome) }
            terminalOutcome = finalOutcome
            let continuation = self.continuation
            self.continuation = nil
            operation = nil
            return (continuation, finalOutcome)
        }
        result.0?.resume(returning: result.1)
    }
}

final class BoundedAXActionExecutor: @unchecked Sendable,
    AXActionExecuting,
    RealInputAdmissionControlling,
    ReservedAXActionExecuting {
    private let queue: OperationQueue
    private let admissionLock = NSLock()
    private let maxPendingOperations: Int
    private var admittedOperationCount = 0

    init(
        maxConcurrentOperations: Int = 2,
        maxPendingOperations: Int = 8,
        operationQueue: OperationQueue? = nil
    ) {
        let concurrentLimit = max(1, maxConcurrentOperations)
        let queue = operationQueue ?? OperationQueue()
        queue.name = "com.indie-mono.screen-switcher.ax-actions"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = concurrentLimit
        self.queue = queue
        self.maxPendingOperations = max(concurrentLimit, maxPendingOperations)
    }

    func execute(
        _ operation: @escaping @Sendable (
            any AXActionCancellationChecking
        ) -> WindowActivationOutcome
    ) async -> WindowActivationOutcome {
        guard let reservation = reserveInputTransaction() else { return .busy }
        defer { reservation.release() }
        return await execute(reservation: reservation, operation)
    }

    func execute(
        reservation: AXActionAdmissionReservation,
        _ operation: @escaping @Sendable (
            any AXActionCancellationChecking
        ) -> WindowActivationOutcome
    ) async -> WindowActivationOutcome {
        guard reservation.belongs(to: self) else { return .busy }
        let control = AXActionOperationControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let queuedOperation = BlockOperation {
                    guard control.shouldStart() else {
                        control.finish(.unavailable)
                        return
                    }
                    control.finish(operation(control))
                }
                control.install(
                    operation: queuedOperation,
                    continuation: continuation
                )
                queue.addOperation(queuedOperation)
            }
        } onCancel: {
            control.cancel()
        }
    }

    func reserveInputTransaction() -> AXActionAdmissionReservation? {
        let admitted = admissionLock.withLock {
            guard admittedOperationCount < maxPendingOperations else { return false }
            admittedOperationCount += 1
            return true
        }
        guard admitted else { return nil }
        return AXActionAdmissionReservation(
            ownerIdentifier: ObjectIdentifier(self),
            releaseHandler: { [weak self] in self?.releaseAdmission() }
        )
    }

    private func releaseAdmission() {
        admissionLock.withLock {
            admittedOperationCount = max(0, admittedOperationCount - 1)
        }
    }
}

@MainActor
public protocol PointerMoving {
    func movePointer(to point: PointSnapshot) -> Bool
}

@MainActor
public protocol DisplayWindowActivating {
    func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor
    ) async -> DisplayWindowActivationResult
}

@MainActor
public protocol DisplayWindowResolving {
    func resolveDisplayWindow(
        display: DisplayDescriptor,
        requestedWindow: WindowDescriptor
    ) -> DisplayWindowResolution
}

@MainActor
public protocol DisplayWindowDiscovering {
    func discoverWindow(for display: DisplayDescriptor) -> WindowDescriptor?
}

@MainActor
public protocol WindowActivationResolving {
    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t
    ) async -> WindowActivationOutcome
}

@MainActor
private protocol ReservedWindowActivationResolving: WindowActivationResolving {
    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t,
        reservation: AXActionAdmissionReservation
    ) async -> WindowActivationOutcome
}

@MainActor
public protocol WindowCandidateResolving {
    func windowCandidates() -> [WindowCandidate]
}

public struct WindowCandidateSelector {
    public init() {}

    public func select(
        requestedWindow: WindowDescriptor,
        from candidates: [WindowCandidate]
    ) -> WindowCandidate? {
        let frameMatches = candidates.filter { sameFrame($0.frame, requestedWindow.frame) }
        if let captureID = requestedWindow.runtimeIdentity?.captureWindowID {
            let captureMatches = frameMatches.filter {
                $0.runtimeIdentity?.captureWindowID == captureID
                    && $0.runtimeIdentity?.ownerProcessIdentifier
                        == requestedWindow.runtimeIdentity?.ownerProcessIdentifier
            }
            return captureMatches.count == 1 ? captureMatches[0] : nil
        }
        let idMatches = frameMatches.filter { $0.id == requestedWindow.id }
        if idMatches.count == 1 {
            return idMatches[0]
        }
        if idMatches.count > 1 {
            return nil
        }
        return frameMatches.count == 1 ? frameMatches[0] : nil
    }

    private func sameFrame(_ lhs: RectDescriptor, _ rhs: RectDescriptor) -> Bool {
        abs(lhs.x - rhs.x) < 1
            && abs(lhs.y - rhs.y) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }
}

@MainActor
public protocol RunningAppActivating {
    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?
    ) async -> AppActivationOutcome
}

public struct WorkspaceExecutionDisplay: Equatable, Sendable {
    public let display: DisplayDescriptor
    public let safeBounds: RectDescriptor

    public init(display: DisplayDescriptor, safeBounds: RectDescriptor) {
        self.display = display
        self.safeBounds = safeBounds
    }
}

public struct WorkspaceExecutionWindow: Equatable, Sendable {
    public let appID: String
    public let displayID: String
    public let window: WindowDescriptor
    public let isMinimized: Bool
    public let appRecencyRank: Int
    public let recencyRank: Int

    public init(
        appID: String,
        displayID: String,
        window: WindowDescriptor,
        isMinimized: Bool,
        appRecencyRank: Int = 0,
        recencyRank: Int
    ) {
        self.appID = appID
        self.displayID = displayID
        self.window = window
        self.isMinimized = isMinimized
        self.appRecencyRank = max(0, appRecencyRank)
        self.recencyRank = max(0, recencyRank)
    }

    public var processIdentifier: pid_t? {
        window.runtimeIdentity?.ownerProcessIdentifier
    }
}

public struct WorkspaceExecutionLiveState: Equatable, Sendable {
    public let displays: [WorkspaceExecutionDisplay]
    public let runningAppIDs: Set<String>
    public let windows: [WorkspaceExecutionWindow]

    public init(
        displays: [WorkspaceExecutionDisplay],
        runningAppIDs: Set<String>,
        windows: [WorkspaceExecutionWindow]
    ) {
        self.displays = displays
        self.runningAppIDs = runningAppIDs
        self.windows = windows
    }
}

@MainActor
public protocol WorkspaceExecutionLiveStateProviding {
    func freshState() async -> Result<WorkspaceExecutionLiveState, SwitcherActionFailure>
}

@MainActor
public protocol WorkspaceAccessibilityGating {
    func requireAccess() -> Bool
}

@MainActor
public protocol WorkspacePointerMoving {
    func movePointer(to point: PointSnapshot, displayID: String) -> Bool
}

@MainActor
public protocol WorkspaceExistingAppActivating {
    func activateExistingApp(appID: String, processIdentifier: pid_t?) -> Bool
}

@MainActor
public protocol WorkspaceWindowFocusing {
    func focus(
        window: WindowDescriptor,
        processIdentifier: pid_t?
    ) async -> WindowActivationOutcome
}

@MainActor
public protocol WorkspaceExecutionExecuting: AnyObject {
    func execute(
        _ request: WorkspaceExecutionRequest
    ) async -> Result<Void, SwitcherActionFailure>
}

@MainActor
public final class WorkspaceExecutionCoordinator {
    private let executor: any WorkspaceExecutionExecuting

    public init(executor: any WorkspaceExecutionExecuting) {
        self.executor = executor
    }

    @discardableResult
    public func handle(
        _ request: WorkspaceExecutionRequest,
        completion: @escaping @MainActor (WorkspaceExecutionCompletion) -> Void
    ) -> Task<Void, Never> {
        let executor = self.executor
        return Task { @MainActor in
            let result = await executor.execute(request)
            guard !Task.isCancelled else { return }
            completion(WorkspaceExecutionCompletion(
                id: request.id,
                target: request.target,
                outcome: result.workspaceExecutionOutcome
            ))
        }
    }
}

private extension Result where Success == Void, Failure == SwitcherActionFailure {
    var workspaceExecutionOutcome: WorkspaceExecutionOutcome {
        switch self {
        case .success: .success
        case let .failure(failure): .failure(failure)
        }
    }
}

public enum WorkspaceSafePoint {
    public static func resolve(
        displayFrame: RectDescriptor,
        safeBounds: RectDescriptor
    ) -> PointSnapshot? {
        guard displayFrame.isValid, safeBounds.isValid else { return nil }
        let minX = max(displayFrame.x, safeBounds.x)
        let minY = max(displayFrame.y, safeBounds.y)
        let maxX = min(displayFrame.maxX, safeBounds.maxX)
        let maxY = min(displayFrame.maxY, safeBounds.maxY)
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
              maxX > minX, maxY > minY else { return nil }
        let point = PointSnapshot(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
        guard point.x > minX, point.x < maxX, point.y > minY, point.y < maxY else {
            return nil
        }
        return point
    }
}

@MainActor
public final class WorkspaceExecutionService: WorkspaceExecutionExecuting {
    private let liveStateProvider: any WorkspaceExecutionLiveStateProviding
    private let accessibilityGate: any WorkspaceAccessibilityGating
    private let pointerMover: any WorkspacePointerMoving
    private let appActivator: any WorkspaceExistingAppActivating
    private let windowFocuser: any WorkspaceWindowFocusing

    public init(
        liveStateProvider: any WorkspaceExecutionLiveStateProviding,
        accessibilityGate: any WorkspaceAccessibilityGating,
        pointerMover: any WorkspacePointerMoving,
        appActivator: any WorkspaceExistingAppActivating,
        windowFocuser: any WorkspaceWindowFocusing
    ) {
        self.liveStateProvider = liveStateProvider
        self.accessibilityGate = accessibilityGate
        self.pointerMover = pointerMover
        self.appActivator = appActivator
        self.windowFocuser = windowFocuser
    }

    public func execute(
        _ request: WorkspaceExecutionRequest
    ) async -> Result<Void, SwitcherActionFailure> {
        guard !Task.isCancelled else { return .failure(.actionOverloaded) }
        let initialState: WorkspaceExecutionLiveState
        switch await liveStateProvider.freshState() {
        case let .success(state): initialState = state
        case let .failure(failure): return .failure(failure)
        }
        guard !Task.isCancelled else { return .failure(.actionOverloaded) }
        switch request.target {
        case let .display(displayID):
            guard initialState.displays.contains(where: { $0.display.id == displayID }) else {
                return .failure(.targetDisplayRemoved)
            }
            let revalidatedState: WorkspaceExecutionLiveState
            switch await liveStateProvider.freshState() {
            case let .success(state): revalidatedState = state
            case let .failure(failure): return .failure(failure)
            }
            guard !Task.isCancelled else { return .failure(.actionOverloaded) }
            guard let revalidatedDisplay = revalidatedState.displays.first(where: {
                $0.display.id == displayID
            }) else {
                return .failure(.targetDisplayRemoved)
            }
            guard let point = WorkspaceSafePoint.resolve(
                displayFrame: revalidatedDisplay.display.frame,
                safeBounds: revalidatedDisplay.safeBounds
            ) else {
                return .failure(.invalidDisplayGeometry)
            }
            let selectedWindow = bestDisplayWindow(
                display: revalidatedDisplay,
                state: revalidatedState
            )
            if selectedWindow != nil, !accessibilityGate.requireAccess() {
                return .failure(.accessibilityMissing)
            }
            guard !Task.isCancelled else { return .failure(.actionOverloaded) }
            guard pointerMover.movePointer(to: point, displayID: displayID) else {
                return .failure(.pointerMoveFailed)
            }
            guard let selectedWindow else { return .success(()) }
            return await activateAndFocus(selectedWindow)

        case let .app(displayID, appID):
            guard let display = initialState.displays.first(where: { $0.display.id == displayID }) else {
                return .failure(.targetDisplayRemoved)
            }
            guard initialState.runningAppIDs.contains(appID) else {
                return .failure(.targetAppTerminated)
            }
            guard accessibilityGate.requireAccess() else {
                return .failure(.accessibilityMissing)
            }
            guard bestWindow(
                appID: appID,
                display: display,
                windows: initialState.windows
            ) != nil else {
                return .failure(.targetAppWindowUnavailable)
            }
            let revalidatedState: WorkspaceExecutionLiveState
            switch await liveStateProvider.freshState() {
            case let .success(state): revalidatedState = state
            case let .failure(failure): return .failure(failure)
            }
            guard !Task.isCancelled else { return .failure(.actionOverloaded) }
            guard let revalidatedDisplay = revalidatedState.displays.first(where: {
                $0.display.id == displayID
            }) else {
                return .failure(.targetDisplayRemoved)
            }
            guard revalidatedState.runningAppIDs.contains(appID) else {
                return .failure(.targetAppTerminated)
            }
            guard let selectedWindow = bestWindow(
                appID: appID,
                display: revalidatedDisplay,
                windows: revalidatedState.windows
            ) else {
                return .failure(.targetAppWindowUnavailable)
            }
            guard let point = WorkspaceSafePoint.resolve(
                displayFrame: revalidatedDisplay.display.frame,
                safeBounds: revalidatedDisplay.safeBounds
            ) else {
                return .failure(.invalidDisplayGeometry)
            }
            guard !Task.isCancelled else { return .failure(.actionOverloaded) }
            guard pointerMover.movePointer(to: point, displayID: displayID) else {
                return .failure(.pointerMoveFailed)
            }
            return await activateAndFocus(selectedWindow)
        }
    }

    private func activateAndFocus(
        _ selectedWindow: WorkspaceExecutionWindow
    ) async -> Result<Void, SwitcherActionFailure> {
        guard !Task.isCancelled else { return .failure(.actionOverloaded) }
        guard appActivator.activateExistingApp(
            appID: selectedWindow.appID,
            processIdentifier: selectedWindow.processIdentifier
        ) else {
            return .failure(.appActivationFailed)
        }
        guard !Task.isCancelled else { return .failure(.actionOverloaded) }
        switch await windowFocuser.focus(
            window: selectedWindow.window,
            processIdentifier: selectedWindow.processIdentifier
        ) {
        case .activated:
            return Task.isCancelled ? .failure(.actionOverloaded) : .success(())
        case .timedOut: return .failure(.appWindowActivationTimedOut)
        case .busy: return .failure(.actionOverloaded)
        case .unavailable, .failed: return .failure(.appWindowActivationFailed)
        }
    }

    private func bestDisplayWindow(
        display: WorkspaceExecutionDisplay,
        state: WorkspaceExecutionLiveState
    ) -> WorkspaceExecutionWindow? {
        state.windows.filter { candidate in
            state.runningAppIDs.contains(candidate.appID)
                && isEligible(candidate, on: display)
        }.sorted { lhs, rhs in
            if lhs.appRecencyRank != rhs.appRecencyRank {
                return lhs.appRecencyRank < rhs.appRecencyRank
            }
            return isWindowOrderedBefore(lhs, rhs)
        }.first
    }

    private func bestWindow(
        appID: String,
        display: WorkspaceExecutionDisplay,
        windows: [WorkspaceExecutionWindow]
    ) -> WorkspaceExecutionWindow? {
        windows.filter { $0.appID == appID && isEligible($0, on: display) }
            .sorted(by: isWindowOrderedBefore)
            .first
    }

    private func isEligible(
        _ candidate: WorkspaceExecutionWindow,
        on display: WorkspaceExecutionDisplay
    ) -> Bool {
        guard candidate.displayID == display.display.id,
              !candidate.isMinimized,
              candidate.window.isOnScreen,
              candidate.window.frame.isValid else { return false }
        let frame = candidate.window.frame
        return display.display.frame.contains(PointSnapshot(
            x: frame.x + frame.width / 2,
            y: frame.y + frame.height / 2
        ))
    }

    private func isWindowOrderedBefore(
        _ lhs: WorkspaceExecutionWindow,
        _ rhs: WorkspaceExecutionWindow
    ) -> Bool {
        if lhs.recencyRank != rhs.recencyRank { return lhs.recencyRank < rhs.recencyRank }
        if lhs.window.isMain != rhs.window.isMain { return lhs.window.isMain }
        return lhs.window.id < rhs.window.id
    }
}

@MainActor
public struct PermissionWorkspaceAccessibilityGate: WorkspaceAccessibilityGating {
    private let permissionService: PermissionService

    public init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    public func requireAccess() -> Bool {
        permissionService.isAccessibilityGranted()
    }
}

@MainActor
public struct CGWorkspacePointerMover: WorkspacePointerMoving {
    private let pointerMover: any PointerMoving

    public init(pointerMover: (any PointerMoving)? = nil) {
        self.pointerMover = pointerMover ?? CGPointerMover()
    }

    public func movePointer(to point: PointSnapshot, displayID _: String) -> Bool {
        pointerMover.movePointer(to: point)
    }
}

@MainActor
public struct NSWorkspaceExistingAppActivator: WorkspaceExistingAppActivating {
    public init() {}

    public func activateExistingApp(appID: String, processIdentifier: pid_t?) -> Bool {
        let application: NSRunningApplication?
        if let processIdentifier,
           let preferred = NSRunningApplication(processIdentifier: processIdentifier),
           preferred.bundleIdentifier == appID,
           !preferred.isTerminated {
            application = preferred
        } else {
            application = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == appID && !$0.isTerminated
            }
        }
        return application?.activate(options: []) == true
    }
}

@MainActor
public struct AccessibilityWorkspaceWindowFocuser: WorkspaceWindowFocusing {
    private let resolver: any WindowActivationResolving

    public init(resolver: any WindowActivationResolving) {
        self.resolver = resolver
    }

    public func focus(
        window: WindowDescriptor,
        processIdentifier: pid_t?
    ) async -> WindowActivationOutcome {
        guard let processIdentifier else { return .unavailable }
        return await resolver.resolveAndRaise(
            window: window,
            processIdentifier: processIdentifier
        )
    }
}

@MainActor
public final class SnapshotWorkspaceExecutionLiveStateProvider: WorkspaceExecutionLiveStateProviding {
    private let snapshotProvider: any LiveSnapshotProviding
    private let permissionService: PermissionService

    public init(
        snapshotProvider: any LiveSnapshotProviding,
        permissionService: PermissionService
    ) {
        self.snapshotProvider = snapshotProvider
        self.permissionService = permissionService
    }

    public func freshState() async -> Result<WorkspaceExecutionLiveState, SwitcherActionFailure> {
        guard !Task.isCancelled else { return .failure(.actionOverloaded) }
        let snapshot = snapshotProvider.liveSnapshot()
        let displays = snapshot.displays.map { display in
            WorkspaceExecutionDisplay(
                display: display,
                safeBounds: visibleBounds(for: display.id) ?? display.frame
            )
        }
        let windows: [WorkspaceExecutionWindow] = snapshot.runningApps.enumerated().compactMap { element in
            let (rank, app) = element
            guard let window = app.mostRecentWindow else { return nil }
            let center = PointSnapshot(
                x: window.frame.x + window.frame.width / 2,
                y: window.frame.y + window.frame.height / 2
            )
            guard let displayID = snapshot.displays.first(where: { $0.frame.contains(center) })?.id else {
                return nil
            }
            return WorkspaceExecutionWindow(
                appID: app.id,
                displayID: displayID,
                window: window,
                isMinimized: false,
                recencyRank: rank
            )
        }
        return .success(WorkspaceExecutionLiveState(
            displays: displays,
            runningAppIDs: Set(snapshot.runningApps.map(\.id)),
            windows: windows
        ))
    }

    private func visibleBounds(for displayID: String) -> RectDescriptor? {
        let screen = NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return false }
            return "display-\(number.uint32Value)" == displayID
        }
        guard let frame = screen?.visibleFrame else { return nil }
        return try? RectDescriptor(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
public final class RuntimeWorkspaceExecutionLiveStateProvider: WorkspaceExecutionLiveStateProviding {
    private let runtimeState: SwitcherRuntimeState
    private let permissionService: PermissionService

    public init(
        runtimeState: SwitcherRuntimeState,
        permissionService: PermissionService
    ) {
        self.runtimeState = runtimeState
        self.permissionService = permissionService
    }

    public func freshState() async -> Result<WorkspaceExecutionLiveState, SwitcherActionFailure> {
        guard !Task.isCancelled else { return .failure(.actionOverloaded) }
        let pointer = runtimeState.pointerLocation.currentPointerLocation()
        let liveDisplays = runtimeState.displayCatalog.snapshot(at: pointer)
        let appIDs = runtimeState.runningAppCatalog.freshExecutionAppIDs()
        let displays = liveDisplays.map { display in
            WorkspaceExecutionDisplay(
                display: display,
                safeBounds: systemVisibleBounds(for: display.id) ?? display.frame
            )
        }
        let windowsByAppID: [String: [WindowDescriptor]]
        if let inventory = runtimeState.runningAppCatalog.windowReader
            as? any FreshDisplayScopedWindowInventoryReading {
            switch await inventory.freshEligibleWindows(
                for: appIDs,
                displays: liveDisplays
            ) {
            case let .success(windows): windowsByAppID = windows
            case .failure(.accessibilityMissing): windowsByAppID = [:]
            case let .failure(failure): return .failure(failure)
            }
        } else {
            return .failure(.windowQueryUnavailable)
        }
        guard !Task.isCancelled else { return .failure(.actionOverloaded) }
        let windows: [WorkspaceExecutionWindow] = appIDs.enumerated().flatMap { appElement in
            let (appRank, appID) = appElement
            return windowsByAppID[appID, default: []].enumerated().compactMap { element -> WorkspaceExecutionWindow? in
                let (rank, window) = element
                let center = PointSnapshot(
                    x: window.frame.x + window.frame.width / 2,
                    y: window.frame.y + window.frame.height / 2
                )
                guard let displayID = liveDisplays.first(where: {
                    $0.frame.contains(center)
                })?.id else { return nil }
                return WorkspaceExecutionWindow(
                    appID: appID,
                    displayID: displayID,
                    window: window,
                    isMinimized: false,
                    appRecencyRank: appRank,
                    recencyRank: rank
                )
            }
        }
        return .success(WorkspaceExecutionLiveState(
            displays: displays,
            runningAppIDs: Set(appIDs),
            windows: windows
        ))
    }

    private func systemVisibleBounds(for displayID: String) -> RectDescriptor? {
        let screen = NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return false }
            return "display-\(number.uint32Value)" == displayID
        }
        guard let frame = screen?.visibleFrame else { return nil }
        return try? RectDescriptor(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
private protocol ReservedRunningAppActivating: RunningAppActivating {
    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?,
        reservation: AXActionAdmissionReservation
    ) async -> AppActivationOutcome
}

@MainActor
private protocol ReservedDisplayWindowActivating: DisplayWindowActivating {
    func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor,
        reservation: AXActionAdmissionReservation
    ) async -> DisplayWindowActivationResult
}

@MainActor
public final class SwitcherActionService {
    private let policy: ExecutionPolicy
    let liveSnapshotProvider: LiveSnapshotProviding
    let executionPolicy: ExecutionPolicy
    private let permissionService: PermissionService
    private let pointerMover: PointerMoving
    private let displayWindowDiscovery: DisplayWindowDiscovering
    private let displayWindowResolver: DisplayWindowResolving
    private let displayWindowActivator: DisplayWindowActivating
    private let appActivator: RunningAppActivating
    private let inputAdmission: RealInputAdmissionControlling

    public init(
        policy: ExecutionPolicy = ExecutionPolicy(),
        liveSnapshotProvider: LiveSnapshotProviding,
        permissionService: PermissionService? = nil,
        pointerMover: PointerMoving? = nil,
        displayWindowDiscovery: DisplayWindowDiscovering? = nil,
        displayWindowResolver: DisplayWindowResolving? = nil,
        displayWindowActivator: DisplayWindowActivating? = nil,
        appActivator: RunningAppActivating? = nil
    ) {
        let permissionService = permissionService ?? PermissionService()
        let actionExecutor = BoundedAXActionExecutor()
        let windowResolver = AccessibilityWindowActivationResolver(
            permissionService: permissionService,
            actionPerformer: AXAccessibilityWindowActionPerformer(),
            actionExecutor: actionExecutor
        )
        self.policy = policy
        self.executionPolicy = policy
        self.liveSnapshotProvider = liveSnapshotProvider
        self.permissionService = permissionService
        self.inputAdmission = actionExecutor
        self.pointerMover = pointerMover ?? CGPointerMover()
        self.displayWindowDiscovery = displayWindowDiscovery
            ?? AppKitDisplayWindowDiscovery(permissionService: permissionService)
        self.displayWindowResolver = displayWindowResolver
            ?? AccessibilityDisplayWindowResolver(permissionService: permissionService)
        self.displayWindowActivator = displayWindowActivator
            ?? AccessibilityDisplayWindowActivator(
                permissionService: permissionService,
                windowResolver: windowResolver
            )
        self.appActivator = appActivator
            ?? NSWorkspaceRunningAppActivator(
                permissionService: permissionService,
                windowResolver: windowResolver
            )
    }

    init(
        policy: ExecutionPolicy,
        liveSnapshotProvider: LiveSnapshotProviding,
        permissionService: PermissionService? = nil,
        pointerMover: PointerMoving? = nil,
        displayWindowDiscovery: DisplayWindowDiscovering? = nil,
        displayWindowResolver: DisplayWindowResolving? = nil,
        displayWindowActivator: DisplayWindowActivating? = nil,
        appActivator: RunningAppActivating? = nil,
        inputAdmission: RealInputAdmissionControlling
    ) {
        let permissionService = permissionService ?? PermissionService()
        let reservedExecutor = inputAdmission as? AXActionExecuting
        let windowResolver: WindowActivationResolving = reservedExecutor.map {
            AccessibilityWindowActivationResolver(
                permissionService: permissionService,
                actionPerformer: AXAccessibilityWindowActionPerformer(),
                actionExecutor: $0
            )
        } ?? AccessibilityWindowActivationResolver(permissionService: permissionService)
        self.policy = policy
        self.executionPolicy = policy
        self.liveSnapshotProvider = liveSnapshotProvider
        self.permissionService = permissionService
        self.inputAdmission = inputAdmission
        self.pointerMover = pointerMover ?? CGPointerMover()
        self.displayWindowDiscovery = displayWindowDiscovery
            ?? AppKitDisplayWindowDiscovery(permissionService: permissionService)
        self.displayWindowResolver = displayWindowResolver
            ?? AccessibilityDisplayWindowResolver(permissionService: permissionService)
        self.displayWindowActivator = displayWindowActivator
            ?? AccessibilityDisplayWindowActivator(
                permissionService: permissionService,
                windowResolver: windowResolver
            )
        self.appActivator = appActivator
            ?? NSWorkspaceRunningAppActivator(
                permissionService: permissionService,
                windowResolver: windowResolver
            )
    }

    public func perform(
        target: SwitcherActionTarget,
        snapshot: SwitcherSnapshot
    ) async -> Result<SwitcherActionResult, SwitcherActionFailure> {
        guard policy.mode != .dryRun else {
            return previewResult(for: target, snapshot: snapshot)
        }
        guard policy.mode == .interactive || policy.isExecuteAllowed else {
            return .failure(.executeNotAllowed)
        }
        guard let reservation = inputAdmission.reserveInputTransaction() else {
            return .failure(.actionOverloaded)
        }
        defer { reservation.release() }

        let liveSnapshot = liveSnapshotProvider.liveSnapshot()
        switch target {
        case let .display(id, window):
            guard let display = liveSnapshot.displays.first(where: { $0.id == id }) else {
                return .failure(.targetDisplayRemoved)
            }
            guard let permissionFailure = accessibilityFailure() else {
                let center = PointSnapshot(
                    x: display.frame.x + display.frame.width / 2,
                    y: display.frame.y + display.frame.height / 2
                )
                return await executeDisplay(
                    target: target,
                    display: display,
                    window: window ?? displayWindowDiscovery.discoverWindow(for: display),
                    center: center,
                    reservation: reservation
                )
            }
            return .failure(permissionFailure)

        case let .app(id):
            guard let app = liveSnapshot.runningApps.first(where: { $0.id == id }) else {
                return .failure(.targetAppTerminated)
            }
            guard let permissionFailure = accessibilityFailure() else {
                let outcome: AppActivationOutcome
                if let reservedActivator = appActivator as? ReservedRunningAppActivating {
                    outcome = await reservedActivator.activateApp(
                        appID: app.id,
                        mostRecentWindow: app.mostRecentWindow,
                        reservation: reservation
                    )
                } else {
                    outcome = await appActivator.activateApp(
                        appID: app.id,
                        mostRecentWindow: app.mostRecentWindow
                    )
                }
                switch outcome {
                case let .activated(windowActivated):
                    return .success(.executed(
                        SwitcherActionExecution(
                            target: target,
                            pointerMoved: false,
                            windowActivated: windowActivated,
                            appActivated: true
                        )
                    ))
                case .windowUnavailable:
                    return .success(.executed(
                        SwitcherActionExecution(
                            target: target,
                            pointerMoved: false,
                            windowActivated: false,
                            appActivated: true
                        )
                    ))
                case .windowActivationTimedOut:
                    return .failure(.appWindowActivationTimedOut)
                case .windowActivationBusy:
                    return .failure(.actionOverloaded)
                case .windowActivationFailed:
                    return .failure(.appWindowActivationFailed)
                case .failed:
                    return .failure(.appActivationFailed)
                }
            }
            return .failure(permissionFailure)
        }
    }

    private func previewResult(
        for target: SwitcherActionTarget,
        snapshot: SwitcherSnapshot
    ) -> Result<SwitcherActionResult, SwitcherActionFailure> {
        switch target {
        case let .display(id, window):
            guard let display = snapshot.displays.first(where: { $0.id == id }) else {
                return .failure(.targetDisplayRemoved)
            }
            let center = PointSnapshot(
                x: display.frame.x + display.frame.width / 2,
                y: display.frame.y + display.frame.height / 2
            )
            return .success(.preview(
                SwitcherActionPreview(
                    target: target,
                    pointerDestination: center,
                    hasWindow: window != nil
                )
            ))

        case let .app(id):
            guard let app = snapshot.runningApps.first(where: { $0.id == id }) else {
                return .failure(.targetAppTerminated)
            }
            return .success(.preview(
                SwitcherActionPreview(
                    target: target,
                    pointerDestination: nil,
                    hasWindow: app.mostRecentWindow != nil
                )
            ))
        }
    }

    private func accessibilityFailure() -> SwitcherActionFailure? {
        do {
            try permissionService.requireAccessibility()
            return nil
        } catch PermissionFailure.accessibilityMissing {
            return .accessibilityMissing
        } catch {
            return .accessibilityMissing
        }
    }

    private func executeDisplay(
        target: SwitcherActionTarget,
        display: DisplayDescriptor,
        window: WindowDescriptor?,
        center: PointSnapshot,
        reservation: AXActionAdmissionReservation
    ) async -> Result<SwitcherActionResult, SwitcherActionFailure> {
        if let window {
            _ = displayWindowResolver.resolveDisplayWindow(
                display: display,
                requestedWindow: window
            )
        }

        guard pointerMover.movePointer(to: center) else {
            return .failure(.pointerMoveFailed)
        }

        var windowActivated = false
        if let window {
            switch displayWindowResolver.resolveDisplayWindow(
                display: display,
                requestedWindow: window
            ) {
            case let .resolved(resolvedWindow):
                let outcome: DisplayWindowActivationResult
                if let reservedActivator = displayWindowActivator
                    as? ReservedDisplayWindowActivating {
                    outcome = await reservedActivator.activateDisplayWindow(
                        display: display,
                        window: resolvedWindow,
                        reservation: reservation
                    )
                } else {
                    outcome = await displayWindowActivator.activateDisplayWindow(
                        display: display,
                        window: resolvedWindow
                    )
                }
                switch outcome {
                case .activated:
                    windowActivated = true
                case .unavailable:
                    break
                case .timedOut:
                    return .failure(.displayWindowActivationFailed)
                case .busy:
                    return .failure(.actionOverloaded)
                case .failed:
                    return .failure(.displayWindowActivationFailed)
                }
            case .unavailable:
                break
            case .failed:
                return .failure(.displayWindowActivationFailed)
            }
        }

        return .success(.executed(
            SwitcherActionExecution(
                target: target,
                pointerMoved: true,
                windowActivated: windowActivated,
                appActivated: false
            )
        ))
    }
}

@MainActor
public struct CGPointerMover: PointerMoving {
    public init() {}

    public func movePointer(to point: PointSnapshot) -> Bool {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y)) == .success
    }
}

@MainActor
public struct UnavailableDisplayWindowActivator: DisplayWindowActivating {
    public init() {}

    public func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor
    ) async -> DisplayWindowActivationResult {
        .unavailable
    }
}

@MainActor
public struct CGWindowCandidateResolver: WindowCandidateResolving {
    private let permissionService: PermissionService
    private let coordinateNormalizer: TopLeftToAppKitCoordinateNormalizer

    public init(
        permissionService: PermissionService? = nil,
        appKitMainDisplayMaxY: Double? = nil
    ) {
        self.permissionService = permissionService ?? PermissionService()
        let detected = NSScreen.screens.first?.frame.maxY ?? 0
        let maxY = appKitMainDisplayMaxY ?? detected
        self.coordinateNormalizer = TopLeftToAppKitCoordinateNormalizer(
            mainDisplayMaxY: maxY.isFinite ? maxY : detected
        )
    }

    public func windowCandidates() -> [WindowCandidate] {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return infos.enumerated().compactMap { index, info in
            guard
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                let topLeftFrame = try? RectDescriptor(
                    x: bounds.origin.x,
                    y: bounds.origin.y,
                    width: bounds.size.width,
                    height: bounds.size.height
                ),
                let frame = coordinateNormalizer.normalize(topLeftFrame)
            else {
                return nil
            }
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            return WindowCandidate(
                id: "cg-window-\(index)",
                frame: frame,
                runtimeIdentity: ownerPID.map {
                    WindowRuntimeIdentity(
                        ownerProcessIdentifier: $0,
                        captureWindowID: CGWindowID(number)
                    )
                }
            )
        }
    }
}

@MainActor
public struct AppKitDisplayWindowDiscovery: DisplayWindowDiscovering {
    private let permissionService: PermissionService
    private let candidateResolver: WindowCandidateResolving

    public init(
        permissionService: PermissionService? = nil,
        candidateResolver: WindowCandidateResolving? = nil
    ) {
        let permissionService = permissionService ?? PermissionService()
        self.permissionService = permissionService
        self.candidateResolver = candidateResolver
            ?? CGWindowCandidateResolver(permissionService: permissionService)
    }

    public func discoverWindow(for display: DisplayDescriptor) -> WindowDescriptor? {
        guard permissionService.isAccessibilityGranted()
        else {
            return nil
        }

        let candidates = candidateResolver.windowCandidates().filter { candidate in
            display.frame.contains(PointSnapshot(
                x: candidate.frame.x + candidate.frame.width / 2,
                y: candidate.frame.y + candidate.frame.height / 2
            ))
        }
        // Without a stable window identity, ambiguity is safer than raising an
        // arbitrary window. A unique frontmost candidate is activatable.
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }
        return WindowDescriptor(
            id: candidate.id,
            frame: candidate.frame,
            isOnScreen: true,
            isMain: true,
            runtimeIdentity: candidate.runtimeIdentity
        )
    }
}

@MainActor
public struct AccessibilityDisplayWindowResolver: DisplayWindowResolving {
    private let permissionService: PermissionService
    private let candidateResolver: WindowCandidateResolving
    private let candidateSelector: WindowCandidateSelector

    public init(
        permissionService: PermissionService? = nil,
        candidateResolver: WindowCandidateResolving? = nil,
        candidateSelector: WindowCandidateSelector? = nil
    ) {
        let permissionService = permissionService ?? PermissionService()
        self.permissionService = permissionService
        self.candidateResolver = candidateResolver
            ?? CGWindowCandidateResolver(permissionService: permissionService)
        self.candidateSelector = candidateSelector ?? WindowCandidateSelector()
    }

    public func resolveDisplayWindow(
        display: DisplayDescriptor,
        requestedWindow: WindowDescriptor
    ) -> DisplayWindowResolution {
        guard permissionService.isAccessibilityGranted()
        else {
            return .unavailable
        }
        let displayCandidates = candidateResolver.windowCandidates().filter {
            display.frame.contains(PointSnapshot(x: $0.frame.x + $0.frame.width / 2,
                                                 y: $0.frame.y + $0.frame.height / 2))
        }
        guard candidateSelector.select(
            requestedWindow: requestedWindow,
            from: displayCandidates
        ) != nil else {
            return .unavailable
        }
        return .resolved(requestedWindow)
    }
}

@MainActor
public struct AccessibilityDisplayWindowActivator: DisplayWindowActivating,
    ReservedDisplayWindowActivating {
    private let permissionService: PermissionService
    private let candidateResolver: WindowCandidateResolving
    private let candidateSelector: WindowCandidateSelector
    private let windowResolver: WindowActivationResolving

    public init(
        permissionService: PermissionService? = nil,
        candidateResolver: WindowCandidateResolving? = nil,
        candidateSelector: WindowCandidateSelector? = nil,
        windowResolver: WindowActivationResolving? = nil
    ) {
        let permissionService = permissionService ?? PermissionService()
        let candidateResolver = candidateResolver
            ?? CGWindowCandidateResolver(permissionService: permissionService)
        let candidateSelector = candidateSelector ?? WindowCandidateSelector()
        self.permissionService = permissionService
        self.candidateResolver = candidateResolver
        self.candidateSelector = candidateSelector
        self.windowResolver = windowResolver ?? AccessibilityWindowActivationResolver(
            permissionService: permissionService
        )
    }

    public func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor
    ) async -> DisplayWindowActivationResult {
        await activateDisplayWindow(
            display: display,
            window: window,
            reservation: nil
        )
    }

    func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor,
        reservation: AXActionAdmissionReservation
    ) async -> DisplayWindowActivationResult {
        await activateDisplayWindow(
            display: display,
            window: window,
            reservation: Optional(reservation)
        )
    }

    private func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor,
        reservation: AXActionAdmissionReservation?
    ) async -> DisplayWindowActivationResult {
        guard permissionService.isAccessibilityGranted()
        else {
            return .unavailable
        }
        let candidates = candidateResolver.windowCandidates().filter {
            display.frame.contains(PointSnapshot(x: $0.frame.x + $0.frame.width / 2,
                                                 y: $0.frame.y + $0.frame.height / 2))
        }
        guard let candidate = candidateSelector.select(
            requestedWindow: window,
            from: candidates
        ), let processIdentifier = candidate.processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier)
        else {
            return .unavailable
        }
        guard application.activate(options: []) else {
            return .unavailable
        }
        let outcome: WindowActivationOutcome
        if let reservation,
           let reservedResolver = windowResolver as? ReservedWindowActivationResolving {
            outcome = await reservedResolver.resolveAndRaise(
                window: window,
                processIdentifier: processIdentifier,
                reservation: reservation
            )
        } else {
            outcome = await windowResolver.resolveAndRaise(
                window: window,
                processIdentifier: processIdentifier
            )
        }
        switch outcome {
        case .activated:
            return .activated
        case .unavailable:
            return .unavailable
        case .timedOut:
            return .timedOut
        case .busy:
            return .busy
        case .failed:
            return .failed
        }
    }
}

@MainActor
struct RunningApplicationActivation {
    let processIdentifier: pid_t
    let activate: @MainActor () -> Bool
}

@MainActor
public struct NSWorkspaceRunningAppActivator: RunningAppActivating,
    ReservedRunningAppActivating {
    private let windowResolver: WindowActivationResolving
    private let applicationLookup: @MainActor (String, pid_t?) -> RunningApplicationActivation?

    public init(
        permissionService: PermissionService? = nil,
        windowResolver: WindowActivationResolving? = nil
    ) {
        let permissionService = permissionService ?? PermissionService()
        self.windowResolver = windowResolver ?? AccessibilityWindowActivationResolver(
            permissionService: permissionService
        )
        self.applicationLookup = { appID, preferredPID in
            let application: NSRunningApplication?
            if let preferredPID {
                let preferred = NSRunningApplication(processIdentifier: preferredPID)
                application = preferred?.bundleIdentifier == appID ? preferred : nil
            } else {
                application = NSWorkspace.shared.runningApplications.first {
                    $0.bundleIdentifier == appID
                }
            }
            guard let application else { return nil }
            return RunningApplicationActivation(
                processIdentifier: application.processIdentifier,
                activate: { application.activate(options: []) }
            )
        }
    }

    init(
        windowResolver: WindowActivationResolving,
        applicationLookup: @escaping @MainActor (String, pid_t?) -> RunningApplicationActivation?
    ) {
        self.windowResolver = windowResolver
        self.applicationLookup = applicationLookup
    }

    public func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?
    ) async -> AppActivationOutcome {
        await activateApp(
            appID: appID,
            mostRecentWindow: mostRecentWindow,
            reservation: nil
        )
    }

    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?,
        reservation: AXActionAdmissionReservation
    ) async -> AppActivationOutcome {
        await activateApp(
            appID: appID,
            mostRecentWindow: mostRecentWindow,
            reservation: Optional(reservation)
        )
    }

    private func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?,
        reservation: AXActionAdmissionReservation?
    ) async -> AppActivationOutcome {
        let preferredPID = mostRecentWindow?.runtimeIdentity?.ownerProcessIdentifier
        guard let application = applicationLookup(appID, preferredPID) else {
            return .failed
        }
        guard application.activate() else {
            return .failed
        }
        guard let mostRecentWindow else {
            return .activated(windowActivated: false)
        }
        let outcome: WindowActivationOutcome
        if let reservation,
           let reservedResolver = windowResolver as? ReservedWindowActivationResolving {
            outcome = await reservedResolver.resolveAndRaise(
                window: mostRecentWindow,
                processIdentifier: application.processIdentifier,
                reservation: reservation
            )
        } else {
            outcome = await windowResolver.resolveAndRaise(
                window: mostRecentWindow,
                processIdentifier: application.processIdentifier
            )
        }
        switch outcome {
        case .activated:
            return .activated(windowActivated: true)
        case .unavailable:
            return .windowUnavailable
        case .timedOut:
            return .windowActivationTimedOut
        case .busy:
            return .windowActivationBusy
        case .failed:
            return .windowActivationFailed
        }
    }
}

@MainActor
public struct AccessibilityWindowActivationResolver: WindowActivationResolving,
    ReservedWindowActivationResolving {
    private let permissionService: PermissionService
    private let actionPerformer: AXWindowActionPerforming
    private let actionExecutor: AXActionExecuting
    private let actionBudget: TimeInterval

    public init(
        permissionService: PermissionService? = nil,
        actionBudget: TimeInterval = 0.25
    ) {
        let permissionService = permissionService ?? PermissionService()
        self.permissionService = permissionService
        self.actionPerformer = AXAccessibilityWindowActionPerformer()
        self.actionExecutor = BoundedAXActionExecutor()
        self.actionBudget = actionBudget.isFinite && actionBudget > 0 ? actionBudget : 0.25
    }

    init(
        permissionService: PermissionService? = nil,
        actionPerformer: AXWindowActionPerforming,
        actionExecutor: AXActionExecuting,
        actionBudget: TimeInterval = 0.25
    ) {
        self.permissionService = permissionService ?? PermissionService()
        self.actionPerformer = actionPerformer
        self.actionExecutor = actionExecutor
        self.actionBudget = actionBudget.isFinite && actionBudget > 0 ? actionBudget : 0.25
    }

    public func resolveAndRaise(
        window descriptor: WindowDescriptor,
        processIdentifier: pid_t
    ) async -> WindowActivationOutcome {
        await resolveAndRaise(
            window: descriptor,
            processIdentifier: processIdentifier,
            reservation: nil
        )
    }

    func resolveAndRaise(
        window descriptor: WindowDescriptor,
        processIdentifier: pid_t,
        reservation: AXActionAdmissionReservation
    ) async -> WindowActivationOutcome {
        await resolveAndRaise(
            window: descriptor,
            processIdentifier: processIdentifier,
            reservation: Optional(reservation)
        )
    }

    private func resolveAndRaise(
        window descriptor: WindowDescriptor,
        processIdentifier: pid_t,
        reservation: AXActionAdmissionReservation?
    ) async -> WindowActivationOutcome {
        guard permissionService.isAccessibilityGranted() else {
            return .unavailable
        }
        let performer = actionPerformer
        let budget = actionBudget
        let operation: @Sendable (
            any AXActionCancellationChecking
        ) -> WindowActivationOutcome = { cancellation in
            guard !cancellation.isCancelled else { return .unavailable }
            return performer.resolveAndRaise(
                window: descriptor,
                processIdentifier: processIdentifier,
                budget: budget,
                cancellation: cancellation
            )
        }
        if let reservation,
           let reservedExecutor = actionExecutor as? ReservedAXActionExecuting {
            return await reservedExecutor.execute(
                reservation: reservation,
                operation
            )
        }
        return await actionExecutor.execute(operation)
    }
}
