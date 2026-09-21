import KeyboardShortcuts
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WorkspaceShortcutTests: XCTestCase {
    // MARK: - Phase 1A single-shortcut model

    func testDefinesSingleMigrationCompatibleShortcutName() {
        // Phase 1A collapses the former four-case matrix onto a single
        // `.screenSwitcher` name. The switch/agents/focus names are gone.
        XCTAssertEqual(KeyboardShortcuts.Name.screenSwitcher.rawValue, "screenSwitcher")
        XCTAssertEqual(Set(SwitcherShortcut.allCases.map(\.name.rawValue)), ["screenSwitcher"])
        XCTAssertEqual(SwitcherShortcut.allCases, [.openHUD])
        XCTAssertEqual(SwitcherShortcut.openHUD.tab, .switch)
    }

    func testConflictRollsBackRecorderWriteAndPublishesInlineError() {
        // With a single shortcut there is no intra-matrix conflict, but the
        // registration-probe path still surfaces a registration failure and
        // rolls the recorder write back to the previous value.
        let previous = KeyboardShortcuts.Shortcut(.k, modifiers: [.command])
        let rejected = KeyboardShortcuts.Shortcut(.a, modifiers: [.command, .shift])
        let storage = ShortcutMatrixStorage(values: [.openHUD: previous])
        let resultReader = StubShortcutRegistrationResultReader(
            results: [.failed(status: -9876), .registered]
        )
        let probe = KeyboardShortcutsWorkspaceRegistrationProbe(
            resultReader: resultReader
        )
        let validator = DefaultWorkspaceShortcutRegistrationValidator(
            registrationProbe: probe
        )
        let store = ShortcutConfigurationStore(
            workspaceStorage: storage,
            registrationValidator: validator
        )

        // KeyboardShortcuts.Recorder writes before invoking onChange.
        storage.setShortcut(rejected, for: .openHUD)
        XCTAssertFalse(store.acceptRecorderChange(rejected, for: .openHUD))

        XCTAssertEqual(storage.shortcut(for: .openHUD), previous)
        XCTAssertEqual(store.configuration(for: .openHUD).shortcut, previous)
        XCTAssertEqual(store.validationFailure(for: .openHUD), .registrationFailed)
        XCTAssertEqual(
            store.validationMessage(for: .openHUD),
            WorkspaceShortcutValidationFailure.registrationFailed.message
        )
        XCTAssertEqual(resultReader.reads.map(\.name), [.screenSwitcher, .screenSwitcher])
        XCTAssertEqual(resultReader.reads.map(\.shortcut), [rejected, previous])
        XCTAssertEqual(storage.writes.suffix(2).map(\.value), [rejected, previous])
    }

    func testCandidateAndRollbackRegistrationFailurePublishesDistinctErrorAndClearsUnusableValue() {
        let previous = KeyboardShortcuts.Shortcut(.k, modifiers: [.command])
        let rejected = KeyboardShortcuts.Shortcut(.j, modifiers: [.command, .shift])
        let storage = ShortcutMatrixStorage(values: [.openHUD: previous])
        let resultReader = StubShortcutRegistrationResultReader(
            results: [.failed(status: -9876), .failed(status: -9877)]
        )
        let store = ShortcutConfigurationStore(
            workspaceStorage: storage,
            registrationValidator: DefaultWorkspaceShortcutRegistrationValidator(
                registrationProbe: KeyboardShortcutsWorkspaceRegistrationProbe(
                    resultReader: resultReader
                )
            )
        )
        storage.setShortcut(rejected, for: .openHUD)

        XCTAssertFalse(store.acceptRecorderChange(rejected, for: .openHUD))
        XCTAssertNil(storage.shortcut(for: .openHUD))
        XCTAssertNil(store.configuration(for: .openHUD).shortcut)
        XCTAssertEqual(store.validationFailure(for: .openHUD), .rollbackFailed)
        XCTAssertEqual(
            store.validationMessage(for: .openHUD),
            WorkspaceShortcutValidationFailure.rollbackFailed.message
        )
        XCTAssertEqual(resultReader.reads.map(\.shortcut), [rejected, previous])
        XCTAssertEqual(storage.writes.suffix(3).map(\.value), [rejected, previous, nil])
    }

    func testSingleShortcutRegistrationOpensHUDOnTrigger() {
        let registrar = NamedShortcutRegistrar()
        let presenter = ShortcutTabPresenter()
        var receivedStarts: [UInt64] = []
        let store = ShortcutConfigurationStore(
            workspaceStorage: ShortcutMatrixStorage(),
            onTabTrigger: { tab, startedAt in
                receivedStarts.append(startedAt)
                presenter.toggle(tab: tab)
            }
        )
        store.registerGlobalTriggers(using: registrar)

        // Phase 1A: only ONE shortcut is registered.
        XCTAssertEqual(registrar.registeredNames, [.screenSwitcher])

        registrar.invoke(.screenSwitcher, startedAt: 11)
        XCTAssertEqual(presenter.visibleTab, .switch)
        XCTAssertEqual(presenter.sessionOpenCount, 1)

        registrar.invoke(.screenSwitcher, startedAt: 22)
        XCTAssertNil(presenter.visibleTab)
        XCTAssertEqual(presenter.closeCount, 1)
        XCTAssertEqual(receivedStarts, [11, 22])
    }

    func testGlobalCallbackCapturesMonotonicStartBeforeSchedulingMainActorAction() {
        var events: [String] = []
        var scheduledTimestamp: UInt64?

        ShortcutTriggerCallbackBoundary.captureBeforeScheduling(
            monotonicNow: {
                events.append("clock")
                return 42
            },
            scheduleOnMainActor: { timestamp in
                events.append("schedule")
                scheduledTimestamp = timestamp
            }
        )

        XCTAssertEqual(events, ["clock", "schedule"])
        XCTAssertEqual(scheduledTimestamp, 42)
    }

    func testCommandTabMatcherConsumesDownAndUpButNotModifiedVariants() {
        XCTAssertTrue(CommandTabEventMatcher.shouldIntercept(
            type: .keyDown,
            keyCode: 48,
            flags: .maskCommand
        ))
        XCTAssertTrue(CommandTabEventMatcher.shouldIntercept(
            type: .keyUp,
            keyCode: 48,
            flags: .maskCommand
        ))
        XCTAssertFalse(CommandTabEventMatcher.shouldIntercept(
            type: .keyDown,
            keyCode: 48,
            flags: [.maskCommand, .maskShift]
        ))
        XCTAssertFalse(CommandTabEventMatcher.shouldIntercept(
            type: .keyDown,
            keyCode: 0,
            flags: .maskCommand
        ))
    }

    func testCommandTabQuickSetupReplacesAndRestoresNormalRegistration() {
        let suite = "command-tab-setup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registrar = NamedShortcutRegistrar()
        let interceptor = StubCommandTabInterceptor()
        var openCount = 0
        let store = ShortcutConfigurationStore(
            workspaceStorage: ShortcutMatrixStorage(),
            userDefaults: defaults,
            commandTabInterceptor: interceptor,
            onTabTrigger: { _, _ in openCount += 1 }
        )

        store.registerGlobalTriggers(using: registrar)
        XCTAssertEqual(registrar.registeredNames, [.screenSwitcher])
        XCTAssertTrue(store.setCommandTabTakeoverEnabled(true))
        XCTAssertTrue(store.isCommandTabTakeoverEnabled)
        XCTAssertTrue(store.isCommandTabTakeoverActive)

        interceptor.invoke(startedAt: 12)
        XCTAssertEqual(openCount, 1)

        XCTAssertTrue(store.setCommandTabTakeoverEnabled(false))
        XCTAssertFalse(store.isCommandTabTakeoverEnabled)
        XCTAssertFalse(store.isCommandTabTakeoverActive)
        XCTAssertEqual(registrar.registeredNames, [.screenSwitcher, .screenSwitcher])
    }

    func testLegacyGeneralMigrationRemainsCompatible() {
        let suite = "workspace-shortcut-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("K", forKey: "screen-switcher.shortcut.key")
        defaults.set(Int(ShortcutModifiers.command.rawValue), forKey: "screen-switcher.shortcut.modifiers")
        let storage = ShortcutMatrixStorage()

        let migrated = ShortcutConfigurationStore(
            workspaceStorage: storage,
            userDefaults: defaults
        )
        XCTAssertEqual(migrated.configuration(for: .openHUD).shortcut,
                       KeyboardShortcuts.Shortcut(.k, modifiers: [.command]))

        let restarted = ShortcutConfigurationStore(
            workspaceStorage: storage,
            userDefaults: defaults
        )
        XCTAssertEqual(
            SwitcherShortcut.allCases.map { restarted.configuration(for: $0).shortcut },
            SwitcherShortcut.allCases.map { migrated.configuration(for: $0).shortcut }
        )
    }

    func testSettingsKeepsLaunchAtLoginOffByDefault() throws {
        let shortcuts = ShortcutConfigurationStore(workspaceStorage: ShortcutMatrixStorage())
        let launch = ShortcutLaunchAtLogin(enabled: false)
        let model = SettingsModel(
            permissionService: shortcutPermissionService(),
            launchAtLogin: launch,
            shortcutStore: shortcuts
        )

        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertTrue(launch.events.isEmpty)
    }

    func testLaunchAtLoginRegistrationFailurePublishesErrorAndKeepsActualOffState() {
        let launch = ShortcutLaunchAtLogin(enabled: false, failingEvent: .register)
        let model = SettingsModel(
            permissionService: shortcutPermissionService(),
            launchAtLogin: launch,
            shortcutStore: ShortcutConfigurationStore(workspaceStorage: ShortcutMatrixStorage())
        )

        XCTAssertFalse(model.setLaunchAtLogin(true))
        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(model.launchAtLoginError, .registrationFailed)
        XCTAssertEqual(
            model.launchAtLoginErrorMessage,
            "Cozy Stage could not be added to Login Items. Try again."
        )
        XCTAssertEqual(launch.events, [.register])
    }

    func testLaunchAtLoginUnregistrationFailurePublishesErrorAndKeepsActualOnState() {
        let launch = ShortcutLaunchAtLogin(enabled: true, failingEvent: .unregister)
        let model = SettingsModel(
            permissionService: shortcutPermissionService(),
            launchAtLogin: launch,
            shortcutStore: ShortcutConfigurationStore(workspaceStorage: ShortcutMatrixStorage())
        )

        XCTAssertFalse(model.setLaunchAtLogin(false))
        XCTAssertTrue(model.launchAtLoginEnabled)
        XCTAssertEqual(model.launchAtLoginError, .unregistrationFailed)
        XCTAssertEqual(
            model.launchAtLoginErrorMessage,
            "Cozy Stage could not be removed from Login Items. Try again."
        )
        XCTAssertEqual(launch.events, [.unregister])
    }

    func testAccessibilityPermissionButtonRequestsBeforeOpeningSettings() {
        let order = ShortcutPermissionOrder()
        let model = SettingsModel(
            permissionService: PermissionService(
                accessibilityChecker: OrderedAccessibilityChecker(order: order),
                settingsOpener: OrderedSettingsOpener(order: order)
            ),
            launchAtLogin: ShortcutLaunchAtLogin(enabled: false),
            shortcutStore: ShortcutConfigurationStore(workspaceStorage: ShortcutMatrixStorage())
        )

        XCTAssertTrue(model.requestAndOpenAccessibilitySettings())
        XCTAssertEqual(order.events, [
            "request:accessibility", "open:accessibility",
        ])
    }

    // MARK: - Bootstrap proves FocusScreenController is the production entry point

    func testDefaultBootstrapReturnsFocusScreenControllerAsProductionPresenter() {
        // The production bootstrap must return a FocusScreenController (not the
        // legacy FullscreenWorkspaceController) as the panel presenter.
        let bootstrap = DefaultAppDelegateBootstrap.make(
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/Applications-under-test/ScreenSwitcher")
        )
        XCTAssertTrue(bootstrap.panelPresenter is FocusScreenController,
                      "Production panel presenter must be FocusScreenController after Task 9")
    }

    func testDefaultBootstrapPresenterConformsToSwitcherRuntimeStarting() {
        let bootstrap = DefaultAppDelegateBootstrap.make(
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/Applications-under-test/ScreenSwitcher")
        )
        XCTAssertTrue(bootstrap.panelPresenter is any SwitcherRuntimeStarting,
                      "Production presenter must conform to SwitcherRuntimeStarting")
        XCTAssertTrue(bootstrap.panelPresenter is any SwitcherPanelPrewarming,
                      "Production presenter must conform to SwitcherPanelPrewarming")
    }
}

@MainActor
private final class ShortcutMatrixStorage: WorkspaceShortcutStorage {
    struct Write {
        let shortcut: SwitcherShortcut
        let value: KeyboardShortcuts.Shortcut?
    }

    private var values: [SwitcherShortcut: KeyboardShortcuts.Shortcut?]
    private(set) var writes: [Write] = []

    init(values: [SwitcherShortcut: KeyboardShortcuts.Shortcut?] = [:]) {
        self.values = values
    }

    func shortcut(for shortcut: SwitcherShortcut) -> KeyboardShortcuts.Shortcut? {
        values[shortcut] ?? nil
    }

    func setShortcut(_ value: KeyboardShortcuts.Shortcut?, for shortcut: SwitcherShortcut) {
        writes.append(Write(shortcut: shortcut, value: value))
        values[shortcut] = value
    }
}

@MainActor
private final class NamedShortcutRegistrar: ShortcutTriggerRegistering {
    private var actions: [KeyboardShortcuts.Name: @MainActor (UInt64) -> Void] = [:]
    private(set) var registeredNames: [KeyboardShortcuts.Name] = []

    func register(
        name: KeyboardShortcuts.Name,
        action: @escaping @MainActor (UInt64) -> Void
    ) -> any ShortcutTriggerRegistration {
        actions[name] = action
        registeredNames.append(name)
        return NamedShortcutRegistration { [weak self] in self?.actions[name] = nil }
    }

    func invoke(_ name: KeyboardShortcuts.Name, startedAt: UInt64) {
        actions[name]?(startedAt)
    }
}

@MainActor
private final class NamedShortcutRegistration: ShortcutTriggerRegistration {
    private let cancellation: @MainActor () -> Void

    init(_ cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}

@MainActor
private final class StubCommandTabInterceptor: CommandTabIntercepting {
    private var action: (@MainActor (UInt64) -> Void)?

    func start(
        action: @escaping @MainActor (UInt64) -> Void
    ) -> (any ShortcutTriggerRegistration)? {
        self.action = action
        return NamedShortcutRegistration { [weak self] in self?.action = nil }
    }

    func invoke(startedAt: UInt64) {
        action?(startedAt)
    }
}

@MainActor
private final class ShortcutTabPresenter {
    private(set) var visibleTab: WorkspaceTab?
    private(set) var sessionOpenCount = 0
    private(set) var closeCount = 0

    func toggle(tab: WorkspaceTab) {
        if visibleTab == tab {
            visibleTab = nil
            closeCount += 1
        } else {
            if visibleTab == nil { sessionOpenCount += 1 }
            visibleTab = tab
        }
    }
}

@MainActor
private final class StubShortcutRegistrationResultReader: WorkspaceShortcutRegistrationResultReading {
    struct Read {
        let shortcut: KeyboardShortcuts.Shortcut
        let name: KeyboardShortcuts.Name
    }

    private var results: [KeyboardShortcuts.RegistrationResult]
    private(set) var reads: [Read] = []

    init(results: [KeyboardShortcuts.RegistrationResult]) {
        self.results = results
    }

    func registrationResult(
        _ proposed: KeyboardShortcuts.Shortcut,
        for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationResult? {
        reads.append(Read(shortcut: proposed, name: name))
        return results.isEmpty ? nil : results.removeFirst()
    }
}

@MainActor
private final class ShortcutLaunchAtLogin: LaunchAtLoginManaging {
    enum Event: Equatable { case register, unregister }
    enum Failure: Error { case requested }
    var isEnabled: Bool
    var events: [Event] = []
    let failingEvent: Event?

    init(enabled: Bool, failingEvent: Event? = nil) {
        isEnabled = enabled
        self.failingEvent = failingEvent
    }
    func register() throws {
        events.append(.register)
        if failingEvent == .register { throw Failure.requested }
        isEnabled = true
    }
    func unregister() throws {
        events.append(.unregister)
        if failingEvent == .unregister { throw Failure.requested }
        isEnabled = false
    }
}

@MainActor
private final class ShortcutPermissionOrder { var events: [String] = [] }

@MainActor
private struct OrderedAccessibilityChecker: AccessibilityChecking {
    let order: ShortcutPermissionOrder
    func isAccessibilityTrusted() -> Bool { true }
    func requestAccessibilityAccess() -> Bool {
        order.events.append("request:accessibility")
        return false
    }
}

@MainActor
private struct OrderedSettingsOpener: PermissionSettingsOpening {
    let order: ShortcutPermissionOrder
    func openSettings(for kind: PermissionKind) -> Bool {
        order.events.append("open:accessibility")
        return true
    }
}

@MainActor
private func shortcutPermissionService() -> PermissionService {
    let order = ShortcutPermissionOrder()
    return PermissionService(
        accessibilityChecker: OrderedAccessibilityChecker(order: order),
        settingsOpener: OrderedSettingsOpener(order: order)
    )
}
