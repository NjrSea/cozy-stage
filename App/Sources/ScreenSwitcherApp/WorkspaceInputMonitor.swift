import AppKit
import PagedNavigationCore

public struct WorkspaceInputModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let none: Self = []
    public static let shift = Self(rawValue: 1 << 0)
    public static let capsLock = Self(rawValue: 1 << 1)
    public static let command = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
    public static let option = Self(rawValue: 1 << 4)
    public static let function = Self(rawValue: 1 << 5)

    public init(appKitFlags: NSEvent.ModifierFlags) {
        let flags = appKitFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Self = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.function) { modifiers.insert(.function) }
        self = modifiers
    }

    fileprivate var containsDisallowedCommandModifier: Bool {
        !intersection([.command, .control, .option, .function]).isEmpty
    }
}

public enum WorkspaceScrollPhase: Equatable, Sendable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

public enum WorkspaceMomentumPhase: Equatable, Sendable {
    case none
    case began
    case changed
    case ended
}

public struct WorkspaceScrollEvent: Equatable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    public let timestamp: TimeInterval
    public let phase: WorkspaceScrollPhase
    public let momentumPhase: WorkspaceMomentumPhase

    public init(
        deltaX: Double,
        deltaY: Double,
        timestamp: TimeInterval,
        phase: WorkspaceScrollPhase,
        momentumPhase: WorkspaceMomentumPhase
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.timestamp = timestamp
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}

public struct WorkspaceScrollInputReducer: Sendable {
    private var activeSessionID: WorkspaceGestureSessionID?
    private var nextSessionRawValue: UInt64 = 1
    private var requiresPhysicalBegin = false
    private var cumulativeX = 0.0
    private var cumulativeY = 0.0
    private var lastTimestamp: TimeInterval?

    public init() {}

    public mutating func reduce(_ event: WorkspaceScrollEvent) -> WorkspaceGestureInput? {
        guard event.deltaX.isFinite,
              event.deltaY.isFinite,
              event.timestamp.isFinite
        else { return nil }

        // A finger phase is authoritative when AppKit reports finger and
        // momentum phases together. Only a pure momentum event (`.none`
        // finger phase) is ignored, so it cannot open or terminate a second
        // semantic paging gesture.
        switch event.phase {
        case .began:
            let sessionID = beginFingerGesture()
            return changedInput(for: event, sessionID: sessionID, startsSession: true)
        case .changed:
            if let activeSessionID {
                return changedInput(for: event, sessionID: activeSessionID, startsSession: false)
            }
            guard !requiresPhysicalBegin else { return nil }
            let sessionID = beginFingerGesture()
            return changedInput(for: event, sessionID: sessionID, startsSession: true)
        case .ended:
            guard let sessionID = activeSessionID else { return nil }
            clearSession()
            return .ended(sessionID: sessionID)
        case .cancelled:
            guard let sessionID = activeSessionID else { return nil }
            clearSession()
            return .cancelled(sessionID: sessionID)
        case .none:
            return nil
        }
    }

    public mutating func reset() {
        clearSession()
        requiresPhysicalBegin = true
    }

    private mutating func clearSession() {
        activeSessionID = nil
        cumulativeX = 0
        cumulativeY = 0
        lastTimestamp = nil
    }

    private mutating func beginFingerGesture() -> WorkspaceGestureSessionID {
        clearSession()
        requiresPhysicalBegin = false
        let sessionID = WorkspaceGestureSessionID(rawValue: nextSessionRawValue)
        nextSessionRawValue = nextSessionRawValue == .max ? 1 : nextSessionRawValue + 1
        activeSessionID = sessionID
        return sessionID
    }

    private mutating func changedInput(
        for event: WorkspaceScrollEvent,
        sessionID: WorkspaceGestureSessionID,
        startsSession: Bool
    ) -> WorkspaceGestureInput {
        cumulativeX += event.deltaX
        cumulativeY += event.deltaY
        let elapsed = lastTimestamp.flatMap { previous -> Double? in
            let interval = event.timestamp - previous
            return interval > 0 && interval.isFinite ? max(interval, 1.0 / 240.0) : nil
        }
        lastTimestamp = event.timestamp
        let velocityX = elapsed.map { event.deltaX / $0 } ?? 0
        let velocityY = elapsed.map { event.deltaY / $0 } ?? 0
        if startsSession {
            return .began(
                sessionID: sessionID,
                dx: cumulativeX,
                dy: cumulativeY,
                velocityX: velocityX,
                velocityY: velocityY
            )
        }
        return .changed(
            sessionID: sessionID,
            dx: cumulativeX,
            dy: cumulativeY,
            velocityX: velocityX,
            velocityY: velocityY
        )
    }
}

public enum WorkspaceInputEvent: Equatable, Sendable {
    case key(character: String, keyCode: UInt16, modifiers: WorkspaceInputModifiers)
    case scroll(WorkspaceScrollEvent)
}

public struct WorkspaceInputTranslator: Sendable {
    private var scrollReducer = WorkspaceScrollInputReducer()

    public init() {}

    public mutating func translate(_ event: WorkspaceInputEvent) -> [WorkspaceInteractionInput] {
        switch event {
        case let .scroll(event):
            return scrollReducer.reduce(event).map { [.gesture($0)] } ?? []
        case let .key(character, keyCode, modifiers):
            guard !modifiers.containsDisallowedCommandModifier else { return [] }
            if keyCode == 53 { return [.key(.escape)] }
            if keyCode == 36 || keyCode == 76 { return [.key(.returnKey)] }

            switch character.lowercased() {
            case "[": return [.key(.previousAppPage)]
            case "]": return [.key(.nextAppPage)]
            case "1": return [.key(.displayIndex(1))]
            case "2": return [.key(.displayIndex(2))]
            case "3": return [.key(.displayIndex(3))]
            default:
                guard let scalar = character.lowercased().unicodeScalars.first,
                      character.lowercased().unicodeScalars.count == 1,
                      (UnicodeScalar("a").value...UnicodeScalar("z").value).contains(scalar.value)
                else { return [] }
                return [.key(.appLetter(Int(scalar.value - UnicodeScalar("a").value)))]
            }
        }
    }

    public mutating func resetScrollSession() {
        scrollReducer.reset()
    }
}

@MainActor
public protocol WorkspaceInputEventSourcing: AnyObject {
    func start(handler: @escaping (WorkspaceInputEvent) -> Bool)
    func stop()
}

@MainActor
private final class WorkspaceInputMonitorSession {
    private let source: any WorkspaceInputEventSourcing
    private var translator: WorkspaceInputTranslator
    private var isActive = false
    private var activeHandler: ((WorkspaceInteractionInput) -> Bool)?

    init(
        source: any WorkspaceInputEventSourcing,
        translator: WorkspaceInputTranslator
    ) {
        self.source = source
        self.translator = translator
    }

    func activate(handler: @escaping (WorkspaceInteractionInput) -> Bool) {
        guard !isActive else { return }
        isActive = true
        activeHandler = handler
        source.start { [weak self] event in
            guard let self, self.isActive else {
                return false
            }
            let inputs = self.translator.translate(event)
            guard !inputs.isEmpty else { return false }
            var handled = false
            for input in inputs {
                if handler(input) { handled = true }
            }
            return handled
        }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        _ = activeHandler?(.interruptInputSession)
        activeHandler = nil
        translator.resetScrollSession()
        source.stop()
    }

    func release() {
        deactivate()
        source.stop()
    }
}

@MainActor
public final class WorkspaceInputMonitor {
    private let session: WorkspaceInputMonitorSession

    public init(
        source: any WorkspaceInputEventSourcing,
        translator: WorkspaceInputTranslator = WorkspaceInputTranslator()
    ) {
        session = WorkspaceInputMonitorSession(source: source, translator: translator)
    }

    public convenience init(translator: WorkspaceInputTranslator = WorkspaceInputTranslator()) {
        self.init(source: AppKitWorkspaceInputEventSource(), translator: translator)
    }

    public func activate(handler: @escaping (WorkspaceInteractionInput) -> Bool) {
        session.activate(handler: handler)
    }

    public func deactivate() {
        session.deactivate()
    }

    deinit {
        let session = self.session
        Task { @MainActor in
            session.release()
        }
    }
}

@MainActor
protocol WorkspaceLocalMonitorRegistering: AnyObject {
    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
private final class SystemWorkspaceLocalMonitorRegistrar: WorkspaceLocalMonitorRegistering {
    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

@MainActor
private final class WorkspaceLocalMonitorState {
    private let registrar: any WorkspaceLocalMonitorRegistering
    private var monitor: Any?

    init(registrar: any WorkspaceLocalMonitorRegistering) {
        self.registrar = registrar
    }

    func start(handler: @escaping (NSEvent) -> NSEvent?) {
        guard monitor == nil else { return }
        monitor = registrar.addLocalMonitor(
            matching: [.keyDown, .scrollWheel],
            handler: handler
        )
    }

    func stop() {
        guard let monitor else { return }
        self.monitor = nil
        registrar.removeMonitor(monitor)
    }
}

@MainActor
public final class AppKitWorkspaceInputEventSource: WorkspaceInputEventSourcing {
    private let monitorState: WorkspaceLocalMonitorState

    public convenience init() {
        self.init(registrar: SystemWorkspaceLocalMonitorRegistrar())
    }

    init(registrar: any WorkspaceLocalMonitorRegistering) {
        monitorState = WorkspaceLocalMonitorState(registrar: registrar)
    }

    public func start(handler: @escaping (WorkspaceInputEvent) -> Bool) {
        monitorState.start { [weak self] event in
            guard let self else { return event }
            let translated: WorkspaceInputEvent?
            switch event.type {
            case .keyDown:
                translated = .key(
                    character: event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode,
                    modifiers: WorkspaceInputModifiers(appKitFlags: event.modifierFlags)
                )
            case .scrollWheel:
                translated = self.translateScroll(event)
            default:
                translated = nil
            }
            guard let translated, handler(translated) else { return event }
            return nil
        }
    }

    public func stop() {
        monitorState.stop()
    }

    deinit {
        let monitorState = self.monitorState
        Task { @MainActor in
            monitorState.stop()
        }
    }

    private func translateScroll(_ event: NSEvent) -> WorkspaceInputEvent? {
        guard event.hasPreciseScrollingDeltas else { return nil }
        return .scroll(WorkspaceScrollEvent(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            timestamp: event.timestamp,
            phase: Self.semanticPhase(event.phase),
            momentumPhase: Self.semanticMomentumPhase(event.momentumPhase)
        ))
    }

    private static func semanticPhase(_ phase: NSEvent.Phase) -> WorkspaceScrollPhase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }

    private static func semanticMomentumPhase(_ phase: NSEvent.Phase) -> WorkspaceMomentumPhase {
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }
}
