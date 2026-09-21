// MARK: - Phase 1B: Space lifecycle reducer

/// Pure state-machine transitions for Saved Space lifecycle.
///
/// Like `FocusScreenReducer`, this is an enum namespace with `public static func`
/// transitions that throw `FocusSpaceDomainError` and run through `validated()`
/// post-conditions. All transitions bump `layoutRevision` exactly once.
public enum FocusSpaceReducer {
    private static let maximumSpaceCount = 9

    /// Snapshots the active Screen's current structure into a new or updated
    /// Saved Space and binds the Screen to it.
    ///
    /// If the Screen is already bound to a Space, the existing Space is updated
    /// with the current structure (auto-save path). If not bound, a new Space is
    /// created and the Screen is bound to it.
    public static func saveSpace(
        from state: FocusScreenState,
        id: SavedSpaceID,
        name: String? = nil
    ) throws -> FocusScreenState {
        var next = state

        // If this Screen is already bound, update the existing Space.
        if let screen = next.screen(id: next.activeScreenID),
           let existingSpaceID = screen.spaceID,
           existingSpaceID == id {
            return try updateBoundSpace(id: id, name: name, in: next)
        }

        // Check the target Space isn't already open on a different Screen.
        if let existingIndex = next.savedSpaces.firstIndex(where: { $0.id == id }) {
            guard next.savedSpaces[existingIndex].lifecycle == .restorable else {
                throw FocusSpaceDomainError.spaceAlreadyOpen(id)
            }
            // Re-bind an existing restorable Space to this Screen.
            return try bindExistingSpace(at: existingIndex, to: next.activeScreenID, name: name, in: next)
        }

        // Create a new Space from the active Screen's structure.
        guard next.savedSpaces.count < maximumSpaceCount else {
            throw FocusSpaceDomainError.spaceLimitReached
        }

        let usedNumbers = Set(next.savedSpaces.map(\.number))
        guard let number = (1...maximumSpaceCount).first(where: { !usedNumbers.contains($0) }) else {
            throw FocusSpaceDomainError.spaceLimitReached
        }

        let screen = next.screen(id: next.activeScreenID)!
        let space = makeSpaceFromScreen(id: id, number: number, name: name, screen: screen, windows: next.windows)

        next.savedSpaces.append(space)
        next.savedSpaces.sort(by: spaceOrder)
        setScreenSpaceID(next.activeScreenID, to: id, in: &next)
        return next
    }

    /// Copies the current Space model into a new Space and rebinds the Screen to
    /// the copy ( "Save as New Space").
    public static func saveAsNewSpace(
        from state: FocusScreenState,
        newID: SavedSpaceID
    ) throws -> FocusScreenState {
        var next = state

        let screen = next.screen(id: next.activeScreenID)!
        guard let sourceSpaceID = screen.spaceID,
              let sourceIndex = next.savedSpaces.firstIndex(where: { $0.id == sourceSpaceID }) else {
            // Not bound to a Space — fall back to saveSpace with the new ID.
            return try saveSpace(from: next, id: newID)
        }

        guard next.savedSpaces.firstIndex(where: { $0.id == newID }) == nil else {
            throw FocusSpaceDomainError.spaceAlreadyOpen(newID)
        }
        guard next.savedSpaces.count < maximumSpaceCount else {
            throw FocusSpaceDomainError.spaceLimitReached
        }

        let source = next.savedSpaces[sourceIndex]
        let usedNumbers = Set(next.savedSpaces.map(\.number))
        guard let number = (1...maximumSpaceCount).first(where: { !usedNumbers.contains($0) }) else {
            throw FocusSpaceDomainError.spaceLimitReached
        }

        // Copy structure, rebind to new ID (id is `let`, so construct a new struct).
        let copy = SavedSpace(
            id: newID,
            number: number,
            name: source.name,
            lifecycle: source.lifecycle,
            layoutRevision: source.layoutRevision + 1,
            canvasLayout: source.canvasLayout,
            appSlots: source.appSlots,
            defaultSlotID: source.defaultSlotID,
            routingRules: source.routingRules,
            canvasTopologyMapping: source.canvasTopologyMapping,
            autoSaveSuspended: false,
            boundScreenID: next.activeScreenID
        )
        next.savedSpaces.append(copy)
        next.savedSpaces.sort(by: spaceOrder)

        // Unbind the source Space since the Screen now points to the copy.
        if let sourceIdx = next.savedSpaces.firstIndex(where: { $0.id == sourceSpaceID }) {
            next.savedSpaces[sourceIdx].boundScreenID = nil
            next.savedSpaces[sourceIdx].lifecycle = .restorable
            next.savedSpaces[sourceIdx].layoutRevision += 1
        }
        setScreenSpaceID(next.activeScreenID, to: newID, in: &next)
        return next
    }

    /// Restores a Saved Space into a Screen, rebuilding its structure from the
    /// saved model. Enforces one-space-one-screen: if the Space is
    /// already open, it throws `spaceAlreadyOpen`.
    public static func restoreSpace(
        _ spaceID: SavedSpaceID,
        into screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state

        guard let spaceIndex = next.savedSpaces.firstIndex(where: { $0.id == spaceID }) else {
            throw FocusSpaceDomainError.spaceMissing(spaceID)
        }
        guard next.savedSpaces[spaceIndex].lifecycle == .restorable else {
            throw FocusSpaceDomainError.spaceAlreadyOpen(spaceID)
        }
        guard let screenIndex = next.screens.firstIndex(where: { $0.id == screenID }) else {
            throw FocusScreenDomainError.screenMissing(screenID)
        }
        // The destination Screen must not already be bound to another Space.
        if let existingBinding = next.screens[screenIndex].spaceID, existingBinding != spaceID {
            throw FocusSpaceDomainError.screenAlreadyBound(screenID)
        }

        let space = next.savedSpaces[spaceIndex]

        // Rebuild app slots: resolved slots that have matching windows become
        // bound; unresolved slots retain Retry. (Full window matching is a
        // runtime concern — the reducer only handles structural state.)
        next.savedSpaces[spaceIndex].lifecycle = .open
        next.savedSpaces[spaceIndex].boundScreenID = screenID
        next.savedSpaces[spaceIndex].autoSaveSuspended = false
        next.savedSpaces[spaceIndex].layoutRevision += 1

        next.screens[screenIndex].spaceID = spaceID

        // If the restored Space had a default slot, set it as the active target.
        if let defaultSlotID = space.defaultSlotID,
           let defaultSlot = space.appSlots.first(where: { $0.id == defaultSlotID }),
           let boundWindowID = defaultSlot.boundWindowID,
           next.screens[screenIndex].windowIDs.contains(boundWindowID) {
            next.screens[screenIndex].lastActiveWindowID = boundWindowID
        }

        next.revision += 1
        return next
    }

    /// Quick Close: suspends structural auto-save so closing real windows does
    /// not overwrite the Space as an empty layout.
    public static func suspendAutoSave(
        _ spaceID: SavedSpaceID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        guard let index = next.savedSpaces.firstIndex(where: { $0.id == spaceID }) else {
            throw FocusSpaceDomainError.spaceMissing(spaceID)
        }
        guard next.savedSpaces[index].lifecycle == .open else {
            throw FocusSpaceDomainError.spaceMissing(spaceID)
        }
        next.savedSpaces[index].autoSaveSuspended = true
        next.savedSpaces[index].layoutRevision += 1
        next.revision += 1
        return next
    }

    /// Resumes auto-save after a Quick Close cycle completes.
    public static func resumeAutoSave(
        _ spaceID: SavedSpaceID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        guard let index = next.savedSpaces.firstIndex(where: { $0.id == spaceID }) else {
            throw FocusSpaceDomainError.spaceMissing(spaceID)
        }
        next.savedSpaces[index].autoSaveSuspended = false
        next.savedSpaces[index].layoutRevision += 1
        next.revision += 1
        return next
    }

    /// Returns an open Space to `restorable` and unbinds its Screen.
    public static func closeSpace(
        _ spaceID: SavedSpaceID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        guard let index = next.savedSpaces.firstIndex(where: { $0.id == spaceID }) else {
            throw FocusSpaceDomainError.spaceMissing(spaceID)
        }
        guard next.savedSpaces[index].lifecycle == .open else {
            throw FocusSpaceDomainError.spaceMissing(spaceID)
        }

        let boundScreenID = next.savedSpaces[index].boundScreenID
        next.savedSpaces[index].lifecycle = .restorable
        next.savedSpaces[index].boundScreenID = nil
        next.savedSpaces[index].autoSaveSuspended = false

        // Unbind the Screen.
        if let screenID = boundScreenID,
           let screenIndex = next.screens.firstIndex(where: { $0.id == screenID }) {
            next.screens[screenIndex].spaceID = nil
        }

        next.savedSpaces[index].layoutRevision += 1
        next.revision += 1
        return next
    }

    /// Deletes a closed (restorable) Space. Only restorable Spaces
    /// can be deleted; open Spaces must be closed first.
    public static func deleteSpace(
        _ spaceID: SavedSpaceID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        guard let index = next.savedSpaces.firstIndex(where: { $0.id == spaceID }) else {
            throw FocusSpaceDomainError.spaceMissing(spaceID)
        }
        guard next.savedSpaces[index].lifecycle == .restorable else {
            throw FocusSpaceDomainError.spaceAlreadyOpen(spaceID)
        }

        next.savedSpaces.remove(at: index)
        next.savedSpaces.sort(by: spaceOrder)
        next.revision += 1
        return next
    }

    // MARK: - Private helpers

    private static func updateBoundSpace(
        id: SavedSpaceID,
        name: String?,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        guard let index = next.savedSpaces.firstIndex(where: { $0.id == id }) else {
            throw FocusSpaceDomainError.spaceMissing(id)
        }
        guard next.savedSpaces[index].lifecycle == .open else {
            throw FocusSpaceDomainError.spaceMissing(id)
        }
        // Auto-save only writes when not suspended (Quick Close).
        if next.savedSpaces[index].autoSaveSuspended {
            throw FocusSpaceDomainError.autoSaveSuspended(id)
        }

        let screen = next.screen(id: next.activeScreenID)!
        let updated = makeSpaceFromScreen(id: id, number: next.savedSpaces[index].number, name: name ?? next.savedSpaces[index].name, screen: screen, windows: next.windows)
        next.savedSpaces[index] = updated
        next.savedSpaces[index].layoutRevision += 1
        next.revision += 1
        return next
    }

    private static func bindExistingSpace(
        at index: Int,
        to screenID: FocusScreenID,
        name: String?,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = state
        next.savedSpaces[index].lifecycle = .open
        next.savedSpaces[index].boundScreenID = screenID
        next.savedSpaces[index].autoSaveSuspended = false
        if let name { next.savedSpaces[index].name = name }
        next.savedSpaces[index].layoutRevision += 1
        setScreenSpaceID(screenID, to: next.savedSpaces[index].id, in: &next)
        next.revision += 1
        return next
    }

    /// Builds a SavedSpace from a Screen's current window structure.
    private static func makeSpaceFromScreen(
        id: SavedSpaceID,
        number: Int,
        name: String?,
        screen: FocusScreen,
        windows: [ManagedWindowID: ManagedWindow]
    ) -> SavedSpace {
        var slots: [LogicalWindowSlot] = []
        var frames: [String: CanvasRect] = [:]

        for (order, windowID) in screen.windowIDs.enumerated() {
            guard let window = windows[windowID] else { continue }
            let slotID = "slot-\(order + 1)"
            slots.append(LogicalWindowSlot(
                id: slotID,
                bundleID: window.appID,
                tabOrder: order,
                boundWindowID: windowID,
                status: .resolved
            ))
            frames[slotID] = window.canonicalFrame
        }

        let defaultSlotID = slots.first?.id

        return SavedSpace(
            id: id,
            number: number,
            name: name,
            lifecycle: .open,
            layoutRevision: 1,
            canvasLayout: SavedCanvasLayout(windowFrames: frames),
            appSlots: slots,
            defaultSlotID: defaultSlotID,
            routingRules: [],
            canvasTopologyMapping: nil,
            autoSaveSuspended: false,
            boundScreenID: screen.id
        )
    }

    private static func setScreenSpaceID(
        _ screenID: FocusScreenID,
        to spaceID: SavedSpaceID,
        in state: inout FocusScreenState
    ) {
        guard let index = state.screens.firstIndex(where: { $0.id == screenID }) else { return }
        state.screens[index].spaceID = spaceID
        state.revision += 1
    }

    private static func spaceOrder(_ left: SavedSpace, _ right: SavedSpace) -> Bool {
        if left.number == right.number {
            return left.id < right.id
        }
        return left.number < right.number
    }
}
