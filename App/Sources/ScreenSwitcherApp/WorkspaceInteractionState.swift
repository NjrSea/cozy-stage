import PagedNavigationCore

public enum WorkspaceInteractionEffect: Equatable, Sendable {
    case selectTab(WorkspaceTab)
    case selectDisplay(String)
    case selectAppPage(Int)
    case executionRequested(WorkspaceExecutionRequest)
    case close(WorkspaceCloseReason)
}

public struct WorkspaceGestureSessionID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum WorkspaceGestureInput: Equatable, Sendable {
    case began(
        sessionID: WorkspaceGestureSessionID,
        dx: Double,
        dy: Double,
        velocityX: Double,
        velocityY: Double
    )
    case changed(
        sessionID: WorkspaceGestureSessionID,
        dx: Double,
        dy: Double,
        velocityX: Double,
        velocityY: Double
    )
    case ended(sessionID: WorkspaceGestureSessionID)
    case cancelled(sessionID: WorkspaceGestureSessionID)

    public var sessionID: WorkspaceGestureSessionID {
        switch self {
        case let .began(sessionID, _, _, _, _),
             let .changed(sessionID, _, _, _, _),
             let .ended(sessionID),
             let .cancelled(sessionID):
            return sessionID
        }
    }

    fileprivate var startsSession: Bool {
        if case .began = self { return true }
        return false
    }

    fileprivate var pageInput: PageGestureInput {
        switch self {
        case let .began(_, dx, dy, velocityX, velocityY),
             let .changed(_, dx, dy, velocityX, velocityY):
            return .changed(dx: dx, dy: dy, velocityX: velocityX, velocityY: velocityY)
        case .ended:
            return .ended
        case .cancelled:
            return .cancelled
        }
    }
}

public enum WorkspaceKeyCommand: Equatable, Sendable {
    case previousAppPage
    case nextAppPage
    case displayIndex(Int)
    case appLetter(Int)
    case returnKey
    case escape
}

public enum WorkspaceExecutionTarget: Equatable, Sendable {
    case display(String)
    case app(displayID: String, appID: String)
}

public struct WorkspaceExecutionID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct WorkspaceExecutionRequest: Equatable, Sendable {
    public let id: WorkspaceExecutionID
    public let target: WorkspaceExecutionTarget

    public init(id: WorkspaceExecutionID, target: WorkspaceExecutionTarget) {
        self.id = id
        self.target = target
    }
}

public enum WorkspaceExecutionOutcome: Equatable, Sendable {
    case success
    case failure(SwitcherActionFailure)
}

public struct WorkspaceExecutionCompletion: Equatable, Sendable {
    public let id: WorkspaceExecutionID
    public let target: WorkspaceExecutionTarget
    public let outcome: WorkspaceExecutionOutcome

    public init(
        id: WorkspaceExecutionID,
        target: WorkspaceExecutionTarget,
        outcome: WorkspaceExecutionOutcome
    ) {
        self.id = id
        self.target = target
        self.outcome = outcome
    }
}

public struct WorkspaceInteractionData: Equatable, Sendable {
    public let displayIDs: [String]
    public let selectedDisplayID: String?
    public let appPagesByDisplayID: [String: [[String]]]
    public let agentsCardCount: Int
    public let focusCardCount: Int

    public init(
        displayIDs: [String],
        selectedDisplayID: String?,
        appPagesByDisplayID: [String: [[String]]],
        agentsCardCount: Int,
        focusCardCount: Int
    ) {
        self.displayIDs = displayIDs
        self.selectedDisplayID = selectedDisplayID
        self.appPagesByDisplayID = appPagesByDisplayID
        self.agentsCardCount = agentsCardCount
        self.focusCardCount = focusCardCount
    }
}

public enum WorkspaceInteractionInput: Equatable, Sendable {
    case selectTab(WorkspaceTab)
    case selectDisplay(String)
    case selectDisplayPage(Int)
    case selectAppPage(Int)
    case activateApp(String)
    case activateDisplay
    case gesture(WorkspaceGestureInput)
    case key(WorkspaceKeyCommand)
    case synchronize(WorkspaceInteractionData)
    case executionCompleted(WorkspaceExecutionCompletion)
    case interruptInputSession
}

public struct WorkspaceInteractionResult: Equatable, Sendable {
    public let effects: [WorkspaceInteractionEffect]
    public let handled: Bool

    public init(effects: [WorkspaceInteractionEffect], handled: Bool) {
        self.effects = effects
        self.handled = handled
    }
}

public struct WorkspaceInteractionState: Sendable {
    public static let displayPageSize = 4

    private enum ActiveGesture: Sendable {
        case horizontal(PageGestureReducer)
        case vertical(tab: WorkspaceTab, reducer: PageGestureReducer)
    }

    public private(set) var workspace: WorkspaceState
    public private(set) var pendingExecution: WorkspaceExecutionRequest?
    public private(set) var executionFailure: SwitcherActionFailure?
    public private(set) var displayCardTerminalRevision: UInt64 = 0

    private var appPagesByDisplayID: [String: [[String]]]
    private var cardCounts: [WorkspaceTab: Int]
    private var cardIndices: [WorkspaceTab: Int]
    private var activeGesture: ActiveGesture?
    private var activeGestureSessionID: WorkspaceGestureSessionID?
    private var latestGestureSessionID: WorkspaceGestureSessionID?
    private var nextExecutionRawValue: UInt64 = 1

    private static let pagingConfiguration = PageGestureConfiguration(
        axisLockDistance: 8,
        commitProgress: 0.22,
        commitVelocity: 720,
        edgeResistance: 0.32
    )

    public init(
        workspace: WorkspaceState,
        appPagesByDisplayID: [String: [[String]]],
        agentsCardCount: Int,
        focusCardCount: Int
    ) {
        let normalizedPages = Self.normalizedPages(appPagesByDisplayID)
        let normalizedWorkspace = Self.normalizedWorkspace(
            workspace,
            appPagesByDisplayID: normalizedPages
        )
        self.workspace = normalizedWorkspace
        executionFailure = nil
        self.appPagesByDisplayID = normalizedPages.filter {
            normalizedWorkspace.displayIDs.contains($0.key)
        }
        let safeAgentsCount = Self.sanitizedCount(agentsCardCount)
        let safeFocusCount = Self.sanitizedCount(focusCardCount)
        cardCounts = [.agents: safeAgentsCount, .focus: safeFocusCount]
        cardIndices = [.agents: 0, .focus: 0]
    }

    public var lockedAxis: NavigationAxis? {
        switch activeGesture {
        case let .horizontal(reducer):
            return reducer.lockedAxis
        case let .vertical(_, reducer):
            return reducer.lockedAxis
        case nil:
            return nil
        }
    }

    public var presentationOffset: Double {
        switch activeGesture {
        case let .horizontal(reducer):
            return reducer.presentationOffset
        case let .vertical(_, reducer):
            return reducer.presentationOffset
        case nil:
            return 0
        }
    }

    public var displayPageCount: Int {
        max((workspace.displayIDs.count + Self.displayPageSize - 1) / Self.displayPageSize, 1)
    }

    public var selectedDisplayPage: Int {
        guard let index = workspace.displayIDs.firstIndex(
            of: workspace.displayPages.selectedDisplayID
        ) else { return 0 }
        return min(index / Self.displayPageSize, displayPageCount - 1)
    }

    public var visibleDisplayIDs: [String] {
        let start = selectedDisplayPage * Self.displayPageSize
        guard start < workspace.displayIDs.count else { return [] }
        return Array(workspace.displayIDs.dropFirst(start).prefix(Self.displayPageSize))
    }

    public func selectedCardIndex(for tab: WorkspaceTab) -> Int {
        cardIndices[tab, default: 0]
    }

    public mutating func reduce(_ input: WorkspaceInteractionInput) -> [WorkspaceInteractionEffect] {
        handle(input).effects
    }

    /// Applies passive catalog content without cancelling an admitted execution.
    /// User input still goes through `handle(_:)`, whose disruptive paths retain
    /// their existing cancellation semantics.
    mutating func synchronizePassiveContent(_ data: WorkspaceInteractionData) {
        // A background AX refresh is observational: it must not discard an
        // in-progress Trackpad session whose terminal event is still pending.
        // A vertical reducer owns a fixed navigation snapshot, however. If the
        // ordered display identities or card count changes, its pending
        // destination can no longer be trusted.
        let activeVerticalTab: WorkspaceTab?
        if case let .vertical(tab, _) = activeGesture {
            activeVerticalTab = tab
        } else {
            activeVerticalTab = nil
        }
        let previousDisplayIDs = workspace.displayIDs
        let previousCardCount = activeVerticalTab.map { cardCounts[$0, default: 0] }
        synchronize(data)
        if let activeVerticalTab {
            let navigationChanged = activeVerticalTab == .switch
                ? previousDisplayIDs != workspace.displayIDs
                : previousCardCount != cardCounts[activeVerticalTab, default: 0]
            if navigationChanged {
                interruptGesture()
            }
        }
    }

    public mutating func handle(_ input: WorkspaceInteractionInput) -> WorkspaceInteractionResult {
        switch input {
        case let .selectTab(tab):
            return selectTab(tab)
        case let .selectDisplay(displayID):
            return selectDisplay(displayID)
        case let .selectDisplayPage(page):
            return selectDisplayPage(page)
        case let .selectAppPage(page):
            return selectAppPage(page)
        case let .activateApp(appID):
            return activateApp(appID)
        case .activateDisplay:
            return activateDisplay()
        case let .gesture(input):
            return reduceGesture(input)
        case let .key(command):
            return reduceKey(command)
        case let .synchronize(data):
            interruptInteractions()
            synchronize(data)
            return WorkspaceInteractionResult(effects: [], handled: true)
        case let .executionCompleted(completion):
            return completeExecution(completion)
        case .interruptInputSession:
            let hadInteraction = activeGestureSessionID != nil || pendingExecution != nil
            interruptInteractions()
            return WorkspaceInteractionResult(effects: [], handled: hadInteraction)
        }
    }

    private mutating func selectTab(_ tab: WorkspaceTab) -> WorkspaceInteractionResult {
        interruptInteractions()
        guard tab != workspace.selectedTab else { return .notHandled }
        workspace.selectedTab = tab
        return .handled([.selectTab(tab)])
    }

    private mutating func selectDisplay(_ displayID: String) -> WorkspaceInteractionResult {
        guard workspace.selectedTab == .switch,
              workspace.displayIDs.contains(displayID),
              displayID != workspace.displayPages.selectedDisplayID
        else { return .notHandled }
        interruptInteractions()
        workspace.displayPages.selectDisplay(displayID)
        return .handled([.selectDisplay(displayID)])
    }

    private mutating func selectDisplayPage(_ page: Int) -> WorkspaceInteractionResult {
        guard workspace.selectedTab == .switch,
              page >= 0,
              page < displayPageCount,
              page != selectedDisplayPage
        else { return .notHandled }
        let index = page * Self.displayPageSize
        guard workspace.displayIDs.indices.contains(index) else { return .notHandled }
        return selectDisplay(workspace.displayIDs[index])
    }

    private mutating func selectAppPage(_ page: Int) -> WorkspaceInteractionResult {
        guard workspace.selectedTab == .switch else { return .notHandled }
        let displayID = workspace.displayPages.selectedDisplayID
        let pageCount = appPagesByDisplayID[displayID, default: []].count
        guard page >= 0,
              page < pageCount,
              page != workspace.displayPages.selectedPage
        else { return .notHandled }
        interruptInteractions()
        workspace.displayPages.selectPage(page)
        return .handled([.selectAppPage(page)])
    }

    private mutating func activateApp(_ appID: String) -> WorkspaceInteractionResult {
        guard workspace.selectedTab == .switch,
              pendingExecution == nil,
              selectedPageApps().contains(appID)
        else { return .notHandled }
        interruptGesture()
        let displayID = workspace.displayPages.selectedDisplayID
        let target = WorkspaceExecutionTarget.app(displayID: displayID, appID: appID)
        let request = makeExecutionRequest(target: target)
        pendingExecution = request
        return .handled([.executionRequested(request)])
    }

    private mutating func activateDisplay() -> WorkspaceInteractionResult {
        guard workspace.selectedTab == .switch,
              pendingExecution == nil,
              !workspace.displayPages.selectedDisplayID.isEmpty
        else { return .notHandled }
        interruptGesture()
        let displayID = workspace.displayPages.selectedDisplayID
        let request = makeExecutionRequest(target: .display(displayID))
        pendingExecution = request
        return .handled([.executionRequested(request)])
    }

    private mutating func reduceGesture(_ input: WorkspaceGestureInput) -> WorkspaceInteractionResult {
        let sessionID = input.sessionID
        if input.startsSession {
            if let latestGestureSessionID, sessionID <= latestGestureSessionID {
                return .notHandled
            }
            latestGestureSessionID = sessionID
            activeGesture = nil
            activeGestureSessionID = sessionID
            pendingExecution = nil
        } else if activeGestureSessionID != sessionID {
            return .notHandled
        }

        let pageInput = input.pageInput
        if activeGesture == nil {
            guard case .changed = pageInput else {
                if Self.isTerminal(pageInput) { activeGestureSessionID = nil }
                return .handled([])
            }
            var probe = PageGestureReducer(
                pageCount: WorkspaceTab.allCases.count,
                selectedIndex: workspace.selectedTab.rawValue,
                configuration: Self.pagingConfiguration
            )
            let probeEffects = probe.reduce(pageInput)
            guard let axis = probe.lockedAxis else {
                return .handled([])
            }

            if axis == .horizontal {
                activeGesture = .horizontal(probe)
                return .handled(mapGestureEffects(
                    probeEffects,
                    axis: axis,
                    tab: workspace.selectedTab
                ))
            }

            let tab = workspace.selectedTab
            let pageCount: Int
            let selectedIndex: Int
            if tab == .switch {
                pageCount = workspace.displayIDs.count
                selectedIndex = workspace.displayIDs.firstIndex(
                    of: workspace.displayPages.selectedDisplayID
                ) ?? 0
            } else {
                pageCount = cardCounts[tab, default: 0]
                selectedIndex = cardIndices[tab, default: 0]
            }
            var reducer = PageGestureReducer(
                pageCount: pageCount,
                selectedIndex: selectedIndex,
                configuration: Self.pagingConfiguration
            )
            let effects = reducer.reduce(pageInput)
            activeGesture = .vertical(tab: tab, reducer: reducer)
            return .handled(mapGestureEffects(effects, axis: axis, tab: tab))
        }

        let isTerminal = Self.isTerminal(pageInput)
        let effects: [WorkspaceInteractionEffect]
        switch activeGesture {
        case var .horizontal(reducer):
            effects = mapGestureEffects(
                reducer.reduce(pageInput),
                axis: .horizontal,
                tab: workspace.selectedTab
            )
            activeGesture = isTerminal ? nil : .horizontal(reducer)
        case let .vertical(tab, currentReducer):
            var reducer = currentReducer
            effects = mapGestureEffects(
                reducer.reduce(pageInput),
                axis: .vertical,
                tab: tab
            )
            if isTerminal, tab == .switch {
                displayCardTerminalRevision &+= 1
            }
            activeGesture = isTerminal ? nil : .vertical(tab: tab, reducer: reducer)
        case nil:
            effects = []
        }
        if isTerminal {
            activeGestureSessionID = nil
        }
        return .handled(effects)
    }

    private mutating func mapGestureEffects(
        _ effects: [PageGestureEffect],
        axis: NavigationAxis,
        tab: WorkspaceTab
    ) -> [WorkspaceInteractionEffect] {
        var mapped: [WorkspaceInteractionEffect] = []
        for effect in effects {
            switch effect {
            case .locked, .cancelled:
                break
            case .thresholdCrossed:
                break
            case let .committed(index):
                if axis == .horizontal, WorkspaceTab.allCases.indices.contains(index) {
                    let selectedTab = WorkspaceTab.allCases[index]
                    workspace.selectedTab = selectedTab
                    pendingExecution = nil
                    mapped.append(.selectTab(selectedTab))
                } else if axis == .vertical {
                    if tab == .switch {
                        guard workspace.displayIDs.indices.contains(index) else { continue }
                        let displayID = workspace.displayIDs[index]
                        workspace.displayPages.selectDisplay(displayID)
                        mapped.append(.selectDisplay(displayID))
                    } else {
                        cardIndices[tab] = index
                    }
                }
            case .snapped:
                break
            }
        }
        return mapped
    }

    private mutating func reduceKey(_ command: WorkspaceKeyCommand) -> WorkspaceInteractionResult {
        switch command {
        case .escape:
            interruptInteractions()
            return .handled([.close(.escape)])
        case .previousAppPage:
            return pageApps(by: -1)
        case .nextAppPage:
            return pageApps(by: 1)
        case let .displayIndex(displayedIndex):
            guard workspace.selectedTab == .switch,
                  (1...3).contains(displayedIndex),
                  workspace.displayIDs.indices.contains(displayedIndex - 1)
            else { return .notHandled }
            let displayID = workspace.displayIDs[displayedIndex - 1]
            guard displayID != workspace.displayPages.selectedDisplayID else { return .notHandled }
            interruptInteractions()
            workspace.displayPages.selectDisplay(displayID)
            return .handled([.selectDisplay(displayID)])
        case let .appLetter(index):
            guard workspace.selectedTab == .switch,
                  pendingExecution == nil,
                  (0..<26).contains(index),
                  let appID = selectedPageApps().element(at: index)
            else { return .notHandled }
            interruptGesture()
            let target = WorkspaceExecutionTarget.app(
                displayID: workspace.displayPages.selectedDisplayID,
                appID: appID
            )
            let request = makeExecutionRequest(target: target)
            pendingExecution = request
            return .handled([.executionRequested(request)])
        case .returnKey:
            guard workspace.selectedTab == .switch,
                  pendingExecution == nil,
                  !workspace.displayPages.selectedDisplayID.isEmpty
            else { return .notHandled }
            interruptGesture()
            let displayID = workspace.displayPages.selectedDisplayID
            let request = makeExecutionRequest(target: .display(displayID))
            pendingExecution = request
            return .handled([.executionRequested(request)])
        }
    }

    private mutating func pageApps(by delta: Int) -> WorkspaceInteractionResult {
        guard workspace.selectedTab == .switch else { return .notHandled }
        let displayID = workspace.displayPages.selectedDisplayID
        let pageCount = appPagesByDisplayID[displayID, default: []].count
        let currentPage = workspace.displayPages.selectedPage
        let nextPage: Int
        if delta < 0 {
            guard currentPage > 0 else { return .notHandled }
            nextPage = currentPage - 1
        } else {
            guard currentPage < max(pageCount - 1, 0) else { return .notHandled }
            nextPage = currentPage + 1
        }
        interruptInteractions()
        workspace.displayPages.selectPage(nextPage)
        return .handled([.selectAppPage(nextPage)])
    }

    private func selectedPageApps() -> [String] {
        let displayID = workspace.displayPages.selectedDisplayID
        let pages = appPagesByDisplayID[displayID, default: []]
        guard pages.indices.contains(workspace.displayPages.selectedPage) else { return [] }
        return pages[workspace.displayPages.selectedPage]
    }

    private mutating func completeExecution(
        _ completion: WorkspaceExecutionCompletion
    ) -> WorkspaceInteractionResult {
        guard let pendingExecution,
              pendingExecution.id == completion.id,
              pendingExecution.target == completion.target
        else { return .notHandled }
        self.pendingExecution = nil
        switch completion.outcome {
        case .success:
            executionFailure = nil
            interruptGesture()
            return .handled([.close(.programmatic)])
        case let .failure(failure):
            executionFailure = failure
            return .handled([])
        }
    }

    private mutating func makeExecutionRequest(
        target: WorkspaceExecutionTarget
    ) -> WorkspaceExecutionRequest {
        executionFailure = nil
        let id = WorkspaceExecutionID(rawValue: nextExecutionRawValue)
        nextExecutionRawValue = nextExecutionRawValue == .max ? 1 : nextExecutionRawValue + 1
        return WorkspaceExecutionRequest(id: id, target: target)
    }

    private mutating func synchronize(_ data: WorkspaceInteractionData) {
        let previousTab = workspace.selectedTab
        let previousSelectedDisplayID = workspace.displayPages.selectedDisplayID
        let previousPages = workspace.displayPages.pageByDisplayID
        let normalizedAppPages = Self.normalizedPages(data.appPagesByDisplayID)
        var nextWorkspace = WorkspaceState(
            displayIDs: data.displayIDs,
            pointerDisplayID: nil,
            selectedTab: previousTab
        )
        let nextDisplayIDs = nextWorkspace.displayIDs
        let selectedDisplayID: String
        if let explicitSelection = data.selectedDisplayID,
           nextDisplayIDs.contains(explicitSelection) {
            selectedDisplayID = explicitSelection
        } else if nextDisplayIDs.contains(previousSelectedDisplayID) {
            selectedDisplayID = previousSelectedDisplayID
        } else {
            selectedDisplayID = nextDisplayIDs.first ?? ""
        }
        nextWorkspace.displayPages = DisplayAppPageState(
            selectedDisplayID: selectedDisplayID,
            pageByDisplayID: Self.clampedPages(
                displayIDs: nextDisplayIDs,
                requestedPages: previousPages,
                appPagesByDisplayID: normalizedAppPages
            )
        )
        workspace = nextWorkspace
        appPagesByDisplayID = normalizedAppPages.filter { nextDisplayIDs.contains($0.key) }

        let safeAgentsCount = Self.sanitizedCount(data.agentsCardCount)
        let safeFocusCount = Self.sanitizedCount(data.focusCardCount)
        cardCounts[.agents] = safeAgentsCount
        cardCounts[.focus] = safeFocusCount
        cardIndices[.agents] = Self.clampedCardIndex(
            cardIndices[.agents, default: 0],
            count: safeAgentsCount
        )
        cardIndices[.focus] = Self.clampedCardIndex(
            cardIndices[.focus, default: 0],
            count: safeFocusCount
        )
    }

    private mutating func interruptInteractions() {
        interruptGesture()
        pendingExecution = nil
    }

    private mutating func interruptGesture() {
        activeGesture = nil
        activeGestureSessionID = nil
    }

    private static func normalizedWorkspace(
        _ workspace: WorkspaceState,
        appPagesByDisplayID: [String: [[String]]]
    ) -> WorkspaceState {
        let selectedDisplayID = workspace.displayIDs.contains(workspace.displayPages.selectedDisplayID)
            ? workspace.displayPages.selectedDisplayID
            : nil
        var normalized = WorkspaceState(
            displayIDs: workspace.displayIDs,
            pointerDisplayID: selectedDisplayID,
            selectedTab: workspace.selectedTab
        )
        normalized.displayPages = DisplayAppPageState(
            selectedDisplayID: normalized.displayPages.selectedDisplayID,
            pageByDisplayID: clampedPages(
                displayIDs: normalized.displayIDs,
                requestedPages: workspace.displayPages.pageByDisplayID,
                appPagesByDisplayID: appPagesByDisplayID
            )
        )
        return normalized
    }

    private static func clampedPages(
        displayIDs: [String],
        requestedPages: [String: Int],
        appPagesByDisplayID: [String: [[String]]]
    ) -> [String: Int] {
        displayIDs.reduce(into: [:]) { pages, displayID in
            let pageCount = appPagesByDisplayID[displayID, default: []].count
            let maximumPage = pageCount > 0 ? pageCount - 1 : 0
            pages[displayID] = min(max(requestedPages[displayID, default: 0], 0), maximumPage)
        }
    }

    private static func normalizedPages(_ pages: [String: [[String]]]) -> [String: [[String]]] {
        pages.reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty else { return }
            var seenAppIDs: Set<String> = []
            var normalizedDisplayPages: [[String]] = []
            for page in entry.value {
                var normalizedPage: [String] = []
                for appID in page where !appID.isEmpty && seenAppIDs.insert(appID).inserted {
                    normalizedPage.append(appID)
                    if normalizedPage.count == 26 { break }
                }
                if !normalizedPage.isEmpty {
                    normalizedDisplayPages.append(normalizedPage)
                }
            }
            result[entry.key] = normalizedDisplayPages
        }
    }

    private static func sanitizedCount(_ count: Int) -> Int {
        max(count, 0)
    }

    private static func clampedCardIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private static func isTerminal(_ input: PageGestureInput) -> Bool {
        switch input {
        case .ended, .cancelled:
            return true
        case .changed:
            return false
        }
    }
}

private extension WorkspaceInteractionResult {
    static var notHandled: Self {
        Self(effects: [], handled: false)
    }

    static func handled(_ effects: [WorkspaceInteractionEffect]) -> Self {
        Self(effects: effects, handled: true)
    }
}

private extension Collection {
    func element(at index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
