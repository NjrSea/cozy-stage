import Foundation
import ScreenDomainCore

enum WindowPresentationFailure: Equatable {
    case invalidScreen(FocusScreenID)
    case invalidTargetWindow(ManagedWindowID)
    case bindingUnavailable(ManagedWindowID)
    case command(windowID: ManagedWindowID, result: WindowCommandResult)
    case geometryMismatch(ManagedWindowID)
    case domainCommitRejected
}

enum WindowPresentationResult: Equatable {
    case committed
    case cancelled(recovery: WindowPresentationCancellationRecovery?)
    case failed(primary: WindowPresentationFailure, recovery: SafetyRecoveryResult)
}

struct WindowPresentationCancellationRecovery: Equatable {
    let result: SafetyRecoveryResult
    let incompatibleBindings: [ManagedWindowID: WindowRuntimeBinding]
}

@MainActor
final class WindowPresentationCoordinator {
    private let bindings: [ManagedWindowID: WindowRuntimeBinding]
    private let stitchedCanvasRegions: [CanvasRect]
    private let commandService: any WindowCommandService
    private let commandTimeout: TimeInterval
    private(set) var state: FocusScreenState
    private(set) var incompatibleWindowIDs: Set<ManagedWindowID>
    private var cancellationRecoveryFrames: [ManagedWindowID: CanvasRect] = [:]
    private var hasIssuedMutation = false
    private var hasRecoveredTransaction = false
    private var cancellationRecovery: WindowPresentationCancellationRecovery?

    init(
        state: FocusScreenState,
        bindings: [ManagedWindowID: WindowRuntimeBinding],
        stitchedCanvasRegions: [CanvasRect],
        commandService: any WindowCommandService,
        commandTimeout: TimeInterval
    ) {
        self.state = state
        self.bindings = bindings
        self.stitchedCanvasRegions = stitchedCanvasRegions
        self.commandService = commandService
        self.commandTimeout = commandTimeout
        incompatibleWindowIDs = Set(
            state.windows.values.lazy.filter { !$0.isCompatible }.map(\.id)
        )
    }

    func switchScreen(
        from oldScreenID: FocusScreenID,
        to targetScreenID: FocusScreenID,
        targetWindowID: ManagedWindowID
    ) async -> WindowPresentationResult {
        await switchScreen(
            from: oldScreenID,
            to: targetScreenID,
            targetWindowID: targetWindowID,
            whileCurrent: { true }
        )
    }

    func switchScreen(
        from oldScreenID: FocusScreenID,
        to targetScreenID: FocusScreenID,
        targetWindowID: ManagedWindowID,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowPresentationResult {
        guard whileCurrent() else { return .cancelled(recovery: nil) }
        guard let oldScreen = state.screen(id: oldScreenID),
              state.activeScreenID == oldScreenID
        else {
            return await fail(
                .invalidScreen(oldScreenID),
                recoveryFrames: canonicalFrames(),
                whileCurrent: whileCurrent
            )
        }
        guard let targetScreen = state.screen(id: targetScreenID) else {
            return await fail(
                .invalidScreen(targetScreenID),
                recoveryFrames: canonicalFrames(),
                whileCurrent: whileCurrent
            )
        }
        guard targetScreen.windowIDs.contains(targetWindowID) else {
            return await fail(
                .invalidTargetWindow(targetWindowID),
                recoveryFrames: canonicalFrames(),
                whileCurrent: whileCurrent
            )
        }

        let involvedIDs = Array(Set(oldScreen.windowIDs + targetScreen.windowIDs)).sorted()
        let compatibleIDs = involvedIDs.filter { state.windows[$0]?.isCompatible == true }
        var preTransactionFrames: [ManagedWindowID: CanvasRect] = [:]
        // Pre-transaction failures pass canonicalFrames() (known-good canonical layout)
        // because preTransactionFrames is not yet populated; later failures pass the
        // actual pre-transaction snapshot so recovery restores the real prior geometry.
        for windowID in compatibleIDs {
            guard whileCurrent() else { return .cancelled(recovery: nil) }
            guard let binding = bindings[windowID] else {
                return await fail(
                    .bindingUnavailable(windowID),
                    recoveryFrames: canonicalFrames(),
                    whileCurrent: whileCurrent
                )
            }
            let snapshot = await commandService.snapshot(binding, timeout: commandTimeout)
            guard whileCurrent() else { return .cancelled(recovery: nil) }
            guard let snapshot else {
                return await fail(
                    .command(windowID: windowID, result: .vanished),
                    recoveryFrames: canonicalFrames(),
                    whileCurrent: whileCurrent
                )
            }
            preTransactionFrames[windowID] = snapshot.frame
        }
        cancellationRecoveryFrames = preTransactionFrames

        let oldCompatibleIDs = oldScreen.windowIDs
            .filter { state.windows[$0]?.isCompatible == true }
            .sorted()
        let shelfFrames = deterministicShelfFrames(for: oldCompatibleIDs)
        for windowID in oldCompatibleIDs {
            guard whileCurrent() else { return .cancelled(recovery: nil) }
            guard let binding = bindings[windowID], let shelfFrame = shelfFrames[windowID] else {
                return await fail(
                    .bindingUnavailable(windowID),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
            hasIssuedMutation = true
            let result = await commandService.setFrame(
                shelfFrame,
                for: binding,
                timeout: commandTimeout
            )
            guard whileCurrent() else { return await cancel() }
            guard result == .applied else {
                return await fail(
                    .command(windowID: windowID, result: result),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
            guard whileCurrent() else { return .cancelled(recovery: nil) }
            let settled = await commandService.snapshot(binding, timeout: commandTimeout)
            guard whileCurrent() else { return await cancel() }
            guard let settled, settled.frame.isApproximatelyEqual(to: shelfFrame) else {
                return await fail(
                    .geometryMismatch(windowID),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
        }

        let targetCompatibleIDs = targetScreen.windowIDs
            .filter { state.windows[$0]?.isCompatible == true }
            .sorted()
        for windowID in targetCompatibleIDs {
            guard whileCurrent() else { return .cancelled(recovery: nil) }
            guard let binding = bindings[windowID],
                  let canonicalFrame = state.windows[windowID]?.canonicalFrame
            else {
                return await fail(
                    .bindingUnavailable(windowID),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
            hasIssuedMutation = true
            let frameResult = await commandService.setFrame(
                canonicalFrame,
                for: binding,
                timeout: commandTimeout
            )
            guard whileCurrent() else { return await cancel() }
            guard frameResult == .applied else {
                return await fail(
                    .command(windowID: windowID, result: frameResult),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
            guard whileCurrent() else { return .cancelled(recovery: nil) }
            let minimizeResult = await commandService.setMinimized(
                false,
                for: binding,
                timeout: commandTimeout
            )
            guard whileCurrent() else { return await cancel() }
            guard minimizeResult == .applied else {
                return await fail(
                    .command(windowID: windowID, result: minimizeResult),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
        }

        for windowID in targetCompatibleIDs {
            guard whileCurrent() else { return .cancelled(recovery: nil) }
            guard let binding = bindings[windowID],
                  let canonicalFrame = state.windows[windowID]?.canonicalFrame
            else {
                return await fail(
                    .geometryMismatch(windowID),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
            let settled = await commandService.snapshot(binding, timeout: commandTimeout)
            guard whileCurrent() else { return await cancel() }
            guard let settled,
                  !settled.isMinimized,
                  settled.frame.isApproximatelyEqual(to: canonicalFrame)
            else {
                return await fail(
                    .geometryMismatch(windowID),
                    recoveryFrames: preTransactionFrames,
                    whileCurrent: whileCurrent
                )
            }
        }

        guard whileCurrent() else { return .cancelled(recovery: nil) }
        guard state.windows[targetWindowID]?.isCompatible == true,
              let targetBinding = bindings[targetWindowID]
        else {
            return await fail(
                .bindingUnavailable(targetWindowID),
                recoveryFrames: preTransactionFrames,
                whileCurrent: whileCurrent
            )
        }
        let focusResult = await commandService.raiseAndFocus(
            targetBinding,
            timeout: commandTimeout,
            whileCurrent: whileCurrent
        )
        guard whileCurrent() else { return await cancel() }
        guard focusResult == .applied else {
            return await fail(
                .command(windowID: targetWindowID, result: focusResult),
                recoveryFrames: preTransactionFrames,
                whileCurrent: whileCurrent
            )
        }

        guard whileCurrent() else { return .cancelled(recovery: nil) }
        do {
            state = try FocusScreenReducer.commitSwitch(screenID: targetScreenID, in: state)
            return .committed
        } catch {
            return await fail(
                .domainCommitRejected,
                recoveryFrames: preTransactionFrames,
                whileCurrent: whileCurrent
            )
        }
    }

    private func deterministicShelfFrames(
        for windowIDs: [ManagedWindowID]
    ) -> [ManagedWindowID: CanvasRect] {
        let maximumX = stitchedCanvasRegions.map { $0.x + $0.width }.max() ?? 0
        let minimumY = stitchedCanvasRegions.map(\.y).min() ?? 0
        var cursorX = maximumX + 80
        var result: [ManagedWindowID: CanvasRect] = [:]
        for windowID in windowIDs {
            guard let canonical = state.windows[windowID]?.canonicalFrame else { continue }
            result[windowID] = CanvasRect(
                x: cursorX,
                y: minimumY,
                width: canonical.width,
                height: canonical.height
            )
            cursorX += canonical.width + 40
        }
        return result
    }

    private func canonicalFrames() -> [ManagedWindowID: CanvasRect] {
        state.windows.reduce(into: [:]) { result, entry in
            guard entry.value.isCompatible else { return }
            result[entry.key] = entry.value.canonicalFrame
        }
    }

    private func fail(
        _ primary: WindowPresentationFailure,
        recoveryFrames: [ManagedWindowID: CanvasRect],
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowPresentationResult {
        guard whileCurrent() else { return .cancelled(recovery: nil) }
        hasRecoveredTransaction = true
        let recovery = SafetyRecoveryCoordinator(
            commandService: commandService,
            stitchedCanvasRegions: stitchedCanvasRegions,
            commandTimeout: commandTimeout
        )
        let result = await recovery.revealAll(
            canonicalFrames: recoveryFrames,
            bindings: bindings
        )
        let cancellationRecovery = WindowPresentationCancellationRecovery(
            result: result,
            incompatibleBindings: Dictionary(uniqueKeysWithValues:
                recovery.incompatibleWindowIDs.compactMap { windowID in
                    bindings[windowID].map { (windowID, $0) }
                }
            )
        )
        self.cancellationRecovery = cancellationRecovery
        guard whileCurrent() else { return .cancelled(recovery: cancellationRecovery) }
        incompatibleWindowIDs.formUnion(recovery.incompatibleWindowIDs)
        for windowID in recovery.incompatibleWindowIDs {
            state.windows[windowID]?.isCompatible = false
        }
        return .failed(primary: primary, recovery: result)
    }

    func cancel() async -> WindowPresentationResult {
        guard hasIssuedMutation, !hasRecoveredTransaction else {
            return .cancelled(recovery: cancellationRecovery)
        }
        hasRecoveredTransaction = true
        let recovery = SafetyRecoveryCoordinator(
            commandService: commandService,
            stitchedCanvasRegions: stitchedCanvasRegions,
            commandTimeout: commandTimeout
        )
        let result = await recovery.revealAll(
            canonicalFrames: cancellationRecoveryFrames,
            bindings: bindings
        )
        let cancellationRecovery = WindowPresentationCancellationRecovery(
            result: result,
            incompatibleBindings: Dictionary(uniqueKeysWithValues:
                recovery.incompatibleWindowIDs.compactMap { windowID in
                    bindings[windowID].map { (windowID, $0) }
                }
            )
        )
        self.cancellationRecovery = cancellationRecovery
        return .cancelled(recovery: cancellationRecovery)
    }
}
