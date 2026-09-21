import Foundation

public enum SwitcherHeadlessSessionCloseReason: Equatable, Sendable {
    case execute
    case escape
    case outsideClick
    case programmatic
}

private enum SwitcherHeadlessSelectionKind {
    case app
    case display
}

private struct SwitcherHeadlessSelection {
    let id: String
    let kind: SwitcherHeadlessSelectionKind
}

/// A presentation-free compatibility model for semantic runtime sessions.
///
/// The production presenter is `FullscreenWorkspaceController`. This model is
/// intentionally limited to a frozen snapshot, stable ID selection, and the
/// asynchronous action lifecycle needed by dev/test semantic adapters.
@MainActor
public final class SwitcherHeadlessSession {
    public let runtimeState: SwitcherRuntimeState?
    public let actionService: SwitcherActionService?

    public private(set) var isOpen = false
    public private(set) var selectedItemID: String?
    public private(set) var closeReason: SwitcherHeadlessSessionCloseReason?

    private var snapshot: SwitcherSnapshot?
    private var selection: SwitcherHeadlessSelection?
    private var nextSessionID: UInt64 = 0
    private var activeSessionID: UInt64?
    private var claimedExecutionSessionID: UInt64?

    public init(
        runtimeState: SwitcherRuntimeState? = nil,
        actionService: SwitcherActionService? = nil
    ) {
        self.runtimeState = runtimeState
        self.actionService = actionService
    }

    public func open(snapshot: SwitcherSnapshot) {
        guard activeSessionID == nil else { return }
        nextSessionID &+= 1
        activeSessionID = nextSessionID
        claimedExecutionSessionID = nil
        self.snapshot = snapshot
        selection = nil
        selectedItemID = nil
        closeReason = nil
        isOpen = true
    }

    @discardableResult
    public func select(itemID: String) -> Bool {
        guard isOpen, let snapshot else { return false }
        let resolved: SwitcherHeadlessSelection?
        if snapshot.runningApps.contains(where: { $0.id == itemID }) {
            resolved = SwitcherHeadlessSelection(id: itemID, kind: .app)
        } else if snapshot.displays.contains(where: { $0.id == itemID }) {
            resolved = SwitcherHeadlessSelection(id: itemID, kind: .display)
        } else {
            resolved = nil
        }
        guard let resolved else { return false }
        selection = resolved
        selectedItemID = itemID
        return true
    }

    public func close(reason: SwitcherHeadlessSessionCloseReason = .programmatic) {
        activeSessionID = nil
        claimedExecutionSessionID = nil
        snapshot = nil
        selection = nil
        selectedItemID = nil
        closeReason = reason
        isOpen = false
    }

    @discardableResult
    public func executeSelected() async -> Result<Void, SwitcherActionFailure> {
        guard let sessionID = activeSessionID, isOpen else {
            return .failure(.panelNotOpen)
        }
        guard claimedExecutionSessionID == nil else {
            return .failure(.actionInProgress)
        }
        guard let selection, let snapshot else {
            return .failure(.executeNotAllowed)
        }

        claimedExecutionSessionID = sessionID
        if let actionService {
            let target: SwitcherActionTarget
            switch selection.kind {
            case .app:
                target = .app(id: selection.id)
            case .display:
                target = .display(id: selection.id, window: nil)
            }
            switch await actionService.perform(target: target, snapshot: snapshot) {
            case .success:
                break
            case let .failure(failure):
                if activeSessionID == sessionID {
                    close(reason: .programmatic)
                } else if claimedExecutionSessionID == sessionID {
                    claimedExecutionSessionID = nil
                }
                return .failure(failure)
            }
        }

        if activeSessionID == sessionID {
            close(reason: .execute)
        } else if claimedExecutionSessionID == sessionID {
            claimedExecutionSessionID = nil
        }
        return .success(())
    }
}

@MainActor
final class SwitcherSemanticModel {
    let runtimeState: SwitcherRuntimeState
    let actionService: SwitcherActionService

    convenience init() {
        self.init(runtimeState: nil, permissionService: nil)
    }

    init(
        runtimeState: SwitcherRuntimeState?,
        permissionService: PermissionService?
    ) {
        let permissionService = permissionService ?? PermissionService()
        let runtimeState = runtimeState ?? SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(),
            runningAppCatalog: RunningAppCatalog(permissionService: permissionService),
            pointerLocation: NSEventPointerLocationProvider(),
            frontmostState: NSWorkspaceFrontmostStateProvider()
        )
        self.runtimeState = runtimeState
        self.actionService = SwitcherActionService(
            policy: ExecutionPolicy(mode: .interactive, environment: [:]),
            liveSnapshotProvider: runtimeState,
            permissionService: permissionService
        )
    }

    func makeHeadlessSession() -> SwitcherHeadlessSession {
        SwitcherHeadlessSession(
            runtimeState: runtimeState,
            actionService: actionService
        )
    }
}
