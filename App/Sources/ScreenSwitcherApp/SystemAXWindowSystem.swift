import AppKit
import ApplicationServices
import Foundation
import ScreenDomainCore

/// The only unchecked concurrency boundary for an Accessibility object.
/// AX access remains serialized by `NativeAXReadExecutor`; this box only
/// preserves the opaque process-local identity while crossing that executor.
final class NativeAXElementBox: @unchecked Sendable, Hashable {
    let rawValue: AXUIElement

    init(_ rawValue: AXUIElement) {
        self.rawValue = rawValue
    }

    static func == (lhs: NativeAXElementBox, rhs: NativeAXElementBox) -> Bool {
        CFEqual(lhs.rawValue, rhs.rawValue)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(rawValue))
    }
}

fileprivate enum NativeApplicationInstanceIdentity: Sendable, Hashable {
    case object(ObjectIdentifier)
    case synthetic(UUID)
}

struct NativeRunningApplication: Sendable, Equatable {
    let appID: String?
    let appName: String
    let processIdentifier: pid_t
    let launchDate: Date?
    let activationPolicy: NSApplication.ActivationPolicy
    let isTerminated: Bool
    fileprivate let instanceIdentity: NativeApplicationInstanceIdentity

    init(
        appID: String?,
        appName: String,
        processIdentifier: pid_t,
        launchDate: Date?,
        activationPolicy: NSApplication.ActivationPolicy,
        isTerminated: Bool
    ) {
        self.init(
            appID: appID,
            appName: appName,
            processIdentifier: processIdentifier,
            launchDate: launchDate,
            activationPolicy: activationPolicy,
            isTerminated: isTerminated,
            instanceIdentity: .synthetic(UUID())
        )
    }

    fileprivate init(
        appID: String?,
        appName: String,
        processIdentifier: pid_t,
        launchDate: Date?,
        activationPolicy: NSApplication.ActivationPolicy,
        isTerminated: Bool,
        instanceIdentity: NativeApplicationInstanceIdentity
    ) {
        self.appID = appID
        self.appName = appName
        self.processIdentifier = processIdentifier
        self.launchDate = launchDate
        self.activationPolicy = activationPolicy
        self.isTerminated = isTerminated
        self.instanceIdentity = instanceIdentity
    }
}

protocol ProcessStartIdentityProvider: Sendable {
    func identity(for application: NativeRunningApplication) -> String?
    func currentIdentity(processIdentifier: pid_t) -> String?
}

extension ProcessStartIdentityProvider {
    func currentIdentity(processIdentifier: pid_t) -> String? { nil }
}

struct KernelProcessStartIdentityProvider: ProcessStartIdentityProvider {
    private let identityReader: @Sendable (NativeRunningApplication) -> String?
    private let currentIdentityReader: @Sendable (pid_t) -> String?

    init(
        _ identityReader: @escaping @Sendable (NativeRunningApplication) -> String?,
        currentIdentityReader: @escaping @Sendable (pid_t) -> String? = { _ in nil }
    ) {
        self.identityReader = identityReader
        self.currentIdentityReader = currentIdentityReader
    }

    init() {
        self.init(
            { application in
                if let launchDate = application.launchDate {
                    let bits = launchDate.timeIntervalSinceReferenceDate.bitPattern
                    return "launch-date:" + String(bits, radix: 16)
                }
                guard !application.isTerminated else { return nil }
                return Self.kernelIdentity(
                    processIdentifier: application.processIdentifier
                )
            },
            currentIdentityReader: { processIdentifier in
                Self.kernelIdentity(processIdentifier: processIdentifier)
            }
        )
    }

    func identity(for application: NativeRunningApplication) -> String? {
        identityReader(application)
    }

    func currentIdentity(processIdentifier: pid_t) -> String? {
        currentIdentityReader(processIdentifier)
    }

    private static func kernelIdentity(processIdentifier: pid_t) -> String? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let readSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(expectedSize)
            )
        }
        guard readSize == expectedSize else { return nil }
        return "kernel:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
}

@MainActor
final class NativeProcessGenerationRegistry {
    struct LaunchResult: Equatable {
        let replaced: AXObservedApplication?
        let current: AXObservedApplication?
    }

    private struct CachedApplication {
        let observed: AXObservedApplication
        let startIdentity: String?
        var instanceIdentities: [NativeApplicationInstanceIdentity]

        mutating func observe(
            _ identity: NativeApplicationInstanceIdentity,
            maximumCount: Int
        ) {
            instanceIdentities.removeAll { $0 == identity }
            instanceIdentities.append(identity)
            if instanceIdentities.count > maximumCount {
                instanceIdentities.removeFirst(instanceIdentities.count - maximumCount)
            }
        }
    }

    private static let maximumInstanceIdentityCount = 8
    private let startIdentityProvider: ProcessStartIdentityProvider
    private let generationGenerator: () -> String
    private var applicationsByPID: [pid_t: CachedApplication] = [:]

    init(
        startIdentityProvider: ProcessStartIdentityProvider,
        generationGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.startIdentityProvider = startIdentityProvider
        self.generationGenerator = generationGenerator
    }

    func reconcileRunning(
        _ applications: [NativeRunningApplication]
    ) -> [AXObservedApplication] {
        var activePIDs = Set<pid_t>()
        var result: [AXObservedApplication] = []
        for application in applications where isEligible(application) {
            activePIDs.insert(application.processIdentifier)
            result.append(resolveScan(application))
        }
        applicationsByPID = applicationsByPID.filter { activePIDs.contains($0.key) }
        return result.sorted(by: AXObservedApplication.isOrderedBefore)
    }

    func launched(_ application: NativeRunningApplication) -> LaunchResult {
        guard isEligible(application) else { return LaunchResult(replaced: nil, current: nil) }
        let pid = application.processIdentifier
        let previous = applicationsByPID[pid]
        let startIdentity = startIdentityProvider.identity(for: application)
        if let previous,
           let startIdentity,
           previous.startIdentity == startIdentity,
           previous.observed.appID == application.appID {
            var updated = previous
            updated.observe(
                application.instanceIdentity,
                maximumCount: Self.maximumInstanceIdentityCount
            )
            applicationsByPID[pid] = updated
            return LaunchResult(replaced: nil, current: previous.observed)
        }
        let current = makeObserved(application, startIdentity: startIdentity)
        applicationsByPID[pid] = CachedApplication(
            observed: current,
            startIdentity: startIdentity,
            instanceIdentities: [application.instanceIdentity]
        )
        return LaunchResult(replaced: previous?.observed, current: current)
    }

    func terminated(_ application: NativeRunningApplication) -> AXObservedApplication? {
        let pid = application.processIdentifier
        guard let cached = applicationsByPID[pid],
              cached.observed.appID == application.appID
        else { return nil }
        if let startIdentity = startIdentityProvider.identity(for: application) {
            guard cached.startIdentity == startIdentity else { return nil }
        } else {
            guard cached.instanceIdentities.contains(application.instanceIdentity)
            else { return nil }
            if let cachedIdentity = cached.startIdentity,
               let currentIdentity = startIdentityProvider.currentIdentity(
                   processIdentifier: pid
               ) {
                guard currentIdentity == cachedIdentity else { return nil }
            }
        }
        applicationsByPID.removeValue(forKey: pid)
        return cached.observed
    }

    private func resolveScan(_ application: NativeRunningApplication) -> AXObservedApplication {
        let pid = application.processIdentifier
        let startIdentity = startIdentityProvider.identity(for: application)
        if let cached = applicationsByPID[pid],
           cached.observed.appID == application.appID,
           cached.startIdentity == startIdentity {
            var updated = cached
            updated.observe(
                application.instanceIdentity,
                maximumCount: Self.maximumInstanceIdentityCount
            )
            applicationsByPID[pid] = updated
            return cached.observed
        }
        let observed = makeObserved(application, startIdentity: startIdentity)
        applicationsByPID[pid] = CachedApplication(
            observed: observed,
            startIdentity: startIdentity,
            instanceIdentities: [application.instanceIdentity]
        )
        return observed
    }

    private func makeObserved(
        _ application: NativeRunningApplication,
        startIdentity: String?
    ) -> AXObservedApplication {
        AXObservedApplication(
            appID: application.appID!,
            appName: application.appName,
            processIdentifier: application.processIdentifier,
            launchGeneration: startIdentity ?? generationGenerator()
        )
    }

    private func isEligible(_ application: NativeRunningApplication) -> Bool {
        !application.isTerminated
            && application.activationPolicy == .regular
            && application.appID != nil
    }
}

private extension AXObservedApplication {
    static func isOrderedBefore(
        _ lhs: AXObservedApplication,
        _ rhs: AXObservedApplication
    ) -> Bool {
        if lhs.appID != rhs.appID { return lhs.appID < rhs.appID }
        if lhs.processIdentifier != rhs.processIdentifier {
            return lhs.processIdentifier < rhs.processIdentifier
        }
        return lhs.launchGeneration < rhs.launchGeneration
    }
}

final class NativeAXReadExecutor: @unchecked Sendable {
    private let queue: OperationQueue

    init(label: String = "com.indie-mono.screen-switcher.window-observation.ax-read") {
        queue = OperationQueue()
        queue.name = label
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
    }

    func execute<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct NativeAXWindowStateBatch: Sendable {
    static let attributes = [
        kAXTitleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXFocusedAttribute,
        kAXMinimizedAttribute,
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXParentAttribute,
        kAXModalAttribute,
        "AXTransient"
    ]

    let title: String
    let frame: CanvasRect
    let isFocused: Bool
    let isMinimized: Bool
    let isPositionSettable: Bool
    let isSizeSettable: Bool
    let role: String
    let subrole: String?
    let parent: AXElement?
    let isModal: Bool
    let isTransient: Bool
}

protocol NativeAXReadPrimitives: Sendable {
    func applicationElement(processIdentifier: pid_t) -> AXElement
    func windows(
        processIdentifier: pid_t,
        messagingTimeout: TimeInterval,
        budget: TimeInterval
    ) throws -> [AXElement]
    func windowState(
        element: AXElement,
        messagingTimeout: TimeInterval,
        budget: TimeInterval,
        attributes: [String]
    ) throws -> NativeAXWindowStateBatch
}

struct NativeAXReadSyscalls: @unchecked Sendable {
    let createApplication: (pid_t) -> AXUIElement
    let setMessagingTimeout: (AXUIElement, Float) -> AXError
    let copyAttributeValue: (AXUIElement, String) -> (AXError, Any?)
    let copyMultipleAttributeValues: (AXUIElement, [String]) -> (AXError, [Any]?)
    let isAttributeSettable: (AXUIElement, String) -> (AXError, Bool)
    let currentTime: () -> CFAbsoluteTime

    static let system = NativeAXReadSyscalls(
        createApplication: AXUIElementCreateApplication,
        setMessagingTimeout: AXUIElementSetMessagingTimeout,
        copyAttributeValue: { element, attribute in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            )
            return (error, value)
        },
        copyMultipleAttributeValues: { element, attributes in
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(
                element,
                attributes.map { $0 as CFString } as CFArray,
                [],
                &values
            )
            return (error, values as? [Any])
        },
        isAttributeSettable: { element, attribute in
            var result = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(
                element,
                attribute as CFString,
                &result
            )
            return (error, result.boolValue)
        },
        currentTime: CFAbsoluteTimeGetCurrent
    )
}

struct SystemNativeAXReadPrimitives: NativeAXReadPrimitives {
    enum ReadError: Error, Equatable {
        case inaccessible
        case timedOut
    }

    private let syscalls: NativeAXReadSyscalls

    init(syscalls: NativeAXReadSyscalls = .system) {
        self.syscalls = syscalls
    }

    func applicationElement(processIdentifier: pid_t) -> AXElement {
        .system(NativeAXElementBox(syscalls.createApplication(processIdentifier)))
    }

    func windows(
        processIdentifier: pid_t,
        messagingTimeout: TimeInterval,
        budget: TimeInterval
    ) throws -> [AXElement] {
        let application = syscalls.createApplication(processIdentifier)
        try requireSuccess(syscalls.setMessagingTimeout(
            application,
            Float(max(0.001, min(messagingTimeout, budget)))
        ))
        let (error, value) = syscalls.copyAttributeValue(application, kAXWindowsAttribute)
        try requireSuccess(error)
        guard error == .success, let windows = value as? [AXUIElement] else {
            throw ReadError.inaccessible
        }
        return windows.map { .system(NativeAXElementBox($0)) }
    }

    func windowState(
        element: AXElement,
        messagingTimeout: TimeInterval,
        budget: TimeInterval,
        attributes: [String]
    ) throws -> NativeAXWindowStateBatch {
        guard case let .system(elementBox) = element,
              attributes == NativeAXWindowStateBatch.attributes
        else { throw ReadError.inaccessible }
        let rawElement = elementBox.rawValue
        let startedAt = syscalls.currentTime()
        let deadline = startedAt + max(0.001, budget)
        try setRemainingTimeout(
            on: rawElement,
            deadline: deadline,
            maximum: messagingTimeout
        )
        let (error, rawValues) = syscalls.copyMultipleAttributeValues(rawElement, attributes)
        try requireSuccess(error)
        guard error == .success,
              let values = rawValues,
              values.count == attributes.count,
              let position = point(values[1]),
              let size = size(values[2]),
              let frame = canvasRect(position: position, size: size),
              let focused = bool(values[3]),
              let minimized = bool(values[4]),
              let role = values[5] as? String,
              let subrole = values[6] as? String,
              let parent = elementValue(values[7]),
              let modal = bool(values[8])
        else { throw ReadError.inaccessible }

        try setRemainingTimeout(on: rawElement, deadline: deadline, maximum: messagingTimeout)
        let positionSettable = try isSettable(kAXPositionAttribute, on: rawElement)
        try setRemainingTimeout(on: rawElement, deadline: deadline, maximum: messagingTimeout)
        let sizeSettable = try isSettable(kAXSizeAttribute, on: rawElement)
        return NativeAXWindowStateBatch(
            title: values[0] as? String ?? "",
            frame: frame,
            isFocused: focused,
            isMinimized: minimized,
            isPositionSettable: positionSettable,
            isSizeSettable: sizeSettable,
            role: role,
            subrole: subrole,
            parent: .system(NativeAXElementBox(parent)),
            isModal: modal,
            isTransient: bool(values[9]) ?? false
        )
    }

    private func setRemainingTimeout(
        on element: AXUIElement,
        deadline: CFAbsoluteTime,
        maximum: TimeInterval
    ) throws {
        let remaining = deadline - syscalls.currentTime()
        guard remaining > 0 else { throw ReadError.timedOut }
        try requireSuccess(syscalls.setMessagingTimeout(
            element,
            Float(max(0.001, min(maximum, remaining)))
        ))
    }

    private func isSettable(_ attribute: String, on element: AXUIElement) throws -> Bool {
        let (error, result) = syscalls.isAttributeSettable(element, attribute)
        try requireSuccess(error)
        return result
    }

    private func requireSuccess(_ error: AXError) throws {
        if error == .cannotComplete { throw ReadError.timedOut }
        guard error == .success else { throw ReadError.inaccessible }
    }

    private func bool(_ value: Any) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private func point(_ value: Any) -> CGPoint? {
        let raw = value as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        var result = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &result) ? result : nil
    }

    private func size(_ value: Any) -> CGSize? {
        let raw = value as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        var result = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &result) ? result : nil
    }

    private func elementValue(_ value: Any) -> AXUIElement? {
        let raw = value as CFTypeRef
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func canvasRect(position: CGPoint, size: CGSize) -> CanvasRect? {
        let values = [position.x, position.y, size.width, size.height].map(Double.init)
        guard values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0,
              (values[0] + values[2]).isFinite,
              (values[1] + values[3]).isFinite
        else { return nil }
        return CanvasRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}

enum NativeAXObservationError: Error {
    case observerCreationFailed
    case notificationRegistrationFailed
}

final class NativeAXCallbackBox {
    let callback: @MainActor (AXElement, String) -> Void
    private(set) var isActive = true

    init(callback: @escaping @MainActor (AXElement, String) -> Void) {
        self.callback = callback
    }

    func deactivate() {
        isActive = false
    }
}

final class NativeAXObserverHandle {
    let storage: AnyObject
    fileprivate let systemObserver: AXObserver?

    init(storage: AnyObject) {
        self.storage = storage
        self.systemObserver = nil
    }

    fileprivate init(observer: AXObserver) {
        self.storage = observer
        self.systemObserver = observer
    }
}

@MainActor
protocol NativeAXObserverPrimitives: AnyObject {
    func createObserver(
        processIdentifier: pid_t,
        callbackBox: NativeAXCallbackBox
    ) throws -> NativeAXObserverHandle
    func addNotification(
        observer: NativeAXObserverHandle,
        element: AXElement,
        notification: String,
        callbackBox: NativeAXCallbackBox
    ) throws
    func removeNotification(
        observer: NativeAXObserverHandle,
        element: AXElement,
        notification: String
    )
    func addRunLoopSource(observer: NativeAXObserverHandle)
    func removeRunLoopSource(observer: NativeAXObserverHandle)
}

@MainActor
final class NativeAXObserverRegistration {
    let observer: NativeAXObserverHandle
    let element: AXElement
    let notifications: [String]
    let callbackBox: NativeAXCallbackBox
    fileprivate var isRemoved = false

    init(
        observer: NativeAXObserverHandle,
        element: AXElement,
        notifications: [String],
        callbackBox: NativeAXCallbackBox
    ) {
        self.observer = observer
        self.element = element
        self.notifications = notifications
        self.callbackBox = callbackBox
    }
}

@MainActor
final class NativeAXObserverOwner {
    private let primitives: NativeAXObserverPrimitives

    init(primitives: NativeAXObserverPrimitives) {
        self.primitives = primitives
    }

    func register(
        processIdentifier: pid_t,
        element: AXElement,
        notifications: [String],
        callback: @escaping @MainActor (AXElement, String) -> Void
    ) throws -> NativeAXObserverRegistration {
        let callbackBox = NativeAXCallbackBox(callback: callback)
        let observer = try primitives.createObserver(
            processIdentifier: processIdentifier,
            callbackBox: callbackBox
        )
        var added: [String] = []
        do {
            for notification in notifications {
                try primitives.addNotification(
                    observer: observer,
                    element: element,
                    notification: notification,
                    callbackBox: callbackBox
                )
                added.append(notification)
            }
        } catch {
            callbackBox.deactivate()
            for notification in added.reversed() {
                primitives.removeNotification(
                    observer: observer,
                    element: element,
                    notification: notification
                )
            }
            throw error
        }
        primitives.addRunLoopSource(observer: observer)
        return NativeAXObserverRegistration(
            observer: observer,
            element: element,
            notifications: added,
            callbackBox: callbackBox
        )
    }

    func remove(_ registration: NativeAXObserverRegistration) {
        guard !registration.isRemoved else { return }
        registration.isRemoved = true
        registration.callbackBox.deactivate()
        primitives.removeRunLoopSource(observer: registration.observer)
        for notification in registration.notifications.reversed() {
            primitives.removeNotification(
                observer: registration.observer,
                element: registration.element,
                notification: notification
            )
        }
    }
}

@MainActor
struct NativeAXObserverSyscalls {
    let createObserver: (pid_t) -> (AXError, NativeAXObserverHandle?)
    let addNotification: (
        NativeAXObserverHandle,
        AXElement,
        String,
        UnsafeMutableRawPointer
    ) -> AXError
    let removeNotification: (NativeAXObserverHandle, AXElement, String) -> Void
    let addRunLoopSource: (NativeAXObserverHandle) -> Void
    let removeRunLoopSource: (NativeAXObserverHandle) -> Void

    static let system = NativeAXObserverSyscalls(
        createObserver: { processIdentifier in
            var observer: AXObserver?
            let error = AXObserverCreate(
                processIdentifier,
                nativeAXObserverCallback,
                &observer
            )
            return (error, observer.map(NativeAXObserverHandle.init(observer:)))
        },
        addNotification: { observer, element, notification, reference in
            guard let rawObserver = observer.systemObserver,
                  case let .system(elementBox) = element
            else { return .illegalArgument }
            return AXObserverAddNotification(
                rawObserver,
                elementBox.rawValue,
                notification as CFString,
                reference
            )
        },
        removeNotification: { observer, element, notification in
            guard let rawObserver = observer.systemObserver,
                  case let .system(elementBox) = element else { return }
            AXObserverRemoveNotification(
                rawObserver,
                elementBox.rawValue,
                notification as CFString
            )
        },
        addRunLoopSource: { observer in
            guard let observer = observer.systemObserver else { return }
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        },
        removeRunLoopSource: { observer in
            guard let observer = observer.systemObserver else { return }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    )
}

@MainActor
final class SystemNativeAXObserverPrimitives: NativeAXObserverPrimitives {
    private let syscalls: NativeAXObserverSyscalls

    init() {
        self.syscalls = .system
    }

    init(syscalls: NativeAXObserverSyscalls) {
        self.syscalls = syscalls
    }

    func createObserver(
        processIdentifier: pid_t,
        callbackBox: NativeAXCallbackBox
    ) throws -> NativeAXObserverHandle {
        let (error, observer) = syscalls.createObserver(processIdentifier)
        guard error == .success, let observer else {
            throw NativeAXObservationError.observerCreationFailed
        }
        return observer
    }

    func addNotification(
        observer: NativeAXObserverHandle,
        element: AXElement,
        notification: String,
        callbackBox: NativeAXCallbackBox
    ) throws {
        let error = syscalls.addNotification(
            observer,
            element,
            notification,
            Unmanaged.passUnretained(callbackBox).toOpaque()
        )
        guard error == .success else {
            throw NativeAXObservationError.notificationRegistrationFailed
        }
    }

    func removeNotification(
        observer: NativeAXObserverHandle,
        element: AXElement,
        notification: String
    ) {
        syscalls.removeNotification(observer, element, notification)
    }

    func addRunLoopSource(observer: NativeAXObserverHandle) {
        syscalls.addRunLoopSource(observer)
    }

    func removeRunLoopSource(observer: NativeAXObserverHandle) {
        syscalls.removeRunLoopSource(observer)
    }

    nonisolated static func deliver(
        element: AXUIElement,
        notification: String,
        reference: UnsafeMutableRawPointer?
    ) {
        guard let reference else { return }
        let box = Unmanaged<NativeAXCallbackBox>
            .fromOpaque(reference)
            .takeUnretainedValue()
        Task { @MainActor in
            guard box.isActive else { return }
            box.callback(
                .system(NativeAXElementBox(element)),
                notification
            )
        }
    }
}

private func nativeAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ reference: UnsafeMutableRawPointer?
) {
    SystemNativeAXObserverPrimitives.deliver(
        element: element,
        notification: notification as String,
        reference: reference
    )
}

enum NativeWorkspaceNotificationKind: Equatable {
    case launched
    case terminated
}

enum NativeWorkspaceEvent {
    case launched(NativeRunningApplication)
    case terminated(NativeRunningApplication)
}

final class NativeWorkspaceObservationToken {
    let id: Int
    let storage: AnyObject

    init(id: Int, storage: AnyObject) {
        self.id = id
        self.storage = storage
    }
}

@MainActor
protocol NativeWorkspaceObservationPrimitives: AnyObject {
    func addObserver(
        kind: NativeWorkspaceNotificationKind,
        handler: @escaping @MainActor @Sendable (NativeRunningApplication) -> Void
    ) -> NativeWorkspaceObservationToken
    func removeObserver(_ token: NativeWorkspaceObservationToken)
}

@MainActor
final class NativeWorkspaceObservationRegistration {
    let tokens: [NativeWorkspaceObservationToken]
    fileprivate var isRemoved = false

    init(tokens: [NativeWorkspaceObservationToken]) {
        self.tokens = tokens
    }
}

@MainActor
final class NativeWorkspaceObservationOwner {
    private let primitives: NativeWorkspaceObservationPrimitives

    init(primitives: NativeWorkspaceObservationPrimitives) {
        self.primitives = primitives
    }

    func observe(
        _ handler: @escaping @MainActor @Sendable (NativeWorkspaceEvent) -> Void
    ) -> NativeWorkspaceObservationRegistration {
        let launch = primitives.addObserver(kind: .launched) {
            handler(.launched($0))
        }
        let termination = primitives.addObserver(kind: .terminated) {
            handler(.terminated($0))
        }
        return NativeWorkspaceObservationRegistration(tokens: [launch, termination])
    }

    func remove(_ registration: NativeWorkspaceObservationRegistration) {
        guard !registration.isRemoved else { return }
        registration.isRemoved = true
        registration.tokens.forEach(primitives.removeObserver)
    }
}

@MainActor
final class SystemNativeWorkspaceObservationPrimitives:
    NativeWorkspaceObservationPrimitives {
    private let workspace: NSWorkspace
    private var nextID = 0

    init(workspace: NSWorkspace) {
        self.workspace = workspace
    }

    func addObserver(
        kind: NativeWorkspaceNotificationKind,
        handler: @escaping @MainActor @Sendable (NativeRunningApplication) -> Void
    ) -> NativeWorkspaceObservationToken {
        let name: Notification.Name = kind == .launched
            ? NSWorkspace.didLaunchApplicationNotification
            : NSWorkspace.didTerminateApplicationNotification
        let token = workspace.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            let observed = NativeRunningApplication(application)
            Task { @MainActor in
                handler(observed)
            }
        }
        nextID += 1
        return NativeWorkspaceObservationToken(id: nextID, storage: token as AnyObject)
    }

    func removeObserver(_ token: NativeWorkspaceObservationToken) {
        workspace.notificationCenter.removeObserver(token.storage)
    }
}

private extension NativeRunningApplication {
    init(_ application: NSRunningApplication) {
        self.init(
            appID: application.bundleIdentifier,
            appName: application.localizedName ?? application.bundleIdentifier ?? "",
            processIdentifier: application.processIdentifier,
            launchDate: application.launchDate,
            activationPolicy: application.activationPolicy,
            isTerminated: application.isTerminated,
            instanceIdentity: .object(ObjectIdentifier(application))
        )
    }
}

@MainActor
final class SystemAXWindowSystem: AXWindowSystem {
    private enum Registration {
        case accessibility(NativeAXObserverRegistration)
        case workspace(NativeWorkspaceObservationRegistration)
    }

    let currentProcessIdentifier: pid_t
    private let workspace: NSWorkspace
    private let readPrimitives: NativeAXReadPrimitives
    private let readExecutor: NativeAXReadExecutor
    private let messagingTimeout: TimeInterval
    private let perWindowBudget: TimeInterval
    private let generationRegistry: NativeProcessGenerationRegistry
    private let observerOwner: NativeAXObserverOwner
    private let workspaceOwner: NativeWorkspaceObservationOwner
    private var nextTokenID = 0
    private var registrations: [AXObservationToken: Registration] = [:]

    init(
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        workspace: NSWorkspace = .shared,
        readPrimitives: NativeAXReadPrimitives = SystemNativeAXReadPrimitives(),
        readExecutor: NativeAXReadExecutor = NativeAXReadExecutor(),
        messagingTimeout: TimeInterval = 0.1,
        perWindowBudget: TimeInterval = 0.2,
        startIdentityProvider: ProcessStartIdentityProvider = KernelProcessStartIdentityProvider(),
        generationGenerator: @escaping () -> String = { UUID().uuidString },
        observerPrimitives: NativeAXObserverPrimitives? = nil,
        workspacePrimitives: NativeWorkspaceObservationPrimitives? = nil
    ) {
        self.currentProcessIdentifier = currentProcessIdentifier
        self.workspace = workspace
        self.readPrimitives = readPrimitives
        self.readExecutor = readExecutor
        self.messagingTimeout = max(0.001, messagingTimeout)
        self.perWindowBudget = max(self.messagingTimeout, perWindowBudget)
        self.generationRegistry = NativeProcessGenerationRegistry(
            startIdentityProvider: startIdentityProvider,
            generationGenerator: generationGenerator
        )
        self.observerOwner = NativeAXObserverOwner(
            primitives: observerPrimitives ?? SystemNativeAXObserverPrimitives()
        )
        self.workspaceOwner = NativeWorkspaceObservationOwner(
            primitives: workspacePrimitives
                ?? SystemNativeWorkspaceObservationPrimitives(workspace: workspace)
        )
    }

    func runningApplications() async throws -> [AXObservedApplication] {
        generationRegistry.reconcileRunning(
            workspace.runningApplications.map(NativeRunningApplication.init)
        )
    }

    func applicationElement(for app: AXObservedApplication) -> AXElement {
        readPrimitives.applicationElement(processIdentifier: app.processIdentifier)
    }

    func windows(for app: AXObservedApplication) async throws -> [AXElement] {
        let primitives = readPrimitives
        let timeout = messagingTimeout
        let budget = perWindowBudget
        return try await readExecutor.execute {
            try primitives.windows(
                processIdentifier: app.processIdentifier,
                messagingTimeout: timeout,
                budget: budget
            )
        }
    }

    func state(
        of window: AXElement,
        in app: AXObservedApplication
    ) async throws -> AXWindowState {
        let primitives = readPrimitives
        let timeout = messagingTimeout
        let budget = perWindowBudget
        let batch = try await readExecutor.execute {
            try primitives.windowState(
                element: window,
                messagingTimeout: timeout,
                budget: budget,
                attributes: NativeAXWindowStateBatch.attributes
            )
        }
        return AXWindowState(
            title: batch.title,
            frame: batch.frame,
            isFocused: batch.isFocused,
            isMinimized: batch.isMinimized,
            isSettable: batch.isPositionSettable && batch.isSizeSettable,
            role: batch.role,
            subrole: batch.subrole,
            parent: batch.parent,
            isModal: batch.isModal,
            isTransient: batch.isTransient
        )
    }

    func observeApplication(
        _ app: AXObservedApplication,
        handler: @escaping @MainActor (AXApplicationNotification) async -> Void
    ) throws -> AXObservationToken {
        let registration = try observerOwner.register(
            processIdentifier: app.processIdentifier,
            element: applicationElement(for: app),
            notifications: [
                kAXWindowCreatedNotification,
                kAXFocusedWindowChangedNotification
            ]
        ) { element, notification in
            Task { @MainActor in
                switch notification {
                case kAXWindowCreatedNotification:
                    await handler(.created(element))
                case kAXFocusedWindowChangedNotification:
                    await handler(.focused(element))
                default:
                    break
                }
            }
        }
        return store(.accessibility(registration))
    }

    func observeWindow(
        _ window: AXElement,
        in app: AXObservedApplication,
        handler: @escaping @MainActor (AXWindowNotification) async -> Void
    ) throws -> AXObservationToken {
        let registration = try observerOwner.register(
            processIdentifier: app.processIdentifier,
            element: window,
            notifications: [
                kAXUIElementDestroyedNotification,
                kAXMovedNotification,
                kAXResizedNotification,
                kAXWindowMiniaturizedNotification,
                kAXWindowDeminiaturizedNotification
            ]
        ) { element, notification in
            Task { @MainActor in
                switch notification {
                case kAXUIElementDestroyedNotification:
                    await handler(.destroyed(element))
                case kAXMovedNotification:
                    await handler(.moved(element))
                case kAXResizedNotification:
                    await handler(.resized(element))
                case kAXWindowMiniaturizedNotification:
                    await handler(.miniaturized(element))
                case kAXWindowDeminiaturizedNotification:
                    await handler(.deminiaturized(element))
                default:
                    break
                }
            }
        }
        return store(.accessibility(registration))
    }

    func observeWorkspace(
        _ handler: @escaping @MainActor (AXWorkspaceNotification) async -> Void
    ) throws -> AXObservationToken {
        let registration = workspaceOwner.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case let .launched(application):
                guard let current = generationRegistry.launched(application).current else { return }
                Task { @MainActor in await handler(.launched(current)) }
            case let .terminated(application):
                guard let current = generationRegistry.terminated(application) else { return }
                Task { @MainActor in await handler(.terminated(current)) }
            }
        }
        return store(.workspace(registration))
    }

    func removeObservation(_ token: AXObservationToken) {
        guard let registration = registrations.removeValue(forKey: token) else { return }
        switch registration {
        case let .accessibility(registration):
            observerOwner.remove(registration)
        case let .workspace(registration):
            workspaceOwner.remove(registration)
        }
    }

    private func store(_ registration: Registration) -> AXObservationToken {
        nextTokenID += 1
        let token = AXObservationToken(id: nextTokenID)
        registrations[token] = registration
        return token
    }
}
