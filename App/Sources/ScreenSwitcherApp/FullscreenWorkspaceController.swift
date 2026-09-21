import AppKit
import SwiftUI

public enum WorkspaceCloseReason: Equatable, Sendable {
    case shortcutToggle
    case escape
    case applicationTermination
    case topologyUnavailable
    case programmatic
}

@MainActor
public protocol FullscreenWorkspacePresenting: AnyObject {
    var visibleTab: WorkspaceTab? { get }
    func toggle(tab: WorkspaceTab)
    func toggle(tab: WorkspaceTab, globalShortcutStartedAtNanoseconds: UInt64)
    func close(reason: WorkspaceCloseReason)
}

public extension FullscreenWorkspacePresenting {
    func toggle(tab: WorkspaceTab, globalShortcutStartedAtNanoseconds: UInt64) {
        _ = globalShortcutStartedAtNanoseconds
        toggle(tab: tab)
    }
}

@MainActor
protocol FullscreenWorkspaceVisibilityObserving: AnyObject {
    func observeVisibilityChanges(
        _ observer: @escaping @MainActor (WorkspaceTab?) -> Void
    ) -> WorkspaceVisibilityObservation
}

@MainActor
final class WorkspaceVisibilityObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
    }

    deinit {
        cancellation?()
    }
}

@MainActor
public struct WorkspaceScreen {
    public let id: String
    public let frame: CGRect
    public let nativeScreen: NSScreen?

    public init(id: String, frame: CGRect, nativeScreen: NSScreen? = nil) {
        self.id = id
        self.frame = frame
        self.nativeScreen = nativeScreen
    }
}

@MainActor
public struct WorkspaceScreenTopology {
    public let screens: [WorkspaceScreen]
    public let pointerScreenID: String?

    public init(screens: [WorkspaceScreen], pointerScreenID: String?) {
        self.screens = screens
        self.pointerScreenID = pointerScreenID
    }
}

@MainActor
public protocol WorkspaceScreenTopologyObserving: AnyObject {
    func cancel()
}

@MainActor
public protocol ScreenTopologyProviding: AnyObject {
    func currentTopology() -> WorkspaceScreenTopology
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any WorkspaceScreenTopologyObserving
}

@MainActor
public final class NSScreenTopologyProvider: ScreenTopologyProviding {
    private let notificationCenter: NotificationCenter

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    public func currentTopology() -> WorkspaceScreenTopology {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { screen in
            WorkspaceScreen(id: Self.id(for: screen), frame: screen.frame, nativeScreen: screen)
        }
        let pointerID = screens.first(where: { $0.frame.contains(pointer) })?.id
            ?? screens.first?.id
        return WorkspaceScreenTopology(screens: screens, pointerScreenID: pointerID)
    }

    public func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any WorkspaceScreenTopologyObserving {
        let token = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return NotificationScreenTopologyObservation(notificationCenter: notificationCenter, token: token)
    }

    private static func id(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        let frame = screen.frame
        return "display-\(frame.minX)-\(frame.minY)-\(frame.width)-\(frame.height)"
    }
}

@MainActor
private final class NotificationScreenTopologyObservation: WorkspaceScreenTopologyObserving {
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(notificationCenter: NotificationCenter, token: NSObjectProtocol) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    func cancel() {
        guard let token else { return }
        notificationCenter.removeObserver(token)
        self.token = nil
    }

    deinit {
        guard let token else { return }
        notificationCenter.removeObserver(token)
    }
}

public enum WorkspaceWindowRole: Equatable, Sendable {
    case interactive
    case dimming
}

@MainActor
public struct WorkspaceWindowConfiguration {
    public let displayID: String
    public let frame: CGRect
    public let role: WorkspaceWindowRole
    public let rootView: AnyView?

    public init(displayID: String, frame: CGRect, role: WorkspaceWindowRole, rootView: AnyView?) {
        self.displayID = displayID
        self.frame = frame
        self.role = role
        self.rootView = rootView
    }
}

@MainActor
public protocol WorkspaceWindowControlling: AnyObject {
    var displayID: String { get }
    var role: WorkspaceWindowRole { get }
    var escapeHandler: (@MainActor () -> Void)? { get set }
    func setFrame(_ frame: CGRect)
    func setRootView(_ rootView: AnyView)
    func observeFirstExposure(
        _ handler: @escaping @MainActor () -> Void
    ) -> WorkspaceWindowExposureObservation?
    func show(makeKey: Bool)
    func close()
}

@MainActor
public final class WorkspaceWindowExposureObservation {
    private var cancellation: (() -> Void)?

    public init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
    }

    deinit {
        cancellation?()
    }
}

public extension WorkspaceWindowControlling {
    func observeFirstExposure(
        _ handler: @escaping @MainActor () -> Void
    ) -> WorkspaceWindowExposureObservation? {
        _ = handler
        return nil
    }
}

@MainActor
public protocol WorkspaceWindowCreating: AnyObject {
    func makeWindow(configuration: WorkspaceWindowConfiguration) -> any WorkspaceWindowControlling
}

@MainActor
final class WorkspacePanel: NSPanel {
    private let acceptsKeyWindow: Bool
    var escapeAction: (@MainActor () -> Void)?

    init(frame: CGRect, role: WorkspaceWindowRole) {
        acceptsKeyWindow = role == .interactive
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { acceptsKeyWindow }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        escapeAction?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            escapeAction?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
public final class AppKitWorkspaceWindow: WorkspaceWindowControlling {
    public let displayID: String
    public let role: WorkspaceWindowRole
    let panel: WorkspacePanel

    public var escapeHandler: (@MainActor () -> Void)? {
        didSet { panel.escapeAction = escapeHandler }
    }

    init(configuration: WorkspaceWindowConfiguration) {
        displayID = configuration.displayID
        role = configuration.role
        panel = WorkspacePanel(frame: configuration.frame, role: configuration.role)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = configuration.role == .dimming
        panel.animationBehavior = .none
        if configuration.role == .interactive {
            panel.setAccessibilityIdentifier("screen-switcher.workspace.window")
            panel.setAccessibilityLabel("Screen Switcher Workspace")
        }
        if let rootView = configuration.rootView {
            panel.contentView = NSHostingView(rootView: rootView)
        } else {
            let dimmingView = NSView(frame: configuration.frame)
            dimmingView.wantsLayer = true
            dimmingView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            panel.contentView = dimmingView
        }
    }

    public func setFrame(_ frame: CGRect) {
        panel.setFrame(frame, display: false)
    }

    public func setRootView(_ rootView: AnyView) {
        if let hosting = panel.contentView as? NSHostingView<AnyView> {
            hosting.rootView = rootView
        } else {
            panel.contentView = NSHostingView(rootView: rootView)
        }
    }

    public func observeFirstExposure(
        _ handler: @escaping @MainActor () -> Void
    ) -> WorkspaceWindowExposureObservation? {
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: panel,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return WorkspaceWindowExposureObservation {
            center.removeObserver(token)
        }
    }

    public func show(makeKey: Bool) {
        if makeKey, role == .interactive {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    public func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

@MainActor
public final class AppKitWorkspaceWindowFactory: WorkspaceWindowCreating {
    public init() {}

    public func makeWindow(configuration: WorkspaceWindowConfiguration) -> any WorkspaceWindowControlling {
        AppKitWorkspaceWindow(configuration: configuration)
    }
}

@MainActor
public protocol WorkspaceApplicationActivating: AnyObject {
    func activate()
}

@MainActor
public final class AppKitWorkspaceApplicationActivator: WorkspaceApplicationActivating {
    public init() {}

    public func activate() {
        NSApp.activate()
    }
}

@MainActor
public protocol WorkspaceHostingContentProviding {
    func rootView(session: WorkspacePanelSession, backdrop: WorkspaceBackdrop) -> AnyView
}

@MainActor
public final class LifecycleWorkspaceHostingContent: WorkspaceHostingContentProviding {
    let runtimeState: SwitcherRuntimeState
    let iconProvider: any RunningAppIconProviding

    public init() {
        let pointerLocation = NSEventPointerLocationProvider()
        let runningAppCatalog = RunningAppCatalog()
        runtimeState = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(pointerLocation: pointerLocation),
            runningAppCatalog: runningAppCatalog,
            pointerLocation: pointerLocation,
            frontmostState: NSWorkspaceFrontmostStateProvider()
        )
        iconProvider = runningAppCatalog.iconProvider
    }

    public func rootView(session: WorkspacePanelSession, backdrop: WorkspaceBackdrop) -> AnyView {
        return AnyView(FullscreenWorkspaceView(
            interactionModel: session.interactionModel,
            backdrop: backdrop,
            accessibilityEnvironment: session.accessibilityEnvironment,
            iconSession: session.iconSession,
            previewProvider: session.previewProvider
        ))
    }
}

@MainActor
public final class WorkspacePanelSession {
    public private(set) var snapshot: SwitcherSnapshot
    public let interactionModel: WorkspaceInteractionModel
    public let iconSession: RunningAppIconSession
    public let previewProvider: any DisplayPreviewProviding
    public let accessibilityEnvironment: WorkspaceAccessibilityEnvironment
    private let resolvesIcons: Bool

    init(
        snapshot: SwitcherSnapshot,
        interactionModel: WorkspaceInteractionModel,
        iconSession: RunningAppIconSession,
        previewProvider: any DisplayPreviewProviding,
        accessibilityEnvironment: WorkspaceAccessibilityEnvironment,
        resolvesIcons: Bool
    ) {
        self.snapshot = resolvesIcons
            ? Self.synchronizeIconAvailability(in: snapshot, with: iconSession)
            : snapshot
        self.interactionModel = interactionModel
        self.iconSession = iconSession
        self.previewProvider = previewProvider
        self.accessibilityEnvironment = accessibilityEnvironment
        self.resolvesIcons = resolvesIcons
    }

    func close() {
        previewProvider.close()
    }

    func update(snapshot: SwitcherSnapshot) {
        let synchronizedSnapshot: SwitcherSnapshot
        if resolvesIcons {
            iconSession.preload(bundleIdentifiers: snapshot.workspaces.flatMap { $0.apps.map(\.id) })
            synchronizedSnapshot = Self.synchronizeIconAvailability(in: snapshot, with: iconSession)
        } else {
            synchronizedSnapshot = snapshot
        }
        guard self.snapshot != synchronizedSnapshot else { return }
        self.snapshot = synchronizedSnapshot
        interactionModel.synchronizeContent(SwitchWorkspaceContent(
            workspaces: synchronizedSnapshot.workspaces,
            selectedDisplayID: interactionModel.presentation.selectedDisplayID
        ))
    }

    private static func synchronizeIconAvailability(
        in snapshot: SwitcherSnapshot,
        with iconSession: RunningAppIconSession
    ) -> SwitcherSnapshot {
        func synchronize(_ app: RunningAppDescriptor) -> RunningAppDescriptor {
            RunningAppDescriptor(
                id: app.id,
                displayName: app.displayName,
                mostRecentWindow: app.mostRecentWindow,
                iconAvailability: iconSession.presentation(bundleIdentifier: app.id).availability
            )
        }

        return SwitcherSnapshot(
            displays: snapshot.displays,
            runningApps: snapshot.runningApps.map(synchronize),
            pointerLocation: snapshot.pointerLocation,
            frontmostAppID: snapshot.frontmostAppID,
            workspaces: snapshot.workspaces.map { workspace in
                DisplayWorkspaceSnapshot(
                    display: workspace.display,
                    apps: workspace.apps.map(synchronize),
                    previewAvailability: workspace.previewAvailability
                )
            }
        )
    }
}

@MainActor
protocol WorkspaceInteractionSessionProviding: AnyObject {
    var activeInteractionModel: WorkspaceInteractionModel? { get }
    var interactionPresentation: WorkspaceInteractionPresentation? { get }
    var frozenSessionSnapshot: SwitcherSnapshot? { get }
    var semanticOverlayDisplayID: String? { get }
    var semanticOverlayFrame: CGRect? { get }
    var semanticPointerDisplayID: String? { get }
    func sendInteraction(_ input: WorkspaceInteractionInput) -> Bool
}

@MainActor
private final class WorkspaceExecutionOrigin {
    weak var model: WorkspaceInteractionModel?
}

@MainActor
public final class FullscreenWorkspaceController: FullscreenWorkspacePresenting, FullscreenWorkspaceVisibilityObserving, SwitcherPanelPresenting, SwitcherPanelPrewarming, WorkspaceInteractionSessionProviding {
    private struct OwnedWindow {
        let role: WorkspaceWindowRole
        let window: any WorkspaceWindowControlling
    }

    public private(set) var visibleTab: WorkspaceTab?

    private let topologyProvider: any ScreenTopologyProviding
    private let windowFactory: any WorkspaceWindowCreating
    private let applicationActivator: any WorkspaceApplicationActivating
    private let backdropProvider: any WorkspaceBackdropProviding
    private let contentProvider: any WorkspaceHostingContentProviding
    private let sessionManager: any SwitcherPanelSessionManaging
    private let iconProvider: any RunningAppIconProviding
    private let previewProviderFactory: @MainActor () -> any DisplayPreviewProviding
    private let accessibilityEnvironmentFactory: @MainActor () -> WorkspaceAccessibilityEnvironment
    private let inputMonitor: WorkspaceInputMonitor
    private let executionRequestHandler: (@MainActor (WorkspaceExecutionRequest) -> Void)?
    private let executionCoordinator: WorkspaceExecutionCoordinator?
    private let evidenceCapture: (any ProductWorkspaceEvidenceCapturing)?
    private let dimmingPresentationEvidence: (any ProductWorkspaceDimmingPresentationRecording)?
    private let performanceTrace: (any ProductWorkspacePerformanceTracing)?
    private var panelSession: WorkspacePanelSession?
    private var windows: [String: OwnedWindow] = [:]
    private var topologyObservation: (any WorkspaceScreenTopologyObserving)?
    private var visibilityObservers: [UUID: @MainActor (WorkspaceTab?) -> Void] = [:]
    private var presentationRevision: UInt64 = 0
    private var executionTask: Task<Void, Never>?
    private var executionTaskToken: UUID?
    private var sessionOverlayDisplayID: String?
    private var sessionOverlayFrame: CGRect?
    private var currentPointerDisplayID: String?
    private var evidenceCaptureToken: (any ProductWorkspaceEvidenceCaptureToken)?
    private var evidenceCaptureDisplayID: String?
    private var performanceTraceToken: (any ProductWorkspacePerformanceTraceToken)?
    private var performanceTraceDisplayID: String?
    private var pendingGlobalShortcutStartNanoseconds: UInt64?
    private var sessionSnapshotObservation: SwitcherPanelSessionSnapshotObservation?

    public init(
        topologyProvider: any ScreenTopologyProviding,
        windowFactory: any WorkspaceWindowCreating,
        backdropProvider: any WorkspaceBackdropProviding,
        applicationActivator: (any WorkspaceApplicationActivating)? = nil,
        contentProvider: (any WorkspaceHostingContentProviding)? = nil,
        sessionManager: (any SwitcherPanelSessionManaging)? = nil,
        iconProvider: (any RunningAppIconProviding)? = nil,
        previewProviderFactory: (@MainActor () -> any DisplayPreviewProviding)? = nil,
        accessibilityEnvironmentFactory: (@MainActor () -> WorkspaceAccessibilityEnvironment)? = nil,
        inputMonitor: WorkspaceInputMonitor? = nil,
        executionRequestHandler: (@MainActor (WorkspaceExecutionRequest) -> Void)? = nil,
        executionExecutor: (any WorkspaceExecutionExecuting)? = nil,
        evidenceCapture: (any ProductWorkspaceEvidenceCapturing)? = nil,
        dimmingPresentationEvidence: (any ProductWorkspaceDimmingPresentationRecording)? = nil,
        performanceTrace: (any ProductWorkspacePerformanceTracing)? = nil
    ) {
        self.topologyProvider = topologyProvider
        self.windowFactory = windowFactory
        self.applicationActivator = applicationActivator ?? AppKitWorkspaceApplicationActivator()
        self.backdropProvider = backdropProvider
        let lifecycleContent = LifecycleWorkspaceHostingContent()
        self.contentProvider = contentProvider ?? lifecycleContent
        self.sessionManager = sessionManager ?? lifecycleContent.runtimeState
        self.iconProvider = iconProvider ?? lifecycleContent.iconProvider
        self.previewProviderFactory = previewProviderFactory ?? { DisplayPreviewProvider() }
        self.accessibilityEnvironmentFactory = accessibilityEnvironmentFactory ?? {
            WorkspaceAccessibilityEnvironment(initial: WorkspaceVisualEnvironment.system(appearance: .dark))
        }
        self.inputMonitor = inputMonitor ?? WorkspaceInputMonitor()
        self.executionRequestHandler = executionRequestHandler
        self.executionCoordinator = executionExecutor.map(WorkspaceExecutionCoordinator.init(executor:))
        self.evidenceCapture = evidenceCapture
        self.dimmingPresentationEvidence = dimmingPresentationEvidence
        self.performanceTrace = performanceTrace
    }

    public var activeInteractionModel: WorkspaceInteractionModel? { panelSession?.interactionModel }
    public var interactionPresentation: WorkspaceInteractionPresentation? { panelSession?.interactionModel.presentation }
    public var frozenSessionSnapshot: SwitcherSnapshot? { panelSession?.snapshot }
    var semanticOverlayDisplayID: String? { sessionOverlayDisplayID }
    var semanticOverlayFrame: CGRect? { sessionOverlayFrame }
    var semanticPointerDisplayID: String? { currentPointerDisplayID }

    public func sendInteraction(_ input: WorkspaceInteractionInput) -> Bool {
        panelSession?.interactionModel.send(input) ?? false
    }

    @discardableResult
    public func completeExecution(_ completion: WorkspaceExecutionCompletion) -> Bool {
        panelSession?.interactionModel.completeExecution(completion) ?? false
    }

    public convenience init() {
        let permissionService = PermissionService()
        let lifecycleContent = LifecycleWorkspaceHostingContent()
        let resolver = AccessibilityWindowActivationResolver(
            permissionService: permissionService
        )
        let executor = WorkspaceExecutionService(
            liveStateProvider: RuntimeWorkspaceExecutionLiveStateProvider(
                runtimeState: lifecycleContent.runtimeState,
                permissionService: permissionService
            ),
            accessibilityGate: PermissionWorkspaceAccessibilityGate(
                permissionService: permissionService
            ),
            pointerMover: CGWorkspacePointerMover(),
            appActivator: NSWorkspaceExistingAppActivator(),
            windowFocuser: AccessibilityWorkspaceWindowFocuser(resolver: resolver)
        )
        self.init(
            topologyProvider: NSScreenTopologyProvider(),
            windowFactory: AppKitWorkspaceWindowFactory(),
            backdropProvider: WorkspaceBackdropProvider(),
            contentProvider: lifecycleContent,
            sessionManager: lifecycleContent.runtimeState,
            iconProvider: lifecycleContent.iconProvider,
            executionExecutor: executor,
            evidenceCapture: ProductWorkspaceEvidenceCapture.configured(
                environment: ProcessInfo.processInfo.environment
            ),
            dimmingPresentationEvidence: ProductWorkspaceDimmingPresentationEvidence.configured(
                environment: ProcessInfo.processInfo.environment,
                bundleURL: Bundle.main.bundleURL
            ),
            performanceTrace: ProductWorkspacePerformanceTrace.configured(
                environment: ProcessInfo.processInfo.environment,
                bundleURL: Bundle.main.bundleURL
            )
        )
    }

    public func toggle(tab: WorkspaceTab) {
        toggle(tab: tab, globalShortcutStartedAtNanoseconds: nil)
    }

    public func toggle(tab: WorkspaceTab, globalShortcutStartedAtNanoseconds: UInt64) {
        toggle(tab: tab, globalShortcutStartedAtNanoseconds: Optional(globalShortcutStartedAtNanoseconds))
    }

    private func toggle(tab: WorkspaceTab, globalShortcutStartedAtNanoseconds: UInt64?) {
        if visibleTab == tab {
            close(reason: .shortcutToggle)
            return
        }

        let startsSession = panelSession == nil
        if startsSession {
            pendingGlobalShortcutStartNanoseconds = globalShortcutStartedAtNanoseconds
            let topology = topologyProvider.currentTopology()
            guard let pointerScreen = pointerScreen(in: topology) else {
                pendingGlobalShortcutStartNanoseconds = nil
                return
            }
            applicationActivator.activate()
            sessionOverlayDisplayID = pointerScreen.id
            sessionOverlayFrame = pointerScreen.frame
            currentPointerDisplayID = pointerScreen.id
            beginPanelSession(initialTab: tab, viewport: pointerScreen.frame.size)
            setVisibleTab(tab)
            if topologyObservation == nil {
                topologyObservation = topologyProvider.observeChanges { [weak self] in
                    self?.reconcile()
                }
            }
            reconcile(topology: topology)
        } else {
            _ = panelSession?.interactionModel.send(.selectTab(tab))
        }
        if topologyObservation == nil {
            topologyObservation = topologyProvider.observeChanges { [weak self] in
                self?.reconcile()
            }
        }
    }

    public func close(reason: WorkspaceCloseReason) {
        executionTask?.cancel()
        executionTask = nil
        executionTaskToken = nil
        cancelEvidenceCapture()
        cancelPerformanceTrace()
        pendingGlobalShortcutStartNanoseconds = nil
        guard visibleTab != nil || !windows.isEmpty || topologyObservation != nil || panelSession != nil else { return }
        presentationRevision &+= 1
        panelSession?.interactionModel.presentationDidChange = nil
        setVisibleTab(nil)
        windows.values.forEach { $0.window.close() }
        windows.removeAll()
        topologyObservation?.cancel()
        topologyObservation = nil
        inputMonitor.deactivate()
        sessionSnapshotObservation?.cancel()
        sessionSnapshotObservation = nil
        sessionOverlayDisplayID = nil
        sessionOverlayFrame = nil
        currentPointerDisplayID = nil
        if let panelSession {
            self.panelSession = nil
            panelSession.close()
            sessionManager.endPanelSession()
        }
    }

    public func openSwitcher() {
        toggle(tab: .switch)
    }

    public func prewarmSwitcher() {
        guard visibleTab == nil, panelSession == nil, windows.isEmpty else { return }
        let topology = topologyProvider.currentTopology()
        guard let pointerScreen = pointerScreen(in: topology) else { return }

        beginPanelSession(
            initialTab: .switch,
            viewport: pointerScreen.frame.size,
            activateInputMonitor: false,
            resolveIcons: false
        )
        guard let panelSession else {
            sessionManager.endPanelSession()
            return
        }

        let rootView = contentProvider.rootView(
            session: panelSession,
            backdrop: .semanticGradient
        )
        let window = windowFactory.makeWindow(configuration: WorkspaceWindowConfiguration(
            displayID: pointerScreen.id,
            frame: pointerScreen.frame,
            role: .interactive,
            rootView: rootView
        ))
        window.close()

        sessionSnapshotObservation?.cancel()
        sessionSnapshotObservation = nil
        self.panelSession = nil
        panelSession.close()
        sessionManager.endPanelSession()
    }

    public func closeSwitcher() {
        close(reason: .programmatic)
    }

    func observeVisibilityChanges(
        _ observer: @escaping @MainActor (WorkspaceTab?) -> Void
    ) -> WorkspaceVisibilityObservation {
        let id = UUID()
        visibilityObservers[id] = observer
        return WorkspaceVisibilityObservation { [weak self] in
            self?.visibilityObservers.removeValue(forKey: id)
        }
    }

    private func setVisibleTab(_ tab: WorkspaceTab?) {
        guard visibleTab != tab else { return }
        visibleTab = tab
        visibilityObservers.values.forEach { $0(tab) }
    }

    private func reconcile() {
        guard let visibleTab else { return }
        reconcile(topology: topologyProvider.currentTopology(), visibleTab: visibleTab)
    }

    private func reconcile(topology: WorkspaceScreenTopology) {
        guard let visibleTab else { return }
        reconcile(topology: topology, visibleTab: visibleTab)
    }

    private func reconcile(topology: WorkspaceScreenTopology, visibleTab: WorkspaceTab) {
        presentationRevision &+= 1
        let revision = presentationRevision
        let screens = validScreens(in: topology)
        let livePointerScreen = screens.first(where: { $0.id == topology.pointerScreenID }) ?? screens.first
        guard let pointerScreen = sessionOverlayDisplayID.flatMap({ overlayID in
            screens.first { $0.id == overlayID }
        }) ?? livePointerScreen else {
            close(reason: .topologyUnavailable)
            return
        }
        currentPointerDisplayID = livePointerScreen?.id

        let validIDs = Set(screens.map(\.id))
        for staleID in windows.keys.filter({ !validIDs.contains($0) }) {
            if staleID == evidenceCaptureDisplayID { cancelEvidenceCapture() }
            if staleID == performanceTraceDisplayID { cancelPerformanceTrace() }
            windows.removeValue(forKey: staleID)?.window.close()
        }

        for screen in screens {
            let role: WorkspaceWindowRole = screen.id == pointerScreen.id ? .interactive : .dimming
            if let owned = windows[screen.id], owned.role != role {
                if screen.id == evidenceCaptureDisplayID { cancelEvidenceCapture() }
                if screen.id == performanceTraceDisplayID { cancelPerformanceTrace() }
                owned.window.close()
                windows.removeValue(forKey: screen.id)
            }

            let rootView: AnyView?
            if role == .interactive {
                let backdrop = backdropProvider.resolveBackdrop(
                    for: screen.id,
                    screen: screen.nativeScreen
                ) { [weak self] backdrop in
                    self?.applyResolvedBackdrop(
                        backdrop,
                        displayID: screen.id,
                        tab: visibleTab,
                        revision: revision
                    )
                }
                rootView = panelSession.map { contentProvider.rootView(session: $0, backdrop: backdrop) }
            } else {
                rootView = nil
            }

            if let owned = windows[screen.id] {
                owned.window.setFrame(screen.frame)
                if let rootView { owned.window.setRootView(rootView) }
            } else {
                let window = windowFactory.makeWindow(configuration: WorkspaceWindowConfiguration(
                    displayID: screen.id,
                    frame: screen.frame,
                    role: role,
                    rootView: rootView
                ))
                if role == .interactive {
                    window.escapeHandler = { [weak self] in self?.close(reason: .escape) }
                }
                windows[screen.id] = OwnedWindow(role: role, window: window)
                if role == .interactive {
                    startPerformanceTraceIfPending(for: window)
                }
                window.show(makeKey: role == .interactive)
                if role == .interactive {
                    startEvidenceCapture(for: window)
                }
            }
        }
        recordDimmingPresentation(for: screens, interactiveDisplayID: pointerScreen.id)
    }

    private func recordDimmingPresentation(
        for screens: [WorkspaceScreen],
        interactiveDisplayID: String
    ) {
        guard let dimmingPresentationEvidence else { return }
        let dimmingWindows = screens.compactMap { screen -> ProductWorkspaceDimmingWindow? in
            guard screen.id != interactiveDisplayID,
                  let owned = windows[screen.id],
                  owned.role == .dimming else { return nil }
            return ProductWorkspaceDimmingWindow(
                displayID: screen.id,
                expectedFrame: screen.frame,
                window: owned.window
            )
        }
        dimmingPresentationEvidence.record(dimmingWindows)
    }

    private func startEvidenceCapture(for window: any WorkspaceWindowControlling) {
        cancelEvidenceCapture()
        evidenceCaptureToken = evidenceCapture?.startCapture(for: window)
        if evidenceCaptureToken != nil {
            evidenceCaptureDisplayID = window.displayID
        }
    }

    private func cancelEvidenceCapture() {
        evidenceCaptureToken?.cancel()
        evidenceCaptureToken = nil
        evidenceCaptureDisplayID = nil
    }

    private func suspendEvidenceCapture() {
        evidenceCaptureToken?.cancel()
        evidenceCaptureToken = nil
    }

    private func rearmEvidenceCapture(
        for model: WorkspaceInteractionModel,
        presentation: WorkspaceInteractionPresentation
    ) {
        guard panelSession?.interactionModel === model,
              let displayID = evidenceCaptureDisplayID,
              let owned = windows[displayID],
              owned.role == .interactive
        else { return }
        guard presentation.gestureAxis == nil,
              presentation.motionOffset == 0 else {
            suspendEvidenceCapture()
            return
        }
        startEvidenceCapture(for: owned.window)
    }

    private func startPerformanceTraceIfPending(for window: any WorkspaceWindowControlling) {
        guard let startNanoseconds = pendingGlobalShortcutStartNanoseconds else { return }
        pendingGlobalShortcutStartNanoseconds = nil
        cancelPerformanceTrace()
        performanceTraceToken = performanceTrace?.beginGlobalShortcutFirstExposure(
            startNanoseconds: startNanoseconds,
            for: window
        )
        if performanceTraceToken != nil {
            performanceTraceDisplayID = window.displayID
        }
    }

    private func cancelPerformanceTrace() {
        performanceTraceToken?.cancel()
        performanceTraceToken = nil
        performanceTraceDisplayID = nil
    }

    private func pointerScreen(in topology: WorkspaceScreenTopology) -> WorkspaceScreen? {
        let screens = validScreens(in: topology)
        return screens.first(where: { $0.id == topology.pointerScreenID }) ?? screens.first
    }

    private func validScreens(in topology: WorkspaceScreenTopology) -> [WorkspaceScreen] {
        var seen: Set<String> = []
        return topology.screens.filter { screen in
            guard !screen.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  screen.frame.width > 0,
                  screen.frame.height > 0,
                  screen.frame.minX.isFinite,
                  screen.frame.minY.isFinite,
                  screen.frame.width.isFinite,
                  screen.frame.height.isFinite
            else { return false }
            return seen.insert(screen.id).inserted
        }
    }

    private func applyResolvedBackdrop(
        _ backdrop: WorkspaceBackdrop,
        displayID: String,
        tab: WorkspaceTab,
        revision: UInt64
    ) {
        guard presentationRevision == revision,
              visibleTab == tab,
              let owned = windows[displayID],
              owned.role == .interactive
        else { return }
        guard let panelSession else { return }
        owned.window.setRootView(contentProvider.rootView(session: panelSession, backdrop: backdrop))
    }

    private func beginPanelSession(
        initialTab: WorkspaceTab,
        viewport: CGSize,
        activateInputMonitor: Bool = true,
        resolveIcons: Bool = true
    ) {
        guard panelSession == nil else { return }
        let snapshot = sessionManager.beginPanelSession()
        let selectedDisplayID = snapshot.workspaces.first(where: { $0.display.isCurrent })?.display.id
            ?? snapshot.workspaces.first?.display.id
        let content = SwitchWorkspaceContent(
            workspaces: snapshot.workspaces,
            selectedDisplayID: selectedDisplayID
        )
        let requestHandler: (@MainActor (WorkspaceExecutionRequest) -> Void)?
        let executionOrigin: WorkspaceExecutionOrigin?
        if let executionRequestHandler {
            requestHandler = executionRequestHandler
            executionOrigin = nil
        } else if executionCoordinator != nil {
            let origin = WorkspaceExecutionOrigin()
            requestHandler = { [weak self] request in
                guard let model = origin.model else { return }
                self?.execute(request, originatingFrom: model)
            }
            executionOrigin = origin
        } else {
            requestHandler = nil
            executionOrigin = nil
        }
        let model = WorkspaceInteractionModel(
            content: content,
            selectedTab: initialTab,
            pageCapacity: SwitchTabLayout(viewport: viewport, content: content).appGrid.pageCapacity,
            closeHandler: { [weak self] reason in self?.close(reason: reason) },
            executionRequestHandler: requestHandler
        )
        executionOrigin?.model = model
        model.presentationDidChange = { [weak self, weak model] presentation in
            guard let self,
                  let model,
                  self.panelSession?.interactionModel === model
            else { return }
            self.setVisibleTab(presentation.selectedTab)
            self.rearmEvidenceCapture(for: model, presentation: presentation)
        }
        let iconSession = RunningAppIconSession(provider: iconProvider)
        if resolveIcons {
            iconSession.preload(bundleIdentifiers: snapshot.workspaces.flatMap { $0.apps.map(\.id) })
        }
        panelSession = WorkspacePanelSession(
            snapshot: snapshot,
            interactionModel: model,
            iconSession: iconSession,
            previewProvider: previewProviderFactory(),
            accessibilityEnvironment: accessibilityEnvironmentFactory(),
            resolvesIcons: resolveIcons
        )
        sessionSnapshotObservation = sessionManager.observePanelSessionSnapshots {
            [weak self] snapshot in
            self?.panelSession?.update(snapshot: snapshot)
        }
        if activateInputMonitor {
            inputMonitor.activate { [weak model] input in
                model?.send(input) ?? false
            }
        }
    }

    private func execute(
        _ request: WorkspaceExecutionRequest,
        originatingFrom model: WorkspaceInteractionModel
    ) {
        executionTask?.cancel()
        let token = UUID()
        executionTaskToken = token
        executionTask = executionCoordinator?.handle(request) { [weak self, weak model] completion in
            guard let self,
                  let model,
                  self.executionTaskToken == token,
                  self.panelSession?.interactionModel === model
            else { return }
            self.executionTask = nil
            self.executionTaskToken = nil
            _ = model.completeExecution(completion)
        }
    }
}
