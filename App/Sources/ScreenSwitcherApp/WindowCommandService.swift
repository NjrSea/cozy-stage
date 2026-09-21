import ApplicationServices
import AppKit
import Darwin
import Foundation
import ScreenDomainCore

enum WindowCommandResult: Equatable, Hashable {
    case applied
    case unsupported
    case timedOut
    case vanished
    case failed
}

enum WindowFocusCommandOutcome: Equatable, Hashable {
    case activate(WindowCommandResult)
    case nativeExact(NativeExactWindowFocusFailure)
    case resolution(WindowCommandResult)
    case raise(WindowCommandResult)
    case focusWrite(WindowCommandResult)
    case readback(WindowCommandResult)
    case applied
    case cancelled

    var commandResult: WindowCommandResult {
        switch self {
        case let .activate(result), let .resolution(result), let .raise(result),
             let .focusWrite(result), let .readback(result):
            return result
        case let .nativeExact(failure):
            return failure == .symbolUnavailable ? .unsupported : .failed
        case .applied:
            return .applied
        case .cancelled:
            return .vanished
        }
    }
}

struct WindowCommandSnapshot: Equatable {
    let frame: CanvasRect
    let isMinimized: Bool
    let isFocused: Bool

    init(frame: CanvasRect, isMinimized: Bool, isFocused: Bool = false) {
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFocused = isFocused
    }
}

@MainActor
protocol WindowCommandService: AnyObject {
    func setFrame(
        _ frame: CanvasRect,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult
    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult
    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowCommandResult
    func raiseAndFocusOutcome(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowFocusCommandOutcome
    func setMinimized(
        _ minimized: Bool,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult
    func close(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult
    func snapshot(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandSnapshot?
}

extension WindowCommandService {
    func raiseAndFocusOutcome(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowFocusCommandOutcome {
        guard whileCurrent() else { return .cancelled }
        let result = await raiseAndFocus(binding, timeout: timeout)
        guard whileCurrent() else { return .cancelled }
        return result == .applied ? .applied : .raise(result)
    }

    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowCommandResult {
        guard whileCurrent() else { return .vanished }
        let result = await raiseAndFocus(binding, timeout: timeout)
        return whileCurrent() ? result : .vanished
    }
}

/// Executes AX calls away from the MainActor. Multiple queues prevent one app's
/// bounded AX timeout from serializing commands for unrelated applications.
final class NativeAXCommandExecutor: @unchecked Sendable {
    private let queue: OperationQueue

    init(maximumConcurrentOperationCount: Int = 8) {
        queue = OperationQueue()
        queue.name = "com.indie-mono.screen-switcher.window-command"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maximumConcurrentOperationCount)
    }

    func execute<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: operation())
            }
        }
    }
}

enum WindowResolutionAttempt<Value: Equatable>: Equatable {
    case resolved(Value)
    case unavailable
    case failed(WindowCommandResult)

    var resolvedValue: Value? {
        guard case let .resolved(value) = self else { return nil }
        return value
    }
}

enum WindowResolutionPollResult<Value: Equatable>: Equatable {
    case resolved(Value, remaining: TimeInterval)
    case unavailable
    case cancelled
    case failed(WindowCommandResult)
}

@MainActor
struct WindowResolutionPoller {
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async -> Void
    private let interval: TimeInterval

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async -> Void = { duration in
            try? await Task.sleep(for: .seconds(duration))
        },
        interval: TimeInterval = 0.01
    ) {
        self.now = now
        self.sleep = sleep
        self.interval = interval
    }

    func resolve<Value: Equatable>(
        timeout: TimeInterval,
        whileCurrent: () -> Bool,
        attempt: (TimeInterval) async -> WindowResolutionAttempt<Value>
    ) async -> WindowResolutionPollResult<Value> {
        let deadline = now() + max(0.001, timeout.isFinite ? timeout : 0.001)
        while whileCurrent() {
            let remaining = deadline - now()
            guard remaining > 0 else { return .unavailable }
            switch await attempt(remaining) {
            case let .resolved(value):
                guard whileCurrent() else { return .cancelled }
                let remaining = deadline - now()
                guard remaining > 0 else { return .unavailable }
                return .resolved(value, remaining: remaining)
            case .unavailable:
                break
            case let .failed(result):
                return .failed(result)
            }
            guard whileCurrent() else { return .cancelled }
            let delay = min(interval, deadline - now())
            guard delay > 0 else { return .unavailable }
            await sleep(delay)
        }
        return .cancelled
    }
}

@MainActor
final class SystemWindowCommandService: WindowCommandService {
    private struct ExactWindowFocusAction: @unchecked Sendable {
        let run: (CGWindowID, pid_t, pid_t?) -> NativeExactWindowFocusPreparation
    }

    private struct FocusResolvedElementAction: @unchecked Sendable {
        let run: (NativeAXElementBox, TimeInterval) -> WindowFocusCommandOutcome
    }

    private let executor: NativeAXCommandExecutor
    private let exactWindowFocus: ExactWindowFocusAction
    private let focusResolvedElement: FocusResolvedElementAction
    private let activateApplication: @MainActor (pid_t) -> WindowCommandResult
    private let resolutionPoller: WindowResolutionPoller

    init(
        executor: NativeAXCommandExecutor = NativeAXCommandExecutor(),
        exactWindowFocus: @escaping (CGWindowID, pid_t, pid_t?) -> NativeExactWindowFocusPreparation = {
            NativeSpaceWindowFocus.prepare(
                cgWindowID: $0,
                processIdentifier: $1,
                originProcessIdentifier: $2
            )
        },
        focusResolvedElement: @escaping (
            NativeAXElementBox,
            TimeInterval
        ) -> WindowFocusCommandOutcome = { box, timeout in
            SystemWindowCommandService.focusResolvedElement(box, timeout: timeout)
        },
        activateApplication: @escaping @MainActor (pid_t) -> WindowCommandResult = { processIdentifier in
            guard let application = NSRunningApplication(processIdentifier: processIdentifier),
                  !application.isTerminated
            else { return .vanished }
            return application.activate(options: []) ? .applied : .failed
        },
        resolutionPoller: WindowResolutionPoller? = nil
    ) {
        self.executor = executor
        self.exactWindowFocus = ExactWindowFocusAction(run: exactWindowFocus)
        self.focusResolvedElement = FocusResolvedElementAction(run: focusResolvedElement)
        self.activateApplication = activateApplication
        self.resolutionPoller = resolutionPoller ?? WindowResolutionPoller()
    }

    func setFrame(
        _ frame: CanvasRect,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        guard !Task.isCancelled else { return .failed }
        return await executor.execute {
            guard let box = NativeWindowServerAXResolver.shared.resolve(
                binding,
                timeout: timeout
            ).resolvedValue else { return .failed }
            let command = NativeAXBoundedCommand(element: box.rawValue, timeout: timeout)
            var point = CGPoint(x: frame.x, y: frame.y)
            var size = CGSize(width: frame.width, height: frame.height)
            guard let positionValue = AXValueCreate(.cgPoint, &point),
                  let sizeValue = AXValueCreate(.cgSize, &size)
            else { return .failed }

            let positionResult = command.setAttribute(kAXPositionAttribute, value: positionValue)
            guard positionResult == .applied else { return positionResult }
            let sizeResult = command.setAttribute(kAXSizeAttribute, value: sizeValue)
            guard sizeResult == .applied else { return sizeResult }
            guard let snapshot = command.snapshot() else { return command.lastFailure ?? .failed }
            return snapshot.frame.isApproximatelyEqual(to: frame) ? .applied : .failed
        }
    }

    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        await raiseAndFocusOutcome(
            binding,
            timeout: timeout,
            whileCurrent: { true }
        ).commandResult
    }

    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowCommandResult {
        await raiseAndFocusOutcome(
            binding,
            timeout: timeout,
            whileCurrent: whileCurrent
        ).commandResult
    }

    func raiseAndFocusOutcome(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowFocusCommandOutcome {
        guard !Task.isCancelled, whileCurrent() else { return .cancelled }
        if case let .windowServer(cgWindowID) = binding.axElement {
            let exactWindowFocus = exactWindowFocus
            let focusResolvedElement = focusResolvedElement
            let processIdentifier = binding.processIdentifier
            let originProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let timeout = max(0.001, timeout.isFinite ? timeout : 0.001)
            let execution = await executor.execute {
                () -> (outcome: WindowFocusCommandOutcome, session: NativeExactWindowFocusSession?) in
                let session: NativeExactWindowFocusSession
                switch exactWindowFocus.run(
                    cgWindowID,
                    processIdentifier,
                    originProcessIdentifier
                ) {
                case let .ready(readySession):
                    session = readySession
                case let .failed(failure):
                    return (.nativeExact(failure), nil)
                }

                if let box = binding.retainedAXElement {
                    let outcome = focusResolvedElement.run(box, timeout)
                    if outcome.commandResult == .vanished {
                        binding.invalidateRetainedAXElement(box)
                    }
                    return (outcome, session)
                }

                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                while true {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else {
                        return (.resolution(.vanished), session)
                    }
                    switch NativeWindowServerAXResolver.shared.resolve(
                        binding,
                        timeout: remaining
                    ) {
                    case let .resolved(box):
                        return (focusResolvedElement.run(box, remaining), session)
                    case .unavailable:
                        Thread.sleep(forTimeInterval: min(0.01, remaining))
                    case let .failed(result):
                        return (.resolution(result), session)
                    }
                }
            }
            let isCurrent = !Task.isCancelled && whileCurrent()
            if execution.outcome != .applied || !isCurrent {
                await executor.execute { execution.session?.restoreOrigin() }
            }
            guard isCurrent else { return .cancelled }
            return execution.outcome
        } else {
            let activationResult = activateApplication(binding.processIdentifier)
            guard activationResult == .applied else { return .activate(activationResult) }
        }
        let resolution = await resolutionPoller.resolve(
            timeout: timeout,
            whileCurrent: { !Task.isCancelled && whileCurrent() }
        ) { remaining in
            await self.executor.execute {
                NativeWindowServerAXResolver.shared.resolve(
                    binding,
                    timeout: remaining
                )
            }
        }
        guard !Task.isCancelled, whileCurrent() else { return .cancelled }
        let box: NativeAXElementBox
        let remaining: TimeInterval
        switch resolution {
        case let .resolved(resolved, budget):
            box = resolved
            remaining = budget
        case .unavailable:
            return .resolution(.vanished)
        case .cancelled:
            return .cancelled
        case let .failed(result):
            return .resolution(result)
        }
        let outcome = await executor.execute {
            Self.focusResolvedElement(box, timeout: remaining)
        }
        guard !Task.isCancelled, whileCurrent() else { return .cancelled }
        return outcome
    }

    private nonisolated static func focusResolvedElement(
        _ box: NativeAXElementBox,
        timeout: TimeInterval
    ) -> WindowFocusCommandOutcome {
        let command = NativeAXBoundedCommand(element: box.rawValue, timeout: timeout)
        let raiseResult = command.performAction(kAXRaiseAction)
        guard raiseResult == .applied else {
            return .raise(raiseResult)
        }
        if command.snapshot()?.isFocused == true {
            return .applied
        }
        let focusResult = command.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
        guard focusResult == .applied else {
            return .focusWrite(focusResult)
        }
        guard let snapshot = command.snapshot() else {
            return .readback(command.lastFailure ?? .failed)
        }
        return snapshot.isFocused ? .applied : .readback(.failed)
    }

    func setMinimized(
        _ minimized: Bool,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        guard !Task.isCancelled else { return .failed }
        return await executor.execute {
            guard let box = NativeWindowServerAXResolver.shared.resolve(
                binding,
                timeout: timeout
            ).resolvedValue else { return .failed }
            let command = NativeAXBoundedCommand(element: box.rawValue, timeout: timeout)
            let result = command.setAttribute(
                kAXMinimizedAttribute,
                value: minimized ? kCFBooleanTrue : kCFBooleanFalse
            )
            guard result == .applied else { return result }
            guard let snapshot = command.snapshot() else { return command.lastFailure ?? .failed }
            return snapshot.isMinimized == minimized ? .applied : .failed
        }
    }

    func close(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        guard !Task.isCancelled else { return .failed }
        return await executor.execute {
            guard let box = NativeWindowServerAXResolver.shared.resolve(
                binding,
                timeout: timeout
            ).resolvedValue else { return .failed }
            return NativeAXBoundedCommand(
                element: box.rawValue,
                timeout: timeout
            ).closeWindow()
        }
    }

    func snapshot(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandSnapshot? {
        guard !Task.isCancelled else { return nil }
        return await executor.execute {
            guard let box = NativeWindowServerAXResolver.shared.resolve(
                binding,
                timeout: timeout
            ).resolvedValue else { return nil }
            return NativeAXBoundedCommand(element: box.rawValue, timeout: timeout).snapshot()
        }
    }
}

/// Resolves a WindowServer id to its AX element after its owning application
/// has become visible. macOS does not expose AX elements for windows on hidden
/// Spaces, while WindowServer still exposes their stable ids.
private final class NativeWindowServerAXResolver: @unchecked Sendable {
    typealias GetWindowID = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    static let shared = NativeWindowServerAXResolver()

    private let processHandle: UnsafeMutableRawPointer?
    private let getWindowID: GetWindowID?

    private init() {
        processHandle = dlopen(nil, RTLD_LAZY)
        getWindowID = processHandle
            .flatMap { dlsym($0, "_AXUIElementGetWindow") }
            .map { unsafeBitCast($0, to: GetWindowID.self) }
    }

    func resolve(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) -> WindowResolutionAttempt<NativeAXElementBox> {
        if let retainedAXElement = binding.retainedAXElement {
            return .resolved(retainedAXElement)
        }
        switch binding.axElement {
        case let .system(box):
            return .resolved(box)
        case let .windowServer(targetID):
            guard let getWindowID else { return .failed(.unsupported) }
            let application = AXUIElementCreateApplication(binding.processIdentifier)
            let timeoutError = AXUIElementSetMessagingTimeout(
                application,
                Float(max(timeout, 0.001))
            )
            guard timeoutError == .success else {
                return .failed(AXErrorMapping.project(timeoutError))
            }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &value
            )
            guard error == .success else {
                return .failed(AXErrorMapping.project(error))
            }
            guard let windows = value as? [AXUIElement] else { return .failed(.failed) }
            for window in windows {
                var id = CGWindowID(0)
                if getWindowID(window, &id) == .success, id == targetID {
                    return .resolved(NativeAXElementBox(window))
                }
            }
            return .unavailable
        case .injected:
            return .failed(.failed)
        }
    }
}

/// Pure projection from a raw `AXError` to the closed `WindowCommandResult`.
///
/// Extracted as a testable seam so the bounded-messaging contract (notably
/// `.cannotComplete -> .timedOut`) can be unit-tested without live Accessibility
/// elements. The opaque AX element itself never enters this mapping.
enum AXErrorMapping {
    static func project(_ error: AXError) -> WindowCommandResult {
        switch error {
        case .success:
            return .applied
        case .cannotComplete:
            // A bounded messaging deadline elapsed (or the app could not service the
            // request in time). This is a timeout, not a generic failure, so callers
            // can distinguish "hung/blocked app" from "permanently broken".
            return .timedOut
        case .invalidUIElement, .noValue:
            return .vanished
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            return .unsupported
        default:
            return .failed
        }
    }
}

private final class NativeAXBoundedCommand {
    let element: AXUIElement
    let deadline: CFAbsoluteTime
    let maximumMessagingTimeout: TimeInterval
    private(set) var lastFailure: WindowCommandResult?

    init(element: AXUIElement, timeout: TimeInterval) {
        self.element = element
        maximumMessagingTimeout = max(0.001, timeout.isFinite ? timeout : 0.001)
        deadline = CFAbsoluteTimeGetCurrent() + maximumMessagingTimeout
    }

    func setAttribute(_ attribute: String, value: CFTypeRef) -> WindowCommandResult {
        guard prepareNextMessage() else { return lastFailure ?? .timedOut }
        return map(AXUIElementSetAttributeValue(element, attribute as CFString, value))
    }

    func performAction(_ action: String) -> WindowCommandResult {
        guard prepareNextMessage() else { return lastFailure ?? .timedOut }
        return map(AXUIElementPerformAction(element, action as CFString))
    }

    func closeWindow() -> WindowCommandResult {
        guard let value = copyAttribute(kAXCloseButtonAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return lastFailure ?? .unsupported }
        let button = unsafeBitCast(value, to: AXUIElement.self)
        let remaining = deadline - CFAbsoluteTimeGetCurrent()
        guard remaining > 0 else { return map(.cannotComplete) }
        let timeoutResult = map(AXUIElementSetMessagingTimeout(
            button,
            Float(max(0.001, min(maximumMessagingTimeout, remaining)))
        ))
        guard timeoutResult == .applied else { return timeoutResult }
        return map(AXUIElementPerformAction(button, kAXPressAction as CFString))
    }

    func snapshot() -> WindowCommandSnapshot? {
        guard let positionValue = copyAttribute(kAXPositionAttribute),
              let sizeValue = copyAttribute(kAXSizeAttribute),
              let minimizedValue = copyAttribute(kAXMinimizedAttribute),
              let focusedValue = copyAttribute(kAXFocusedAttribute),
              let position = point(positionValue),
              let size = size(sizeValue),
              let minimized = (minimizedValue as? NSNumber)?.boolValue,
              let focused = (focusedValue as? NSNumber)?.boolValue,
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else { return nil }
        return WindowCommandSnapshot(
            frame: CanvasRect(
                x: position.x,
                y: position.y,
                width: size.width,
                height: size.height
            ),
            isMinimized: minimized,
            isFocused: focused
        )
    }

    private func copyAttribute(_ attribute: String) -> CFTypeRef? {
        guard prepareNextMessage() else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        let mapped = map(result)
        guard mapped == .applied else { return nil }
        return value
    }

    private func prepareNextMessage() -> Bool {
        let remaining = deadline - CFAbsoluteTimeGetCurrent()
        guard remaining > 0 else {
            lastFailure = .timedOut
            return false
        }
        let result = AXUIElementSetMessagingTimeout(
            element,
            Float(max(0.001, min(maximumMessagingTimeout, remaining)))
        )
        let mapped = map(result)
        return mapped == .applied
    }

    private func map(_ error: AXError) -> WindowCommandResult {
        let result = AXErrorMapping.project(error)
        if result != .applied { lastFailure = result }
        return result
    }

    private func point(_ value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var result = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &result) ? result : nil
    }

    private func size(_ value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var result = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &result) ? result : nil
    }
}

extension CanvasRect {
    func isApproximatelyEqual(to other: CanvasRect, tolerance: Double = 1) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
