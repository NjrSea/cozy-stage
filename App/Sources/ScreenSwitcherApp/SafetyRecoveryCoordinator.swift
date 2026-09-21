import Foundation
import ScreenDomainCore

enum SafetyRecoveryFailureCode: String, Equatable {
    case revealAllIncomplete = "reveal_all_incomplete"
}

enum SafetyRecoveryResult: Equatable {
    case complete
    case incomplete(windowIDs: [ManagedWindowID])

    var failureCode: SafetyRecoveryFailureCode? {
        guard case .incomplete = self else { return nil }
        return .revealAllIncomplete
    }
}

@MainActor
final class SafetyRecoveryCoordinator {
    private struct RestoreOutcome {
        let windowID: ManagedWindowID
        let commandFailed: Bool
        let snapshot: WindowCommandSnapshot?
    }

    private let commandService: any WindowCommandService
    private let stitchedCanvasRegions: [CanvasRect]
    private let commandTimeout: TimeInterval
    private(set) var incompatibleWindowIDs = Set<ManagedWindowID>()

    init(
        commandService: any WindowCommandService,
        stitchedCanvasRegions: [CanvasRect],
        commandTimeout: TimeInterval
    ) {
        self.commandService = commandService
        self.stitchedCanvasRegions = stitchedCanvasRegions
        self.commandTimeout = commandTimeout
    }

    func revealAll(
        canonicalFrames: [ManagedWindowID: CanvasRect],
        bindings: [ManagedWindowID: WindowRuntimeBinding]
    ) async -> SafetyRecoveryResult {
        let IDs = canonicalFrames.keys.sorted()
        var tasks: [ManagedWindowID: Task<RestoreOutcome, Never>] = [:]
        for windowID in IDs {
            guard let binding = bindings[windowID], let frame = canonicalFrames[windowID] else {
                continue
            }
            tasks[windowID] = Task { @MainActor [commandService, commandTimeout] in
                let frameResult = await commandService.setFrame(
                    frame,
                    for: binding,
                    timeout: commandTimeout
                )
                let minimizeResult = await commandService.setMinimized(
                    false,
                    for: binding,
                    timeout: commandTimeout
                )
                let snapshot = await commandService.snapshot(binding, timeout: commandTimeout)
                return RestoreOutcome(
                    windowID: windowID,
                    commandFailed: frameResult != .applied || minimizeResult != .applied,
                    snapshot: snapshot
                )
            }
        }

        var outcomes: [ManagedWindowID: RestoreOutcome] = [:]
        for windowID in IDs {
            if let task = tasks[windowID] {
                outcomes[windowID] = await task.value
            }
        }

        var incomplete: [ManagedWindowID] = []
        for windowID in IDs {
            guard bindings[windowID] != nil, let outcome = outcomes[windowID] else {
                incomplete.append(windowID)
                incompatibleWindowIDs.insert(windowID)
                continue
            }
            guard let snapshot = outcome.snapshot else {
                // A nil snapshot after a restore command FAILURE may mean the window is
                // still alive off-Canvas but unreadable (AX timeout / accessibility loss).
                // That is NOT a safe vanish: report it incomplete so it can never remain
                // hidden. Only when the restore commands SUCCEEDED is a nil snapshot a
                // reasonable signal that the window vanished on its own.
                if outcome.commandFailed {
                    incomplete.append(windowID)
                    incompatibleWindowIDs.insert(windowID)
                }
                continue
            }
            let isVisible = !snapshot.isMinimized
                && stitchedCanvasRegions.contains { $0.hasVisibleIntersection(with: snapshot.frame) }
            if !isVisible {
                incomplete.append(windowID)
                incompatibleWindowIDs.insert(windowID)
            } else if outcome.commandFailed {
                // Visible As Is is safe, but must not be advertised compatible.
                incompatibleWindowIDs.insert(windowID)
            }
        }
        return incomplete.isEmpty ? .complete : .incomplete(windowIDs: incomplete)
    }
}

private extension CanvasRect {
    func hasVisibleIntersection(with other: CanvasRect) -> Bool {
        max(x, other.x) < min(x + width, other.x + other.width)
            && max(y, other.y) < min(y + height, other.y + other.height)
    }
}
