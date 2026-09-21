// MARK: - Phase 1B: Window routing engine

/// The deterministic rule that decides which Screen a newly created top-level
/// window lands in. Every manageable window belongs to exactly one Screen.
///
/// Routing targets a **Saved Space and optional Pane role, not a transient
/// Screen number**. If the routed Space is closed, Screen Switcher
/// does NOT silently restore it — the window falls back to the Active Screen.
public struct WindowRoutingDecision: Equatable, Sendable {
    public let targetScreenID: FocusScreenID
    public let reason: RoutingReason
    /// When the routing fell back because a routed Space was closed, this carries
    /// the Space ID so the runtime can offer a reversible notice.
    public let closedSpaceFallbackID: SavedSpaceID?

    public init(targetScreenID: FocusScreenID, reason: RoutingReason, closedSpaceFallbackID: SavedSpaceID? = nil) {
        self.targetScreenID = targetScreenID
        self.reason = reason
        self.closedSpaceFallbackID = closedSpaceFallbackID
    }
}

public enum RoutingReason: String, Codable, Equatable, Sendable {
    /// A Pane `+` or other explicit destination intent was provided.
    case explicitPane
    /// A pending Saved Space restore slot claims this window.
    case pendingSlot
    /// An App routing rule targets a Saved Space + optional Pane role.
    case appRoute
    /// The same App already has a window in the Active Screen.
    case sameAppActiveScreen
    /// The App exists in exactly one other open Screen.
    case appOnlyOpenScreen
    /// Ambiguous or unmatched: join the Active Screen's default Pane.
    case activeScreenDefault
}

public enum FocusWindowRouter {

    /// Routes a newly observed top-level window according to the 
    /// precedence chain:
    ///
    /// 1. explicit Pane / Restore intent
    /// 2. pending Saved Space slot
    /// 3. App route (Saved Space + optional Pane role)
    /// 4. same-App Pane in the Active Screen
    /// 5. the App's only open Screen
    /// 6. Active Screen's default Pane
    ///
    /// Returns `nil` only if there is no active Screen (bootstrap not complete).
    public static func route(
        bundleID: String,
        state: FocusScreenState,
        explicitScreenID: FocusScreenID? = nil,
        pendingSlotID: String? = nil
    ) -> WindowRoutingDecision? {
        guard let activeScreen = state.screen(id: state.activeScreenID) else {
            return nil
        }

        // 1. Explicit Pane intent (a Pane `+` provides the destination).
        if let explicit = explicitScreenID, state.screen(id: explicit) != nil {
            return WindowRoutingDecision(targetScreenID: explicit, reason: .explicitPane)
        }

        // 2. Pending Saved Space restore slot.
        if let pendingSlotID,
           let slot = findPendingSlot(id: pendingSlotID, in: state),
           let openScreenID = screenIDForOpenSpace(havingSlot: slot, in: state) {
            return WindowRoutingDecision(targetScreenID: openScreenID, reason: .pendingSlot)
        }

        // 3. App route — targets a Saved Space, not a transient Screen number.
        if let route = findAppRoute(for: bundleID, in: state) {
            // If the routed Space is open, route to its bound Screen.
            if let space = state.space(id: route.spaceID),
               space.lifecycle == .open,
               let boundScreenID = space.boundScreenID,
               state.screen(id: boundScreenID) != nil {
                return WindowRoutingDecision(targetScreenID: boundScreenID, reason: .appRoute)
            }
            // If the routed Space is closed, do NOT silently restore. Fall back
            // to active Screen, carrying the closed Space ID for a reversible notice.
            if let space = state.space(id: route.spaceID), space.lifecycle == .restorable {
                return WindowRoutingDecision(
                    targetScreenID: activeScreen.id,
                    reason: .activeScreenDefault,
                    closedSpaceFallbackID: route.spaceID
                )
            }
        }

        // 4. Same-App window in the Active Screen.
        if let _ = sameAppWindowID(bundleID: bundleID, in: activeScreen, state: state) {
            return WindowRoutingDecision(targetScreenID: activeScreen.id, reason: .sameAppActiveScreen)
        }

        // 5. App's only open Screen (if it exists in exactly one other open Screen).
        let screensWithApp = openScreensContaining(bundleID: bundleID, in: state)
        if screensWithApp.count == 1 {
            return WindowRoutingDecision(targetScreenID: screensWithApp[0], reason: .appOnlyOpenScreen)
        }

        // 6. Active Screen's default Pane (ambiguous/unmatched).
        return WindowRoutingDecision(targetScreenID: activeScreen.id, reason: .activeScreenDefault)
    }

    // MARK: - Private lookup helpers

    /// Finds a pending (unresolved) slot by ID in any open Space.
    private static func findPendingSlot(id: String, in state: FocusScreenState) -> LogicalWindowSlot? {
        for space in state.savedSpaces where space.lifecycle == .open {
            if let slot = space.appSlots.first(where: { $0.id == id && $0.status == .unresolved }) {
                return slot
            }
        }
        return nil
    }

    /// Finds the open Screen whose bound Space contains the given slot.
    private static func screenIDForOpenSpace(havingSlot slot: LogicalWindowSlot, in state: FocusScreenState) -> FocusScreenID? {
        for space in state.savedSpaces where space.lifecycle == .open {
            if space.appSlots.contains(where: { $0.id == slot.id }), let bound = space.boundScreenID {
                return bound
            }
        }
        return nil
    }

    /// Finds an App routing rule for the given bundle ID.
    private static func findAppRoute(for bundleID: String, in state: FocusScreenState) -> RoutingRule? {
        for space in state.savedSpaces {
            if let rule = space.routingRules.first(where: { $0.bundleID == bundleID }) {
                return rule
            }
        }
        return nil
    }

    /// Checks if the active Screen already has a window from this App.
    private static func sameAppWindowID(bundleID: String, in screen: FocusScreen, state: FocusScreenState) -> ManagedWindowID? {
        screen.windowIDs.first { windowID in
            state.windows[windowID]?.appID == bundleID
        }
    }

    /// Returns all open Screen IDs that contain at least one window from this App.
    private static func openScreensContaining(bundleID: String, in state: FocusScreenState) -> [FocusScreenID] {
        state.screens.filter { screen in
            screen.lifecycle == .active || screen.lifecycle == .background
        }.filter { screen in
            screen.windowIDs.contains { windowID in
                state.windows[windowID]?.appID == bundleID
            }
        }.map(\.id)
    }
}
