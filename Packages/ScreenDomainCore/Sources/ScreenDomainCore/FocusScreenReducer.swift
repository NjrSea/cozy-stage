public enum FocusScreenReducer {
    private static let maximumScreenCount = 9

    public static func bootstrap(
        currentWindows: [ManagedWindow],
        id: FocusScreenID = "screen-1"
    ) throws -> FocusScreenState {
        var windowsByID: [ManagedWindowID: ManagedWindow] = [:]
        for window in currentWindows {
            guard windowsByID[window.id] == nil else {
                throw FocusScreenDomainError.windowAlreadyOwned(window.id)
            }
            windowsByID[window.id] = window
        }

        let state = FocusScreenState(
            screens: [
                FocusScreen(
                    id: id,
                    number: 1,
                    lifecycle: .active,
                    windowIDs: currentWindows.map(\.id),
                    lastActiveWindowID: currentWindows.last?.id
                )
            ],
            windows: windowsByID,
            activeScreenID: id,
            inspectedScreenID: id,
            revision: 1
        )
        return try validated(state)
    }

    public static func createBlankScreen(
        in state: FocusScreenState,
        id: FocusScreenID
    ) throws -> FocusScreenState {
        var next = try validated(state)
        guard next.screens.count < maximumScreenCount else {
            throw FocusScreenDomainError.screenLimitReached
        }
        guard next.screen(id: id) == nil else {
            throw FocusScreenDomainError.invalidLifecycle(id)
        }
        let activeIndex = try liveScreenIndex(id: next.activeScreenID, in: next)
        let usedNumbers = Set(next.screens.map(\.number))
        guard let number = (1...maximumScreenCount).first(where: { !usedNumbers.contains($0) }) else {
            throw FocusScreenDomainError.screenLimitReached
        }

        next.screens[activeIndex].lifecycle = .background
        next.screens.append(
            FocusScreen(id: id, number: number, lifecycle: .active)
        )
        next.screens.sort(by: screenOrder)
        next.activeScreenID = id
        next.inspectedScreenID = id
        next.revision += 1
        return try validated(next)
    }

    public static func inspect(
        screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = try validated(state)
        _ = try liveScreenIndex(id: screenID, in: next)
        next.inspectedScreenID = screenID
        next.revision += 1
        return try validated(next)
    }

    public static func commitSwitch(
        screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = try validated(state)
        _ = try liveScreenIndex(id: screenID, in: next)

        for index in next.screens.indices {
            switch next.screens[index].lifecycle {
            case .active, .background:
                next.screens[index].lifecycle = next.screens[index].id == screenID ? .active : .background
            case .closing, .closed:
                break
            }
        }
        next.activeScreenID = screenID
        next.inspectedScreenID = screenID
        next.revision += 1
        return try validated(next)
    }

    public static func registerUnowned(
        _ window: ManagedWindow,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = try validated(state)
        guard next.windows[window.id] == nil else {
            throw FocusScreenDomainError.windowAlreadyOwned(window.id)
        }
        let activeIndex = try liveScreenIndex(id: next.activeScreenID, in: next)

        next.windows[window.id] = window
        next.screens[activeIndex].windowIDs.append(window.id)
        next.screens[activeIndex].lastActiveWindowID = window.id
        next.revision += 1
        return try validated(next)
    }

    public static func assign(
        windowID: ManagedWindowID,
        to screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = try validated(state)
        guard next.windows[windowID] != nil else {
            throw FocusScreenDomainError.windowMissing(windowID)
        }
        let destinationIndex = try liveScreenIndex(id: screenID, in: next)
        guard !next.screens.contains(where: { $0.windowIDs.contains(windowID) }) else {
            throw FocusScreenDomainError.windowAlreadyOwned(windowID)
        }

        next.screens[destinationIndex].windowIDs.append(windowID)
        if next.screens[destinationIndex].lastActiveWindowID == nil {
            next.screens[destinationIndex].lastActiveWindowID = windowID
        }
        next.revision += 1
        return try validated(next)
    }

    public static func beginClosing(
        screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = try validated(state)
        let closingIndex = try liveScreenIndex(id: screenID, in: next)
        guard let inspectionFallbackID = next.screens
            .filter({ $0.id != screenID && isLive($0.lifecycle) })
            .sorted(by: screenOrder)
            .first?.id
        else {
            throw FocusScreenDomainError.soleScreenCannotClose
        }

        let wasActive = next.activeScreenID == screenID
        next.screens[closingIndex].lifecycle = .closing
        if wasActive {
            for index in next.screens.indices where isLive(next.screens[index].lifecycle) {
                next.screens[index].lifecycle = next.screens[index].id == inspectionFallbackID ? .active : .background
            }
            next.activeScreenID = inspectionFallbackID
            next.inspectedScreenID = inspectionFallbackID
        } else if next.inspectedScreenID == screenID {
            next.inspectedScreenID = inspectionFallbackID
        }
        next.revision += 1
        return try validated(next)
    }

    public static func cancelClosing(
        screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = try validated(state)
        guard let index = next.screens.firstIndex(where: { $0.id == screenID }) else {
            throw FocusScreenDomainError.screenMissing(screenID)
        }
        guard next.screens[index].lifecycle == .closing else {
            throw FocusScreenDomainError.invalidLifecycle(screenID)
        }

        next.screens[index].lifecycle = screenID == next.activeScreenID ? .active : .background
        next.revision += 1
        return try validated(next)
    }

    public static func finishClosing(
        screenID: FocusScreenID,
        in state: FocusScreenState
    ) throws -> FocusScreenState {
        var next = try validated(state)
        guard let closingIndex = next.screens.firstIndex(where: { $0.id == screenID }) else {
            throw FocusScreenDomainError.screenMissing(screenID)
        }
        guard next.screens[closingIndex].lifecycle == .closing else {
            throw FocusScreenDomainError.invalidLifecycle(screenID)
        }

        let removedWindowIDs = next.screens[closingIndex].windowIDs
        next.screens.remove(at: closingIndex)
        for windowID in removedWindowIDs {
            next.windows.removeValue(forKey: windowID)
        }

        next.screens.sort(by: screenOrder)
        for index in next.screens.indices {
            next.screens[index].number = index + 1
        }
        // Window cleanup, Screen removal, and number compaction are one atomic
        // domain transition, so finishing a close advances revision once.
        next.revision += 1
        return try validated(next)
    }

    private static func liveScreenIndex(
        id: FocusScreenID,
        in state: FocusScreenState
    ) throws -> Int {
        guard let index = state.screens.firstIndex(where: { $0.id == id }) else {
            throw FocusScreenDomainError.screenMissing(id)
        }
        guard isLive(state.screens[index].lifecycle) else {
            throw FocusScreenDomainError.invalidLifecycle(id)
        }
        return index
    }

    private static func isLive(_ lifecycle: FocusScreenLifecycle) -> Bool {
        lifecycle == .active || lifecycle == .background
    }

    private static func screenOrder(_ left: FocusScreen, _ right: FocusScreen) -> Bool {
        if left.number == right.number {
            return left.id < right.id
        }
        return left.number < right.number
    }

    @discardableResult
    private static func validated(_ state: FocusScreenState) throws -> FocusScreenState {
        guard !state.screens.isEmpty, state.screens.count <= maximumScreenCount else {
            throw FocusScreenDomainError.screenLimitReached
        }

        var screenIDs = Set<FocusScreenID>()
        var screenNumbers = Set<Int>()
        var ownedWindowIDs = Set<ManagedWindowID>()
        for screen in state.screens {
            guard screen.lifecycle != .closed else {
                throw FocusScreenDomainError.invalidLifecycle(screen.id)
            }
            guard screenIDs.insert(screen.id).inserted,
                  (1...maximumScreenCount).contains(screen.number),
                  screenNumbers.insert(screen.number).inserted
            else {
                throw FocusScreenDomainError.invalidLifecycle(screen.id)
            }
            for windowID in screen.windowIDs {
                guard state.windows[windowID] != nil else {
                    throw FocusScreenDomainError.windowMissing(windowID)
                }
                guard ownedWindowIDs.insert(windowID).inserted else {
                    throw FocusScreenDomainError.windowAlreadyOwned(windowID)
                }
            }
            if let lastActiveWindowID = screen.lastActiveWindowID,
               !screen.windowIDs.contains(lastActiveWindowID) {
                throw FocusScreenDomainError.windowMissing(lastActiveWindowID)
            }
        }

        for (windowID, window) in state.windows where windowID != window.id {
            throw FocusScreenDomainError.windowMissing(windowID)
        }

        guard let activeScreen = state.screen(id: state.activeScreenID) else {
            throw FocusScreenDomainError.screenMissing(state.activeScreenID)
        }
        guard let inspectedScreen = state.screen(id: state.inspectedScreenID) else {
            throw FocusScreenDomainError.screenMissing(state.inspectedScreenID)
        }
        guard isLive(inspectedScreen.lifecycle) else {
            throw FocusScreenDomainError.invalidLifecycle(inspectedScreen.id)
        }
        guard activeScreen.lifecycle == .active else {
            throw FocusScreenDomainError.invalidLifecycle(activeScreen.id)
        }

        let activeLifecycleIDs = state.screens
            .filter { $0.lifecycle == .active }
            .map(\.id)
        guard activeLifecycleIDs == [activeScreen.id] else {
            throw FocusScreenDomainError.invalidLifecycle(activeScreen.id)
        }

        return state
    }
}
