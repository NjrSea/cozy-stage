import AppKit
import Foundation
import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    /// The single migration-compatible Screen Switcher shortcut key. Phase 1A
    /// collapses the former four-case matrix (general/switch/agents/focus) into
    /// one shortcut that opens the compact HUD.
    static let screenSwitcher = Self("screenSwitcher")
}

/// Phase 1A single-shortcut model. The Screen Switcher registers exactly one
/// global shortcut — `openHUD` — which opens the compact focus HUD. The former
/// `general`/`switch`/`agents`/`focus` matrix is collapsed onto this case.
///
/// `WorkspaceShortcut` is retained as a deprecated alias so historical call
/// sites and tests can continue to compile while the migration completes; new
/// code should use `SwitcherShortcut`.
public enum SwitcherShortcut: String, CaseIterable, Hashable, Sendable {
    case openHUD

    public var name: KeyboardShortcuts.Name {
        switch self {
        case .openHUD: .screenSwitcher
        }
    }

    /// The HUD-agnostic tab the legacy semantic assembly used to route through.
    /// Phase 1A always opens the `.switch` HUD surface.
    public var tab: WorkspaceTab {
        .switch
    }
}

@available(*, deprecated, renamed: "SwitcherShortcut", message: "Use SwitcherShortcut.openHUD; Phase 1A collapsed the shortcut matrix to a single HUD shortcut.")
public typealias WorkspaceShortcut = SwitcherShortcut

public extension SwitcherShortcut {
    /// Migration helper: the historical `.general` case maps to `.openHUD`.
    static var general: SwitcherShortcut { .openHUD }
}

public struct ShortcutModifiers: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)
}

public struct ShortcutChord: Equatable, Hashable {
    public let modifiers: ShortcutModifiers
    public let key: String

    public init(modifiers: ShortcutModifiers, key: String) {
        self.modifiers = modifiers
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = normalized.count == 1 ? normalized.uppercased() : normalized.lowercased()
    }

    public init?(shortcut: KeyboardShortcuts.Shortcut) {
        guard let key = Self.keyLabel(for: shortcut.key?.rawValue) else {
            return nil
        }

        self.init(
            modifiers: Self.modifiers(from: shortcut.modifiers),
            key: key
        )
    }

    public var validation: ShortcutValidation {
        guard !modifiers.isEmpty else { return .requiresModifier }
        guard !key.isEmpty else { return .invalidKey }
        if ["escape", "return", "tab", "left", "right", "up", "down"].contains(key) {
            return .reserved
        }
        guard key.count == 1, let scalar = key.unicodeScalars.first else {
            return .invalidKey
        }
        guard CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) else {
            return .invalidKey
        }
        return .valid
    }

    fileprivate var keyboardShortcut: KeyboardShortcuts.Shortcut? {
        guard let keyCode = Self.keyCode(for: key), validation == .valid else {
            return nil
        }

        var modifiers: NSEvent.ModifierFlags = []
        if self.modifiers.contains(.command) { modifiers.insert(.command) }
        if self.modifiers.contains(.option) { modifiers.insert(.option) }
        if self.modifiers.contains(.control) { modifiers.insert(.control) }
        if self.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcuts.Shortcut(
            KeyboardShortcuts.Key(rawValue: keyCode),
            modifiers: modifiers
        )
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private static func keyCode(for key: String) -> Int? {
        let labels = [
            "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
            "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
        ]
        let keys: [KeyboardShortcuts.Key] = [
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
            .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine
        ]
        return zip(labels, keys).first(where: { $0.0 == key.uppercased() })?.1.rawValue
    }

    private static func keyLabel(for rawValue: Int?) -> String? {
        guard let rawValue else { return nil }
        let labels = [
            "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
            "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
        ]
        let keys: [KeyboardShortcuts.Key] = [
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
            .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine
        ]
        return zip(labels, keys).first(where: { $0.1.rawValue == rawValue })?.0
    }
}

public enum ShortcutValidation: Equatable {
    case valid
    case requiresModifier
    case invalidKey
    case reserved
}

public struct ShortcutConfiguration: Equatable {
    public let shortcut: KeyboardShortcuts.Shortcut?

    public init(shortcut: KeyboardShortcuts.Shortcut? = nil) {
        self.shortcut = shortcut
    }

    public init(chord: ShortcutChord?) {
        self.shortcut = chord?.keyboardShortcut
    }

    public var chord: ShortcutChord? {
        shortcut.flatMap(ShortcutChord.init(shortcut:))
    }

    public var requiresFirstRun: Bool {
        shortcut == nil
    }
}

public enum ShortcutRegistrationResult: Equatable {
    case registered(ShortcutChord)
    case invalid(ShortcutValidation)
    case registrationFailed
}

/// Storage boundary around KeyboardShortcuts, kept injectable so unit tests do
/// not write the process-wide shortcut UserDefaults.
@MainActor
public protocol ShortcutStorage {
    var shortcut: KeyboardShortcuts.Shortcut? { get }
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?)
}

@MainActor
public protocol WorkspaceShortcutStorage {
    func shortcut(for shortcut: WorkspaceShortcut) -> KeyboardShortcuts.Shortcut?
    func setShortcut(_ value: KeyboardShortcuts.Shortcut?, for shortcut: WorkspaceShortcut)
}

@MainActor
public struct KeyboardShortcutsWorkspaceStorage: WorkspaceShortcutStorage {
    public init() {}

    public func shortcut(for shortcut: WorkspaceShortcut) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: shortcut.name)
    }

    public func setShortcut(_ value: KeyboardShortcuts.Shortcut?, for shortcut: WorkspaceShortcut) {
        KeyboardShortcuts.setShortcut(value, for: shortcut.name)
    }
}

@MainActor
private final class LegacyWorkspaceShortcutStorage: WorkspaceShortcutStorage {
    private let generalStorage: any ShortcutStorage
    private var directValues: [WorkspaceShortcut: KeyboardShortcuts.Shortcut] = [:]

    init(generalStorage: any ShortcutStorage) {
        self.generalStorage = generalStorage
    }

    func shortcut(for shortcut: WorkspaceShortcut) -> KeyboardShortcuts.Shortcut? {
        shortcut == .general ? generalStorage.shortcut : directValues[shortcut]
    }

    func setShortcut(_ value: KeyboardShortcuts.Shortcut?, for shortcut: WorkspaceShortcut) {
        if shortcut == .general {
            generalStorage.setShortcut(value)
        } else {
            directValues[shortcut] = value
        }
    }
}

@MainActor
public protocol WorkspaceShortcutRegistrationProbing: AnyObject {
    func isRegistered(
        _ proposed: KeyboardShortcuts.Shortcut,
        for name: KeyboardShortcuts.Name
    ) -> Bool
}

@MainActor
public protocol WorkspaceShortcutRegistrationResultReading: AnyObject {
    func registrationResult(
        _ proposed: KeyboardShortcuts.Shortcut,
        for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationResult?
}

@MainActor
public final class KeyboardShortcutsRegistrationResultReader:
    WorkspaceShortcutRegistrationResultReading {
    public init() {}

    public func registrationResult(
        _ proposed: KeyboardShortcuts.Shortcut,
        for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationResult? {
        guard KeyboardShortcuts.getShortcut(for: name) == proposed else { return nil }
        return KeyboardShortcuts.registrationResult(for: name)
    }
}

@MainActor
public final class KeyboardShortcutsWorkspaceRegistrationProbe: WorkspaceShortcutRegistrationProbing {
    private let resultReader: any WorkspaceShortcutRegistrationResultReading

    public init(
        resultReader: (any WorkspaceShortcutRegistrationResultReading)? = nil
    ) {
        self.resultReader = resultReader ?? KeyboardShortcutsRegistrationResultReader()
    }

    public func isRegistered(
        _ proposed: KeyboardShortcuts.Shortcut,
        for name: KeyboardShortcuts.Name
    ) -> Bool {
        resultReader.registrationResult(proposed, for: name) == .registered
    }
}

public enum WorkspaceShortcutValidationFailure: String, Equatable, Sendable {
    case conflict = "shortcut_conflict"
    case registrationFailed = "shortcut_registration_failed"
    case rollbackFailed = "shortcut_rollback_failed"

    public var message: String {
        switch self {
        case .conflict:
            "This shortcut is already assigned to another Cozy Stage action."
        case .registrationFailed:
            "The shortcut could not be registered. Your previous shortcut was restored."
        case .rollbackFailed:
            "Neither shortcut could be registered. Choose a new shortcut."
        }
    }
}

@MainActor
public protocol WorkspaceShortcutRegistrationValidating {
    func validationFailure(
        for proposed: KeyboardShortcuts.Shortcut?,
        shortcut: WorkspaceShortcut,
        current: [WorkspaceShortcut: KeyboardShortcuts.Shortcut?]
    ) -> WorkspaceShortcutValidationFailure?
}

@MainActor
public struct DefaultWorkspaceShortcutRegistrationValidator: WorkspaceShortcutRegistrationValidating {
    private let registrationProbe: (any WorkspaceShortcutRegistrationProbing)?

    public init(registrationProbe: (any WorkspaceShortcutRegistrationProbing)? = nil) {
        self.registrationProbe = registrationProbe
    }

    public func validationFailure(
        for proposed: KeyboardShortcuts.Shortcut?,
        shortcut: WorkspaceShortcut,
        current: [WorkspaceShortcut: KeyboardShortcuts.Shortcut?]
    ) -> WorkspaceShortcutValidationFailure? {
        guard let proposed else { return nil }
        if current.contains(where: { key, value in key != shortcut && value == proposed }) {
            return .conflict
        }
        if let registrationProbe,
           !registrationProbe.isRegistered(proposed, for: shortcut.name) {
            return .registrationFailed
        }
        return nil
    }
}

/// KeyboardShortcuts 2.4.0 stores values in `UserDefaults.standard`. Injecting
/// a unique `Name` gives tests an isolated canonical key; callers needing a
/// different defaults domain can provide their own `ShortcutStorage`.
@MainActor
public struct KeyboardShortcutsStorage: ShortcutStorage {
    private let name: KeyboardShortcuts.Name

    public init(name: KeyboardShortcuts.Name = .screenSwitcher) {
        self.name = name
    }

    public var shortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: name)
    }

    public func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }
}

@MainActor
public protocol ShortcutTriggerRegistration {
    func cancel()
}

/// Event registration boundary around KeyboardShortcuts.onKeyUp(for:).
/// Tests inject a callback recorder instead of synthesizing keyboard events.
@MainActor
public protocol ShortcutTriggerRegistering {
    func register(
        name: KeyboardShortcuts.Name,
        action: @escaping @MainActor (UInt64) -> Void
    ) -> any ShortcutTriggerRegistration
}

@MainActor
public protocol CommandTabIntercepting: AnyObject {
    func start(
        action: @escaping @MainActor (UInt64) -> Void
    ) -> (any ShortcutTriggerRegistration)?
}

enum CommandTabEventMatcher {
    static func shouldIntercept(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags
    ) -> Bool {
        (type == .keyDown || type == .keyUp)
            && keyCode == 48
            && flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskShift)
    }
}

private final class CommandTabEventTapContext: @unchecked Sendable {
    let action: @MainActor (UInt64) -> Void
    var machPort: CFMachPort?

    init(action: @escaping @MainActor (UInt64) -> Void) {
        self.action = action
    }
}

@MainActor
public final class SystemCommandTabInterceptor: CommandTabIntercepting {
    public init() {}

    public func start(
        action: @escaping @MainActor (UInt64) -> Void
    ) -> (any ShortcutTriggerRegistration)? {
        let context = CommandTabEventTapContext(action: action)
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let context = Unmanaged<CommandTabEventTapContext>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()
                    if let port = context.machPort {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                guard CommandTabEventMatcher.shouldIntercept(
                    type: type,
                    keyCode: keyCode,
                    flags: event.flags
                ) else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown, !isRepeat {
                    let context = Unmanaged<CommandTabEventTapContext>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    Task { @MainActor in context.action(startedAt) }
                }
                return nil
            },
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { return nil }
        context.machPort = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CommandTabEventTapRegistration(tap: tap, source: source, context: context)
    }
}

@MainActor
private final class CommandTabEventTapRegistration: ShortcutTriggerRegistration {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let context: CommandTabEventTapContext

    init(tap: CFMachPort, source: CFRunLoopSource, context: CommandTabEventTapContext) {
        self.tap = tap
        self.source = source
        self.context = context
    }

    func cancel() {
        guard let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        _ = context
    }
}

enum ShortcutTriggerCallbackBoundary {
    static func captureBeforeScheduling(
        monotonicNow: () -> UInt64,
        scheduleOnMainActor: (UInt64) -> Void
    ) {
        let startedAt = monotonicNow()
        scheduleOnMainActor(startedAt)
    }
}

@MainActor
public final class KeyboardShortcutsTriggerRegistrar: ShortcutTriggerRegistering {
    public init() {}

    public func register(
        name: KeyboardShortcuts.Name,
        action: @escaping @MainActor (UInt64) -> Void
    ) -> any ShortcutTriggerRegistration {
        KeyboardShortcuts.removeHandler(for: name)
        KeyboardShortcuts.onKeyUp(for: name) {
            ShortcutTriggerCallbackBoundary.captureBeforeScheduling(
                monotonicNow: { DispatchTime.now().uptimeNanoseconds },
                scheduleOnMainActor: { startedAt in
                    Task { @MainActor in
                        action(startedAt)
                    }
                }
            )
        }
        return KeyboardShortcutsTriggerRegistration(name: name)
    }
}

@MainActor
private final class KeyboardShortcutsTriggerRegistration: ShortcutTriggerRegistration {
    private let name: KeyboardShortcuts.Name
    private var isCancelled = false

    init(name: KeyboardShortcuts.Name) {
        self.name = name
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        KeyboardShortcuts.removeHandler(for: name)
    }
}

@MainActor
public final class ShortcutConfigurationStore {
    private let workspaceStorage: any WorkspaceShortcutStorage
    private let registrationValidator: any WorkspaceShortcutRegistrationValidating
    private let onTabTrigger: @MainActor (WorkspaceTab, UInt64) -> Void
    private let userDefaults: UserDefaults
    private let commandTabInterceptor: any CommandTabIntercepting
    private var activeRegistrar: (any ShortcutTriggerRegistering)?
    private var triggerRegistrations: [any ShortcutTriggerRegistration] = []
    private var configurations: [WorkspaceShortcut: ShortcutConfiguration] = [:]
    private var validationFailures: [WorkspaceShortcut: WorkspaceShortcutValidationFailure] = [:]

    public private(set) var isCommandTabTakeoverActive = false
    public var isCommandTabTakeoverEnabled: Bool {
        userDefaults.bool(forKey: Self.commandTabTakeoverKey)
    }

    public var configuration: ShortcutConfiguration {
        configuration(for: .general)
    }

    public init(
        storage: (any ShortcutStorage)? = nil,
        userDefaults: UserDefaults = .standard,
        commandTabInterceptor: (any CommandTabIntercepting)? = nil,
        onTrigger: @escaping @MainActor () -> Void = {}
    ) {
        let workspaceStorage: any WorkspaceShortcutStorage
        if let storage {
            workspaceStorage = LegacyWorkspaceShortcutStorage(generalStorage: storage)
        } else {
            workspaceStorage = KeyboardShortcutsWorkspaceStorage()
        }
        self.workspaceStorage = workspaceStorage
        self.registrationValidator = DefaultWorkspaceShortcutRegistrationValidator(
            registrationProbe: storage == nil ? KeyboardShortcutsWorkspaceRegistrationProbe() : nil
        )
        self.userDefaults = userDefaults
        self.commandTabInterceptor = commandTabInterceptor ?? SystemCommandTabInterceptor()
        self.onTabTrigger = { tab, _ in
            guard tab == .switch else { return }
            onTrigger()
        }
        Self.migrateLegacyShortcutIfNeeded(userDefaults: userDefaults, storage: workspaceStorage)
        reloadConfigurations()
    }

    public init(
        storage: (any ShortcutStorage)? = nil,
        userDefaults: UserDefaults = .standard,
        commandTabInterceptor: (any CommandTabIntercepting)? = nil,
        onTabTrigger: @escaping @MainActor (WorkspaceTab, UInt64) -> Void
    ) {
        let workspaceStorage: any WorkspaceShortcutStorage
        if let storage {
            workspaceStorage = LegacyWorkspaceShortcutStorage(generalStorage: storage)
        } else {
            workspaceStorage = KeyboardShortcutsWorkspaceStorage()
        }
        self.workspaceStorage = workspaceStorage
        self.registrationValidator = DefaultWorkspaceShortcutRegistrationValidator(
            registrationProbe: storage == nil ? KeyboardShortcutsWorkspaceRegistrationProbe() : nil
        )
        self.userDefaults = userDefaults
        self.commandTabInterceptor = commandTabInterceptor ?? SystemCommandTabInterceptor()
        self.onTabTrigger = onTabTrigger
        Self.migrateLegacyShortcutIfNeeded(userDefaults: userDefaults, storage: workspaceStorage)
        reloadConfigurations()
    }

    public init(
        workspaceStorage: any WorkspaceShortcutStorage,
        userDefaults: UserDefaults = .standard,
        registrationValidator: (any WorkspaceShortcutRegistrationValidating)? = nil,
        commandTabInterceptor: (any CommandTabIntercepting)? = nil,
        onTabTrigger: @escaping @MainActor (WorkspaceTab, UInt64) -> Void = { _, _ in }
    ) {
        self.workspaceStorage = workspaceStorage
        self.registrationValidator = registrationValidator
            ?? DefaultWorkspaceShortcutRegistrationValidator()
        self.userDefaults = userDefaults
        self.commandTabInterceptor = commandTabInterceptor ?? SystemCommandTabInterceptor()
        self.onTabTrigger = onTabTrigger
        Self.migrateLegacyShortcutIfNeeded(userDefaults: userDefaults, storage: workspaceStorage)
        reloadConfigurations()
    }

    public var requiresFirstRun: Bool {
        configuration.requiresFirstRun
    }

    public var isReady: Bool {
        !requiresFirstRun
    }

    public func registerGlobalTrigger(using registrar: any ShortcutTriggerRegistering) {
        registerGlobalTriggers(using: registrar)
    }

    public func registerGlobalTriggers(using registrar: any ShortcutTriggerRegistering) {
        activeRegistrar = registrar
        applyGlobalRegistration()
    }

    private func applyGlobalRegistration() {
        cancelGlobalRegistration()
        guard let registrar = activeRegistrar else { return }
        if isCommandTabTakeoverEnabled {
            if let registration = commandTabInterceptor.start(action: { [onTabTrigger] startedAt in
                onTabTrigger(.switch, startedAt)
            }) {
                triggerRegistrations = [registration]
                isCommandTabTakeoverActive = true
                return
            }
        }
        triggerRegistrations = WorkspaceShortcut.allCases.map { shortcut in
            registrar.register(name: shortcut.name) { [onTabTrigger] startedAt in
                onTabTrigger(shortcut.tab, startedAt)
            }
        }
    }

    public func unregisterGlobalTrigger() {
        activeRegistrar = nil
        cancelGlobalRegistration()
    }

    private func cancelGlobalRegistration() {
        triggerRegistrations.forEach { $0.cancel() }
        triggerRegistrations.removeAll()
        isCommandTabTakeoverActive = false
    }

    @discardableResult
    public func setCommandTabTakeoverEnabled(_ enabled: Bool) -> Bool {
        userDefaults.set(enabled, forKey: Self.commandTabTakeoverKey)
        applyGlobalRegistration()
        return !enabled || isCommandTabTakeoverActive
    }

    public func retryCommandTabTakeover() {
        guard isCommandTabTakeoverEnabled, !isCommandTabTakeoverActive else { return }
        applyGlobalRegistration()
    }

    /// Synchronize the product facade after `KeyboardShortcuts.Recorder` has
    /// written its canonical value. The Recorder owns persistence; this method
    /// intentionally does not write to storage again.
    public func synchronize(shortcut: KeyboardShortcuts.Shortcut?) {
        configurations[.general] = ShortcutConfiguration(shortcut: shortcut)
        validationFailures[.general] = nil
    }

    public func refresh() {
        reloadConfigurations()
    }

    public func configuration(for shortcut: WorkspaceShortcut) -> ShortcutConfiguration {
        configurations[shortcut] ?? ShortcutConfiguration()
    }

    public func validationMessage(for shortcut: WorkspaceShortcut) -> String? {
        validationFailures[shortcut]?.message
    }

    public func validationFailure(
        for shortcut: WorkspaceShortcut
    ) -> WorkspaceShortcutValidationFailure? {
        validationFailures[shortcut]
    }

    @discardableResult
    public func acceptRecorderChange(
        _ proposed: KeyboardShortcuts.Shortcut?,
        for shortcut: WorkspaceShortcut
    ) -> Bool {
        let previous = configuration(for: shortcut).shortcut
        var current = Dictionary(uniqueKeysWithValues: WorkspaceShortcut.allCases.map {
            ($0, configuration(for: $0).shortcut)
        })
        current[shortcut] = proposed
        if let failure = registrationValidator.validationFailure(
            for: proposed,
            shortcut: shortcut,
            current: current
        ) {
            restorePreviousShortcut(
                previous,
                for: shortcut,
                after: failure,
                current: current
            )
            return false
        }
        configurations[shortcut] = ShortcutConfiguration(shortcut: proposed)
        validationFailures[shortcut] = nil
        return true
    }

    /// Compatibility entry point for existing product callers that provide a
    /// legacy chord. New UI writes through KeyboardShortcuts.Recorder instead.
    @discardableResult
    public func capture(_ chord: ShortcutChord) -> ShortcutRegistrationResult {
        guard chord.validation == .valid else {
            return .invalid(chord.validation)
        }
        guard let shortcut = chord.keyboardShortcut else {
            return .registrationFailed
        }
        var current = Dictionary(uniqueKeysWithValues: WorkspaceShortcut.allCases.map {
            ($0, configuration(for: $0).shortcut)
        })
        current[.general] = shortcut
        let previous = configuration.shortcut
        workspaceStorage.setShortcut(shortcut, for: .general)
        if let failure = registrationValidator.validationFailure(
            for: shortcut,
            shortcut: .general,
            current: current
        ) {
            restorePreviousShortcut(
                previous,
                for: .general,
                after: failure,
                current: current
            )
            return .registrationFailed
        }
        configurations[.general] = ShortcutConfiguration(shortcut: shortcut)
        validationFailures[.general] = nil
        return .registered(chord)
    }

    private func restorePreviousShortcut(
        _ previous: KeyboardShortcuts.Shortcut?,
        for shortcut: WorkspaceShortcut,
        after originalFailure: WorkspaceShortcutValidationFailure,
        current: [WorkspaceShortcut: KeyboardShortcuts.Shortcut?]
    ) {
        workspaceStorage.setShortcut(previous, for: shortcut)
        guard let previous else {
            configurations[shortcut] = ShortcutConfiguration()
            validationFailures[shortcut] = originalFailure
            return
        }

        var rollbackState = current
        rollbackState[shortcut] = previous
        if registrationValidator.validationFailure(
            for: previous,
            shortcut: shortcut,
            current: rollbackState
        ) != nil {
            workspaceStorage.setShortcut(nil, for: shortcut)
            configurations[shortcut] = ShortcutConfiguration()
            validationFailures[shortcut] = .rollbackFailed
            return
        }

        configurations[shortcut] = ShortcutConfiguration(shortcut: previous)
        validationFailures[shortcut] = originalFailure
    }

    private func reloadConfigurations() {
        configurations = Dictionary(uniqueKeysWithValues: WorkspaceShortcut.allCases.map {
            ($0, ShortcutConfiguration(shortcut: workspaceStorage.shortcut(for: $0)))
        })
    }

    private static func migrateLegacyShortcutIfNeeded(
        userDefaults: UserDefaults,
        storage: any WorkspaceShortcutStorage
    ) {
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        if storage.shortcut(for: .general) == nil,
           let key = userDefaults.string(forKey: legacyKeyName),
           let modifiers = legacyModifiers(from: userDefaults),
           let shortcut = ShortcutChord(modifiers: modifiers, key: key).keyboardShortcut {
            storage.setShortcut(shortcut, for: .general)
        }

        userDefaults.set(true, forKey: migrationKey)
    }

    private static func legacyModifiers(from userDefaults: UserDefaults) -> ShortcutModifiers? {
        let modifiers = ShortcutModifiers(rawValue: UInt8(userDefaults.integer(forKey: legacyModifiersName)))
        return modifiers.isEmpty ? nil : modifiers
    }

    private static let legacyKeyName = "screen-switcher.shortcut.key"
    private static let legacyModifiersName = "screen-switcher.shortcut.modifiers"
    private static let migrationKey = "screen-switcher.shortcut.keyboard-shortcuts-migrated"
    private static let commandTabTakeoverKey = "screen-switcher.shortcut.command-tab-takeover"
}
