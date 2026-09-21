import AppKit
import Foundation
import ScreenDomainCore

/// Phase 1A runtime start hook. `AppDelegate.applicationDidFinishLaunching` calls
/// `start()` on this before prewarming and semantic-server readiness so the
/// bounded initial observation and Screen 1 bootstrap happen first.
///
/// `start()` performs the bounded initial observation, bootstraps Screen 1 from
/// the observed windows WITHOUT moving any window, and starts live observation.
/// All observation events serialize through the main actor.
@MainActor
public protocol SwitcherRuntimeStarting: AnyObject {
    func start() async throws
}

/// Lifecycle seam for the compact focus HUD. Decouples `FocusScreenController`
/// from the concrete `FocusHUDController` so the controller can be unit-tested
/// against an in-memory HUD stand-in. The real `FocusHUDController` conforms in
/// production.
@MainActor
protocol FocusHUDControlling: AnyObject {
    /// Lazily attach the HUD controller to its AppKit surface (prewarm).
    func attach()
    /// Refresh the in-memory HUD projection from the supplied domain state.
    func refresh(state: FocusScreenState)
    /// Present the compact panel.
    func present(
        inventoryRevision: UInt64,
        safeBounds: CanvasRect
    ) -> Result<Void, FocusHUDControllerPresentationError>
    /// Dismiss the compact panel without touching Screens.
    func close()
    /// Receives the intents emitted by the visible HUD.
    func setIntentHandler(_ handler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void)
    /// Distinguishes a real empty Screen from unavailable window discovery.
    func setWindowDiscoveryStatus(_ status: FocusHUDWindowDiscoveryStatus)
    /// Rebuild the snapshot in-place when the HUD was presented in loading
    /// state and inventory has since become ready.
    func rebuildSnapshotIfNeeded(inventoryRevision: UInt64, safeBounds: CanvasRect)
    /// Configure whether the HUD dismisses when the command modifier is released.
    func setDismissesOnModifierRelease(_ value: Bool)
    /// Advance keyboard focus to the next app in the HUD.
    func advanceFocusToNext()
    /// Activate the currently focused app and close the HUD.
    func activateFocusedApp()
    /// Directly set which window is focused (highlighted) in the HUD.
    func focusWindow(_ windowID: ManagedWindowID)
    /// The currently focused window ID, if any.
    var focusedWindowID: ManagedWindowID? { get }
}

@MainActor
protocol FocusHUDWindowMetadataRecording: FocusHUDWindowMetadataProviding {
    func record(_ window: ObservedWindow)
    func remove(windowID: ManagedWindowID)
}

struct NativeWindowApplication: Equatable {
    let appID: String
    let appName: String
    let isActive: Bool
    let isHidden: Bool

    init(
        appID: String,
        appName: String,
        isActive: Bool,
        isHidden: Bool = false
    ) {
        self.appID = appID
        self.appName = appName
        self.isActive = isActive
        self.isHidden = isHidden
    }
}

/// Phase 1A production runtime. Composes the Task 5–8 components into the
/// single Screen Switcher controller:
///
/// - `WindowObservationService` (Task 5) — bounded initial snapshot + live events.
/// - `FocusScreenState` + `FocusScreenReducer` (Tasks 1–2) — the domain core.
/// - `FocusHUDViewModel` / `FocusHUDController` (Task 8) — the compact HUD.
/// - `WindowPresentationCoordinator` (Task 6) — exact-window switch transactions.
/// - `PointerCoordinator` (Task 7) — exact-window pointer landing.
/// - `SafetyRecoveryCoordinator` (Task 6) — Reveal All recovery.
///
/// The controller is the production entry point returned by the bootstrap
/// factory. It conforms to `SwitcherPanelPresenting`, `SwitcherPanelPrewarming`
/// and `SwitcherRuntimeStarting`, and — as a Task 9 minimal bridge to the
/// existing `FullscreenSemanticAdapterAssembly` — to `FullscreenWorkspacePresenting`
/// and `FullscreenWorkspaceVisibilityObserving` via readback. The full v3
/// semantic server migration is owned by Task 10.
@MainActor
public final class FocusScreenController: SwitcherPanelPresenting, SwitcherPanelPrewarming, SwitcherRuntimeStarting {
    private let observationService: any WindowObservationService
    private let commandService: any WindowCommandService
    private let pointerLocation: @MainActor () -> CanvasPoint?
    private let pointerMove: @MainActor (CanvasPoint) -> Bool
    private let canvasProvider: @MainActor () -> CanvasRect
    private let hudSafeBoundsProvider: @MainActor () -> CanvasRect
    private let regionsProvider: @MainActor () -> [FocusSemanticCanvasRegion]
    private let hudController: any FocusHUDControlling
    private let metadataRecorder: (any FocusHUDWindowMetadataRecording)?
    private let accessibilityChecker: AccessibilityChecking
    private let nativeSpaceCatalog: (any NativeSpaceCataloging)?
    private let nativeWindowApplication: @MainActor (pid_t) -> NativeWindowApplication?
    private let frontmostApplicationID: @MainActor () -> String?
    private let activateApplication: @MainActor (String) -> Bool
    private let reopenApplication: @MainActor (String) -> Bool
    private let ownApplicationID: String?
    private let workspaceNotificationCenter: NotificationCenter?
    private let screenNotificationCenter: NotificationCenter?
    private let modifierFlagsProvider: @MainActor () -> NSEvent.ModifierFlags
    private let monotonicNowNanoseconds: @MainActor () -> UInt64
    private var currentWindowMetadata: [
        ManagedWindowID: (binding: WindowRuntimeBinding, title: String)
    ] = [:]

    /// Internal accessor for the semantic v3 runtime (Task 10) so it can read
    /// the HUD view model's published projection (page, intent) without
    /// duplicating UI state.
    var semanticHUDController: any FocusHUDControlling { hudController }
    private let commandTimeout: TimeInterval
    private static let commandTabHoldDelayNanoseconds: UInt64 = 200_000_000

    /// Post-transaction window frames keyed by `ManagedWindowID`. Populated by
    /// `refreshPresentedFrames()` after a switch commit / Reveal All so the
    /// semantic v3 snapshot can truthfully project each window's real on-/off-
    /// Canvas position (and therefore its visibility), instead of reporting the
    /// canonical (on-Canvas) frame for every window. A window absent from this
    /// map falls back to its `canonicalFrame`.
    private(set) var presentedFrames: [ManagedWindowID: CanvasRect] = [:]

    /// The real stitched-Canvas regions, sourced from the topology provider.
    /// Used by the semantic snapshot so scenarios can test on-/off-Canvas
    /// intersection against the actual display topology, not a placeholder.
    var semanticCanvasRegions: [FocusSemanticCanvasRegion] { regionsProvider() }

    /// Refreshes `presentedFrames` by reading each known window's live AX frame
    /// through the command service. Called after transactions that move windows
    /// (switch commit, Reveal All) so the snapshot reflects reality. Failures
    /// (vanished/unreadable window) leave the previous frame untouched.
    func refreshPresentedFrames() async {
        _ = await refreshPresentedFrames(whileCurrent: { true })
    }

    private func refreshPresentedFrames(
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        var nextPresentedFrames = presentedFrames
        for (windowID, _) in state.windows {
            guard whileCurrent() else { return false }
            guard let binding = bindings[windowID] else { continue }
            let snapshot = await commandService.snapshot(binding, timeout: commandTimeout)
            guard whileCurrent() else { return false }
            if let snapshot {
                nextPresentedFrames[windowID] = snapshot.frame
            }
        }
        guard whileCurrent() else { return false }
        presentedFrames = nextPresentedFrames
        return true
    }

    /// The authoritative domain state. Exposed read-only for tests and contract
    /// assertions; mutated only through the coordinators / reducer.
    private(set) public var state: FocusScreenState

    /// Test-only seam to install a reducer-produced state directly. Production
    /// code never calls this; it exists so integration tests can stage exact
    /// multi-screen topologies (e.g. a window on a background screen) that the
    /// Phase 1A reducer does not expose through a single public transition.
    func setStateForTest(_ next: FocusScreenState) {
        state = next
    }

    func setHUDActivationForTest(_ activation: FocusSemanticHUDActivation) {
        precondition(activation.isValidCombination)
        hudActivation = activation
        activeHUDActivationTransaction = nil
        isHUDActivationRevisionExhausted = activation.revision == UInt64.max
    }

    func awaitInventoryRefreshForTest() async {
        await inventoryRefreshTask?.value
    }

    func awaitHUDSelectionForTest() async {
        await hudSelectionTransactionTail?.value
    }

    /// Window runtime bindings keyed by `ManagedWindowID`. Built from the
    /// observation stream and kept in sync as windows are created/destroyed.
    private(set) var bindings: [ManagedWindowID: WindowRuntimeBinding] = [:]

    /// `true` once the compact HUD is showing. Drives the
    /// `FullscreenWorkspacePresenting.visibleTab` readback used by the
    /// (Task-9-bridged) semantic assembly.
    private var isHUDPresented = false
    private(set) var lastHUDPresentationError: FocusHUDControllerPresentationError?

    /// Whether `start()` has run and observation is live.
    private var isStarted = false
    private var isStarting = false
    private var isRefreshingInventory = false
    private var inventoryRefreshTask: Task<Void, Never>?
    private var inventoryRefreshRequested = false
    private var inventoryInvalidationRevision: UInt64 = 0
    private var hasPreparedHUDInventory = false
    private var deferredPresentationTask: Task<Void, Never>?
    private var deferredModifierMonitor: Any?
    private(set) var inventoryRevision: UInt64 = 0
    private(set) var inventoryStatus: FocusHUDWindowDiscoveryStatus = .loading
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var screenObserverTokens: [NSObjectProtocol] = []
    private var windowServerWindowIDs: Set<ManagedWindowID> = []
    private(set) var workspaceAppIDsByScreen: [FocusScreenID: Set<String>] = [:]
    private var focusedWindowID: ManagedWindowID?
    private var recentApplicationIDs: [String] = []
    private var hudAppIDsByFrozenWindowID: [ManagedWindowID: String] = [:]
    private var hudScreenIDByFrozenWindowID: [ManagedWindowID: FocusScreenID] = [:]
    private(set) var hudSelectionToken = UUID()
    private var hudSelectionTransactionTail: Task<Void, Never>?
    private(set) var hudActivation = FocusSemanticHUDActivation.idle
    private var activeHUDActivationTransaction: HUDActivationTransaction?
    private var isHUDActivationRevisionExhausted = false
    private var recoveryIncompatibleBindings: [ManagedWindowID: WindowRuntimeBinding] = [:]
    private var latestLifecycleRecoveryResult = SafetyRecoveryResult.complete

    private enum HUDPhysicalMutationBlock: Equatable {
        case none
        case permissionRecovery(UUID)
        case permissionReadiness
        case termination

        var isActive: Bool { self != .none }
    }

    private struct HUDActivationTransaction: Equatable {
        let revision: UInt64
        let selectionToken: UUID
    }

    private var hudPhysicalMutationBlock: HUDPhysicalMutationBlock = .none

    private enum NativeReconcileResult: Equatable {
        case fallback
        case authoritative
        case stale
    }

    /// Whether observers have been torn down (post-termination).
    private var isTornDown = false

    /// Deferred observers installed via `observeVisibilityChanges`. The legacy
    /// semantic assembly registers one observer; we replay HUD visibility to it.
    /// Each entry carries a unique token so removal is identity-stable without
    /// relying on closure pointer identity.
    private struct VisibilityObserver {
        let id: UUID
        let body: @MainActor (WorkspaceTab?) -> Void
    }
    private var visibilityObservers: [VisibilityObserver] = []

    init(
        observationService: any WindowObservationService,
        commandService: any WindowCommandService,
        pointerLocation: @escaping @MainActor () -> CanvasPoint?,
        pointerMove: @escaping @MainActor (CanvasPoint) -> Bool,
        canvasProvider: @escaping @MainActor () -> CanvasRect,
        hudSafeBoundsProvider: (@MainActor () -> CanvasRect)? = nil,
        regionsProvider: @escaping @MainActor () -> [FocusSemanticCanvasRegion],
        hudController: any FocusHUDControlling,
        commandTimeout: TimeInterval,
        modifierFlagsProvider: @escaping @MainActor () -> NSEvent.ModifierFlags = {
            NSEvent.modifierFlags
        },
        monotonicNowNanoseconds: @escaping @MainActor () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        accessibilityChecker: AccessibilityChecking? = nil,
        metadataRecorder: (any FocusHUDWindowMetadataRecording)? = nil,
        nativeSpaceCatalog: (any NativeSpaceCataloging)? = nil,
        nativeWindowApplication: @escaping @MainActor (pid_t) -> NativeWindowApplication? = { processIdentifier in
            guard let application = NSRunningApplication(processIdentifier: processIdentifier),
                  !application.isTerminated,
                  application.activationPolicy == .regular,
                  let appID = application.bundleIdentifier
            else { return nil }
            return NativeWindowApplication(
                appID: appID,
                appName: application.localizedName ?? appID,
                isActive: application.isActive,
                isHidden: application.isHidden
            )
        },
        frontmostApplicationID: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        activateApplication: @escaping @MainActor (String) -> Bool = { appID in
            NSRunningApplication.runningApplications(withBundleIdentifier: appID)
                .first(where: { !$0.isTerminated })?
                .activate(options: []) == true
        },
        reopenApplication: @escaping @MainActor (String) -> Bool = { appID in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: appID
            ) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            return true
        },
        ownApplicationID: String? = Bundle.main.bundleIdentifier,
        workspaceNotificationCenter: NotificationCenter? = nil,
        screenNotificationCenter: NotificationCenter? = nil
    ) {
        self.observationService = observationService
        self.commandService = commandService
        self.pointerLocation = pointerLocation
        self.pointerMove = pointerMove
        self.canvasProvider = canvasProvider
        self.hudSafeBoundsProvider = hudSafeBoundsProvider ?? canvasProvider
        self.regionsProvider = regionsProvider
        self.hudController = hudController
        self.metadataRecorder = metadataRecorder
        self.commandTimeout = commandTimeout
        self.modifierFlagsProvider = modifierFlagsProvider
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
        self.accessibilityChecker = accessibilityChecker ?? AXAccessibilityChecker()
        self.nativeSpaceCatalog = nativeSpaceCatalog
        self.nativeWindowApplication = nativeWindowApplication
        self.frontmostApplicationID = frontmostApplicationID
        self.activateApplication = activateApplication
        self.reopenApplication = reopenApplication
        self.ownApplicationID = ownApplicationID
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.screenNotificationCenter = screenNotificationCenter

        // Seed an empty Screen 1 so readbacks are valid before `start()`
        // completes. `start()` replaces this with the observed inventory.
        state = (try? FocusScreenReducer.bootstrap(currentWindows: [], id: "screen-1"))
            ?? FocusScreenState(
                screens: [FocusScreen(id: "screen-1", number: 1, lifecycle: .active)],
                windows: [:],
                activeScreenID: "screen-1",
                inspectedScreenID: "screen-1",
                revision: 1
            )
        hudController.setIntentHandler { [weak self] intent in
            self?.handleHUDIntent(intent)
        }
        if let appID = frontmostApplicationID() {
            recordApplicationActivation(appID)
        }
    }

    /// Production factory used by the bootstrap. Wires the real System*
    /// services, a concrete `FocusHUDController`, and canvas/regions providers
    /// derived from the live screen topology. The canvas is the union of all
    /// screens; each screen is one `FocusSemanticCanvasRegion`.
    static func makeProductionInstance(
        commandTimeout: TimeInterval = 1.5,
        topologyProvider: any ScreenTopologyProviding,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FocusScreenController {
        let observationService = SystemWindowObservationService()
        let commandService = SystemWindowCommandService()
        let metadataProvider = RunningAppWindowMetadataProvider()
        let permissionService = PermissionService()
        // The HUD controller needs a view model seeded with the empty
        // bootstrap state; `start()` and `openSwitcher()` refresh it.
        let seed = FocusScreenState(
            screens: [FocusScreen(id: "screen-1", number: 1, lifecycle: .active)],
            windows: [:],
            activeScreenID: "screen-1",
            inspectedScreenID: "screen-1",
            revision: 1
        )
        let viewModel = FocusHUDViewModel(
            state: seed,
            metadataProvider: metadataProvider,
            intentHandler: { _ in },
            accessibilityRequestHandler: {
                try? permissionService.requestAndOpenSettings(for: .accessibility)
            }
        )
        let canvasProvider: @MainActor () -> CanvasRect = {
            FocusScreenController.stitchedCanvas(from: topologyProvider.currentTopology())
        }
        let hudController = FocusHUDController(
            viewModel: viewModel,
            evidenceCapture: ProductWorkspaceEvidenceCapture.configured(
                environment: environment
            ),
            visualQualificationEnvironment: environment
        )
        let hudSafeBoundsProvider: @MainActor () -> CanvasRect = {
            let topology = topologyProvider.currentTopology()
            let pointerScreen = topology.pointerScreenID.flatMap { pointerID in
                topology.screens.first(where: { $0.id == pointerID })
            } ?? topology.screens.first
            guard let visibleFrame = pointerScreen?.nativeScreen?.visibleFrame else {
                return canvasProvider()
            }
            return CanvasRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        }
        let regionsProvider: @MainActor () -> [FocusSemanticCanvasRegion] = {
            FocusScreenController.semanticRegions(from: topologyProvider.currentTopology())
        }
        let pointerLocation: @MainActor () -> CanvasPoint? = {
            // NSEvent.mouseLocation is main-thread safe and returns screen
            // coordinates in the same bottom-left origin the focus canvas uses.
            let location = NSEvent.mouseLocation
            return CanvasPoint(x: location.x, y: location.y)
        }
        let pointerMove: @MainActor (CanvasPoint) -> Bool = { point in
            // The canvas is bottom-left origin; CoreGraphics is top-left. Flip
            // against the primary screen height for a best-effort landing. A
            // degraded move never invalidates an otherwise-successful focus.
            var cgPoint = CGPoint(x: point.x, y: point.y)
            if let mainScreen = NSScreen.main {
                cgPoint.y = mainScreen.frame.maxY - cgPoint.y
            }
            return CGWarpMouseCursorPosition(cgPoint) == .success
        }
        let controller = FocusScreenController(
            observationService: observationService,
            commandService: commandService,
            pointerLocation: pointerLocation,
            pointerMove: pointerMove,
            canvasProvider: canvasProvider,
            hudSafeBoundsProvider: hudSafeBoundsProvider,
            regionsProvider: regionsProvider,
            hudController: hudController,
            commandTimeout: commandTimeout,
            metadataRecorder: metadataProvider,
            nativeSpaceCatalog: SystemNativeSpaceCatalog(),
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
            screenNotificationCenter: .default
        )
        return controller
    }

    /// Computes the stitched Canvas as the smallest bounding rect containing
    /// every screen's frame.
    private static func stitchedCanvas(from topology: WorkspaceScreenTopology) -> CanvasRect {
        guard !topology.screens.isEmpty else {
            return CanvasRect(x: 0, y: 0, width: 1440, height: 900)
        }
        let minX = topology.screens.map { $0.frame.minX }.min() ?? 0
        let minY = topology.screens.map { $0.frame.minY }.min() ?? 0
        let maxX = topology.screens.map { $0.frame.maxX }.max() ?? 1440
        let maxY = topology.screens.map { $0.frame.maxY }.max() ?? 900
        return CanvasRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 1),
            height: max(maxY - minY, 1)
        )
    }

    /// One semantic canvas region per physical screen.
    private static func semanticRegions(from topology: WorkspaceScreenTopology) -> [FocusSemanticCanvasRegion] {
        topology.screens.map { screen in
            FocusSemanticCanvasRegion(
                id: screen.id,
                frame: CanvasRect(
                    x: screen.frame.minX,
                    y: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                scale: 1
            )
        }
    }

    // MARK: - SwitcherRuntimeStarting

    /// Performs the bounded initial observation, bootstraps Screen 1 from the
    /// observed windows WITHOUT moving any window, and starts live observation.
    /// All observation events serialize through the main actor.
    public func start() async throws {
        guard !isStarted, !isStarting, !isTornDown else { return }
        isStarting = true
        defer { isStarting = false }
        setInventoryStatus(.loading)
        // Cross-app window observation requires Accessibility. The HUD owns the
        // explicit request action; startup never opens a prompt or Settings.
        if !accessibilityChecker.isAccessibilityTrusted() {
            setInventoryStatus(.accessibilityRequired)
            throw PermissionFailure.accessibilityMissing
        }
        let snapshot: WindowObservationSnapshot
        do {
            snapshot = try await observationService.refreshSnapshot()
        } catch {
            setInventoryStatus(.unavailable)
            throw error
        }
        let observed = snapshot.windows
        let managedWindows = observed.map(Self.managedWindow(from:))
        focusedWindowID = observed.first(where: \.isFocused)?.id
        for observed in observed {
            bindings[observed.id] = observed.binding
            recordWindowMetadata(observed)
        }
        // Bootstrap Screen 1 from the observed inventory. If the reducer
        // rejects (e.g. duplicate ids), fall back to an empty active Screen 1
        // so the runtime never crashes on startup.
        if let bootstrapped = try? FocusScreenReducer.bootstrap(currentWindows: managedWindows, id: "screen-1") {
            state = bootstrapped
        }
        let nativeInventoryReady = await reconcileNativeSpaces(
            pendingMetadataRecords: observed
        ) == .authoritative
        // A live AX observer is an optimization after the snapshot has already
        // succeeded. Some apps reject observer registration; keep the complete
        // WindowServer/AX generation and refresh it on HUD/system events.
        try? observationService.start { [weak self] event in
            self?.handleObservationEvent(event)
        }
        isStarted = true
        startWorkspaceRecoveryObservation()
        if snapshot.completeness == .complete || nativeInventoryReady {
            if hudPhysicalMutationBlock == .permissionReadiness {
                hudPhysicalMutationBlock = .none
            }
            hasPreparedHUDInventory = true
            inventoryRevision &+= 1
        }
        if nativeInventoryReady {
            setInventoryStatus(.ready)
        } else {
            updateWindowDiscoveryStatus(for: snapshot)
        }
        if isHUDPresented {
            hudController.refresh(state: state)
            hudController.rebuildSnapshotIfNeeded(
                inventoryRevision: inventoryRevision,
                safeBounds: hudSafeBoundsProvider()
            )
            freezeHUDWindowMaps()
            requestWindowInventoryRefresh()
        }
    }

    // MARK: - SwitcherPanelPresenting

    public func openSwitcher() {
        guard !isTornDown else { return }
        invalidateHUDSelection()
        if let appID = frontmostApplicationID() {
            recordApplicationActivation(appID)
        }
        if !hasPreparedHUDInventory {
            setInventoryStatus(.loading)
        }
        if !isHUDPresented {
            freezeHUDWindowMaps()
        }
        hudController.refresh(state: state)
        let presentation = hudController.present(
            inventoryRevision: inventoryRevision,
            safeBounds: hudSafeBoundsProvider()
        )
        if case let .failure(error) = presentation {
            lastHUDPresentationError = error
            isHUDPresented = false
            hudAppIDsByFrozenWindowID = [:]
            return
        }
        lastHUDPresentationError = nil
        isHUDPresented = true
        // Dismiss on modifier release if any modifier is currently held (shortcut flow)
        let modifiersHeld = !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        hudController.setDismissesOnModifierRelease(modifiersHeld)
        notifyVisibility(.switch)
        if isStarted {
            requestWindowInventoryRefresh()
        } else {
            if accessibilityChecker.isAccessibilityTrusted() {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await self.start()
                    guard self.isHUDPresented else { return }
                    self.hudController.refresh(state: self.state)
                    self.hudController.rebuildSnapshotIfNeeded(
                        inventoryRevision: self.inventoryRevision,
                        safeBounds: self.hudSafeBoundsProvider()
                    )
                    self.freezeHUDWindowMaps()
                    // After a fresh accessibility grant the AX subsystem may
                    // need up to ~1s to fully propagate trust. If inventory is
                    // not ready after start(), wait once and let the existing
                    // requestWindowInventoryRefresh retry machinery handle it.
                    if !self.hasPreparedHUDInventory, self.isStarted {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard self.isHUDPresented, !self.isTornDown else { return }
                        self.requestWindowInventoryRefresh()
                    }
                }
            } else {
                setInventoryStatus(.accessibilityRequired)
            }
        }
    }

    public func closeSwitcher() {
        invalidateHUDSelection()
        dismissSwitcher()
    }

    private func dismissSwitcher() {
        guard !isTornDown else { return }
        hudController.close()
        isHUDPresented = false
        hudAppIDsByFrozenWindowID = [:]
        hudScreenIDByFrozenWindowID = [:]
        notifyVisibility(nil)
    }

    private func freezeHUDWindowMaps() {
        hudAppIDsByFrozenWindowID = state.windows.mapValues(\.appID)
        // Only freeze the screen map once per HUD session — subsequent
        // refreshes may corrupt it by reporting all windows on active Space.
        if hudScreenIDByFrozenWindowID.isEmpty {
            var screenMap: [ManagedWindowID: FocusScreenID] = [:]
            for screen in state.screens {
                for windowID in screen.windowIDs {
                    screenMap[windowID] = screen.id
                }
            }
            hudScreenIDByFrozenWindowID = screenMap
        }
    }

    // MARK: - SwitcherPanelPrewarming

    public func prewarmSwitcher() {
        hudController.attach()
        hudController.refresh(state: state)
        requestWindowInventoryRefresh()
    }

    // MARK: - Domain operations

    /// Creates a new blank (empty) Screen and promotes it to active. The
    /// previously-active Screen becomes background. Does not move windows.
    func createBlankScreen(id: FocusScreenID) throws {
        state = try FocusScreenReducer.createBlankScreen(in: state, id: id)
        hudController.refresh(state: state)
    }

    /// Begins the closing transition for `screenID`, marking it `.closing` and
    /// promoting a fallback live Screen to active/inspected. Mirrors the
    /// `createBlankScreen` reducer exposure so the semantic v3 runtime routes
    /// `screen.close` through the SAME controller intent the UI will use, rather
    /// than a test seam. Throws the reducer's typed error (e.g.
    /// `soleScreenCannotClose`, `screenMissing`, `invalidLifecycle`) so the
    /// semantic server can map each to its error code.
    func beginClosing(screenID: FocusScreenID) throws {
        state = try FocusScreenReducer.beginClosing(screenID: screenID, in: state)
        hudController.refresh(state: state)
    }

    /// Authenticated Diagnostics cleanup uses the ordinary close transitions, but
    /// an empty Screen has no window transaction that could later finish it.
    /// Complete that no-window close synchronously so a temporary visual-proof
    /// Screen cannot remain retained in `closing`.
    func closeScreenForSemanticDiagnostics(screenID: FocusScreenID) throws {
        let wasEmpty = state.screen(id: screenID)?.windowIDs.isEmpty == true
        state = try FocusScreenReducer.beginClosing(screenID: screenID, in: state)
        if wasEmpty {
            state = try FocusScreenReducer.finishClosing(screenID: screenID, in: state)
        }
        hudController.refresh(state: state)
    }

    func closeOwnedEmptyScreenForSemanticDiagnostics(
        expected: FocusSemanticScreen
    ) -> FocusSemanticOwnedScreenCloseOutcome {
        guard let screen = state.screen(id: expected.id) else { return .notFound }
        let current = FocusSemanticScreen(
            id: screen.id,
            number: screen.number,
            lifecycle: screen.lifecycle.rawValue,
            windowIDs: screen.windowIDs,
            activeWindowID: screen.lastActiveWindowID,
            layoutRevision: UInt64(state.revision)
        )
        guard current == expected else { return .ownershipLost }
        guard screen.windowIDs.isEmpty, screen.lastActiveWindowID == nil else { return .failed }
        do {
            var next = try FocusScreenReducer.beginClosing(screenID: screen.id, in: state)
            next = try FocusScreenReducer.finishClosing(screenID: screen.id, in: next)
            state = next
            hudController.refresh(state: state)
            return .closed
        } catch {
            return .failed
        }
    }

    /// Assigns an unowned window to the named Screen. Used by tests and (in
    /// later tasks) by the HUD's drag-to-screen interaction.
    func assign(windowID: ManagedWindowID, to screenID: FocusScreenID) throws {
        state = try FocusScreenReducer.assign(windowID: windowID, to: screenID, in: state)
        hudController.refresh(state: state)
    }

    // MARK: - Phase 1B: Space operations

    /// `space.save` — saves the active Screen's structure into a Saved Space
    /// and binds the Screen to it. Routes through the SAME
    /// `FocusSpaceReducer` transition the UI will use.
    func saveSpace(id: SavedSpaceID, name: String? = nil) throws {
        state = try FocusSpaceReducer.saveSpace(from: state, id: id, name: name)
        hudController.refresh(state: state)
    }

    /// `space.restore` — restores a restorable Saved Space into a Screen,
    /// rebuilding its structure. Enforces one-space-one-screen.
    func restoreSpace(_ spaceID: SavedSpaceID, into screenID: FocusScreenID) throws {
        state = try FocusSpaceReducer.restoreSpace(spaceID, into: screenID, in: state)
        hudController.refresh(state: state)
    }

    // MARK: - Phase 1C: Pane/Tab operations

    /// `layout.set` — sets the Layout kind for a Screen, creating the Pane
    /// structure.
    func setLayout(_ kind: LayoutKind, for screenID: FocusScreenID) throws {
        state = try FocusPaneReducer.setLayout(kind, for: screenID, in: state)
        hudController.refresh(state: state)
    }

    /// `tab.activate` — activates a Tab within a Pane.
    func activateTab(_ tabID: TabID, in paneID: PaneID, screenID: FocusScreenID) throws {
        state = try FocusPaneReducer.activateTab(tabID, in: paneID, screenID: screenID, state: state)
        hudController.refresh(state: state)
    }

    /// `tab.move` — moves a Tab to another Pane.
    func moveTab(_ tabID: TabID, to paneID: PaneID, screenID: FocusScreenID) throws {
        state = try FocusPaneReducer.moveTab(tabID, to: paneID, screenID: screenID, state: state)
        hudController.refresh(state: state)
    }

    /// `tab.close` — closes a Tab. Active → right-neighbor-first.
    func closeTab(_ tabID: TabID, in paneID: PaneID, screenID: FocusScreenID) throws {
        state = try FocusPaneReducer.closeTab(tabID, in: paneID, screenID: screenID, state: state)
        hudController.refresh(state: state)
    }

    /// `pane.resize` — sets the normalized Pane ratio.
    func setPaneRatio(_ paneID: PaneID, ratio: PaneRatio, screenID: FocusScreenID) throws {
        state = try FocusPaneReducer.setPaneRatio(paneID, ratio: ratio, screenID: screenID, state: state)
        hudController.refresh(state: state)
    }

    /// Runs an explicit HUD-driven Screen switch that targets a single window.
    /// Performs the full window transaction (Task 6) and applies the
    /// exact-window pointer landing policy (Task 7).
    func switchTo(screenID: FocusScreenID, targeting windowID: ManagedWindowID) async -> WindowPresentationResult {
        await switchTo(screenID: screenID, targeting: windowID, whileCurrent: { true })
    }

    private func switchTo(
        screenID: FocusScreenID,
        targeting windowID: ManagedWindowID,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowPresentationResult {
        guard whileCurrent() else { return .cancelled(recovery: nil) }
        var transactionState = state
        guard transactionState.windows[windowID] != nil else {
            return await revealAllAndFail(primary: .invalidTargetWindow(windowID))
        }
        // `screen.switch` means "switch to this Screen and bring this window
        // into it." If the window is not yet owned by the target Screen, route
        // (move) it there first via the domain reducer — removing it from its
        // current owner — so the switch transaction can focus it. This matches
        // the user's mental model (a Screen is a concrete-window grouping, not
        // a physical display) and the scenario contract.
        if transactionState.screen(id: screenID)?.windowIDs.contains(windowID) != true {
            for index in transactionState.screens.indices
                where transactionState.screens[index].windowIDs.contains(windowID) {
                transactionState.screens[index].windowIDs.removeAll { $0 == windowID }
                if transactionState.screens[index].lastActiveWindowID == windowID {
                    transactionState.screens[index].lastActiveWindowID =
                        transactionState.screens[index].windowIDs.last
                }
            }
            if let destination = transactionState.screens.firstIndex(where: { $0.id == screenID }) {
                transactionState.screens[destination].windowIDs.append(windowID)
                transactionState.screens[destination].lastActiveWindowID = windowID
                transactionState.revision &+= 1
            } else {
                return await revealAllAndFail(primary: .invalidScreen(screenID))
            }
        }
        guard whileCurrent() else { return .cancelled(recovery: nil) }
        guard let targetWindow = transactionState.windows[windowID] else {
            return await revealAllAndFail(primary: .invalidTargetWindow(windowID))
        }
        let currentBindings = bindings
        let transactionIsCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self, whileCurrent() else { return false }
            return self.bindings == currentBindings
        }
        guard transactionIsCurrent() else { return .cancelled(recovery: nil) }
        let oldScreen = transactionState.activeScreenID
        let presentation = WindowPresentationCoordinator(
            state: transactionState,
            bindings: currentBindings,
            stitchedCanvasRegions: regionsProvider().map(\.frame),
            commandService: commandService,
            commandTimeout: commandTimeout
        )
        let result = await presentation.switchScreen(
            from: oldScreen,
            to: screenID,
            targetWindowID: windowID,
            whileCurrent: transactionIsCurrent
        )
        guard transactionIsCurrent() else {
            let cancellation = await presentation.cancel()
            mergeCancellationRecovery(cancellation)
            return cancellation
        }
        if case .cancelled = result {
            mergeCancellationRecovery(result)
            return result
        }
        // Commit the coordinator's post-transaction state back into the
        // controller (it may have mutated compatibility flags during recovery).
        // Invalidate any inventory candidate captured before this transaction
        // so it cannot overwrite the newly committed active Screen.
        commitAsyncPresentationState(presentation.state)

        if case .committed = result {
            guard transactionIsCurrent() else { return .cancelled(recovery: nil) }
            _ = landPointer(on: targetWindow.canonicalFrame)
            // Read back each window's live AX frame so the semantic snapshot
            // can truthfully project on-/off-Canvas positions (parked
            // background-Screen windows vs. restored active-Screen windows).
            guard await refreshPresentedFrames(whileCurrent: transactionIsCurrent) else {
                return .cancelled(recovery: nil)
            }
        }
        return result
    }

    /// Handles accessibility permission loss: runs Reveal All so no window is
    /// left hidden off-Canvas. Recovery is best-effort; the result is exposed
    /// for diagnostics.
    @discardableResult
    func handlePermissionLoss() async -> SafetyRecoveryResult {
        if hudPhysicalMutationBlock == .termination {
            await hudSelectionTransactionTail?.value
            return latestLifecycleRecoveryResult
        }
        let recoveryToken = UUID()
        var result = SafetyRecoveryResult.complete
        await runHUDLifecycleMutation(.permissionRecovery(recoveryToken)) { [weak self] in
            guard let self else { return }
            result = await self.revealAll()
            self.latestLifecycleRecoveryResult = result
            if self.hudPhysicalMutationBlock == .permissionRecovery(recoveryToken) {
                self.hudPhysicalMutationBlock = .permissionReadiness
            }
        }
        return result
    }

    /// App termination hook. Settles any in-flight HUD mutation, runs Reveal All,
    /// dismisses the HUD, THEN tears down observers. Reveal All must run before
    /// teardown so observers are still alive to confirm window restores.
    ///
    /// This method is async because `SafetyRecoveryCoordinator.revealAll` issues
    /// async AX commands. `AppDelegate.applicationWillTerminate` invokes it from
    /// a `Task` on the main actor and blocks (via a bounded run-loop spin) until
    /// it completes, so Reveal All actually runs before the process exits; the
    /// internal ordering — settle HUD mutation → Reveal All → close HUD → stop
    /// observers — is strict.
    func handleApplicationTermination() async {
        guard !isTornDown else { return }
        await runHUDLifecycleMutation(.termination) { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.latestLifecycleRecoveryResult = await self.revealAll()
            self.dismissSwitcher()
            self.inventoryRefreshTask?.cancel()
            self.inventoryRefreshTask = nil
            self.inventoryRefreshRequested = false
            self.stopWorkspaceRecoveryObservation()
            self.observationService.stop()
            self.isTornDown = true
            self.isStarted = false
        }
    }

    /// Semantic diagnostics seam (Task 10). Forwards a translated HUD key through the
    /// SAME `FocusHUDViewModel.handle` path the UI uses (Task 8), so the diagnostics
    /// and the keyboard monitor drive one intent pipeline. Returns the resulting
    /// `FocusHUDOverviewIntent` so the semantic server can report side effects without
    /// inspecting UI state. Returns `.none` when the HUD is closed or torn down.
    @discardableResult
    func sendHUDKey(_ key: FocusHUDOverviewKey) -> FocusHUDOverviewIntent {
        guard isHUDPresented, !isTornDown else { return .none }
        guard let viewModel = (hudController as? FocusHUDController)?.viewModel else {
            return .none
        }
        return viewModel.handle(key: key)
    }

    /// Returns whether the compact HUD is currently presented. Exposed for the
    /// semantic v3 runtime so its snapshot projection reads the same visibility
    /// flag the UI drives.
    var isHUDVisible: Bool { isHUDPresented }

    // MARK: - Observation handling

    /// Reconciles the live AX inventory into the Screen domain without
    /// rebuilding Screen ownership. A partial scan may add or refresh known
    /// windows, but only a complete scan may remove missing windows.
    @discardableResult
    func refreshWindowInventory() async -> Bool? {
        guard isStarted, !isTornDown, !isRefreshingInventory else { return nil }
        isRefreshingInventory = true
        defer { isRefreshingInventory = false }

        guard accessibilityChecker.isAccessibilityTrusted() else {
            setInventoryStatus(.accessibilityRequired)
            return nil
        }
        if !hasPreparedHUDInventory {
            setInventoryStatus(.loading)
        }
        let refreshRevision = inventoryInvalidationRevision

        let snapshot: WindowObservationSnapshot
        do {
            snapshot = try await observationService.refreshSnapshot()
        } catch {
            guard !isTornDown else { return nil }
            if !hasPreparedHUDInventory {
                setInventoryStatus(.unavailable)
            }
            return nil
        }
        guard !isTornDown else { return nil }

        var candidateState = state
        var candidateBindings = bindings
        var pendingMetadataRecords: [ObservedWindow] = []
        let observedIDs = Set(snapshot.windows.map(\.id))
        for observed in snapshot.windows {
            candidateBindings[observed.id] = observed.binding
            pendingMetadataRecords.append(observed)
            if candidateState.windows[observed.id] == nil,
               let next = try? FocusScreenReducer.registerUnowned(
                   Self.managedWindow(from: observed),
                   in: candidateState
               ) {
                candidateState = next
            }
        }
        if snapshot.completeness == .complete {
            let missingWindowIDs = candidateState.windows.keys.filter { windowID in
                guard !observedIDs.contains(windowID) else { return false }
                if let binding = candidateBindings[windowID],
                   case .windowServer = binding.axElement {
                    return false
                }
                return true
            }
            for windowID in missingWindowIDs {
                candidateBindings.removeValue(forKey: windowID)
                candidateState.windows.removeValue(forKey: windowID)
                for index in candidateState.screens.indices {
                    candidateState.screens[index].windowIDs.removeAll { $0 == windowID }
                    if candidateState.screens[index].lastActiveWindowID == windowID {
                        candidateState.screens[index].lastActiveWindowID =
                            candidateState.screens[index].windowIDs.last
                    }
                }
                candidateState.revision &+= 1
            }
        }

        let nativeResult = await reconcileNativeSpaces(
            baseState: candidateState,
            baseBindings: candidateBindings,
            pendingMetadataRecords: pendingMetadataRecords,
            expectedInvalidationRevision: refreshRevision
        )
        guard nativeResult != .stale,
              inventoryInvalidationRevision == refreshRevision
        else { return false }
        if nativeResult == nil {
            commitAXInventory(
                state: candidateState,
                bindings: candidateBindings,
                metadataRecords: pendingMetadataRecords
            )
        }
        let nativeInventoryReady = nativeResult == .authoritative
        if snapshot.completeness == .complete || nativeInventoryReady {
            hasPreparedHUDInventory = true
            inventoryRevision &+= 1
        }
        if nativeInventoryReady {
            setInventoryStatus(.ready)
        } else if hasPreparedHUDInventory {
            updateWindowDiscoveryStatus(for: snapshot)
        } else {
            setInventoryStatus(.loading)
        }
        hudController.refresh(state: state)
        hudController.rebuildSnapshotIfNeeded(
            inventoryRevision: inventoryRevision,
            safeBounds: hudSafeBoundsProvider()
        )
        hudAppIDsByFrozenWindowID = state.windows.mapValues(\.appID)
        let inventoryIsReady = snapshot.completeness == .complete || nativeInventoryReady
        if inventoryIsReady, hudPhysicalMutationBlock == .permissionReadiness {
            hudPhysicalMutationBlock = .none
        }
        return inventoryIsReady
    }

    private func requestWindowInventoryRefresh() {
        guard isStarted, !isTornDown else { return }
        inventoryInvalidationRevision &+= 1
        inventoryRefreshRequested = true
        guard inventoryRefreshTask == nil else { return }
        inventoryRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var partialRetryCount = 0
            while self.inventoryRefreshRequested, !Task.isCancelled {
                self.inventoryRefreshRequested = false
                let result = await self.refreshWindowInventory()
                if result == false,
                   partialRetryCount < 2 {
                    partialRetryCount += 1
                    try? await Task.sleep(for: .milliseconds(100))
                    self.inventoryRefreshRequested = true
                } else if result != false {
                    partialRetryCount = 0
                }
            }
            self.inventoryRefreshTask = nil
        }
    }

    private func updateWindowDiscoveryStatus(for snapshot: WindowObservationSnapshot) {
        let hasUsableInventory = !snapshot.windows.isEmpty || !state.windows.isEmpty
        setInventoryStatus(
            snapshot.completeness == .complete || hasUsableInventory
                ? .ready
                : .unavailable
        )
    }

    private func setInventoryStatus(_ status: FocusHUDWindowDiscoveryStatus) {
        inventoryStatus = status
        hudController.setWindowDiscoveryStatus(status)
    }

    private func recordWindowMetadata(_ window: ObservedWindow) {
        currentWindowMetadata[window.id] = (window.binding, window.title)
        metadataRecorder?.record(window)
    }

    private func removeWindowMetadata(_ windowID: ManagedWindowID) {
        currentWindowMetadata.removeValue(forKey: windowID)
        metadataRecorder?.remove(windowID: windowID)
    }

    private func commitAXInventory(
        state nextState: FocusScreenState,
        bindings nextBindings: [ManagedWindowID: WindowRuntimeBinding],
        metadataRecords: [ObservedWindow]
    ) {
        let removedWindowIDs = Set(state.windows.keys).subtracting(nextState.windows.keys)
        for windowID in removedWindowIDs {
            removeWindowMetadata(windowID)
        }
        for observed in metadataRecords {
            recordWindowMetadata(observed)
        }
        state = nextState
        bindings = nextBindings
        recoveryIncompatibleBindings = recoveryIncompatibleBindings.filter {
            nextBindings[$0.key] == $0.value
        }
        presentedFrames = presentedFrames.filter { nextState.windows[$0.key] != nil }
        workspaceAppIDsByScreen = Dictionary(uniqueKeysWithValues: nextState.screens.map { screen in
            (screen.id, Set(screen.windowIDs.compactMap { nextState.windows[$0]?.appID }))
        })
    }

    private func commitAsyncPresentationState(_ nextState: FocusScreenState) {
        inventoryInvalidationRevision &+= 1
        state = nextState
    }

    private func startWorkspaceRecoveryObservation() {
        guard workspaceObserverTokens.isEmpty, let workspaceNotificationCenter else { return }
        let notifications: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        workspaceObserverTokens = notifications.map { name in
            workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestWindowInventoryRefresh()
                    guard name == NSWorkspace.didLaunchApplicationNotification
                            || name == NSWorkspace.activeSpaceDidChangeNotification
                    else { return }
                    // Launch and Space notifications can arrive before AX
                    // windows or native Space membership have settled.
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.requestWindowInventoryRefresh()
                }
            }
        }
        workspaceObserverTokens.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let appID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.requestWindowInventoryRefresh()
                if let appID { self?.recordApplicationActivation(appID) }
            }
        })
        if let screenNotificationCenter {
            screenObserverTokens = [screenNotificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestWindowInventoryRefresh()
                }
            }]
        }
    }

    private func stopWorkspaceRecoveryObservation() {
        guard let workspaceNotificationCenter else { return }
        for token in workspaceObserverTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()
        if let screenNotificationCenter {
            for token in screenObserverTokens {
                screenNotificationCenter.removeObserver(token)
            }
        }
        screenObserverTokens.removeAll()
    }

    @discardableResult
    private func reconcileNativeSpaces(
        baseState: FocusScreenState? = nil,
        baseBindings: [ManagedWindowID: WindowRuntimeBinding]? = nil,
        pendingMetadataRecords: [ObservedWindow] = [],
        expectedInvalidationRevision: UInt64? = nil
    ) async -> NativeReconcileResult? {
        let sourceState = baseState ?? state
        let sourceBindings = baseBindings ?? bindings
        guard let nativeSpaceCatalog,
              let snapshot = await nativeSpaceCatalog.snapshot(
                windowBindings: sourceBindings,
                focusedWindowID: focusedWindowID
              ),
              !snapshot.desktops.isEmpty,
              let activeDesktop = snapshot.desktops.first(where: \.isActive)
        else { return nil }

        let committedState = state
        let previousState = sourceState
        let previousScreens = Dictionary(
            uniqueKeysWithValues: previousState.screens.map { ($0.id, $0) }
        )
        var nextWindows = previousState.windows
        var nextBindings = sourceBindings
        var nextPresentedFrames = presentedFrames
        var nextWindowServerWindowIDs = windowServerWindowIDs
        var nextWorkspaceAppIDs: [FocusScreenID: Set<String>] = [:]
        var windowsByScreenID: [FocusScreenID: [ManagedWindowID]] = [:]
        var metadataRecords = pendingMetadataRecords

        if let catalogWindows = snapshot.windows {
            metadataRecords.removeAll(keepingCapacity: true)
            nextWindows.removeAll(keepingCapacity: true)
            nextBindings = nextBindings.filter { !previousState.windows.keys.contains($0.key) }
            nextPresentedFrames = nextPresentedFrames.filter {
                !previousState.windows.keys.contains($0.key)
            }
            nextWindowServerWindowIDs = []
            nextWorkspaceAppIDs = Dictionary(uniqueKeysWithValues: snapshot.desktops.map {
                (Self.nativeScreenID($0.id), Set<String>())
            })
            var candidatesByWindowID: [
                CGWindowID: (binding: WindowRuntimeBinding, isSettable: Bool)
            ] = [:]
            var candidateWindowIDsByBinding: [WindowRuntimeBinding: Set<CGWindowID>] = [:]
            let pendingWindowIDs = Set(pendingMetadataRecords.map(\.id))
            let pendingBindings = Set(pendingMetadataRecords.map(\.binding))
            func hasRetainableAXElement(_ binding: WindowRuntimeBinding) -> Bool {
                if binding.retainedAXElement != nil { return true }
                guard case .system = binding.axElement else { return false }
                return true
            }
            let residentMetadataRecords = sourceState.windows.values.compactMap {
                managed -> ObservedWindow? in
                guard !pendingWindowIDs.contains(managed.id),
                      let binding = sourceBindings[managed.id],
                      !pendingBindings.contains(binding),
                      let metadata = currentWindowMetadata[managed.id],
                      metadata.binding == binding,
                      hasRetainableAXElement(binding)
                else { return nil }
                return ObservedWindow(
                    id: managed.id,
                    appID: managed.appID,
                    appName: "",
                    title: metadata.title,
                    frame: managed.canonicalFrame,
                    isFocused: false,
                    isMinimized: false,
                    isSettable: managed.isCompatible,
                    binding: binding
                )
            }
            let residentMetadataByBinding = Dictionary(
                grouping: residentMetadataRecords,
                by: \.binding
            ).compactMapValues { records -> ObservedWindow? in
                guard let first = records.first,
                      records.allSatisfy({
                          $0.appID == first.appID
                              && $0.frame == first.frame
                              && $0.isSettable == first.isSettable
                      })
                else { return nil }
                return first
            }
            let deduplicatedResidentMetadata = Array(residentMetadataByBinding.values)

            func matchingSources(
                _ records: [ObservedWindow],
                for window: NativeDesktopSnapshot.Window,
                application: NativeWindowApplication,
                sourceWindowID: ManagedWindowID? = nil,
                requiresCompatibleTitle: Bool = true
            ) -> [ObservedWindow] {
                records.filter { observed in
                    guard hasRetainableAXElement(observed.binding) else { return false }
                    return (sourceWindowID == nil || observed.id == sourceWindowID)
                        && sourceBindings[observed.id] == observed.binding
                        && observed.appID == application.appID
                        && observed.binding.processIdentifier == window.processIdentifier
                        && (sourceWindowID != nil || observed.frame == window.frame)
                        && (!requiresCompatibleTitle
                            || sourceWindowID != nil
                            || (!observed.title.isEmpty
                                && !window.title.isEmpty
                                && observed.title == window.title))
                }
            }

            for window in catalogWindows {
                guard let application = nativeWindowApplication(window.processIdentifier)
                else { continue }
                let exactResidentMatches = deduplicatedResidentMetadata.filter { observed in
                    observed.binding.cgWindowID == window.id
                        && observed.appID == application.appID
                        && observed.binding.processIdentifier == window.processIdentifier
                }
                let pendingMatches = matchingSources(
                    pendingMetadataRecords,
                    for: window,
                    application: application,
                    sourceWindowID: window.sourceWindowID
                )
                let pendingIdentityMatches = matchingSources(
                    pendingMetadataRecords,
                    for: window,
                    application: application,
                    sourceWindowID: window.sourceWindowID,
                    requiresCompatibleTitle: false
                )
                let residentMatches = matchingSources(
                    window.sourceWindowID == nil
                        ? deduplicatedResidentMetadata
                        : residentMetadataRecords,
                    for: window,
                    application: application,
                    sourceWindowID: window.sourceWindowID
                )
                let matches = exactResidentMatches.count == 1
                    ? exactResidentMatches
                    : (pendingIdentityMatches.isEmpty ? residentMatches : pendingMatches)
                guard matches.count == 1, let observed = matches.first else { continue }
                candidatesByWindowID[window.id] = (
                    observed.binding,
                    observed.isSettable
                )
                candidateWindowIDsByBinding[observed.binding, default: []].insert(window.id)
            }
            for window in catalogWindows.sorted(by: { $0.zOrder < $1.zOrder }) {
                guard window.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      let application = nativeWindowApplication(window.processIdentifier),
                      NativeWorkspaceWindowPolicy.isSwitchTarget(
                        isInVisibleList: window.isInVisibleList,
                        desktopIDs: window.desktopIDs,
                        visibleDesktopIDs: snapshot.visibleDesktopIDs,
                        tags: window.tags,
                        isApplicationHidden: application.isHidden,
                        isFocused: window.isFocused
                      )
                else { continue }

                let matchingDesktops = snapshot.desktops.filter { desktop in
                    !Set(desktop.memberDesktopIDs).isDisjoint(with: window.desktopIDs)
                }
                guard !matchingDesktops.isEmpty else { continue }
                let needsScopedID = matchingDesktops.count > 1
                for desktop in matchingDesktops {
                    let screenID = Self.nativeScreenID(desktop.id)
                    let id = Self.nativeWindowID(
                        window.id,
                        screenID: needsScopedID ? screenID : nil
                    )
                    let source: (binding: WindowRuntimeBinding, isSettable: Bool)? = {
                        guard let candidate = candidatesByWindowID[window.id],
                              candidateWindowIDsByBinding[candidate.binding]?.count == 1
                        else { return nil }
                        return candidate
                    }()
                    let retainedAXElement: NativeAXElementBox? = source.flatMap { source in
                        if let retained = source.binding.retainedAXElement { return retained }
                        guard case let .system(box) = source.binding.axElement else { return nil }
                        return box
                    }
                    let binding = WindowRuntimeBinding(
                        launchGeneration: source?.binding.launchGeneration
                            ?? "window-server-\(window.processIdentifier)",
                        processIdentifier: window.processIdentifier,
                        element: .windowServer(window.id),
                        cgWindowID: window.id,
                        retainedAXElement: retainedAXElement
                    )
                    let observed = ObservedWindow(
                        id: id,
                        appID: application.appID,
                        appName: application.appName.isEmpty ? window.ownerName : application.appName,
                        title: window.title,
                        frame: window.frame,
                        isFocused: window.isFocused || application.isActive,
                        isMinimized: NativeWorkspaceWindowPolicy.isMinimized(tags: window.tags),
                        isSettable: source?.isSettable ?? false,
                        binding: binding
                    )
                    if source == nil { nextWindowServerWindowIDs.insert(id) }
                    nextWorkspaceAppIDs[screenID, default: []].insert(application.appID)
                    windowsByScreenID[screenID, default: []].append(id)
                    nextBindings[id] = binding
                    nextWindows[id] = Self.managedWindow(from: observed)
                    metadataRecords.append(observed)
                }
            }
        } else {
            for windowID in nextWindows.keys.sorted() {
                let desktopIDs = snapshot.windowDesktopIDs[windowID] ?? [activeDesktop.id]
                let desktop = snapshot.desktops.first {
                    !Set($0.memberDesktopIDs).isDisjoint(with: desktopIDs)
                } ?? activeDesktop
                windowsByScreenID[Self.nativeScreenID(desktop.id), default: []].append(windowID)
            }
        }

        let activeScreenID = Self.nativeScreenID(activeDesktop.id)
        let previousOrder = previousState.screens.map(\.id)
        let desktopByScreenID = Dictionary(
            uniqueKeysWithValues: snapshot.desktops.map { (Self.nativeScreenID($0.id), $0) }
        )
        let orderedScreenIDs = previousOrder.filter { desktopByScreenID[$0] != nil }
            + snapshot.desktops.map { Self.nativeScreenID($0.id) }.filter {
                !previousOrder.contains($0)
            }
        let screens: [FocusScreen] = orderedScreenIDs.enumerated().compactMap { index, id in
            guard let desktop = desktopByScreenID[id] else { return nil as FocusScreen? }
            let id = Self.nativeScreenID(desktop.id)
            let windowIDs = windowsByScreenID[id] ?? []
            let previousLastActive = previousScreens[id]?.lastActiveWindowID
            let savedName = previousScreens[id]?.spaceID.flatMap { spaceID in
                previousState.savedSpaces.first { $0.id == spaceID }?.name
            }
            return FocusScreen(
                id: id,
                number: index + 1,
                name: savedName ?? desktop.name,
                lifecycle: desktop.isActive ? .active : .background,
                windowIDs: windowIDs,
                lastActiveWindowID: previousLastActive.flatMap {
                    windowIDs.contains($0) ? $0 : nil
                } ?? windowIDs.first,
                spaceID: previousScreens[id]?.spaceID,
                layout: previousScreens[id]?.layout
            )
        }
        let screenIDs = Set(screens.map(\.id))
        let inspectedScreenID = isHUDPresented && screenIDs.contains(state.inspectedScreenID)
            ? state.inspectedScreenID
            : activeScreenID
        let nextState = FocusScreenState(
            screens: screens,
            windows: nextWindows,
            activeScreenID: activeScreenID,
            inspectedScreenID: inspectedScreenID,
            revision: previousState.revision &+ 1,
            savedSpaces: previousState.savedSpaces
        )
        if snapshot.windows == nil {
            nextWorkspaceAppIDs = Dictionary(uniqueKeysWithValues: screens.map { screen in
                (screen.id, Set(screen.windowIDs.compactMap { nextState.windows[$0]?.appID }))
            })
        }

        // No await occurs below this point: consumers observe one complete
        // inventory generation rather than a partially rebuilt Screen set.
        if let expectedInvalidationRevision,
           expectedInvalidationRevision != inventoryInvalidationRevision {
            return .stale
        }
        let removedWindowIDs = Set(committedState.windows.keys).subtracting(nextWindows.keys)
        for windowID in removedWindowIDs {
            removeWindowMetadata(windowID)
        }
        for observed in metadataRecords {
            recordWindowMetadata(observed)
        }
        state = nextState
        bindings = nextBindings
        recoveryIncompatibleBindings = recoveryIncompatibleBindings.filter {
            nextBindings[$0.key] == $0.value
        }
        presentedFrames = nextPresentedFrames
        windowServerWindowIDs = nextWindowServerWindowIDs
        workspaceAppIDsByScreen = nextWorkspaceAppIDs
        return snapshot.windows == nil ? .fallback : .authoritative
    }

    private static func nativeScreenID(_ desktopID: UInt64) -> FocusScreenID {
        "native-space-\(desktopID)"
    }

    private static func nativeDesktopID(_ screenID: FocusScreenID) -> UInt64? {
        let prefix = "native-space-"
        guard screenID.hasPrefix(prefix) else { return nil }
        return UInt64(screenID.dropFirst(prefix.count))
    }

    private static func nativeWindowID(
        _ windowID: CGWindowID,
        screenID: FocusScreenID? = nil
    ) -> ManagedWindowID {
        screenID.map { "native-window-\(windowID)-\($0)" }
            ?? "native-window-\(windowID)"
    }

    private func handleObservationEvent(_ event: ObservedWindowEvent) {
        guard isStarted, !isTornDown else { return }
        var refreshesProjection = false
        switch event {
        case let .created(window):
            refreshesProjection = true
            if promoteCreatedSystemWindow(window) {
                requestWindowInventoryRefresh()
            } else {
                if let blockedBinding = recoveryIncompatibleBindings[window.id],
                   blockedBinding != window.binding {
                    recoveryIncompatibleBindings.removeValue(forKey: window.id)
                }
                bindings[window.id] = window.binding
                recordWindowMetadata(window)
                if state.windows[window.id] == nil {
                    let managed = Self.managedWindow(from: window)
                    if let next = try? FocusScreenReducer.registerUnowned(managed, in: state) {
                        state = next
                    }
                }
            }
        case let .focused(windowID):
            refreshesProjection = true
            focusedWindowID = windowID
            handleExternalFocus(windowID: windowID)
        case let .frameChanged(windowID, frame):
            if var window = state.windows[windowID] {
                window.canonicalFrame = frame
                state.windows[windowID] = window
            }
        case let .minimizedChanged(windowID, minimized):
            _ = minimized
            _ = windowID
            // Minimize state is UI-only for Phase 1A; no domain mutation.
        case .destroyed(let windowID):
            refreshesProjection = true
            removeWindow(windowID)
        case .appTerminated:
            // App-level termination is handled by window destruction events;
            // no additional domain action is required for Phase 1A.
            break
        }
        if refreshesProjection {
            workspaceAppIDsByScreen = Dictionary(uniqueKeysWithValues: state.screens.map { screen in
                (screen.id, Set(screen.windowIDs.compactMap { state.windows[$0]?.appID }))
            })
            if isHUDPresented {
                hudController.refresh(state: state)
            }
        }
    }

    private func promoteCreatedSystemWindow(_ window: ObservedWindow) -> Bool {
        guard case .system = window.binding.axElement else { return false }
        let matchingIDs = windowServerWindowIDs.filter { windowID in
            guard let managed = state.windows[windowID],
                  let binding = bindings[windowID],
                  let metadata = currentWindowMetadata[windowID],
                  metadata.binding == binding,
                  case .windowServer = binding.axElement
            else { return false }
            return managed.appID == window.appID
                && binding.processIdentifier == window.binding.processIdentifier
                && managed.canonicalFrame == window.frame
                && !metadata.title.isEmpty
                && !window.title.isEmpty
                && metadata.title == window.title
        }
        let matchingCGWindowIDs = Set(matchingIDs.compactMap { windowID -> CGWindowID? in
            guard let binding = bindings[windowID],
                  case let .windowServer(cgWindowID) = binding.axElement
            else { return nil }
            return cgWindowID
        })
        guard matchingCGWindowIDs.count == 1,
              let cgWindowID = matchingCGWindowIDs.first
        else { return false }
        let scopedIDs = windowServerWindowIDs.filter { windowID in
            guard let binding = bindings[windowID],
                  case let .windowServer(candidateCGWindowID) = binding.axElement
            else { return false }
            return candidateCGWindowID == cgWindowID
        }
        guard scopedIDs == matchingIDs else { return false }
        for windowID in scopedIDs {
            let retainedBinding = WindowRuntimeBinding(
                launchGeneration: window.binding.launchGeneration,
                processIdentifier: window.binding.processIdentifier,
                element: .windowServer(cgWindowID),
                cgWindowID: cgWindowID,
                retainedAXElement: {
                    guard case let .system(box) = window.binding.axElement else { return nil }
                    return box
                }()
            )
            bindings[windowID] = retainedBinding
            state.windows[windowID]?.isCompatible = window.isSettable
            currentWindowMetadata[windowID] = (retainedBinding, window.title)
            recoveryIncompatibleBindings.removeValue(forKey: windowID)
        }
        windowServerWindowIDs.subtract(scopedIDs)
        state.revision &+= 1
        return true
    }

    /// Promotes the Screen owning `windowID` to active when an externally-driven
    /// focus event arrives on a background Screen's window. Never warps the
    /// pointer and never runs a switch transaction — the system already owns
    /// focus.
    private func handleExternalFocus(windowID: ManagedWindowID) {
        guard let ownerScreenID = currentScreenID(owning: windowID) else { return }
        if ownerScreenID == state.activeScreenID { return }
        if let next = try? FocusScreenReducer.commitSwitch(screenID: ownerScreenID, in: state) {
            state = next
        }
    }

    private func removeWindow(_ windowID: ManagedWindowID) {
        recoveryIncompatibleBindings.removeValue(forKey: windowID)
        bindings.removeValue(forKey: windowID)
        presentedFrames.removeValue(forKey: windowID)
        removeWindowMetadata(windowID)
        // Phase 1A: window destruction removes the window from the state map
        // and any Screen that owned it. The reducer does not expose a single
        // "remove window" transition; emulate via beginClosing/finishClosing
        // is too heavyweight, so perform the minimal state repair inline while
        // preserving the reducer's invariants.
        guard state.windows[windowID] != nil else { return }
        state.windows.removeValue(forKey: windowID)
        for index in state.screens.indices {
            if let removeIndex = state.screens[index].windowIDs.firstIndex(of: windowID) {
                state.screens[index].windowIDs.remove(at: removeIndex)
            }
            if state.screens[index].lastActiveWindowID == windowID {
                state.screens[index].lastActiveWindowID = state.screens[index].windowIDs.last
            }
        }
        state.revision += 1
    }

    // MARK: - Recovery

    /// Semantic diagnostics seam (Task 10). Runs Reveal All through the SAME
    /// `SafetyRecoveryCoordinator` path the UI/lifecycle uses, so the diagnostics
    /// and the permission-loss / termination paths share one recovery pipeline.
    @discardableResult
    func revealAllForSemanticDiagnostics() async -> SafetyRecoveryResult {
        await revealAll()
    }

    @discardableResult
    private func revealAll() async -> SafetyRecoveryResult {
        let coordinator = SafetyRecoveryCoordinator(
            commandService: commandService,
            stitchedCanvasRegions: regionsProvider().map(\.frame),
            commandTimeout: commandTimeout
        )
        var canonicalFrames: [ManagedWindowID: CanvasRect] = [:]
        for (windowID, window) in state.windows where window.isCompatible {
            canonicalFrames[windowID] = window.canonicalFrame
        }
        let result = await coordinator.revealAll(
            canonicalFrames: canonicalFrames,
            bindings: bindings
        )
        // Mark incompatible windows so subsequent switches avoid them.
        for windowID in coordinator.incompatibleWindowIDs {
            state.windows[windowID]?.isCompatible = false
        }
        // Reveal All restores every window to its canonical frame on the Canvas;
        // refresh the live frames so the snapshot reflects the recovered state.
        await refreshPresentedFrames()
        return result
    }

    private func revealAllAndFail(primary: WindowPresentationFailure) async -> WindowPresentationResult {
        let recovery = await revealAll()
        return .failed(primary: primary, recovery: recovery)
    }

    // MARK: - Helpers

    private func currentScreenID(owning windowID: ManagedWindowID) -> FocusScreenID? {
        state.screens.first(where: { $0.windowIDs.contains(windowID) })?.id
    }

    private func landPointer(on targetFrame: CanvasRect?) -> PointerLandingResult {
        PointerCoordinator(location: pointerLocation, move: pointerMove).landIfRequired(
            targetFrame: targetFrame,
            regions: regionsProvider()
        )
    }

    private enum HUDExactFocusResult {
        case applied
        case stale
        case failed(FocusSemanticHUDActivationBlockReason)
    }

    private func raiseFocusAndLand(
        _ targetWindow: ManagedWindow,
        binding: WindowRuntimeBinding,
        transaction: HUDActivationTransaction
    ) async -> HUDExactFocusResult {
        let selectionToken = transaction.selectionToken
        guard isCurrentHUDSelection(
            selectionToken,
            windowID: targetWindow.id,
            binding: binding
        ) else {
            recordHUDActivationCancellation(
                transaction: transaction,
                windowID: targetWindow.id,
                binding: binding
            )
            return .stale
        }
        let outcome = await commandService.raiseAndFocusOutcome(
            binding,
            timeout: commandTimeout,
            whileCurrent: { [weak self] in
                self?.isCurrentHUDSelection(
                    selectionToken,
                    windowID: targetWindow.id,
                    binding: binding
                ) == true
            }
        )
        guard isCurrentHUDSelection(
            selectionToken,
            windowID: targetWindow.id,
            binding: binding
        ) else {
            recordHUDActivationCancellation(
                transaction: transaction,
                windowID: targetWindow.id,
                binding: binding
            )
            return .stale
        }
        switch outcome {
        case .applied:
            recordHUDActivation(
                transaction: transaction,
                stage: .applied,
                result: .applied,
                binding: binding,
                selectionCurrent: true,
                bindingCurrent: true
            )
        case .cancelled:
            recordHUDActivationCancellation(
                transaction: transaction,
                windowID: targetWindow.id,
                binding: binding
            )
            return .stale
        case .activate, .nativeExact, .resolution, .raise, .focusWrite, .readback:
            let projection = semanticProjection(outcome)
            recordHUDActivation(
                transaction: transaction,
                stage: projection.stage,
                result: projection.result,
                binding: binding,
                selectionCurrent: true,
                bindingCurrent: true,
                blockReason: projection.blockReason
            )
            return .failed(projection.blockReason)
        }
        let settled = await commandService.snapshot(
            binding,
            timeout: commandTimeout
        )
        guard isCurrentHUDSelection(
            selectionToken,
            windowID: targetWindow.id,
            binding: binding
        ) else {
            recordHUDActivationCancellation(
                transaction: transaction,
                windowID: targetWindow.id,
                binding: binding
            )
            return .stale
        }
        guard let settled else { return .applied }
        _ = landPointer(on: settled.frame)
        return .applied
    }

    private func isCurrentHUDSelection(
        _ selectionToken: UUID,
        windowID: ManagedWindowID,
        binding: WindowRuntimeBinding
    ) -> Bool {
        hudSelectionToken == selectionToken && bindings[windowID] == binding
    }

    @discardableResult
    private func invalidateHUDSelection() -> UUID {
        let token = UUID()
        hudSelectionToken = token
        return token
    }

    private func beginHUDActivationIntent() -> HUDActivationTransaction? {
        let selectionToken = invalidateHUDSelection()
        let (nextRevision, overflow) = hudActivation.revision.addingReportingOverflow(1)
        guard !isHUDActivationRevisionExhausted, !overflow else {
            isHUDActivationRevisionExhausted = true
            activeHUDActivationTransaction = nil
            return nil
        }
        let transaction = HUDActivationTransaction(
            revision: nextRevision,
            selectionToken: selectionToken
        )
        activeHUDActivationTransaction = transaction
        hudActivation = FocusSemanticHUDActivation(
            revision: nextRevision,
            stage: .intent,
            result: .pending,
            bindingKind: .none,
            selectionCurrent: false,
            bindingCurrent: false,
            blockReason: .none
        )
        return transaction
    }

    private func recordHUDActivation(
        transaction: HUDActivationTransaction,
        stage: FocusSemanticHUDActivationStage,
        result: FocusSemanticHUDActivationResult,
        binding: WindowRuntimeBinding? = nil,
        selectionCurrent: Bool,
        bindingCurrent: Bool,
        blockReason: FocusSemanticHUDActivationBlockReason = .none
    ) {
        guard activeHUDActivationTransaction == transaction,
              hudActivation.revision == transaction.revision else { return }
        hudActivation = FocusSemanticHUDActivation(
            revision: transaction.revision,
            stage: stage,
            result: result,
            bindingKind: semanticBindingKind(binding),
            selectionCurrent: selectionCurrent,
            bindingCurrent: bindingCurrent,
            blockReason: blockReason
        )
        assert(hudActivation.isValidCombination)
    }

    private func recordHUDActivationCancellation(
        transaction: HUDActivationTransaction,
        windowID: ManagedWindowID,
        binding: WindowRuntimeBinding
    ) {
        let selectionToken = transaction.selectionToken
        let selectionCurrent = hudSelectionToken == selectionToken
        let bindingCurrent = bindings[windowID] == binding
        recordHUDActivation(
            transaction: transaction,
            stage: .cancelled,
            result: .cancelled,
            binding: binding,
            selectionCurrent: selectionCurrent,
            bindingCurrent: bindingCurrent,
            blockReason: selectionCurrent
                ? (bindingCurrent ? .inventoryChanged : .bindingChanged)
                : .selectionSuperseded
        )
    }

    private func semanticBindingKind(
        _ binding: WindowRuntimeBinding?
    ) -> FocusSemanticHUDActivationBindingKind {
        guard let binding else { return .none }
        switch binding.axElement {
        case .system:
            return .system
        case .windowServer:
            return .windowServer
        case .injected:
            return .injected
        }
    }

    private func semanticProjection(
        _ outcome: WindowFocusCommandOutcome
    ) -> (
        stage: FocusSemanticHUDActivationStage,
        result: FocusSemanticHUDActivationResult,
        blockReason: FocusSemanticHUDActivationBlockReason
    ) {
        switch outcome {
        case let .activate(result):
            return (.activate, semanticResult(result), .activationRejected)
        case let .nativeExact(failure):
            let reason: FocusSemanticHUDActivationBlockReason
            switch failure {
            case .symbolUnavailable:
                reason = .exactFocusSymbolUnavailable
            case .processResolutionFailed:
                reason = .exactFocusProcessResolutionFailed
            case .frontProcessRejected:
                reason = .exactFocusFrontProcessRejected
            case .keyEventRejected:
                reason = .exactFocusKeyEventRejected
            }
            return (.activate, semanticResult(outcome.commandResult), reason)
        case let .resolution(result):
            return (
                .resolution,
                semanticResult(result),
                result == .vanished ? .resolutionUnavailable : .resolutionRejected
            )
        case let .raise(result):
            return (.raise, semanticResult(result), .raiseRejected)
        case let .focusWrite(result):
            return (.focusWrite, semanticResult(result), .focusWriteRejected)
        case let .readback(result):
            return (.readback, semanticResult(result), .readbackRejected)
        case .applied:
            return (.applied, .applied, .none)
        case .cancelled:
            return (.cancelled, .cancelled, .selectionSuperseded)
        }
    }

    private func semanticResult(
        _ result: WindowCommandResult
    ) -> FocusSemanticHUDActivationResult {
        switch result {
        case .applied:
            return .applied
        case .unsupported:
            return .unsupported
        case .timedOut:
            return .timedOut
        case .vanished:
            return .vanished
        case .failed:
            return .failed
        }
    }

    private func focusHUDWindow(
        _ window: ManagedWindow,
        binding: WindowRuntimeBinding,
        windowID: ManagedWindowID,
        screenID: FocusScreenID,
        transaction: HUDActivationTransaction
    ) async {
        let selectionToken = transaction.selectionToken
        switch await raiseFocusAndLand(
            window,
            binding: binding,
            transaction: transaction
        ) {
        case .applied:
            if isCurrentHUDSelection(
                selectionToken,
                windowID: windowID,
                binding: binding
            ) {
                recordExactFocus(windowID: windowID, screenID: screenID)
                recordHUDActivation(
                    transaction: transaction,
                    stage: .commit,
                    result: .applied,
                    binding: binding,
                    selectionCurrent: true,
                    bindingCurrent: true
                )
            } else {
                recordHUDActivationCancellation(
                    transaction: transaction,
                    windowID: windowID,
                    binding: binding
                )
            }
        case let .failed(blockReason):
            if hudSelectionToken == selectionToken {
                guard case .windowServer = binding.axElement else {
                    let reopened = reopenApplication(window.appID)
                    recordHUDActivation(
                        transaction: transaction,
                        stage: .fallback,
                        result: reopened ? .applied : .failed,
                        binding: binding,
                        selectionCurrent: true,
                        bindingCurrent: bindings[windowID] == binding,
                        blockReason: blockReason
                    )
                    return
                }
            }
        case .stale:
            break
        }
    }

    private func recordExactFocus(windowID: ManagedWindowID, screenID: FocusScreenID) {
        inventoryInvalidationRevision &+= 1
        focusedWindowID = windowID
        if screenID != state.activeScreenID,
           let next = try? FocusScreenReducer.commitSwitch(screenID: screenID, in: state) {
            state = next
        }
        if let index = state.screens.firstIndex(where: { $0.id == screenID }) {
            state.screens[index].lastActiveWindowID = windowID
        }
        state.revision &+= 1
    }

    private func handleHUDIntent(_ intent: FocusHUDOverviewIntent) {
        let activationTransaction: HUDActivationTransaction?
        if case .activateWindow = intent {
            activationTransaction = beginHUDActivationIntent()
            guard activationTransaction != nil else {
                dismissSwitcher()
                return
            }
        } else {
            activationTransaction = nil
        }
        if hudPhysicalMutationBlock.isActive {
            if case .activateWindow = intent, let activationTransaction {
                recordHUDActivation(
                    transaction: activationTransaction,
                    stage: .intent,
                    result: .blocked,
                    selectionCurrent: false,
                    bindingCurrent: false,
                    blockReason: .physicalMutation
                )
            }
            if case .cancel = intent { closeSwitcher() }
            return
        }
        switch intent {
        case let .activateWindow(windowID):
            guard let activationTransaction else { return }
            let selectionToken = activationTransaction.selectionToken
            guard let appID = hudAppIDsByFrozenWindowID[windowID] else {
                recordHUDActivation(
                    transaction: activationTransaction,
                    stage: .intent,
                    result: .blocked,
                    selectionCurrent: false,
                    bindingCurrent: false,
                    blockReason: .mappingUnavailable
                )
                return
            }
            recordHUDActivation(
                transaction: activationTransaction,
                stage: .queued,
                result: .pending,
                selectionCurrent: true,
                bindingCurrent: false
            )
            let resolvedWindowID: ManagedWindowID?
            if state.windows[windowID]?.appID == appID {
                resolvedWindowID = windowID
            } else {
                let replacements = state.windows.values.filter { $0.appID == appID }
                resolvedWindowID = replacements.count == 1 ? replacements[0].id : nil
            }
            guard let resolvedWindowID,
                  let screenID = hudScreenIDByFrozenWindowID[resolvedWindowID]
                      ?? currentScreenID(owning: resolvedWindowID),
                  let window = state.windows[resolvedWindowID]
            else {
                dismissSwitcher()
                enqueueHUDSelection { [weak self] in
                    guard let self else { return }
                    guard self.hudSelectionToken == selectionToken else {
                        self.recordHUDActivation(
                            transaction: activationTransaction,
                            stage: .queued,
                            result: .cancelled,
                            selectionCurrent: false,
                            bindingCurrent: false,
                            blockReason: .selectionSuperseded
                        )
                        return
                    }
                    let reopened = self.reopenApplication(appID)
                    self.recordHUDActivation(
                        transaction: activationTransaction,
                        stage: .fallback,
                        result: reopened ? .applied : .failed,
                        selectionCurrent: true,
                        bindingCurrent: false,
                        blockReason: .targetUnavailable
                    )
                }
                return
            }
            dismissSwitcher()
            enqueueHUDSelection { [weak self] in
                guard let self else { return }
                guard self.hudSelectionToken == selectionToken else {
                    self.recordHUDActivation(
                        transaction: activationTransaction,
                        stage: .queued,
                        result: .cancelled,
                        selectionCurrent: false,
                        bindingCurrent: false,
                        blockReason: .selectionSuperseded
                    )
                    return
                }
                if let recoveryBinding = self.recoveryIncompatibleBindings[resolvedWindowID],
                   recoveryBinding == self.bindings[resolvedWindowID] {
                    if self.hudSelectionToken == selectionToken {
                        let reopened = self.reopenApplication(window.appID)
                        self.recordHUDActivation(
                            transaction: activationTransaction,
                            stage: .fallback,
                            result: reopened ? .applied : .failed,
                            binding: recoveryBinding,
                            selectionCurrent: true,
                            bindingCurrent: true,
                            blockReason: .recoveryIncompatible
                        )
                    } else {
                        self.recordHUDActivationCancellation(
                            transaction: activationTransaction,
                            windowID: resolvedWindowID,
                            binding: recoveryBinding
                        )
                    }
                    return
                }
                guard let binding = self.bindings[resolvedWindowID] else {
                    guard self.hudSelectionToken == selectionToken else {
                        self.recordHUDActivation(
                            transaction: activationTransaction,
                            stage: .queued,
                            result: .cancelled,
                            selectionCurrent: false,
                            bindingCurrent: false,
                            blockReason: .selectionSuperseded
                        )
                        return
                    }
                    let reopened = self.reopenApplication(window.appID)
                    self.recordHUDActivation(
                        transaction: activationTransaction,
                        stage: .fallback,
                        result: reopened ? .applied : .failed,
                        selectionCurrent: true,
                        bindingCurrent: false,
                        blockReason: .bindingUnavailable
                    )
                    return
                }
                self.recordHUDActivation(
                    transaction: activationTransaction,
                    stage: .binding,
                    result: .pending,
                    binding: binding,
                    selectionCurrent: true,
                    bindingCurrent: true
                )
                if case .windowServer = binding.axElement {
                    if screenID != self.state.activeScreenID,
                       let targetDesktopID = Self.nativeDesktopID(screenID) {
                        guard let nativeSpaceCatalog = self.nativeSpaceCatalog,
                              await nativeSpaceCatalog.switchToDesktop(id: targetDesktopID)
                        else {
                            self.recordHUDActivation(
                                transaction: activationTransaction,
                                stage: .activate,
                                result: .failed,
                                binding: binding,
                                selectionCurrent: true,
                                bindingCurrent: self.bindings[resolvedWindowID] == binding,
                                blockReason: .transactionRejected
                            )
                            return
                        }
                    }
                    await self.focusHUDWindow(
                        window,
                        binding: binding,
                        windowID: resolvedWindowID,
                        screenID: screenID,
                        transaction: activationTransaction
                    )
                    return
                }
                if screenID == self.state.activeScreenID {
                    await self.focusHUDWindow(
                        window,
                        binding: binding,
                        windowID: resolvedWindowID,
                        screenID: screenID,
                        transaction: activationTransaction
                    )
                } else {
                    guard self.hudSelectionToken == selectionToken else {
                        self.recordHUDActivationCancellation(
                            transaction: activationTransaction,
                            windowID: resolvedWindowID,
                            binding: binding
                        )
                        return
                    }
                    let result = await self.switchTo(
                        screenID: screenID,
                        targeting: resolvedWindowID,
                        whileCurrent: { [weak self] in
                            self?.hudSelectionToken == selectionToken
                        }
                    )
                    guard self.hudSelectionToken == selectionToken else {
                        self.recordHUDActivationCancellation(
                            transaction: activationTransaction,
                            windowID: resolvedWindowID,
                            binding: binding
                        )
                        return
                    }
                    switch result {
                    case .committed:
                        if self.bindings[resolvedWindowID] == binding {
                            self.recordHUDActivation(
                                transaction: activationTransaction,
                                stage: .commit,
                                result: .applied,
                                binding: binding,
                                selectionCurrent: true,
                                bindingCurrent: true
                            )
                        } else {
                            self.recordHUDActivationCancellation(
                                transaction: activationTransaction,
                                windowID: resolvedWindowID,
                                binding: binding
                            )
                        }
                    case .cancelled:
                        self.recordHUDActivationCancellation(
                            transaction: activationTransaction,
                            windowID: resolvedWindowID,
                            binding: binding
                        )
                    case .failed:
                        let reopened = self.reopenApplication(window.appID)
                        self.recordHUDActivation(
                            transaction: activationTransaction,
                            stage: .fallback,
                            result: reopened ? .applied : .failed,
                            binding: binding,
                            selectionCurrent: true,
                            bindingCurrent: self.bindings[resolvedWindowID] == binding,
                            blockReason: .transactionRejected
                        )
                    }
                }
            }
        case .activatePreviousApplication:
            activatePreviousApplication()
        case .cancel:
            closeSwitcher()
        case .focusWindow, .none:
            break
        }
    }

    private func mergeCancellationRecovery(_ result: WindowPresentationResult) {
        guard case let .cancelled(.some(recovery)) = result else { return }
        let currentIncompatibleBindings = recovery.incompatibleBindings.filter {
            state.windows[$0.key] != nil && bindings[$0.key] == $0.value
        }
        guard !currentIncompatibleBindings.isEmpty else { return }
        inventoryInvalidationRevision &+= 1
        for (windowID, recoveryBinding) in currentIncompatibleBindings {
            recoveryIncompatibleBindings[windowID] = recoveryBinding
            state.windows[windowID]?.isCompatible = false
        }
    }

    private func enqueueHUDSelection(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        guard !hudPhysicalMutationBlock.isActive else { return }
        let previous = hudSelectionTransactionTail
        hudSelectionTransactionTail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func runHUDLifecycleMutation(
        _ block: HUDPhysicalMutationBlock,
        operation: @escaping @MainActor () async -> Void
    ) async {
        if block == .termination || hudPhysicalMutationBlock != .termination {
            hudPhysicalMutationBlock = block
        }
        invalidateHUDSelection()
        let previous = hudSelectionTransactionTail
        let lifecycleMutation = Task { @MainActor in
            await previous?.value
            await operation()
        }
        hudSelectionTransactionTail = lifecycleMutation
        await lifecycleMutation.value
    }

    func recordApplicationActivation(_ appID: String) {
        guard !appID.isEmpty, appID != ownApplicationID else { return }
        recentApplicationIDs.removeAll { $0 == appID }
        recentApplicationIDs.insert(appID, at: 0)
        if recentApplicationIDs.count > 2 {
            recentApplicationIDs.removeLast(recentApplicationIDs.count - 2)
        }
    }

    private func activatePreviousApplication() {
        guard !hudPhysicalMutationBlock.isActive else {
            dismissSwitcher()
            return
        }
        guard let previousAppID = recentApplicationIDs.dropFirst().first else {
            if !isHUDPresented {
                openSwitcher()
            }
            return
        }
        let selectionToken = invalidateHUDSelection()
        dismissSwitcher()
        enqueueHUDSelection { [weak self] in
            guard let self, self.hudSelectionToken == selectionToken else { return }
            if !self.activateApplication(previousAppID) {
                self.openSwitcher()
            }
        }
    }

    private func notifyVisibility(_ tab: WorkspaceTab?) {
        for observer in visibilityObservers {
            observer.body(tab)
        }
    }

    private static func managedWindow(from observed: ObservedWindow) -> ManagedWindow {
        ManagedWindow(
            id: observed.id,
            appID: observed.appID,
            canonicalFrame: observed.frame,
            isCompatible: observed.isSettable
        )
    }
}

// MARK: - Fullscreen semantic-assembly bridge (Task 9 minimal adapter)

/// Task 9 leaves the existing `FullscreenSemanticAdapterAssembly` in place; the
/// full v3 semantic server is Task 10. To keep the assembly compiling against
/// the new production controller without implementing v3 here, the controller
/// conforms via readback:
///
/// - `visibleTab` is `.switch` while the HUD is presented, else `nil`.
/// - `toggle(tab:)` / `close(reason:)` map to `openSwitcher()` / `closeSwitcher()`.
/// - `observeVisibilityChanges(_:)` replays HUD visibility to the legacy
///   assembly's single observer.
extension FocusScreenController: FullscreenWorkspacePresenting, FullscreenWorkspaceVisibilityObserving {
    public var visibleTab: WorkspaceTab? {
        isHUDPresented ? .switch : nil
    }

    public func toggle(tab: WorkspaceTab) {
        // The legacy semantic assembly toggles the `.switch` tab when the panel
        // opens or closes. Map both directions onto open/close.
        switch tab {
        case .switch:
            if isHUDPresented {
                closeSwitcher()
            } else {
                openSwitcher()
            }
        case .agents, .focus:
            // Phase 1A collapses every direct shortcut onto the single HUD.
            openSwitcher()
        }
    }

    public func toggle(tab: WorkspaceTab, globalShortcutStartedAtNanoseconds: UInt64) {
        // If HUD is visible in modifier-hold mode: toggle between two most recent apps
        if tab == .switch, isHUDPresented {
            toggleFocusBetweenRecentApps()
            return
        }
        // If in deferred grace period and triggered again: show HUD immediately
        // with the "other" recent app focused
        if tab == .switch, deferredPresentationTask != nil {
            cancelDeferredPresentation()
            openSwitcher()
            toggleFocusBetweenRecentApps()
            return
        }
        // Capture which modifier keys are currently held (the "primary" keys
        // of the shortcut, e.g. cmd, option, ctrl, or any combination).
        let heldModifiers = modifierFlagsProvider()
            .intersection([.command, .option, .control, .shift])
        let hasModifierHeld = !heldModifiers.isEmpty
        if hasModifierHeld, tab == .switch, !isHUDPresented {
            cancelDeferredPresentation()
            let now = monotonicNowNanoseconds()
            let elapsed = now >= globalShortcutStartedAtNanoseconds
                ? now - globalShortcutStartedAtNanoseconds
                : 0
            let remainingDelay = elapsed >= Self.commandTabHoldDelayNanoseconds
                ? 0
                : Self.commandTabHoldDelayNanoseconds - elapsed
            if remainingDelay == 0 {
                openSwitcher()
                return
            }
            // Monitor for modifier release during the grace period.
            // If ALL held modifiers are released → quick-switch to previous app.
            deferredModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return }
                let currentModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if currentModifiers.intersection(heldModifiers).isEmpty {
                    self.cancelDeferredPresentation()
                    self.activatePreviousApplication()
                }
            }
            deferredPresentationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: remainingDelay)
                guard let self, !Task.isCancelled else { return }
                self.removeDeferredModifierMonitor()
                self.toggle(tab: tab)
            }
        } else {
            toggle(tab: tab)
        }
    }

    /// Toggles HUD focus between the two most recent apps.
    private func toggleFocusBetweenRecentApps() {
        guard recentApplicationIDs.count >= 2 else {
            hudController.advanceFocusToNext()
            return
        }
        // Determine which recent app is currently focused
        let currentFocusedAppID: String? = hudController.focusedWindowID.flatMap { hudAppIDsByFrozenWindowID[$0] }
        let targetAppID = (currentFocusedAppID == recentApplicationIDs[0])
            ? recentApplicationIDs[1]
            : recentApplicationIDs[0]
        // Find the windowID for the target app
        if let windowID = hudAppIDsByFrozenWindowID.first(where: { $0.value == targetAppID })?.key {
            hudController.focusWindow(windowID)
        } else {
            hudController.advanceFocusToNext()
        }
    }

    private func cancelDeferredPresentation() {
        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil
        removeDeferredModifierMonitor()
    }

    private func removeDeferredModifierMonitor() {
        if let monitor = deferredModifierMonitor {
            NSEvent.removeMonitor(monitor)
            deferredModifierMonitor = nil
        }
    }

    public func close(reason: WorkspaceCloseReason) {
        closeSwitcher()
    }

    func observeVisibilityChanges(
        _ observer: @escaping @MainActor (WorkspaceTab?) -> Void
    ) -> WorkspaceVisibilityObservation {
        let token = VisibilityObserver(id: UUID(), body: observer)
        visibilityObservers.append(token)
        // Emit the current visibility once on attach so the assembly
        // synchronizes its session against the real state.
        observer(visibleTab)
        return WorkspaceVisibilityObservation { [weak self, id = token.id] in
            self?.removeVisibilityObserver(id: id)
        }
    }

    private func removeVisibilityObserver(id: UUID) {
        visibilityObservers.removeAll(where: { $0.id == id })
    }
}

// MARK: - Concrete FocusHUDController conformance to FocusHUDControlling

@MainActor
extension FocusHUDController: FocusHUDControlling {
    func attach() {
        // The concrete controller lazily builds its panel in `init`; nothing
        // to attach here. Kept as a no-op seam so prewarm is idempotent.
    }

    func refresh(state: FocusScreenState) {
        viewModel.update(state: state)
    }

    // The concrete controller's close takes a `FocusHUDCloseReason`; provide
    // the parameterless bridge used by the runtime seam (programmatic dismiss).
    func close() {
        close(reason: .programmatic)
    }

    func setIntentHandler(_ handler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void) {
        viewModel.setIntentHandler(handler)
    }

    func setWindowDiscoveryStatus(_ status: FocusHUDWindowDiscoveryStatus) {
        viewModel.setWindowDiscoveryStatus(status)
    }

    func rebuildSnapshotIfNeeded(inventoryRevision: UInt64, safeBounds: CanvasRect) {
        rebuildSnapshot(inventoryRevision: inventoryRevision, safeBounds: safeBounds)
    }

    func advanceFocusToNext() {
        _ = viewModel.handle(key: .right)
    }

    func activateFocusedApp() {
        guard let focusedID = viewModel.focusedWindowID else { return }
        _ = viewModel.activateApp(windowID: focusedID)
    }

    func focusWindow(_ windowID: ManagedWindowID) {
        viewModel.setFocusedWindowID(windowID)
    }

    var focusedWindowID: ManagedWindowID? {
        viewModel.focusedWindowID
    }
}

// MARK: - Default window-metadata provider for the production path

/// Retains UI-only metadata from the observation stream for the current HUD.
@MainActor
final class RunningAppWindowMetadataProvider: FocusHUDWindowMetadataRecording {
    private var metadataByWindowID: [ManagedWindowID: FocusHUDWindowMetadata] = [:]

    func record(_ window: ObservedWindow) {
        let app = NSRunningApplication(processIdentifier: window.binding.processIdentifier)
        let appName = window.appName.isEmpty ? (app?.localizedName ?? window.appID) : window.appName
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadataByWindowID[window.id] = FocusHUDWindowMetadata(
            appName: appName,
            appIcon: app?.icon,
            windowTitle: title.isEmpty ? "Untitled Window" : title
        )
    }

    func remove(windowID: ManagedWindowID) {
        metadataByWindowID.removeValue(forKey: windowID)
    }

    func metadata(for window: ManagedWindow) -> FocusHUDWindowMetadata {
        metadataByWindowID[window.id]
            ?? FocusHUDWindowMetadata(appName: window.appID, appIcon: nil, windowTitle: "Untitled Window")
    }
}
