import Foundation
import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WindowPresentationCoordinatorTests: XCTestCase {
    func testSwitchParksOldScreenOutsideCanvasBeforeRestoringTargetAndFocusingExactWindow() async throws {
        let fixture = PresentationFixture()
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(result, .committed)
        XCTAssertEqual(coordinator.state.activeScreenID, "screen-target")
        XCTAssertEqual(coordinator.state.revision, fixture.state.revision + 1)

        let parkedFrames = commands.events.compactMap { event -> CanvasRect? in
            guard case let .setFrame(id, frame) = event, id.hasPrefix("old-") else { return nil }
            return frame
        }
        XCTAssertEqual(parkedFrames.count, 2)
        XCTAssertEqual(Set(parkedFrames).count, 2)
        XCTAssertTrue(parkedFrames.allSatisfy { !$0.intersects(fixture.canvas) })

        let targetRestoreIndices = ["target-a", "target-b"].compactMap { id in
            commands.events.firstIndex(of: .setFrame(id, fixture.frames[id]!))
        }
        let targetUnminimizeIndices = ["target-a", "target-b"].compactMap { id in
            commands.events.firstIndex(of: .setMinimized(id, false))
        }
        let focusIndex = try XCTUnwrap(commands.events.firstIndex(of: .raiseAndFocus("target-b")))
        XCTAssertEqual(targetRestoreIndices.count, 2)
        XCTAssertEqual(targetUnminimizeIndices.count, 2)
        XCTAssertTrue((targetRestoreIndices + targetUnminimizeIndices).allSatisfy { $0 < focusIndex })
        XCTAssertFalse(commands.events.contains(.raiseAndFocus("target-a")))
    }

    func testAnyCommandFailureRevealsEveryWindowFromPreTransactionSnapshotsWithoutCommit() async {
        let fixture = PresentationFixture()
        let commands = TransactionCommandService(
            states: fixture.initialSnapshots,
            oneShotResults: [.setFrame("old-a", fixture.frames["old-a"]!): .timedOut]
        )
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(
            result,
            .failed(
                primary: .command(windowID: "old-a", result: .timedOut),
                recovery: .complete
            )
        )
        XCTAssertEqual(coordinator.state, fixture.state)
        for id in fixture.compatibleWindowIDs {
            XCTAssertTrue(commands.events.contains(.setFrame(id, fixture.frames[id]!)))
            XCTAssertTrue(commands.events.contains(.setMinimized(id, false)))
        }
    }

    func testIncompatibleWindowRemainsVisibleAsIsAndIsNeverParked() async {
        let fixture = PresentationFixture(includeIncompatibleWindow: true)
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(result, .committed)
        XCTAssertFalse(coordinator.state.windows["old-as-is"]?.isCompatible ?? true)
        XCTAssertTrue(coordinator.incompatibleWindowIDs.contains("old-as-is"))
        XCTAssertFalse(commands.events.contains { $0.windowID == "old-as-is" })
        XCTAssertEqual(commands.states["old-as-is"], fixture.initialSnapshots["old-as-is"])
    }

    // MARK: - Risk #1 at the transaction seam: nil pre-transaction snapshot is a vanish failure, not a safe skip

    func testNilPreTransactionSnapshotProjectsAsVanishFailureAndTriggersRevealAllWithoutCommit() async {
        let fixture = PresentationFixture()
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        // old-a's pre-transaction snapshot is unreadable (AX timeout / accessibility loss).
        // The coordinator must NOT treat this as "safely vanished"; it must fail the
        // transaction with .vanished and run Reveal All from the other pre-transaction
        // snapshots, without committing.
        commands.snapshotOverrides["old-a"] = .unreadable
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(
            result,
            .failed(primary: .command(windowID: "old-a", result: .vanished), recovery: .complete)
        )
        // State untouched (no commit).
        XCTAssertEqual(coordinator.state, fixture.state)
    }

    // MARK: - Typed failure projections across each transaction step

    func testUnsupportedOnTargetRestoreProjectsTypedFailureAndRevealsAllWithoutCommit() async {
        let fixture = PresentationFixture()
        let targetFrame = fixture.frames["target-a"]!
        let commands = TransactionCommandService(
            states: fixture.initialSnapshots,
            oneShotResults: [.setFrame("target-a", targetFrame): .unsupported]
        )
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(
            result,
            .failed(primary: .command(windowID: "target-a", result: .unsupported), recovery: .complete)
        )
        XCTAssertEqual(coordinator.state, fixture.state)
    }

    func testVanishedOnTargetUnminimizeProjectsTypedFailureAndRevealsAllWithoutCommit() async {
        let fixture = PresentationFixture()
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        commands.oneShotResults[.init(event: .setMinimized("target-a", false))] = .vanished
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(
            result,
            .failed(primary: .command(windowID: "target-a", result: .vanished), recovery: .complete)
        )
        XCTAssertEqual(coordinator.state, fixture.state)
    }

    func testFailedFocusOnExactTargetProjectsTypedFailureAndRevealsAllWithoutCommit() async {
        let fixture = PresentationFixture()
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        commands.oneShotResults[.init(event: .raiseAndFocus("target-b"))] = .failed
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(
            result,
            .failed(primary: .command(windowID: "target-b", result: .failed), recovery: .complete)
        )
        XCTAssertEqual(coordinator.state, fixture.state)
    }

    func testGeometrySettleMismatchOnTargetProjectsGeometryMismatchFailureWithoutCommit() async {
        let fixture = PresentationFixture()
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        // After target restore, target-a's readback snapshot reports a drifted frame that no
        // longer matches its canonical frame -> geometry mismatch. The transaction must fail
        // without committing (no reducer revision bump, active screen unchanged).
        commands.snapshotOverrides["target-a"] = .value(WindowCommandSnapshot(
            frame: CanvasRect(x: 5_000, y: 5_000, width: 420, height: 360),
            isMinimized: false
        ))
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        guard case let .failed(primary, _) = result else {
            XCTFail("expected geometry mismatch failure, got \(result)")
            return
        }
        XCTAssertEqual(primary, .geometryMismatch("target-a"))
        // No commit: revision and active screen are unchanged.
        XCTAssertEqual(coordinator.state.revision, fixture.state.revision)
        XCTAssertEqual(coordinator.state.activeScreenID, fixture.state.activeScreenID)
    }

    // MARK: - Commit happens exactly once and strictly after restore/verify/focus

    func testCommitIsAppliedExactlyOnceStrictlyAfterRestoreVerifyAndFocus() async throws {
        let fixture = PresentationFixture()
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        let coordinator = fixture.makeCoordinator(commands: commands)

        let result = await coordinator.switchScreen(
            from: "screen-old",
            to: "screen-target",
            targetWindowID: "target-b"
        )

        XCTAssertEqual(result, .committed)
        // Reducer revision increments exactly once.
        XCTAssertEqual(coordinator.state.revision, fixture.state.revision + 1)
        // There is exactly one focus event (the target), and every target restore + unminimize
        // precedes it.
        let focusEvents = commands.events.filter { event in
            if case .raiseAndFocus = event { return true }
            return false
        }
        XCTAssertEqual(focusEvents, [.raiseAndFocus("target-b")])

        let focusIndex = try XCTUnwrap(commands.events.firstIndex(of: .raiseAndFocus("target-b")))
        for id in ["target-a", "target-b"] {
            let restoreIndex = try XCTUnwrap(commands.events.firstIndex(of: .setFrame(id, fixture.frames[id]!)))
            let unminimizeIndex = try XCTUnwrap(commands.events.firstIndex(of: .setMinimized(id, false)))
            XCTAssertLessThan(restoreIndex, focusIndex)
            XCTAssertLessThan(unminimizeIndex, focusIndex)
        }
    }

    // MARK: - Deterministic shelf: non-overlapping + stable across runs

    func testShelfSlotsDoNotOverlapAndAreStableAcrossRuns() async {
        let fixture = PresentationFixture()
        let commands1 = TransactionCommandService(states: fixture.initialSnapshots)
        let coordinator1 = fixture.makeCoordinator(commands: commands1)
        _ = await coordinator1.switchScreen(from: "screen-old", to: "screen-target", targetWindowID: "target-b")

        let commands2 = TransactionCommandService(states: fixture.initialSnapshots)
        let coordinator2 = fixture.makeCoordinator(commands: commands2)
        _ = await coordinator2.switchScreen(from: "screen-old", to: "screen-target", targetWindowID: "target-b")

        func parkedFrames(from commands: TransactionCommandService) -> [CanvasRect] {
            commands.events.compactMap { event -> CanvasRect? in
                guard case let .setFrame(id, frame) = event, id.hasPrefix("old-") else { return nil }
                return frame
            }
        }

        let firstRun = parkedFrames(from: commands1)
        let secondRun = parkedFrames(from: commands2)

        // Stability: identical inputs yield identical shelf assignment (same order).
        XCTAssertEqual(firstRun, secondRun)
        // Non-overlap: no two parked frames intersect.
        for i in firstRun.indices {
            for j in (i + 1)..<firstRun.count {
                XCTAssertFalse(firstRun[i].intersects(firstRun[j]), "parked shelf slots overlap")
            }
        }
    }

    // MARK: - Stitched multi-region Canvas: shelf placed beyond the union of disjoint regions

    func testShelfPlacedBeyondStitchedUnionOfMultipleDisjointCanvasRegions() async {
        // Two disjoint canvas regions; the shelf must be placed beyond the combined extent
        // (max(x+width)) of BOTH regions, not just one physical display.
        let leftRegion = CanvasRect(x: -900, y: 0, width: 900, height: 900)
        let rightRegion = CanvasRect(x: 0, y: 0, width: 1_200, height: 900)
        let combinedMaxX = max(
            leftRegion.x + leftRegion.width,
            rightRegion.x + rightRegion.width
        )

        let fixture = PresentationFixture()
        let commands = TransactionCommandService(states: fixture.initialSnapshots)
        let coordinator = WindowPresentationCoordinator(
            state: fixture.state,
            bindings: fixture.bindings,
            stitchedCanvasRegions: [leftRegion, rightRegion],
            commandService: commands,
            commandTimeout: 0.05
        )

        _ = await coordinator.switchScreen(from: "screen-old", to: "screen-target", targetWindowID: "target-b")

        let parkedFrames = commands.events.compactMap { event -> CanvasRect? in
            guard case let .setFrame(id, frame) = event, id.hasPrefix("old-") else { return nil }
            return frame
        }
        XCTAssertFalse(parkedFrames.isEmpty)
        // Every parked frame sits strictly beyond the stitched union's right edge.
        for frame in parkedFrames {
            XCTAssertGreaterThanOrEqual(frame.x, combinedMaxX)
            XCTAssertFalse(leftRegion.intersects(frame), "parked frame intersects left canvas region")
            XCTAssertFalse(rightRegion.intersects(frame), "parked frame intersects right canvas region")
        }
    }
}

private struct PresentationFixture {
    let canvas = CanvasRect(x: -900, y: 0, width: 2_100, height: 900)
    let frames: [ManagedWindowID: CanvasRect]
    let bindings: [ManagedWindowID: WindowRuntimeBinding]
    let state: FocusScreenState

    init(includeIncompatibleWindow: Bool = false) {
        var frames: [ManagedWindowID: CanvasRect] = [
            "old-a": CanvasRect(x: -850, y: 40, width: 360, height: 300),
            "old-b": CanvasRect(x: -450, y: 60, width: 360, height: 300),
            "target-a": CanvasRect(x: 40, y: 80, width: 420, height: 360),
            "target-b": CanvasRect(x: 500, y: 100, width: 500, height: 400)
        ]
        if includeIncompatibleWindow {
            frames["old-as-is"] = CanvasRect(x: 10, y: 10, width: 240, height: 180)
        }
        self.frames = frames
        bindings = frames.reduce(into: [:]) { result, entry in
            result[entry.key] = WindowRuntimeBinding(
                launchGeneration: "launch-\(entry.key)",
                processIdentifier: pid_t(result.count + 100),
                element: .injected(entry.key)
            )
        }
        let windows = frames.reduce(into: [ManagedWindowID: ManagedWindow]()) { result, entry in
            result[entry.key] = ManagedWindow(
                id: entry.key,
                appID: "app-\(entry.key)",
                canonicalFrame: entry.value,
                isCompatible: entry.key != "old-as-is"
            )
        }
        var oldIDs = ["old-a", "old-b"]
        if includeIncompatibleWindow { oldIDs.append("old-as-is") }
        state = FocusScreenState(
            screens: [
                FocusScreen(
                    id: "screen-old",
                    number: 1,
                    lifecycle: .active,
                    windowIDs: oldIDs,
                    lastActiveWindowID: "old-b"
                ),
                FocusScreen(
                    id: "screen-target",
                    number: 2,
                    lifecycle: .background,
                    windowIDs: ["target-a", "target-b"],
                    lastActiveWindowID: "target-b"
                )
            ],
            windows: windows,
            activeScreenID: "screen-old",
            inspectedScreenID: "screen-old",
            revision: 7
        )
    }

    var initialSnapshots: [ManagedWindowID: WindowCommandSnapshot] {
        frames.reduce(into: [:]) { result, entry in
            result[entry.key] = WindowCommandSnapshot(
                frame: entry.value,
                isMinimized: entry.key.hasPrefix("target-")
            )
        }
    }

    var compatibleWindowIDs: [ManagedWindowID] {
        state.windows.values.filter(\.isCompatible).map(\.id).sorted()
    }

    @MainActor
    func makeCoordinator(commands: TransactionCommandService) -> WindowPresentationCoordinator {
        WindowPresentationCoordinator(
            state: state,
            bindings: bindings,
            stitchedCanvasRegions: [canvas],
            commandService: commands,
            commandTimeout: 0.05
        )
    }
}

enum TransactionCommandEvent: Equatable {
    case setFrame(ManagedWindowID, CanvasRect)
    case setMinimized(ManagedWindowID, Bool)
    case raiseAndFocus(ManagedWindowID)
    case close(ManagedWindowID)
    case snapshot(ManagedWindowID)

    var windowID: ManagedWindowID {
        switch self {
        case let .setFrame(id, _), let .setMinimized(id, _), let .raiseAndFocus(id),
             let .close(id), let .snapshot(id):
            return id
        }
    }
}

struct TransactionCommandKey: Hashable {
    let event: TransactionCommandEvent

    static func setFrame(_ id: ManagedWindowID, _ frame: CanvasRect) -> Self {
        Self(event: .setFrame(id, frame))
    }

    func hash(into hasher: inout Hasher) {
        switch event {
        case let .setFrame(id, _):
            hasher.combine(0)
            hasher.combine(id)
        default:
            hasher.combine(String(describing: event))
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.event, rhs.event) {
        case let (.setFrame(leftID, _), .setFrame(rightID, _)):
            return leftID == rightID
        default:
            return lhs.event == rhs.event
        }
    }
}

/// Boxed snapshot override so that an explicit `nil` snapshot (window unreadable)
/// is distinguishable from "no override" -- a plain `[ID: WindowCommandSnapshot?]`
/// collapses both into key-absence, masking behavior.
enum TransactionSnapshotOverride: Equatable {
    case unreadable
    case value(WindowCommandSnapshot)
}

@MainActor
final class TransactionCommandService: WindowCommandService {
    private let IDsByBinding: [WindowRuntimeBinding: ManagedWindowID]
    var oneShotResults: [TransactionCommandKey: WindowCommandResult]
    var states: [ManagedWindowID: WindowCommandSnapshot]
    var snapshotOverrides: [ManagedWindowID: TransactionSnapshotOverride] = [:]
    private(set) var events: [TransactionCommandEvent] = []

    init(
        states: [ManagedWindowID: WindowCommandSnapshot],
        oneShotResults: [TransactionCommandKey: WindowCommandResult] = [:]
    ) {
        self.states = states
        self.oneShotResults = oneShotResults
        IDsByBinding = states.keys.reduce(into: [:]) { result, id in
            result[WindowRuntimeBinding(
                launchGeneration: "launch-\(id)",
                processIdentifier: pid_t(states.keys.sorted().firstIndex(of: id)! + 100),
                element: .injected(id)
            )] = id
        }
    }

    func setFrame(
        _ frame: CanvasRect,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        let id = ID(binding)
        let event = TransactionCommandEvent.setFrame(id, frame)
        events.append(event)
        if let result = oneShotResults.removeValue(forKey: .init(event: event)) { return result }
        guard let previous = states[id] else { return .vanished }
        states[id] = WindowCommandSnapshot(frame: frame, isMinimized: previous.isMinimized)
        return .applied
    }

    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        let id = ID(binding)
        let event = TransactionCommandEvent.raiseAndFocus(id)
        events.append(event)
        if let result = oneShotResults.removeValue(forKey: .init(event: event)) { return result }
        if let previous = states[id] {
            states[id] = WindowCommandSnapshot(
                frame: previous.frame,
                isMinimized: previous.isMinimized,
                isFocused: true
            )
        }
        return .applied
    }

    func setMinimized(
        _ minimized: Bool,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        let id = ID(binding)
        let event = TransactionCommandEvent.setMinimized(id, minimized)
        events.append(event)
        if let result = oneShotResults.removeValue(forKey: .init(event: event)) { return result }
        guard let previous = states[id] else { return .vanished }
        states[id] = WindowCommandSnapshot(frame: previous.frame, isMinimized: minimized)
        return .applied
    }

    func close(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        let id = ID(binding)
        let event = TransactionCommandEvent.close(id)
        events.append(event)
        if let result = oneShotResults.removeValue(forKey: .init(event: event)) { return result }
        states.removeValue(forKey: id)
        return .applied
    }

    func snapshot(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandSnapshot? {
        let id = ID(binding)
        events.append(.snapshot(id))
        switch snapshotOverrides[id] {
        case .unreadable: return nil
        case let .value(snapshot): return snapshot
        case .none: return states[id]
        }
    }

    private func ID(_ binding: WindowRuntimeBinding) -> ManagedWindowID {
        if case let .injected(id) = binding.axElement { return id }
        return IDsByBinding[binding]!
    }
}

private extension CanvasRect {
    func intersects(_ other: CanvasRect) -> Bool {
        x < other.x + other.width
            && x + width > other.x
            && y < other.y + other.height
            && y + height > other.y
    }
}
