// MARK: - Phase 1C: Pane/Tab lifecycle reducer

/// Pure state-machine transitions for Pane/Tab lifecycle within a Screen's
/// Layout.
///
/// Like the screen/space reducers, this is an enum namespace with `public static
/// func` transitions that throw `FocusPaneDomainError`.
public enum FocusPaneReducer {

    /// Sets the Layout kind for a Screen, creating the appropriate Pane structure
    ///. Split creates 2 Panes; Focus+Stack creates 3 Panes.
    public static func setLayout(
        _ kind: LayoutKind,
        for screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        guard let screenIndex = next.screens.firstIndex(where: { $0.id == screenID }) else {
            throw FocusScreenDomainError.screenMissing(screenID)
        }

        switch kind {
        case .asIs:
            // Downgrade to As Is: clear the layout but keep window ownership.
            next.screens[screenIndex].layout = nil
        case .focus:
            next.screens[screenIndex].layout = FocusLayout(
                kind: .focus,
                panes: [FocusPane(id: paneID(for: 0), role: "primary")]
            )
        case .split:
            next.screens[screenIndex].layout = FocusLayout(
                kind: .split,
                panes: [
                    FocusPane(id: paneID(for: 0), role: "primary", ratio: PaneRatio(primary: 0.5)),
                    FocusPane(id: paneID(for: 1), role: "secondary", ratio: PaneRatio(primary: 0.5))
                ]
            )
        case .focusStack:
            next.screens[screenIndex].layout = FocusLayout(
                kind: .focusStack,
                panes: [
                    FocusPane(id: paneID(for: 0), role: "primary", ratio: PaneRatio(primary: 0.6, secondary: 0.5)),
                    FocusPane(id: paneID(for: 1), role: "secondary-top", ratio: PaneRatio(primary: 0.4, secondary: 0.5)),
                    FocusPane(id: paneID(for: 2), role: "secondary-bottom", ratio: PaneRatio(primary: 0.4, secondary: 0.5))
                ]
            )
        }

        if next.screens[screenIndex].layout != nil {
            next.screens[screenIndex].layout?.revision += 1
        }
        next.revision += 1
        return next
    }

    /// Activates a Tab within a Pane. Only one Tab may be active per Pane
    /// (click a Tab to activate its window).
    public static func activateTab(
        _ tabID: TabID,
        in paneID: PaneID,
        screenID: FocusScreenID,
        state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        try mutateLayout(screenID: screenID, in: &next) { layout in
            guard let paneIndex = layout.panes.firstIndex(where: { $0.id == paneID }) else {
                throw FocusPaneDomainError.paneMissing(paneID)
            }
            guard layout.tabs[tabID] != nil else {
                throw FocusPaneDomainError.tabMissing(tabID)
            }
            guard layout.panes[paneIndex].tabIDs.contains(tabID) else {
                throw FocusPaneDomainError.tabMissing(tabID)
            }

            // Deactivate all tabs in this pane, then activate the target.
            for tid in layout.panes[paneIndex].tabIDs {
                layout.tabs[tid]?.state = (tid == tabID) ? .active : .inactive
            }
            layout.panes[paneIndex].activeTabID = tabID
            layout.revision += 1
        }
        return next
    }

    /// Moves a Tab to another Pane, preserving Tab order (drag to
    /// another existing Pane to move the concrete window).
    public static func moveTab(
        _ tabID: TabID,
        to destinationPaneID: PaneID,
        screenID: FocusScreenID,
        state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        try mutateLayout(screenID: screenID, in: &next) { layout in
            guard let destIndex = layout.panes.firstIndex(where: { $0.id == destinationPaneID }) else {
                throw FocusPaneDomainError.paneMissing(destinationPaneID)
            }
            guard layout.tabs[tabID] != nil else {
                throw FocusPaneDomainError.tabMissing(tabID)
            }

            // Remove from source pane.
            for i in layout.panes.indices where layout.panes[i].tabIDs.contains(tabID) {
                layout.panes[i].tabIDs.removeAll { $0 == tabID }
                if layout.panes[i].activeTabID == tabID {
                    // Close active → prefer right neighbor, else left.
                    layout.panes[i].activeTabID = layout.panes[i].tabIDs.first
                }
            }

            // Append to destination pane.
            layout.panes[destIndex].tabIDs.append(tabID)
            // The moved tab becomes inactive in the new pane (unless it's the only tab).
            layout.tabs[tabID]?.state = layout.panes[destIndex].tabIDs.count == 1 ? .active : .inactive
            if layout.panes[destIndex].activeTabID == nil {
                layout.panes[destIndex].activeTabID = tabID
            }
            layout.revision += 1
        }
        return next
    }

    /// Closes a Tab. Closing the active Tab prefers the right neighbor before
    /// the left; closing an inactive Tab removes it immediately.
    public static func closeTab(
        _ tabID: TabID,
        in paneID: PaneID,
        screenID: FocusScreenID,
        state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        try mutateLayout(screenID: screenID, in: &next) { layout in
            guard let paneIndex = layout.panes.firstIndex(where: { $0.id == paneID }) else {
                throw FocusPaneDomainError.paneMissing(paneID)
            }
            guard let closeIndex = layout.panes[paneIndex].tabIDs.firstIndex(of: tabID) else {
                throw FocusPaneDomainError.tabMissing(tabID)
            }

            let wasActive = layout.panes[paneIndex].activeTabID == tabID
            layout.panes[paneIndex].tabIDs.remove(at: closeIndex)
            layout.tabs.removeValue(forKey: tabID)

            if wasActive {
                // Prefer the tab to the right; if none, use the left.
                let rightNeighbor = closeIndex < layout.panes[paneIndex].tabIDs.count
                    ? layout.panes[paneIndex].tabIDs[closeIndex]
                    : nil
                let leftNeighbor = closeIndex > 0
                    ? layout.panes[paneIndex].tabIDs[closeIndex - 1]
                    : nil
                let newActive = rightNeighbor ?? leftNeighbor

                layout.panes[paneIndex].activeTabID = newActive
                if let newActive {
                    layout.tabs[newActive]?.state = .active
                }
            }
            layout.revision += 1
        }
        return next
    }

    /// Sets the normalized Pane ratio (dragging a divider or legal
    /// window-edge drag maps to the same domain operation).
    public static func setPaneRatio(
        _ paneID: PaneID,
        ratio: PaneRatio,
        screenID: FocusScreenID,
        state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        try mutateLayout(screenID: screenID, in: &next) { layout in
            guard let paneIndex = layout.panes.firstIndex(where: { $0.id == paneID }) else {
                throw FocusPaneDomainError.paneMissing(paneID)
            }
            layout.panes[paneIndex].ratio = ratio
            layout.revision += 1
        }
        return next
    }

    /// Downgrades a Screen to As Is: clears the layout but keeps window
    /// ownership ( compatibility downgrade).
    public static func downgradeToAsIs(
        screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        try setLayout(.asIs, for: screenID, in: state)
    }

    // MARK: - Private helpers

    private static func mutateLayout(
        screenID: FocusScreenID,
        in state: inout FocusScreenState,
        body: (inout FocusLayout) throws -> Void
    ) throws {
        guard let screenIndex = state.screens.firstIndex(where: { $0.id == screenID }) else {
            throw FocusScreenDomainError.screenMissing(screenID)
        }
        guard state.screens[screenIndex].layout != nil else {
            throw FocusPaneDomainError.layoutNotSet
        }
        try body(&state.screens[screenIndex].layout!)
        state.revision += 1
    }

    private static func paneID(for index: Int) -> PaneID {
        "pane-\(index + 1)"
    }
}
