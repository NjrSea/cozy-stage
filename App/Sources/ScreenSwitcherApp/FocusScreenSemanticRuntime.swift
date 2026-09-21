import Foundation
import ScreenDomainCore

/// The semantic v3 runtime boundary over a `FocusScreenController`.
///
/// `FocusScreenSemanticRuntime` is the ACTIVE production adapter consumed by the
/// v3 semantic server (`SemanticFocusScreenServer`). It:
///
/// - Reads reducer, HUD, Canvas, observed-window, pointer, and transaction
///   revisions and builds a content-free `FocusScreenSemanticSnapshotV3`.
/// - Hashes every App bundle identity through the existing per-run opaque token
///   boundary (`ProductAppAXIdentity.opaqueToken(forBundleIdentifier:)`), so no
///   raw bundle id, title, path, token, or PID ever crosses the wire.
/// - Routes every diagnostics mutation through the SAME controller intents the UI
///   uses (`openSwitcher`, `closeSwitcher`, `sendHUDKey`, `createBlankScreen`,
///   `beginClosing`, `switchTo`, `revealAllForSemanticDiagnostics`). It never
///   mutates reducer state directly.
///
/// The runtime is `@MainActor` (the controller is main-actor-isolated) and
/// inert by construction: the server that owns it stays disabled in packaged
/// production (see `apps/screen-switcher/AGENTS.md`).
@MainActor
public final class FocusScreenSemanticRuntime {
    private let controller: FocusScreenController
    private let identityHasher: (String) -> String

    /// Constructs the production runtime over a controller, using the shared
    /// `ProductAppAXIdentity.opaqueToken` hash for App bundle identity.
    public init(controller: FocusScreenController) {
        self.controller = controller
        self.identityHasher = { ProductAppAXIdentity.opaqueToken(forBundleIdentifier: $0) }
    }

    /// Test seam that injects a deterministic identity hasher. Production code
    /// uses the default initializer.
    init(
        controller: FocusScreenController,
        identityHasher: @escaping (String) -> String
    ) {
        self.controller = controller
        self.identityHasher = identityHasher
    }

    /// Whether the compact HUD is currently presented. The semantic server
    /// gates `hud.key` on this so it can reject keys issued while the overlay
    /// is closed.
    public var isHUDVisible: Bool { controller.isHUDVisible }

    /// Builds the content-free v3 snapshot. The snapshot is read-only and may
    /// be served even under a dry-run execution policy (it issues no commands).
    public func snapshot() -> FocusScreenSemanticSnapshotV3 {
        let state = controller.state
        let hudController = controller.semanticHUDController as? FocusHUDController
        let viewModel = hudController?.viewModel
        let frozenSnapshot = controller.isHUDVisible ? viewModel?.snapshot : nil
        let inspectedScreenID: FocusScreenID?
        let appIdentityHashes: [String]
        let workspaceAppIdentityHashes: [String]
        let layoutMode: FocusSemanticHUDLayoutMode
        let workspaceSections: [FocusSemanticHUDWorkspaceSection]
        let keyAssignmentRevision: UInt64
        let presentationRevision: UInt64
        let settledRevision: UInt64
        let interactionRevision: UInt64
        let renderedPresentationRevision: UInt64
        let renderedInteractionRevision: UInt64
        let renderedState: FocusHUDRenderedState
        let hoverRevision: UInt64
        let renderedHoverRevision: UInt64
        let visibleNameCount: Int
        let nameFocusSource: FocusSemanticHUDNameFocusSource
        let hudInventoryRevision: UInt64
        if let frozenSnapshot {
            let activeSection = frozenSnapshot.sections.first(where: \.isCurrent)
            inspectedScreenID = activeSection?.screenID
            appIdentityHashes = Array(Set(
                frozenSnapshot.sections.flatMap(\.apps).map(\.appIdentityHash)
            )).sorted()
            workspaceAppIdentityHashes = Array(Set(
                activeSection?.apps.map(\.appIdentityHash) ?? []
            )).sorted()
            let rowCounts: [Int]
            if let layout = frozenSnapshot.layout.availableLayout,
               layout.workspaceLayouts.count == frozenSnapshot.sections.count,
               zip(layout.workspaceLayouts, frozenSnapshot.sections).allSatisfy({ layout, section in
                   layout.appCount == section.apps.count && (0...3).contains(layout.rowCount)
               }) {
                rowCounts = layout.workspaceLayouts.map(\.rowCount)
            } else {
                rowCounts = Array(repeating: 0, count: frozenSnapshot.sections.count)
            }
            layoutMode = .workspaceOverview
            workspaceSections = zip(frozenSnapshot.sections, rowCounts).map { section, rowCount in
                FocusSemanticHUDWorkspaceSection(
                    screenID: section.screenID,
                    appIdentityHashes: section.apps.map(\.appIdentityHash),
                    shortcutCount: section.apps.lazy.filter { $0.shortcut != nil }.count,
                    rowCount: rowCount
                )
            }
            keyAssignmentRevision = frozenSnapshot.keyAssignmentRevision
            presentationRevision = frozenSnapshot.presentationRevision
            settledRevision = frozenSnapshot.presentationRevision
            interactionRevision = viewModel?.interactionRevision ?? 0
            renderedPresentationRevision = viewModel?.renderedPresentationRevision ?? 0
            renderedInteractionRevision = viewModel?.renderedInteractionRevision ?? 0
            renderedState = viewModel?.renderedState ?? .empty
            hoverRevision = viewModel?.hoverRevision ?? 0
            renderedHoverRevision = viewModel?.renderedHoverRevision ?? 0
            visibleNameCount = viewModel?.visibleNameCount ?? 0
            nameFocusSource = viewModel?.nameFocusSource ?? .none
            hudInventoryRevision = frozenSnapshot.inventoryRevision
        } else {
            let liveInspectedScreenID = state.inspectedScreenID
            inspectedScreenID = liveInspectedScreenID
            let displayedAppIDs = Set(state.screen(id: liveInspectedScreenID)?.windowIDs.compactMap {
                state.windows[$0]?.appID
            } ?? [])
            let workspaceAppIDs = controller.workspaceAppIDsByScreen[liveInspectedScreenID]
                ?? displayedAppIDs
            appIdentityHashes = displayedAppIDs.map(identityHasher).sorted()
            workspaceAppIdentityHashes = workspaceAppIDs.map(identityHasher).sorted()
            layoutMode = .segmented
            workspaceSections = []
            keyAssignmentRevision = 0
            presentationRevision = 0
            settledRevision = 0
            interactionRevision = 0
            renderedPresentationRevision = 0
            renderedInteractionRevision = 0
            renderedState = .empty
            hoverRevision = 0
            renderedHoverRevision = 0
            visibleNameCount = 0
            nameFocusSource = .none
            hudInventoryRevision = controller.inventoryRevision
        }
        let hud = FocusSemanticHUD(
            visible: controller.isHUDVisible,
            isKeyWindow: controller.isHUDVisible && hudController?.isPanelKeyWindow == true,
            inspectedScreenID: inspectedScreenID,
            page: 0,
            keyAssignmentRevision: keyAssignmentRevision,
            presentationRevision: presentationRevision,
            settledRevision: settledRevision,
            interactionRevision: interactionRevision,
            renderedPresentationRevision: renderedPresentationRevision,
            renderedInteractionRevision: renderedInteractionRevision,
            renderedLayoutState: renderedState.layoutState,
            renderedCellSize: renderedState.cellSize,
            renderedVisibleIconSize: renderedState.visibleIconSize,
            renderedNameFontSize: renderedState.nameFontSize,
            renderedBadgeSize: renderedState.badgeSize,
            renderedBadgeFontSize: renderedState.badgeFontSize,
            renderedAppTargetCount: renderedState.appTargetCount,
            renderedDismissTargetCount: renderedState.dismissTargetCount,
            renderedEmptyWorkspaceCount: renderedState.emptyWorkspaceCount,
            hoverRevision: hoverRevision,
            renderedHoverRevision: renderedHoverRevision,
            visibleNameCount: visibleNameCount,
            nameFocusSource: nameFocusSource,
            inventoryStatus: inventoryStatus(controller.inventoryStatus),
            inventoryRevision: hudInventoryRevision,
            appIdentityHashes: appIdentityHashes,
            workspaceAppIdentityHashes: workspaceAppIdentityHashes,
            layoutMode: layoutMode,
            workspaceSections: workspaceSections,
            lastCloseReason: hudController?.lastCloseReason ?? .none,
            lastMouseRoute: hudController?.lastMouseRoute ?? .staleIgnored,
            matchedFocusAttempt: hudController?.matchedFocusAttempt ?? false,
            activation: controller.hudActivation
        )

        let screens = state.screens.map { screen -> FocusSemanticScreen in
            FocusSemanticScreen(
                id: screen.id,
                number: screen.number,
                lifecycle: screen.lifecycle.rawValue,
                windowIDs: screen.windowIDs,
                activeWindowID: screen.lastActiveWindowID,
                layoutRevision: UInt64(state.revision)
            )
        }

        // The window the runtime has committed focus to is the active Screen's
        // last-active window. `FocusScreenReducer.commitSwitch` /
        // `registerUnowned` / `assign` maintain it as the target of the most
        // recent commit, and `WindowPresentationCoordinator` raises+focuses it
        // during a switch transaction. The semantic snapshot MUST reflect this
        // truthfully so callers (scenarios, contract tests) can observe the
        // post-commit focus state without waiting for an AX focus event to
        // round-trip through the observation service (which does not reliably
        // fire for non-activating programmatic raises).
        let focusedWindowID = state.screen(id: state.activeScreenID)?.lastActiveWindowID

        // Real stitched-Canvas regions from the topology provider, so scenarios
        // can test on-/off-Canvas intersection against the actual display
        // topology instead of a placeholder. Falls back to a degenerate 1×1
        // region only if the topology is unavailable.
        let canvasRegions = controller.semanticCanvasRegions
        let canvasFrames = canvasRegions.map(\.frame)
        let isOnCanvas = { (frame: CanvasRect) -> Bool in
            canvasFrames.contains { $0.contains(frame.center) }
        }

        let windows = state.windows.map { (windowID, window) in
            // Project the window's REAL post-transaction frame: the live AX
            // frame read back after the last switch commit / Reveal All
            // (`presentedFrames`), falling back to the canonical frame before
            // any transaction has run. This lets the snapshot truthfully
            // distinguish a parked (off-Canvas) background-Screen window from a
            // restored (on-Canvas) active-Screen window — the core Screen-
            // switching (window-visibility) behavior, NOT physical-display
            // switching.
            let frame = controller.presentedFrames[windowID] ?? window.canonicalFrame
            // Visibility reflects real Screen-switching (window-visibility)
            // semantics, NOT physical-display switching:
            //  - Compatible windows: visible iff their post-transaction frame
            //    is on the Canvas (a parked background-Screen window is off-
            //    Canvas and thus not visible; a restored active-Screen window
            //    is on-Canvas and visible).
            //  - Incompatible windows: per spec they degrade to `As Is` and
            //    stay visible in place; they are never parked, so a window
            //    observed on the Canvas remains visible.
            let visible = window.isCompatible ? isOnCanvas(frame) : isOnCanvas(window.canonicalFrame)
            return FocusSemanticWindow(
                id: windowID,
                appIdentityHash: identityHasher(window.appID),
                screenID: screenID(owning: windowID, in: state) ?? state.activeScreenID,
                visible: visible,
                minimized: false,
                focused: windowID == focusedWindowID,
                frame: frame,
                compatibility: window.isCompatible ? "compatible" : "incompatible",
                transactionRevision: UInt64(state.revision)
            )
        }.sorted { (lhs: FocusSemanticWindow, rhs: FocusSemanticWindow) in lhs.id < rhs.id }

        let resolvedCanvasRegions = canvasRegions.isEmpty
            ? [FocusSemanticCanvasRegion(
                id: "canvas",
                frame: CanvasRect(x: 0, y: 0, width: 1, height: 1),
                scale: 1
              )]
            : canvasRegions

        let pointer = FocusSemanticPointer(
            regionID: nil,
            position: nil,
            intendedWindowID: nil,
            landingRevision: 0
        )

        // Phase 1B: project Saved Spaces (content-free).
        let semanticSpaces = state.savedSpaces.map { space in
            FocusSemanticSpace(
                id: space.id,
                number: space.number,
                namePresent: space.name != nil,
                lifecycle: space.lifecycle.rawValue,
                layoutRevision: space.layoutRevision,
                windowSlotCount: space.appSlots.count,
                resolvedSlotCount: space.appSlots.filter { $0.status == .resolved }.count,
                boundScreenID: space.boundScreenID,
                autoSaveSuspended: space.autoSaveSuspended
            )
        }

        // Phase 1C: project Panes and Tabs from active Screen layouts.
        var semanticPanes: [FocusSemanticPane] = []
        var semanticTabs: [FocusSemanticTab] = []
        for screen in state.screens {
            guard let layout = screen.layout else { continue }
            for pane in layout.panes {
                semanticPanes.append(FocusSemanticPane(
                    id: pane.id,
                    screenID: screen.id,
                    role: pane.role,
                    ratioPrimary: pane.ratio.primary,
                    ratioSecondary: pane.ratio.secondary,
                    tabIDs: pane.tabIDs,
                    activeTabID: pane.activeTabID,
                    frame: pane.frame
                ))
            }
            for (tabID, tab) in layout.tabs {
                let order = paneOrder(of: tabID, in: layout)
                let paneID = paneID(containing: tabID, in: layout) ?? ""
                semanticTabs.append(FocusSemanticTab(
                    id: tabID,
                    windowID: tab.windowID,
                    paneID: paneID,
                    state: tab.state.rawValue,
                    order: order
                ))
            }
        }

        return FocusScreenSemanticSnapshotV3(
            hud: hud,
            screens: screens,
            windows: windows,
            canvasRegions: resolvedCanvasRegions,
            spaces: semanticSpaces,
            panes: semanticPanes,
            tabs: semanticTabs,
            pointer: pointer,
            stateRevision: UInt64(state.revision)
        )
    }

    // MARK: - Mutation (routes through controller intents, same as UI)

    /// `hud.open` — opens the compact HUD via the SAME `openSwitcher()` path the
    /// global shortcut / panel presenter uses.
    public func openHUD() {
        controller.openSwitcher()
    }

    /// `hud.close` — closes the compact HUD via the SAME `closeSwitcher()` path.
    public func closeHUD() {
        controller.closeSwitcher()
    }

    /// `hud.key` — forwards a semantic key through the SAME `FocusHUDViewModel`
    /// pipeline the keyboard monitor drives. Returns the resulting intent.
    @discardableResult
    public func sendHUDKey(_ key: FocusHUDOverviewKey) -> FocusHUDOverviewIntent {
        controller.sendHUDKey(key)
    }

    /// `screen.create` — creates a new blank Screen via the SAME
    /// `createBlankScreen` reducer transition the UI uses.
    public func createScreen(id: FocusScreenID) throws {
        try controller.createBlankScreen(id: id)
    }

    /// `screen.switch` — runs the SAME exact-window switch transaction the HUD
    /// drives (`switchTo(screenID:targeting:)`), including the pointer landing
    /// policy and the Reveal All recovery path on failure.
    func switchScreen(id: FocusScreenID, windowID: ManagedWindowID) async -> WindowPresentationResult {
        await controller.switchTo(screenID: id, targeting: windowID)
    }

    /// `screen.close` — runs the SAME closing transition the UI uses
    /// (`FocusScreenController.beginClosing`), which wraps the reducer's
    /// `beginClosing` transition. The semantic server still gates `screen.close`
    /// on execution policy before calling this, and maps the typed reducer error
    /// (e.g. `soleScreenCannotClose`, `screenMissing`, `invalidLifecycle`) to an
    /// error code. Empty Screens finish synchronously because they have no
    /// window-close transaction; non-empty Screens retain the existing staged
    /// close behavior.
    public func closeScreen(id: FocusScreenID) throws {
        try controller.closeScreenForSemanticDiagnostics(screenID: id)
    }

    public func closeOwnedScreen(
        expected: FocusSemanticScreen
    ) -> FocusSemanticOwnedScreenCloseOutcome {
        controller.closeOwnedEmptyScreenForSemanticDiagnostics(expected: expected)
    }

    /// `recovery.revealAll` — runs Reveal All through the SAME
    /// `SafetyRecoveryCoordinator` path the permission-loss / termination hooks
    /// use. Recovery is best-effort; the result is exposed for diagnostics.
    @discardableResult
    func revealAll() async -> SafetyRecoveryResult {
        await controller.revealAllForSemanticDiagnostics()
    }

    // MARK: - Phase 1B: Space operations (route through controller, same as UI)

    /// `space.save` — saves the active Screen's structure into a Saved Space.
    func saveSpace(id: SavedSpaceID, name: String? = nil) throws {
        try controller.saveSpace(id: id, name: name)
    }

    /// `space.restore` — restores a restorable Saved Space into a Screen.
    func restoreSpace(_ spaceID: SavedSpaceID, into screenID: FocusScreenID) throws {
        try controller.restoreSpace(spaceID, into: screenID)
    }

    // MARK: - Phase 1C: Pane/Tab operations (route through controller, same as UI)

    /// `layout.set` — sets the Layout kind for a Screen.
    func setLayout(_ kind: LayoutKind, for screenID: FocusScreenID) throws {
        try controller.setLayout(kind, for: screenID)
    }

    /// `tab.activate` — activates a Tab within a Pane.
    func activateTab(_ tabID: TabID, in paneID: PaneID, screenID: FocusScreenID) throws {
        try controller.activateTab(tabID, in: paneID, screenID: screenID)
    }

    /// `tab.move` — moves a Tab to another Pane.
    func moveTab(_ tabID: TabID, to paneID: PaneID, screenID: FocusScreenID) throws {
        try controller.moveTab(tabID, to: paneID, screenID: screenID)
    }

    /// `tab.close` — closes a Tab (active → right-neighbor-first).
    func closeTab(_ tabID: TabID, in paneID: PaneID, screenID: FocusScreenID) throws {
        try controller.closeTab(tabID, in: paneID, screenID: screenID)
    }

    /// `pane.resize` — sets the normalized Pane ratio.
    func setPaneRatio(_ paneID: PaneID, ratio: PaneRatio, screenID: FocusScreenID) throws {
        try controller.setPaneRatio(paneID, ratio: ratio, screenID: screenID)
    }

    // MARK: - Helpers

    private func inventoryStatus(_ status: FocusHUDWindowDiscoveryStatus) -> String {
        switch status {
        case .loading: "loading"
        case .ready: "ready"
        case .accessibilityRequired: "accessibility_required"
        case .unavailable: "unavailable"
        }
    }

    private func screenID(owning windowID: ManagedWindowID, in state: FocusScreenState) -> FocusScreenID? {
        state.screens.first { $0.windowIDs.contains(windowID) }?.id
    }

    private func paneID(containing tabID: TabID, in layout: FocusLayout) -> PaneID? {
        layout.panes.first { $0.tabIDs.contains(tabID) }?.id
    }

    private func paneOrder(of tabID: TabID, in layout: FocusLayout) -> Int {
        for pane in layout.panes {
            if let index = pane.tabIDs.firstIndex(of: tabID) {
                return index
            }
        }
        return 0
    }
}
