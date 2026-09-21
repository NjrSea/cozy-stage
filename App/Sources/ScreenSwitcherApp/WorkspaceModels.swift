public enum WorkspaceTab: Int, CaseIterable, Codable, Sendable {
    case `switch`
    case agents
    case focus
}

public struct DisplayAppPageState: Equatable, Sendable {
    public var selectedDisplayID: String
    public var pageByDisplayID: [String: Int]

    public init(selectedDisplayID: String, pageByDisplayID: [String: Int] = [:]) {
        self.selectedDisplayID = selectedDisplayID
        self.pageByDisplayID = pageByDisplayID.reduce(into: [:]) { pages, entry in
            guard !entry.key.isEmpty else { return }
            pages[entry.key] = max(0, entry.value)
        }
        if !selectedDisplayID.isEmpty, self.pageByDisplayID[selectedDisplayID] == nil {
            self.pageByDisplayID[selectedDisplayID] = 0
        }
    }

    public var selectedPage: Int {
        pageByDisplayID[selectedDisplayID, default: 0]
    }

    public mutating func selectDisplay(_ displayID: String) {
        guard !displayID.isEmpty else { return }
        selectedDisplayID = displayID
        if pageByDisplayID[displayID] == nil {
            pageByDisplayID[displayID] = 0
        }
    }

    public mutating func selectPage(_ page: Int) {
        guard !selectedDisplayID.isEmpty else { return }
        pageByDisplayID[selectedDisplayID] = max(0, page)
    }
}

public struct WorkspaceState: Equatable, Sendable {
    public var selectedTab: WorkspaceTab
    public let displayIDs: [String]
    public var displayPages: DisplayAppPageState

    public init(
        displayIDs: [String],
        pointerDisplayID: String?,
        selectedTab: WorkspaceTab = .switch
    ) {
        self.selectedTab = selectedTab
        var seenDisplayIDs: Set<String> = []
        let normalizedDisplayIDs = displayIDs.filter { displayID in
            !displayID.isEmpty && seenDisplayIDs.insert(displayID).inserted
        }
        self.displayIDs = normalizedDisplayIDs

        let selectedDisplayID: String
        if let pointerDisplayID, normalizedDisplayIDs.contains(pointerDisplayID) {
            selectedDisplayID = pointerDisplayID
        } else {
            selectedDisplayID = normalizedDisplayIDs.first ?? ""
        }
        displayPages = DisplayAppPageState(selectedDisplayID: selectedDisplayID)
    }

    public var isDisplayRailVisible: Bool {
        displayIDs.count > 1
    }
}
