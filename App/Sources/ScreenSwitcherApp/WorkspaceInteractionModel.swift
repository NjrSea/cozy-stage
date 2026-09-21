import Combine
import PagedNavigationCore
import SwiftUI

public struct WorkspaceDisplayCardAnimationIdentity: Equatable, Sendable {
    public let displayID: String
    public let terminalRevision: UInt64
}

public struct WorkspaceInteractionPresentation: Equatable, Sendable {
    public let selectedTab: WorkspaceTab
    public let selectedDisplayID: String
    public let selectedAppPage: Int
    public let selectedDisplayPage: Int
    public let displayPageCount: Int
    public let visibleDisplayIDs: [String]
    public let displayIDs: [String]
    public let gestureAxis: NavigationAxis?
    public let motionOffset: Double
    public let displayCardAnimationIdentity: WorkspaceDisplayCardAnimationIdentity
    public let displayTransitionDirection: WorkspaceCardPagingDirection?
    public let tabTransitionRevision: UInt64
    public let tabSettledRevision: UInt64
    public let displayCardSettledRevision: UInt64
    public let executionFailure: SwitcherActionFailure?

    init(
        state: WorkspaceInteractionState,
        displayTransitionDirection: WorkspaceCardPagingDirection? = nil,
        tabTransitionRevision: UInt64 = 0,
        tabSettledRevision: UInt64 = 0,
        displayCardTransitionRevision: UInt64 = 0,
        displayCardSettledRevision: UInt64 = 0
    ) {
        selectedTab = state.workspace.selectedTab
        selectedDisplayID = state.workspace.displayPages.selectedDisplayID
        selectedAppPage = state.workspace.displayPages.selectedPage
        selectedDisplayPage = state.selectedDisplayPage
        displayPageCount = state.displayPageCount
        visibleDisplayIDs = state.visibleDisplayIDs
        displayIDs = state.workspace.displayIDs
        gestureAxis = state.lockedAxis
        motionOffset = state.presentationOffset
        displayCardAnimationIdentity = WorkspaceDisplayCardAnimationIdentity(
            displayID: state.workspace.displayPages.selectedDisplayID,
            terminalRevision: displayCardTransitionRevision
        )
        self.displayTransitionDirection = displayTransitionDirection
        self.tabTransitionRevision = tabTransitionRevision
        self.tabSettledRevision = tabSettledRevision
        self.displayCardSettledRevision = displayCardSettledRevision
        executionFailure = state.executionFailure
    }
}

@MainActor
public final class WorkspaceInteractionModel: ObservableObject {
    @Published public private(set) var presentation: WorkspaceInteractionPresentation
    @Published public private(set) var content: SwitchWorkspaceContent

    private var state: WorkspaceInteractionState
    private var pageCapacity: Int
    private let closeHandler: @MainActor (WorkspaceCloseReason) -> Void
    private let executionRequestHandler: (@MainActor (WorkspaceExecutionRequest) -> Void)?
    private var tabTransitionRevision: UInt64 = 0
    private var tabSettledRevision: UInt64 = 0
    private var displayCardTransitionRevision: UInt64 = 0
    private var displayCardSettledRevision: UInt64 = 0
    var presentationDidChange: (@MainActor (WorkspaceInteractionPresentation) -> Void)?

    public init(
        content: SwitchWorkspaceContent,
        selectedTab: WorkspaceTab,
        pageCapacity: Int = 26,
        closeHandler: @escaping @MainActor (WorkspaceCloseReason) -> Void = { _ in },
        executionRequestHandler: (@MainActor (WorkspaceExecutionRequest) -> Void)? = nil
    ) {
        self.content = content
        self.pageCapacity = Self.sanitizePageCapacity(pageCapacity)
        self.closeHandler = closeHandler
        self.executionRequestHandler = executionRequestHandler
        let initialState = WorkspaceState(
            displayIDs: content.workspaces.map(\.display.id),
            pointerDisplayID: content.selectedDisplayID,
            selectedTab: selectedTab
        )
        state = WorkspaceInteractionState(
            workspace: initialState,
            appPagesByDisplayID: Self.appPages(content: content, capacity: self.pageCapacity),
            agentsCardCount: 0,
            focusCardCount: 0
        )
        presentation = WorkspaceInteractionPresentation(state: state)
    }

    public var selectedTabBinding: Binding<WorkspaceTab> {
        Binding(
            get: { self.presentation.selectedTab },
            set: { _ = self.send(.selectTab($0)) }
        )
    }

    public var selectedDisplayBinding: Binding<String> {
        Binding(
            get: { self.presentation.selectedDisplayID },
            set: { _ = self.send(.selectDisplay($0)) }
        )
    }

    public func send(_ input: WorkspaceInteractionInput) -> Bool {
        let previousTab = presentation.selectedTab
        let previousDisplayID = presentation.selectedDisplayID
        let previousTerminalRevision = state.displayCardTerminalRevision
        let result = state.handle(input)
        if previousTab != state.workspace.selectedTab {
            tabTransitionRevision &+= 1
        }
        if previousDisplayID != state.workspace.displayPages.selectedDisplayID
            || previousTerminalRevision != state.displayCardTerminalRevision {
            displayCardTransitionRevision &+= 1
        }
        publish(displayTransitionDirection: Self.displayTransitionDirection(
            from: previousDisplayID,
            to: state.workspace.displayPages.selectedDisplayID,
            orderedDisplayIDs: state.workspace.displayIDs
        ))
        apply(result.effects)
        return result.handled
    }

    public func markTabTransitionSettled(revision: UInt64) {
        guard revision == tabTransitionRevision,
              revision > tabSettledRevision else { return }
        tabSettledRevision = revision
        publish()
    }

    public func markDisplayCardTransitionSettled(revision: UInt64) {
        guard revision == displayCardTransitionRevision,
              revision > displayCardSettledRevision else { return }
        displayCardSettledRevision = revision
        publish()
    }

    public func updatePageCapacity(_ requestedCapacity: Int) {
        let capacity = Self.sanitizePageCapacity(requestedCapacity)
        guard capacity != pageCapacity else { return }
        pageCapacity = capacity
        _ = state.handle(.synchronize(WorkspaceInteractionData(
            displayIDs: content.workspaces.map(\.display.id),
            selectedDisplayID: presentation.selectedDisplayID,
            appPagesByDisplayID: Self.appPages(content: content, capacity: capacity),
            agentsCardCount: 0,
            focusCardCount: 0
        )))
        publish()
    }

    public func synchronizeContent(_ content: SwitchWorkspaceContent) {
        guard self.content != content else { return }
        self.content = content
        state.synchronizePassiveContent(WorkspaceInteractionData(
            displayIDs: content.workspaces.map(\.display.id),
            selectedDisplayID: presentation.selectedDisplayID,
            appPagesByDisplayID: Self.appPages(content: content, capacity: pageCapacity),
            agentsCardCount: 0,
            focusCardCount: 0
        ))
        publish()
    }

    public func selectedContent() -> SwitchWorkspaceContent {
        content.selecting(presentation.selectedDisplayID)
    }

    public var pendingExecutionRequest: WorkspaceExecutionRequest? {
        state.pendingExecution
    }

    @discardableResult
    public func completeExecution(_ completion: WorkspaceExecutionCompletion) -> Bool {
        send(.executionCompleted(completion))
    }

    private func publish(
        displayTransitionDirection: WorkspaceCardPagingDirection? = nil
    ) {
        let next = WorkspaceInteractionPresentation(
            state: state,
            displayTransitionDirection: displayTransitionDirection,
            tabTransitionRevision: tabTransitionRevision,
            tabSettledRevision: tabSettledRevision,
            displayCardTransitionRevision: displayCardTransitionRevision,
            displayCardSettledRevision: displayCardSettledRevision
        )
        if presentation != next {
            presentation = next
            presentationDidChange?(next)
        }
    }

    private static func displayTransitionDirection(
        from previousID: String,
        to nextID: String,
        orderedDisplayIDs: [String]
    ) -> WorkspaceCardPagingDirection? {
        guard previousID != nextID,
              let previousIndex = orderedDisplayIDs.firstIndex(of: previousID),
              let nextIndex = orderedDisplayIDs.firstIndex(of: nextID)
        else { return nil }
        return nextIndex < previousIndex ? .previous : .next
    }

    private func apply(_ effects: [WorkspaceInteractionEffect]) {
        for effect in effects {
            switch effect {
            case let .close(reason):
                closeHandler(reason)
            case let .executionRequested(request):
                if let executionRequestHandler {
                    executionRequestHandler(request)
                } else {
                    _ = completeExecution(WorkspaceExecutionCompletion(
                        id: request.id,
                        target: request.target,
                        outcome: .failure(.executorUnavailable)
                    ))
                }
            case .selectTab, .selectDisplay, .selectAppPage:
                break
            }
        }
    }

    private static func sanitizePageCapacity(_ capacity: Int) -> Int {
        min(max(capacity, 1), 26)
    }

    private static func appPages(
        content: SwitchWorkspaceContent,
        capacity: Int
    ) -> [String: [[String]]] {
        Dictionary(uniqueKeysWithValues: content.workspaces.map { workspace in
            let ids = workspace.apps.map(\.id)
            let pages = stride(from: 0, to: ids.count, by: capacity).map { start in
                Array(ids[start..<min(start + capacity, ids.count)])
            }
            return (workspace.display.id, pages)
        })
    }
}
