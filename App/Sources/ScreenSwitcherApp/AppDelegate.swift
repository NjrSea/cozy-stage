import AppKit
import KeyboardShortcuts

@MainActor
public protocol SwitcherPanelPresenting: AnyObject {
    func openSwitcher()
    func closeSwitcher()
}

@MainActor
public protocol SwitcherPanelPrewarming: AnyObject {
    func prewarmSwitcher()
}

@MainActor
public protocol SwitcherSettingsPresenting: AnyObject {
    func openSettings()
}

@MainActor
public protocol ApplicationTerminating: AnyObject {
    func terminate()
}

@MainActor
public protocol SemanticAdapterServerControlling: AnyObject {
    func start() async throws -> SemanticAdapterRuntimeMetadata
    func stop()
}

public typealias SemanticAdapterServerFactory = @MainActor () -> (any SemanticAdapterServerControlling)?
public typealias DeferredMainActionScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void
public typealias MenuTrackingCanceller = @MainActor (NSMenu) -> Void

public struct RuntimeAdapterStartupPolicy: Equatable, Sendable {
    public static let runtimeEnvironmentKey = "CS_DIAG_RUNTIME"
    public static let dogfoodEnvironmentKey = "CS_DIAG_DOGFOOD"
    public static let enabledValue = "1"
    public static let metadataEnvironmentKeys = [
        "SCREEN_SWITCHER_RUNTIME_METADATA_FILE",
        "CS_DIAG_SCREEN_SWITCHER_ADAPTER_METADATA"
    ]
    public static let tokenEnvironmentKeys = [
        "SCREEN_SWITCHER_RUNTIME_TOKEN",
        "CS_DIAG_SCREEN_SWITCHER_ADAPTER_TOKEN"
    ]

    public let isEnabled: Bool
    public let isDogfood: Bool
    public let shouldRegisterUserGlobalOpeners: Bool

    public init(environment: [String: String], isPackagedProduction: Bool) {
        let explicitRuntime = environment[Self.runtimeEnvironmentKey] == Self.enabledValue
        let explicitDogfood = environment[Self.dogfoodEnvironmentKey] == Self.enabledValue
        let hasRegistration = Self.registrationValue(in: environment, keys: Self.metadataEnvironmentKeys) != nil
            && Self.registrationValue(in: environment, keys: Self.tokenEnvironmentKeys) != nil
        self.isDogfood = explicitDogfood
        self.shouldRegisterUserGlobalOpeners = !explicitRuntime
        self.isEnabled = isPackagedProduction
            ? explicitRuntime && explicitDogfood
            : (explicitRuntime || hasRegistration)
    }

    public static func fromProcessEnvironment() -> Self {
        let environment = ProcessInfo.processInfo.environment
        return Self(environment: environment, isPackagedProduction: isPackagedProduction(bundleURL: Bundle.main.bundleURL, environment: environment))
    }

    public static func isPackagedProduction(bundleURL: URL, environment _: [String: String]) -> Bool {
        bundleURL.pathExtension == "app"
    }

    public static func registrationValue(in environment: [String: String], keys: [String]) -> String? {
        keys.lazy.compactMap { key in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }.first
    }
}

private final class SemanticAdapterLifecycleReleaseToken: Sendable {
    private let cleanup: @Sendable () -> Void

    init(cleanup: @escaping @Sendable () -> Void) {
        self.cleanup = cleanup
    }

    deinit {
        cleanup()
    }
}

@MainActor
final class SemanticAdapterLifecycleController {
    @MainActor
    private final class State {
        @MainActor
        private final class StartAttempt {
            let server: any SemanticAdapterServerControlling
            private var isStopped = false

            init(server: any SemanticAdapterServerControlling) {
                self.server = server
            }

            func stopOnce() {
                guard !isStopped else { return }
                isStopped = true
                server.stop()
            }
        }

        private let startupPolicy: RuntimeAdapterStartupPolicy
        private let serverFactory: SemanticAdapterServerFactory
        private var currentAttempt: StartAttempt?
        private var startTask: Task<Void, Never>?

        init(
            startupPolicy: RuntimeAdapterStartupPolicy,
            serverFactory: @escaping SemanticAdapterServerFactory
        ) {
            self.startupPolicy = startupPolicy
            self.serverFactory = serverFactory
        }

        func start() {
            guard startupPolicy.isEnabled,
                  currentAttempt == nil,
                  startTask == nil,
                  let server = serverFactory()
            else { return }

            let attempt = StartAttempt(server: server)
            currentAttempt = attempt
            startTask = Task { @MainActor [weak self, attempt] in
                let failed: Bool
                do {
                    _ = try await attempt.server.start()
                    failed = false
                } catch {
                    failed = true
                }

                guard let self else {
                    attempt.stopOnce()
                    return
                }
                self.finish(attempt: attempt, failed: failed)
            }
        }

        func stop() {
            let task = startTask
            let attempt = currentAttempt
            startTask = nil
            currentAttempt = nil
            task?.cancel()
            attempt?.stopOnce()
        }

        private func finish(attempt: StartAttempt, failed: Bool) {
            guard currentAttempt === attempt else { return }
            startTask = nil
            if failed {
                attempt.stopOnce()
                currentAttempt = nil
            }
        }
    }

    private let state: State
    private let releaseToken: SemanticAdapterLifecycleReleaseToken

    init(
        startupPolicy: RuntimeAdapterStartupPolicy,
        serverFactory: @escaping SemanticAdapterServerFactory
    ) {
        let state = State(startupPolicy: startupPolicy, serverFactory: serverFactory)
        self.state = state
        self.releaseToken = SemanticAdapterLifecycleReleaseToken {
            Task { @MainActor [state] in
                state.stop()
            }
        }
    }

    func start() {
        state.start()
    }

    func stop() {
        state.stop()
    }
}

@MainActor
final class FullscreenSemanticAdapterAssembly {
    private let workspacePresenter: any FullscreenWorkspacePresenting & FullscreenWorkspaceVisibilityObserving
    private let semanticModel: SwitcherSemanticModel
    private let sessionManager: any SwitcherPanelSessionManaging
    private let headlessSessionFactory: @MainActor (SwitcherSnapshot) -> SwitcherHeadlessSession
    private let prefersWorkspaceSession: Bool

    init(
        workspacePresenter: any FullscreenWorkspacePresenting & FullscreenWorkspaceVisibilityObserving,
        semanticModel: SwitcherSemanticModel,
        sessionManager: (any SwitcherPanelSessionManaging)? = nil,
        headlessSessionFactory: (@MainActor (SwitcherSnapshot) -> SwitcherHeadlessSession)? = nil
    ) {
        self.workspacePresenter = workspacePresenter
        self.semanticModel = semanticModel
        self.prefersWorkspaceSession = sessionManager == nil && headlessSessionFactory == nil
        self.sessionManager = sessionManager ?? semanticModel.runtimeState
        self.headlessSessionFactory = headlessSessionFactory ?? { [semanticModel] _ in
            semanticModel.makeHeadlessSession()
        }
    }

    func makeRuntime() -> FullscreenHeadlessSemanticRuntime {
        FullscreenHeadlessSemanticRuntime(
            workspacePresenter: workspacePresenter,
            headlessSessionFactory: headlessSessionFactory,
            runtimeState: semanticModel.runtimeState,
            sessionManager: sessionManager,
            semanticModelOwner: semanticModel,
            prefersWorkspaceSession: prefersWorkspaceSession
        )
    }
}

@MainActor
final class FullscreenHeadlessSemanticRuntime: SemanticAdapterRuntime, SemanticAdapterRuntimeTearingDown {
    private struct Session {
        let model: SwitcherHeadlessSession
        let snapshot: SwitcherSnapshot
    }

    private let workspacePresenter: any FullscreenWorkspacePresenting & FullscreenWorkspaceVisibilityObserving
    private let headlessSessionFactory: @MainActor (SwitcherSnapshot) -> SwitcherHeadlessSession
    private let runtimeState: SwitcherRuntimeState
    private let sessionManager: any SwitcherPanelSessionManaging
    private let semanticModelOwner: SwitcherSemanticModel
    private let prefersWorkspaceSession: Bool
    private var session: Session?
    private var visibilityObservation: WorkspaceVisibilityObservation?
    private var isTornDown = false
    private var activeSemanticGestureID: WorkspaceGestureSessionID?
    private var semanticGesturePhase = "idle"
    private var semanticSelectedTargetKind: String?
    private var semanticSelectedTargetIdentity: String?
    private var semanticDryRunSelectionConfirmed = false

    init(
        workspacePresenter: any FullscreenWorkspacePresenting & FullscreenWorkspaceVisibilityObserving,
        headlessSessionFactory: @escaping @MainActor (SwitcherSnapshot) -> SwitcherHeadlessSession,
        runtimeState: SwitcherRuntimeState,
        sessionManager: any SwitcherPanelSessionManaging,
        semanticModelOwner: SwitcherSemanticModel,
        prefersWorkspaceSession: Bool = false
    ) {
        self.workspacePresenter = workspacePresenter
        self.headlessSessionFactory = headlessSessionFactory
        self.runtimeState = runtimeState
        self.sessionManager = sessionManager
        self.semanticModelOwner = semanticModelOwner
        self.prefersWorkspaceSession = prefersWorkspaceSession
        visibilityObservation = workspacePresenter.observeVisibilityChanges { [weak self] visibleTab in
            guard let self else { return }
            if visibleTab == nil {
                self.resetSemanticTransientState()
            }
            self.synchronizeSession()
        }
        synchronizeSession()
    }

    func state() -> SemanticAdapterRuntimeState {
        synchronizeSession()
        if prefersWorkspaceSession,
           let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding,
           let presentation = provider.interactionPresentation {
            let overlayFrame = provider.semanticOverlayFrame
            return SemanticAdapterRuntimeState(
                isPanelOpen: workspacePresenter.visibleTab != nil,
                selectedItemID: presentation.selectedDisplayID,
                permissionState: permissionState(),
                panelGeometry: nil,
                currentTab: presentation.selectedTab,
                appPage: presentation.selectedAppPage,
                gesturePhase: semanticGesturePhase,
                overlayDisplayID: provider.semanticOverlayDisplayID,
                pointerDisplayID: provider.semanticPointerDisplayID,
                overlayFrame: overlayFrame.map {
                    SemanticWorkspaceFrame(
                        x: $0.origin.x,
                        y: $0.origin.y,
                        width: $0.size.width,
                        height: $0.size.height
                    )
                },
                selectedTargetKind: semanticSelectedTargetKind,
                selectedTargetIdentity: semanticSelectedTargetIdentity,
                dryRunSelectionConfirmed: semanticDryRunSelectionConfirmed,
                tabTransitionRevision: presentation.tabTransitionRevision,
                tabSettledRevision: presentation.tabSettledRevision,
                displayCardTransitionRevision: presentation.displayCardAnimationIdentity.terminalRevision,
                displayCardSettledRevision: presentation.displayCardSettledRevision
            )
        }
        let model = session?.model
        let snapshot = session?.snapshot
        return SemanticAdapterRuntimeState(
            isPanelOpen: model?.isOpen == true,
            selectedItemID: model?.selectedItemID,
            permissionState: permissionState(),
            panelGeometry: nil,
            currentTab: workspacePresenter.visibleTab ?? .switch,
            gesturePhase: semanticGesturePhase,
            overlayDisplayID: snapshot?.displays.first(where: \.isCurrent)?.id,
            pointerDisplayID: runtimeState.semanticSnapshot().displays.first(where: \.isCurrent)?.id,
            overlayFrame: snapshot?.displays.first(where: \.isCurrent).map {
                SemanticWorkspaceFrame(
                    x: $0.frame.x,
                    y: $0.frame.y,
                    width: $0.frame.width,
                    height: $0.frame.height
                )
            },
            selectedTargetKind: semanticSelectedTargetKind,
            selectedTargetIdentity: semanticSelectedTargetIdentity,
            dryRunSelectionConfirmed: semanticDryRunSelectionConfirmed
        )
    }

    func snapshot() -> SwitcherSnapshot {
        synchronizeSession()
        if prefersWorkspaceSession,
           let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding,
           let snapshot = provider.frozenSessionSnapshot {
            return snapshot
        }
        return session?.snapshot ?? runtimeState.semanticSnapshot()
    }

    func openPanel() {
        guard !isTornDown else { return }
        if workspacePresenter.visibleTab != .switch {
            workspacePresenter.toggle(tab: .switch)
        }
        synchronizeSession()
    }

    func openWorkspace(tab: WorkspaceTab) {
        guard !isTornDown else { return }
        if workspacePresenter.visibleTab == nil {
            resetSemanticDryRunSelection()
        }
        if workspacePresenter.visibleTab == nil || workspacePresenter.visibleTab != tab {
            workspacePresenter.toggle(tab: tab)
        }
        synchronizeSession()
    }

    func sendWorkspaceKey(_ key: WorkspaceKeyCommand) -> Bool {
        guard !isTornDown,
              let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding,
              provider.interactionPresentation != nil else { return false }
        return provider.sendInteraction(.key(key))
    }

    func selectWorkspaceDryRunTarget(_ key: WorkspaceKeyCommand) -> Bool {
        guard !isTornDown,
              let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding,
              let presentation = provider.interactionPresentation,
              presentation.selectedTab == .switch,
              let snapshot = provider.frozenSessionSnapshot else { return false }

        switch key {
        case let .appLetter(index):
            guard (0..<26).contains(index),
                  let workspace = snapshot.workspaces.first(where: {
                      $0.display.id == presentation.selectedDisplayID
                  }) else { return false }
            let appIndex = presentation.selectedAppPage * 26 + index
            guard workspace.apps.indices.contains(appIndex) else { return false }
            semanticSelectedTargetKind = "app"
            semanticSelectedTargetIdentity = workspace.apps[appIndex].id
        case let .displayIndex(displayedIndex):
            guard (1...3).contains(displayedIndex),
                  presentation.displayIDs.indices.contains(displayedIndex - 1) else { return false }
            semanticSelectedTargetKind = "display"
            semanticSelectedTargetIdentity = presentation.displayIDs[displayedIndex - 1]
        default:
            return false
        }
        semanticDryRunSelectionConfirmed = false
        return true
    }

    func sendWorkspaceGesture(_ gesture: SemanticWorkspaceGesture) -> Bool {
        guard !isTornDown,
              let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding,
              provider.interactionPresentation != nil else { return false }
        let input: WorkspaceGestureInput
        switch gesture.phase {
        case .began:
            guard activeSemanticGestureID == nil else { return false }
            let id = WorkspaceGestureSessionID(rawValue: gesture.id)
            activeSemanticGestureID = id
            semanticGesturePhase = "began"
            input = .began(
                sessionID: id,
                dx: gesture.deltaX,
                dy: gesture.deltaY,
                velocityX: gesture.velocityX,
                velocityY: gesture.velocityY
            )
        case .changed:
            guard let id = activeSemanticGestureID,
                  id.rawValue == gesture.id else { return false }
            semanticGesturePhase = "changed"
            input = .changed(
                sessionID: id,
                dx: gesture.deltaX,
                dy: gesture.deltaY,
                velocityX: gesture.velocityX,
                velocityY: gesture.velocityY
            )
        case .ended:
            guard let id = activeSemanticGestureID,
                  id.rawValue == gesture.id else { return false }
            activeSemanticGestureID = nil
            semanticGesturePhase = "ended"
            input = .ended(sessionID: id)
        case .cancelled:
            guard let id = activeSemanticGestureID,
                  id.rawValue == gesture.id else { return false }
            activeSemanticGestureID = nil
            semanticGesturePhase = "cancelled"
            input = .cancelled(sessionID: id)
        }
        return provider.sendInteraction(.gesture(input))
    }

    func executeWorkspaceDryRun() -> Bool {
        guard !isTornDown,
              semanticSelectedTargetIdentity != nil,
              let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding else {
            guard session?.model.isOpen == true, semanticSelectedTargetIdentity != nil else {
                return false
            }
            semanticDryRunSelectionConfirmed = true
            return true
        }
        guard provider.interactionPresentation != nil else { return false }
        semanticDryRunSelectionConfirmed = true
        return true
    }

    func select(itemID: String) -> Bool {
        guard !isTornDown else { return false }
        synchronizeSession()
        if prefersWorkspaceSession,
           let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding,
           provider.interactionPresentation?.displayIDs.contains(itemID) == true {
            return provider.sendInteraction(.selectDisplay(itemID))
        }
        return session?.model.select(itemID: itemID) ?? false
    }

    func executeSelected() async -> Result<Void, SwitcherActionFailure> {
        guard !isTornDown else { return .failure(.panelNotOpen) }
        synchronizeSession()
        if prefersWorkspaceSession,
           let provider = workspacePresenter as? any WorkspaceInteractionSessionProviding {
            return provider.interactionPresentation == nil
                ? .failure(.panelNotOpen)
                : .failure(.executeNotAllowed)
        }
        guard let executingSession = session else {
            return .failure(.panelNotOpen)
        }
        let result = await executingSession.model.executeSelected()
        if session?.model === executingSession.model {
            if workspacePresenter.visibleTab != nil {
                workspacePresenter.close(reason: .programmatic)
            } else {
                discardSession()
            }
        }
        synchronizeSession()
        return result
    }

    func permissionState() -> SemanticAdapterPermissionState {
        switch runtimeState.runningAppCatalog.permissionState() {
        case .granted:
            return .granted
        case .accessibilityMissing:
            return .accessibilityMissing
        }
    }

    func closePanel() {
        guard !isTornDown else { return }
        if workspacePresenter.visibleTab != nil {
            workspacePresenter.close(reason: .programmatic)
        } else if session != nil {
            discardSession()
        }
        resetSemanticTransientState()
        synchronizeSession()
    }

    private func synchronizeSession() {
        guard !isTornDown else {
            discardSession()
            return
        }
        guard workspacePresenter.visibleTab == .switch else {
            discardSession()
            return
        }
        if prefersWorkspaceSession,
           workspacePresenter is any WorkspaceInteractionSessionProviding {
            discardSession()
            return
        }
        guard session == nil else { return }

        let snapshot = sessionManager.beginPanelSession()
        let model = headlessSessionFactory(snapshot)
        let newSession = Session(model: model, snapshot: snapshot)
        session = newSession
        model.open(snapshot: snapshot)
    }

    private func discardSession() {
        guard let session else { return }
        self.session = nil
        session.model.close(reason: .programmatic)
        sessionManager.endPanelSession()
    }

    private func resetSemanticDryRunSelection() {
        semanticSelectedTargetKind = nil
        semanticSelectedTargetIdentity = nil
        semanticDryRunSelectionConfirmed = false
    }

    private func resetSemanticTransientState() {
        activeSemanticGestureID = nil
        semanticGesturePhase = "idle"
        resetSemanticDryRunSelection()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        visibilityObservation?.cancel()
        visibilityObservation = nil
        discardSession()
    }
}

@MainActor
struct DefaultAppDelegateBootstrap {
    typealias WorkspaceFactory = @MainActor () -> (
        any FullscreenWorkspacePresenting
            & FullscreenWorkspaceVisibilityObserving
            & SwitcherPanelPresenting
    )
    typealias SemanticModelFactory = @MainActor (URL?) -> SwitcherSemanticModel
    typealias SemanticServerBuilder = @MainActor (
        FullscreenHeadlessSemanticRuntime,
        String?,
        ExecutionPolicy,
        URL?
    ) -> any SemanticAdapterServerControlling
    /// Task 10 v3 builder: constructs the ACTIVE production semantic server
    /// from a `FocusScreenController`. Replaces the v2 builder in the
    /// production bootstrap path.
    typealias FocusScreenSemanticServerBuilder = @MainActor (
        FocusScreenController,
        String?,
        ExecutionPolicy,
        URL?
    ) -> any SemanticAdapterServerControlling

    let panelPresenter: any SwitcherPanelPresenting
    let settingsPresenter: any SwitcherSettingsPresenting
    let applicationTerminator: any ApplicationTerminating
    let shortcutStore: ShortcutConfigurationStore
    let runtimeAdapterStartupPolicy: RuntimeAdapterStartupPolicy
    let semanticAdapterServerFactory: SemanticAdapterServerFactory

    static func make(environment: [String: String], bundleURL: URL) -> Self {
        // Task 10: the ACTIVE production semantic server is the v3
        // `SemanticFocusScreenServer` over `FocusScreenSemanticRuntime`. The
        // controller is the production focus-screen runtime.
        let focusScreenController = FocusScreenController.makeProductionInstance(
            topologyProvider: NSScreenTopologyProvider(),
            environment: environment
        )
        return makeFocusScreen(
            environment: environment,
            bundleURL: bundleURL,
            focusScreenController: focusScreenController,
            semanticModelFactory: { captureDirectory in
                _ = captureDirectory
                return SwitcherSemanticModel()
            },
            semanticServerBuilder: { controller, token, executionPolicy, metadataURL in
                SemanticFocusScreenServer(
                    runtime: FocusScreenSemanticRuntime(controller: controller),
                    mode: .devTest,
                    token: token,
                    executionPolicy: executionPolicy,
                    metadataURL: metadataURL
                )
            },
            shortcutStorage: nil,
            userDefaults: .standard
        )
    }

    /// Task 10 v3 production bootstrap. Builds the v3 semantic server from a
    /// `FocusScreenController` instead of the v2 workspace assembly.
    static func makeFocusScreen(
        environment: [String: String],
        bundleURL: URL,
        focusScreenController: FocusScreenController,
        semanticModelFactory: SemanticModelFactory,
        semanticServerBuilder: @escaping FocusScreenSemanticServerBuilder,
        shortcutStorage: (any ShortcutStorage)?,
        userDefaults: UserDefaults
    ) -> Self {
        let captureDirectory = environment["CS_DIAG_CAPTURE_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let workspace: any FullscreenWorkspacePresenting
            & FullscreenWorkspaceVisibilityObserving
            & SwitcherPanelPresenting = focusScreenController
        let semanticModel = semanticModelFactory(captureDirectory)
        let shortcuts = ShortcutConfigurationStore(
            storage: shortcutStorage,
            userDefaults: userDefaults,
            onTabTrigger: { [weak focusScreenController] tab, startedAt in
                focusScreenController?.toggle(
                    tab: tab,
                    globalShortcutStartedAtNanoseconds: startedAt
                )
            }
        )
        let startupPolicy = RuntimeAdapterStartupPolicy(
            environment: environment,
            isPackagedProduction: RuntimeAdapterStartupPolicy.isPackagedProduction(
                bundleURL: bundleURL,
                environment: environment
            )
        )
        let serverFactory: SemanticAdapterServerFactory = {
            let token = RuntimeAdapterStartupPolicy.registrationValue(
                in: environment,
                keys: RuntimeAdapterStartupPolicy.tokenEnvironmentKeys
            )
            let metadataPath = RuntimeAdapterStartupPolicy.registrationValue(
                in: environment,
                keys: RuntimeAdapterStartupPolicy.metadataEnvironmentKeys
            )
            let metadataURL = metadataPath.map { URL(fileURLWithPath: $0) }
            let executionPolicy = ExecutionPolicy(
                mode: environment["CS_DIAG_ALLOW_INPUT"] == "1" ? .execute : .dryRun,
                environment: environment
            )
            return semanticServerBuilder(
                focusScreenController,
                token,
                executionPolicy,
                metadataURL
            )
        }
        _ = semanticModel
        return Self(
            panelPresenter: workspace,
            settingsPresenter: DefaultSettingsPresenter(shortcutStore: shortcuts),
            applicationTerminator: NSApplicationTerminator(),
            shortcutStore: shortcuts,
            runtimeAdapterStartupPolicy: startupPolicy,
            semanticAdapterServerFactory: serverFactory
        )
    }

    static func make(
        environment: [String: String],
        bundleURL: URL,
        workspaceFactory: WorkspaceFactory,
        semanticModelFactory: SemanticModelFactory,
        semanticServerBuilder: @escaping SemanticServerBuilder,
        shortcutStorage: (any ShortcutStorage)?,
        userDefaults: UserDefaults
    ) -> Self {
        let captureDirectory = environment["CS_DIAG_CAPTURE_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let workspace = workspaceFactory()
        let semanticModel = semanticModelFactory(captureDirectory)
        let semanticAssembly = FullscreenSemanticAdapterAssembly(
            workspacePresenter: workspace,
            semanticModel: semanticModel
        )
        let shortcuts = ShortcutConfigurationStore(
            storage: shortcutStorage,
            userDefaults: userDefaults,
            onTabTrigger: { [weak workspace] tab, startedAt in
                workspace?.toggle(
                    tab: tab,
                    globalShortcutStartedAtNanoseconds: startedAt
                )
            }
        )
        let startupPolicy = RuntimeAdapterStartupPolicy(
            environment: environment,
            isPackagedProduction: RuntimeAdapterStartupPolicy.isPackagedProduction(
                bundleURL: bundleURL,
                environment: environment
            )
        )
        let serverFactory: SemanticAdapterServerFactory = { [semanticAssembly] in
            let token = RuntimeAdapterStartupPolicy.registrationValue(
                in: environment,
                keys: RuntimeAdapterStartupPolicy.tokenEnvironmentKeys
            )
            let metadataPath = RuntimeAdapterStartupPolicy.registrationValue(
                in: environment,
                keys: RuntimeAdapterStartupPolicy.metadataEnvironmentKeys
            )
            let metadataURL = metadataPath.map { URL(fileURLWithPath: $0) }
            let executionPolicy = ExecutionPolicy(
                mode: environment["CS_DIAG_ALLOW_INPUT"] == "1" ? .execute : .dryRun,
                environment: environment
            )
            return semanticServerBuilder(
                semanticAssembly.makeRuntime(),
                token,
                executionPolicy,
                metadataURL
            )
        }
        return Self(
            panelPresenter: workspace,
            settingsPresenter: DefaultSettingsPresenter(shortcutStore: shortcuts),
            applicationTerminator: NSApplicationTerminator(),
            shortcutStore: shortcuts,
            runtimeAdapterStartupPolicy: startupPolicy,
            semanticAdapterServerFactory: serverFactory
        )
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public enum MenuAction: String, CaseIterable {
        case openSwitcher = "menu.open-switcher"
        case settings = "menu.settings"
        case quit = "menu.quit"
    }

    private let panelPresenter: SwitcherPanelPresenting
    private let settingsPresenter: SwitcherSettingsPresenting
    private let applicationTerminator: ApplicationTerminating
    private let semanticAdapterLifecycle: SemanticAdapterLifecycleController
    private let shortcutTriggerRegistrar: any ShortcutTriggerRegistering
    private let shouldRegisterUserGlobalOpeners: Bool
    private let deferredMainActionScheduler: DeferredMainActionScheduler
    private let menuTrackingCanceller: MenuTrackingCanceller
    /// Phase 1A runtime start hook. When the production presenter is a
    /// `FocusScreenController`, `applicationDidFinishLaunching` awaits `start()`
    /// before prewarming and semantic-server readiness. `nil` for non-focus
    /// bootstrap paths (e.g. legacy tests).
    private let runtimeStarter: (any SwitcherRuntimeStarting)?
    /// Phase 1A termination hook. When present, `applicationWillTerminate`
    /// runs Reveal All → close HUD before stopping the semantic server.
    private let focusScreenTerminator: FocusScreenController?
    private var statusItem: NSStatusItem?
    private var isTerminating = false
    private var isStatusMenuTracking = false
    private var isOpenSwitcherScheduled = false

    public let menu: NSMenu
    public let shortcutStore: ShortcutConfigurationStore?

    public init(
        panelPresenter: SwitcherPanelPresenting,
        settingsPresenter: SwitcherSettingsPresenting,
        applicationTerminator: ApplicationTerminating,
        shortcutStore: ShortcutConfigurationStore? = nil,
        runtimeAdapterStartupPolicy: RuntimeAdapterStartupPolicy = RuntimeAdapterStartupPolicy(environment: [:], isPackagedProduction: true),
        semanticAdapterServerFactory: @escaping SemanticAdapterServerFactory = { nil },
        shortcutTriggerRegistrar: (any ShortcutTriggerRegistering)? = nil,
        deferredMainActionScheduler: @escaping DeferredMainActionScheduler = { action in
            DispatchQueue.main.async {
                action()
            }
        },
        menuTrackingCanceller: @escaping MenuTrackingCanceller = { menu in
            menu.cancelTracking()
        },
        runtimeStarter: (any SwitcherRuntimeStarting)? = nil,
        focusScreenTerminator: FocusScreenController? = nil
    ) {
        self.panelPresenter = panelPresenter
        self.settingsPresenter = settingsPresenter
        self.applicationTerminator = applicationTerminator
        self.shortcutStore = shortcutStore
        self.semanticAdapterLifecycle = SemanticAdapterLifecycleController(
            startupPolicy: runtimeAdapterStartupPolicy,
            serverFactory: semanticAdapterServerFactory
        )
        self.shortcutTriggerRegistrar = shortcutTriggerRegistrar ?? KeyboardShortcutsTriggerRegistrar()
        self.shouldRegisterUserGlobalOpeners = runtimeAdapterStartupPolicy.shouldRegisterUserGlobalOpeners
        self.deferredMainActionScheduler = deferredMainActionScheduler
        self.menuTrackingCanceller = menuTrackingCanceller
        // If the caller did not pass an explicit runtime starter, derive it
        // from the panel presenter when it is itself a FocusScreenController.
        if let runtimeStarter {
            self.runtimeStarter = runtimeStarter
        } else if let starter = panelPresenter as? any SwitcherRuntimeStarting {
            self.runtimeStarter = starter
        } else {
            self.runtimeStarter = nil
        }
        self.focusScreenTerminator = focusScreenTerminator ?? panelPresenter as? FocusScreenController
        self.menu = NSMenu(title: "Cozy Stage")
        super.init()
        configureMenu()
    }

    public override convenience init() {
        self.init(bootstrap: DefaultAppDelegateBootstrap.make(
            environment: ProcessInfo.processInfo.environment,
            bundleURL: Bundle.main.bundleURL
        ))
    }

    convenience init(bootstrap: DefaultAppDelegateBootstrap) {
        self.init(
            panelPresenter: bootstrap.panelPresenter,
            settingsPresenter: bootstrap.settingsPresenter,
            applicationTerminator: bootstrap.applicationTerminator,
            shortcutStore: bootstrap.shortcutStore,
            runtimeAdapterStartupPolicy: bootstrap.runtimeAdapterStartupPolicy,
            semanticAdapterServerFactory: bootstrap.semanticAdapterServerFactory
        )
    }

    public var menuItems: [NSMenuItem] {
        menu.items
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let captureDirectory = ProcessInfo.processInfo.environment["CS_DIAG_CAPTURE_DIRECTORY"],
           !captureDirectory.isEmpty {
            ProductWorkspaceEvidenceCapture.recordStartup(
                directory: URL(fileURLWithPath: captureDirectory, isDirectory: true),
                environment: ProcessInfo.processInfo.environment
            )
        }
        if let application = NSApp {
            application.setActivationPolicy(.accessory)
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.isVisible = true
            configureStatusItem(item)
            statusItem = item
        }
        if shouldRegisterUserGlobalOpeners {
            shortcutStore?.registerGlobalTriggers(using: shortcutTriggerRegistrar)
        }
        // Phase 1A: the bounded initial observation and Screen 1 bootstrap
        // (`FocusScreenController.start()`) MUST run before prewarming and
        // semantic-server readiness, and all observation events serialize
        // through the main actor. Chain start → prewarm → semantic start on the
        // main actor so the ordering is strict even though
        // `applicationDidFinishLaunching` itself is synchronous.
        if let starter = runtimeStarter {
            deferredMainActionScheduler { [weak self] in
                guard let self, !self.isTerminating else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isTerminating else { return }
                    do {
                        try await starter.start()
                    } catch {
                        // Observation failures are non-fatal at launch; the
                        // runtime remains in its empty bootstrap state and the
                        // semantic server / shortcuts still come up.
                    }
                    guard !self.isTerminating else { return }
                    self.prewarmAndStartSemanticServer()
                }
            }
        } else {
            prewarmAndStartSemanticServer()
        }
    }

    private func prewarmAndStartSemanticServer() {
        if panelPresenter is any SwitcherPanelPrewarming {
            deferredMainActionScheduler { [weak self] in
                guard let self,
                      !self.isTerminating,
                      let prewarmer = self.panelPresenter as? any SwitcherPanelPrewarming
                else { return }
                prewarmer.prewarmSwitcher()
            }
        }
        semanticAdapterLifecycle.start()
    }

    func configureStatusItem(_ item: NSStatusItem) {
        item.button?.toolTip = "Cozy Stage"
        item.button?.setAccessibilityLabel("Cozy Stage")
        item.button?.setAccessibilityTitle("Cozy Stage")
        item.button?.setAccessibilityIdentifier("screen-switcher.status-item")
        item.button?.image = Self.makeStatusItemImage()
        item.button?.imagePosition = .imageOnly
        item.menu = menu
    }

    static func makeStatusItemImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let arch = NSBezierPath()
            arch.move(to: NSPoint(x: 3.2, y: 4.8))
            arch.line(to: NSPoint(x: 3.2, y: 10.6))
            arch.curve(
                to: NSPoint(x: 9, y: 14.7),
                controlPoint1: NSPoint(x: 3.2, y: 13.2),
                controlPoint2: NSPoint(x: 5.6, y: 14.7)
            )
            arch.curve(
                to: NSPoint(x: 14.8, y: 10.6),
                controlPoint1: NSPoint(x: 12.4, y: 14.7),
                controlPoint2: NSPoint(x: 14.8, y: 13.2)
            )
            arch.line(to: NSPoint(x: 14.8, y: 4.8))
            arch.lineWidth = 1.7
            arch.lineCapStyle = .round
            arch.lineJoinStyle = .round
            arch.stroke()

            let stage = NSBezierPath()
            stage.move(to: NSPoint(x: 2.3, y: 3.9))
            stage.line(to: NSPoint(x: 15.7, y: 3.9))
            stage.lineWidth = 1.7
            stage.lineCapStyle = .round
            stage.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cozy Stage"
        return image
    }

    public func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        isOpenSwitcherScheduled = false
        if shouldRegisterUserGlobalOpeners {
            shortcutStore?.unregisterGlobalTrigger()
        }
        if let terminator = focusScreenTerminator {
            // Phase 1A termination order: Reveal All → close HUD → stop
            // semantic server. Reveal All is async (bounded AX commands).
            //
            // IMPORTANT: macOS does NOT keep the run loop alive after this
            // method returns, so a fire-and-forget `Task` can be cut off mid
            // Reveal All when the process exits — leaving windows hidden
            // off-Canvas on quit. (Pre-Task-9 termination was fully
            // synchronous.) Block here until Reveal All actually completes so
            // the restore commands are issued before the app dies.
            //
            // The async work is `@MainActor`. Because we are already on the
            // main actor, spinning the current run loop pumps the task's main
            // queue continuations so it can make progress while we wait. The
            // wait is bounded so a pathological hung AX call cannot freeze
            // quit forever.
            let deadline = Date(timeIntervalSinceNow: Self.terminationRevealAllTimeout)
            var didFinish = false
            Task { @MainActor [weak self] in
                await terminator.handleApplicationTermination()
                self?.semanticAdapterLifecycle.stop()
                didFinish = true
            }
            let runLoop = RunLoop.current
            while !didFinish, Date() < deadline {
                runLoop.run(until: Date(timeIntervalSinceNow: 0.005))
            }
        } else {
            panelPresenter.closeSwitcher()
            semanticAdapterLifecycle.stop()
        }
    }

    /// Best-effort upper bound for how long `applicationWillTerminate` should
    /// wait for the focus-screen Reveal All. Each restore command is itself
    /// bounded by the controller's command timeout, and the worst case restores
    /// one window per screen plus a small unminimize pass; this is purely a
    /// safety ceiling so a pathological hung AX call cannot freeze quit
    /// forever. In practice the bounded AX calls return in milliseconds.
    private static let terminationRevealAllTimeout: TimeInterval = 4.0

    public func dispatchMenuAction(identifier: String) {
        guard let action = MenuAction(rawValue: identifier) else { return }
        switch action {
        case .openSwitcher:
            if isStatusMenuTracking {
                menuTrackingCanceller(menu)
                isStatusMenuTracking = false
            }
            scheduleOpenSwitcher()
        case .settings:
            settingsPresenter.openSettings()
        case .quit:
            applicationTerminator.terminate()
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isStatusMenuTracking = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isStatusMenuTracking = false
    }

    @objc private func openSwitcher(_ sender: Any?) {
        dispatchMenuAction(identifier: MenuAction.openSwitcher.rawValue)
    }

    @objc private func openSettings(_ sender: Any?) {
        dispatchMenuAction(identifier: MenuAction.settings.rawValue)
    }

    @objc private func quit(_ sender: Any?) {
        dispatchMenuAction(identifier: MenuAction.quit.rawValue)
    }

    private func configureMenu() {
        menu.removeAllItems()
        menu.delegate = self
        menu.addItem(menuItem("Open Switcher", action: #selector(openSwitcher(_:)), identifier: .openSwitcher))
        menu.addItem(menuItem("Settings", action: #selector(openSettings(_:)), identifier: .settings))
        menu.addItem(menuItem("Quit", action: #selector(quit(_:)), identifier: .quit))
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        identifier: MenuAction
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(identifier.rawValue)
        return item
    }

    private func scheduleOpenSwitcher() {
        guard !isOpenSwitcherScheduled else { return }
        isOpenSwitcherScheduled = true
        deferredMainActionScheduler { [weak self] in
            guard let self else { return }
            self.isOpenSwitcherScheduled = false
            guard !self.isTerminating else { return }
            self.panelPresenter.openSwitcher()
        }
    }
}

@MainActor
private final class NoopSettingsPresenter: SwitcherSettingsPresenting {
    func openSettings() {}
}

@MainActor
private final class NSApplicationTerminator: ApplicationTerminating {
    func terminate() {
        NSApp.terminate(nil)
    }
}
