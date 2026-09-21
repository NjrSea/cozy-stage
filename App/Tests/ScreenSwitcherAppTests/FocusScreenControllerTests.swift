import AppKit
import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

/// Task 9 integration tests for `FocusScreenController`.
///
/// These tests prove the Phase 1A runtime contracts listed in the plan:
///   1. Launch bootstrap to Screen 1 (single active Screen seeded from the
///      initial observation snapshot, no window motion).
///   2. Blank Screen creation (the new Screen becomes active and empty).
///   3. A newly observed window is registered to the Active Screen.
///   4. External focus of a background-owned window switches the active Screen
///      WITHOUT warping the pointer.
///   5. HUD explicit switch runs a window transaction WITH the pointer policy.
///   6. Permission-loss triggers Reveal All.
///   7. App termination triggers Reveal All before observer teardown.
///
/// All collaborators (observation, command, pointer, HUD) are injected so the
/// scenarios run deterministically without live Accessibility.
@MainActor
final class FocusScreenControllerTests: XCTestCase {

    private func assertRetainedWindowServerBinding(
        _ actual: WindowRuntimeBinding?,
        windowID: CGWindowID,
        source: WindowRuntimeBinding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(actual.launchGeneration, source.launchGeneration, file: file, line: line)
        XCTAssertEqual(actual.processIdentifier, source.processIdentifier, file: file, line: line)
        XCTAssertEqual(actual.axElement, .windowServer(windowID), file: file, line: line)
        guard case let .system(sourceElement) = source.axElement else {
            return XCTFail("source binding must carry an AX element", file: file, line: line)
        }
        XCTAssertTrue(actual.retainedAXElement === sourceElement, file: file, line: line)
    }

    func testNativeWorkspaceWindowPolicyRejectsClosedSystemSettingsScene() {
        XCTAssertFalse(NativeWorkspaceWindowPolicy.isSwitchTarget(
            isInVisibleList: false,
            desktopIDs: [41],
            visibleDesktopIDs: [41],
            tags: 0x0000_0001_0048_2001,
            isApplicationHidden: false,
            isFocused: false
        ))
        XCTAssertFalse(NativeWorkspaceWindowPolicy.isSwitchTarget(
            isInVisibleList: false,
            isInAllList: false,
            desktopIDs: [],
            visibleDesktopIDs: [41],
            tags: 0,
            isApplicationHidden: false,
            isFocused: false
        ))
    }

    func testNativeWorkspaceWindowPolicyKeepsVisibleMinimizedHiddenFocusedAndOtherSpaceWindows() {
        XCTAssertTrue(NativeWorkspaceWindowPolicy.isSwitchTarget(
            isInVisibleList: true,
            desktopIDs: [41],
            visibleDesktopIDs: [41],
            tags: 0,
            isApplicationHidden: false,
            isFocused: false
        ))
        XCTAssertTrue(NativeWorkspaceWindowPolicy.isSwitchTarget(
            isInVisibleList: false,
            desktopIDs: [41],
            visibleDesktopIDs: [41],
            tags: 0x1000_0000_0000_0000,
            isApplicationHidden: false,
            isFocused: false
        ))
        XCTAssertTrue(NativeWorkspaceWindowPolicy.isSwitchTarget(
            isInVisibleList: false,
            desktopIDs: [41],
            visibleDesktopIDs: [41],
            tags: 0,
            isApplicationHidden: true,
            isFocused: false
        ))
        XCTAssertTrue(NativeWorkspaceWindowPolicy.isSwitchTarget(
            isInVisibleList: false,
            desktopIDs: [42],
            visibleDesktopIDs: [41],
            tags: 0x1100_0001_0048_0001,
            isApplicationHidden: false,
            isFocused: false
        ))
        XCTAssertTrue(NativeWorkspaceWindowPolicy.isSwitchTarget(
            isInVisibleList: false,
            desktopIDs: [41],
            visibleDesktopIDs: [41],
            tags: 0,
            isApplicationHidden: false,
            isFocused: true
        ))
    }

    func testNativeSpaceSwitchPlanUsesCurrentSystemOrderForOneContinuousGesture() {
        XCTAssertEqual(
            NativeSpaceSwitchPlan.distance(
                from: 42,
                to: 44,
                orderedDesktopIDs: [41, 43, 42, 44]
            ),
            1
        )
        XCTAssertEqual(
            NativeSpaceSwitchPlan.distance(
                from: 44,
                to: 41,
                orderedDesktopIDs: [41, 43, 42, 44]
            ),
            -3
        )
        XCTAssertNil(
            NativeSpaceSwitchPlan.distance(
                from: 42,
                to: 99,
                orderedDesktopIDs: [41, 43, 42, 44]
            )
        )
    }

    // MARK: - Step 1: launch bootstrap to Screen 1

    func testStartBootstrapsSingleActiveScreenFromObservationWithoutMovingWindows() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame),
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        let controller = fixture.makeController()

        try await controller.start()

        XCTAssertEqual(controller.state.screens.count, 1)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.screens.first?.number, 1)
        XCTAssertEqual(
            Set(controller.state.screens.first?.windowIDs ?? []),
            Set(["w1", "w2"])
        )
        // start() must never move windows: no commands may have run.
        XCTAssertTrue(fixture.commandService.events.isEmpty,
                      "start() must bootstrap Screen 1 without touching any window")
        XCTAssertEqual(fixture.pointer.moves, 0,
                       "start() must never warp the pointer")
    }

    func testStartKeepsCompletedInventoryWhenLiveObservationRegistrationFails() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        fixture.observation.startError = WindowObservationServiceError.registrationFailed
        let controller = fixture.makeController()

        try await controller.start()
        controller.openSwitcher()

        XCTAssertEqual(controller.state.screens.first?.windowIDs, [window.id])
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
        XCTAssertTrue(fixture.hud.presented)
    }

    func testFirstHUDOpenDuringStartupReceivesCompletedWindowSnapshot() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        fixture.observation.suspendNextSnapshot()
        let snapshotStarted = fixture.observation.expectSnapshotRefresh()
        let controller = fixture.makeController()
        let startTask = Task { try await controller.start() }
        await fulfillment(of: [snapshotStarted], timeout: 1)

        controller.openSwitcher()
        fixture.observation.resumeSnapshot()
        try await startTask.value
        for _ in 0..<100 where fixture.hud.windowDiscoveryStatus != .ready {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(fixture.hud.presented)
        XCTAssertEqual(fixture.hud.lastRefreshedState?.screens.first?.windowIDs, ["w1"])
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
    }

    func testFirstHUDOpenRetriesPartialInventoryWithoutSpaceChange() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        let recovered = Fixtures.window(
            id: "w-recovered",
            appID: "com.test.recovered",
            frame: Fixtures.leftFrame
        )
        fixture.observation.queueSnapshots([
            WindowObservationSnapshot(windows: [], completeness: .partial),
            WindowObservationSnapshot(windows: [recovered], completeness: .complete)
        ])

        controller.openSwitcher()
        for _ in 0..<100 where controller.state.windows[recovered.id] == nil
            || fixture.hud.windowDiscoveryStatus != .ready {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state.screens.first?.windowIDs, [recovered.id])
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
        XCTAssertGreaterThanOrEqual(fixture.observation.snapshotCallCount, 3)
    }

    func testFirstHUDOpenKeepsLastCompleteInventoryWhileRefreshIsPending() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.suspendNextSnapshot()
        let refreshStarted = fixture.observation.expectSnapshotRefresh()

        controller.openSwitcher()
        await fulfillment(of: [refreshStarted], timeout: 1)

        XCTAssertTrue(fixture.hud.presented)
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)

        fixture.observation.resumeSnapshot()
        for _ in 0..<100 where fixture.hud.windowDiscoveryStatus != .ready {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
    }

    func testAuthoritativeNativeInventoryEndsLoadingWhenAXSnapshotIsPartial() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.setSnapshot([], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: []
        ))

        controller.openSwitcher()
        for _ in 0..<100 where fixture.hud.windowDiscoveryStatus != .ready {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
    }

    func testStartProjectsNativeDesktopsAndTheirWindowsIntoHUDScreens() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame),
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, name: "Desktop 1", isActive: true),
                .init(id: 42, number: 2, name: "ChatGPT", isActive: false)
            ],
            windowDesktopIDs: ["w1": [41], "w2": [42]]
        ))
        let controller = fixture.makeController()

        try await controller.start()

        XCTAssertEqual(controller.state.screens.map(\.number), [1, 2])
        XCTAssertEqual(controller.state.screens.map(\.name), ["Desktop 1", "ChatGPT"])
        XCTAssertEqual(controller.state.activeScreenID, "native-space-41")
        XCTAssertEqual(controller.state.screen(id: "native-space-41")?.windowIDs, ["w1"])
        XCTAssertEqual(controller.state.screen(id: "native-space-42")?.windowIDs, ["w2"])
    }

    func testHUDShortcutSwitchesToWindowServerAppsOwningNativeWorkspace() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(
                id: "ax-settings-false-positive",
                appID: "com.apple.systempreferences",
                frame: Fixtures.leftFrame
            )
        ])
        fixture.nativeApplications[4241] = NativeWindowApplication(
            appID: "com.test.active",
            appName: "Active",
            isActive: true
        )
        fixture.nativeApplications[4242] = NativeWindowApplication(
            appID: "com.test.background",
            appName: "Background",
            isActive: false
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: true),
                .init(id: 42, number: 2, isActive: false)
            ],
            windowDesktopIDs: [:],
            windows: [
                .init(
                    id: 800,
                    desktopIDs: [41],
                    processIdentifier: 4241,
                    ownerName: "Active",
                    title: "",
                    frame: Fixtures.leftFrame
                ),
                .init(
                    id: 900,
                    desktopIDs: [42],
                    processIdentifier: 4242,
                    ownerName: "Background",
                    title: "",
                    frame: Fixtures.rightFrame
                )
            ]
        ))
        let controller = fixture.makeController()

        try await controller.start()
        controller.openSwitcher()
        for _ in 0..<100 where fixture.hud.windowDiscoveryStatus != .ready {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            Set(controller.state.screen(id: "native-space-41")?.windowIDs.compactMap {
                controller.state.windows[$0]?.appID
            } ?? []),
            ["com.test.active"]
        )
        XCTAssertEqual(
            Set(controller.state.screen(id: "native-space-42")?.windowIDs.compactMap {
                controller.state.windows[$0]?.appID
            } ?? []),
            ["com.test.background"]
        )
        XCTAssertEqual(controller.workspaceAppIDsByScreen, [
            "native-space-41": ["com.test.active"],
            "native-space-42": ["com.test.background"]
        ])
        XCTAssertFalse(controller.state.windows.values.contains {
            $0.appID == "com.apple.systempreferences"
        })
        XCTAssertEqual(
            controller.state.screen(id: "native-space-42")?.windowIDs,
            ["native-window-900"]
        )
        XCTAssertEqual(
            controller.state.windows["native-window-900"]?.appID,
            "com.test.background"
        )
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
        fixture.commandService.register("native-window-900", frame: Fixtures.rightFrame)

        fixture.hud.send(.activateWindow("native-window-900"))
        for _ in 0..<20 where !fixture.commandService.events.contains(
            .raiseAndFocus("native-window-900")
        ) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(fixture.commandService.events.contains(
            .raiseAndFocus("native-window-900")
        ))

        XCTAssertTrue(fixture.hud.closed)
        XCTAssertEqual(
            fixture.commandService.events,
            [.raiseAndFocus("native-window-900"), .snapshot("native-window-900")]
        )
        let switchedDesktopIDs = await fixture.nativeSpaces.switchedDesktopIDs()
        XCTAssertEqual(switchedDesktopIDs, [42])
        XCTAssertEqual(controller.state.activeScreenID, "native-space-42")
        XCTAssertEqual(fixture.pointer.moves, 1)
        XCTAssertEqual(fixture.pointer.location, Fixtures.rightRegionCenter)
    }

    func testAuthoritativeNativeInventoryPreservesMatchedSystemBindingForHUDActivation() async throws {
        let processIdentifier = pid_t(4242)
        let sourceWindow = Fixtures.systemWindow(
            id: "ax-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            isFocused: true,
            title: "Native Title"
        )
        let sourceBinding = sourceWindow.binding
        let fixture = makeFixture(initialWindows: [sourceWindow])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: sourceWindow.appID,
            appName: sourceWindow.appName,
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: sourceWindow.appName,
                title: sourceWindow.title,
                frame: sourceWindow.frame,
                isFocused: true
            )]
        ))
        let controller = fixture.makeController()

        try await controller.start()
        _ = await controller.refreshWindowInventory()

        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900"],
            windowID: 900,
            source: sourceBinding
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, true)
        fixture.commandService.register(
            "native-window-900",
            binding: sourceBinding,
            frame: sourceWindow.frame,
            isFocused: true
        )
        controller.openSwitcher()
        fixture.hud.send(.activateWindow("native-window-900"))
        for _ in 0..<100 where controller.hudActivation.stage != .commit {
            await Task.yield()
        }

        XCTAssertEqual(controller.hudActivation.stage, .commit)
        XCTAssertEqual(controller.hudActivation.result, .applied)
        XCTAssertTrue(fixture.commandService.events.contains(
            .raiseAndFocus("native-window-900")
        ))
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testAuthoritativeNativeInventoryRecoversResidentSystemBindingAfterPartialAXRefresh() async throws {
        let processIdentifier = pid_t(4242)
        let sourceWindow = Fixtures.systemWindow(
            id: "ax-resident-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: "Native Title"
        )
        let fixture = makeFixture(initialWindows: [])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: sourceWindow.appID,
            appName: sourceWindow.appName,
            isActive: true
        )
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.emitImmediately(.created(sourceWindow))
        fixture.observation.setSnapshot([], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: sourceWindow.appName,
                title: sourceWindow.title,
                frame: sourceWindow.frame
            )]
        ))

        _ = await controller.refreshWindowInventory()

        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900"],
            windowID: 900,
            source: sourceWindow.binding
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, true)
        XCTAssertNil(controller.bindings[sourceWindow.id])
        XCTAssertNil(controller.state.windows[sourceWindow.id])
    }

    func testResidentSystemBindingFallbackPreservesScopedAliasesButRejectsDistinctCGWindows() async throws {
        let processIdentifier = pid_t(4242)
        let sourceWindow = Fixtures.systemWindow(
            id: "ax-resident-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: "Native Title"
        )

        do {
            let fixture = makeFixture(initialWindows: [sourceWindow])
            fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
                appID: sourceWindow.appID,
                appName: sourceWindow.appName,
                isActive: true
            )
            let controller = fixture.makeController()
            try await controller.start()
            fixture.observation.setSnapshot([], completeness: .partial)
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [
                    .init(id: 41, number: 1, isActive: true, memberDesktopIDs: [41, 51]),
                    .init(id: 42, number: 2, isActive: false, memberDesktopIDs: [42, 51])
                ],
                visibleDesktopIDs: [41, 51],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [51],
                    processIdentifier: processIdentifier,
                    ownerName: sourceWindow.appName,
                    title: sourceWindow.title,
                    frame: sourceWindow.frame
                )]
            ))

            _ = await controller.refreshWindowInventory()

            for id in [
                "native-window-900-native-space-41",
                "native-window-900-native-space-42"
            ] {
                try assertRetainedWindowServerBinding(
                    controller.bindings[id],
                    windowID: 900,
                    source: sourceWindow.binding
                )
                XCTAssertEqual(controller.state.windows[id]?.isCompatible, true)
            }
        }

        do {
            let fixture = makeFixture(initialWindows: [sourceWindow])
            fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
                appID: sourceWindow.appID,
                appName: sourceWindow.appName,
                isActive: true
            )
            let controller = fixture.makeController()
            try await controller.start()
            fixture.observation.setSnapshot([], completeness: .partial)
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [900, 901].map { id in
                    .init(
                        id: CGWindowID(id),
                        desktopIDs: [41],
                        processIdentifier: processIdentifier,
                        ownerName: sourceWindow.appName,
                        title: sourceWindow.title,
                        frame: sourceWindow.frame
                    )
                }
            ))

            _ = await controller.refreshWindowInventory()

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement,
                  case .windowServer(901) = controller.bindings["native-window-901"]?.axElement
            else {
                XCTFail("one resident AX binding must not bind two distinct CGWindowIDs")
                return
            }
        }
    }

    func testResidentSystemBindingFallbackFailsClosedForAmbiguousOrMismatchedSources() async throws {
        let nativePID = pid_t(4242)
        let cases: [(String, [ObservedWindow])] = [
            ("missing", []),
            ("ambiguous", [
                Fixtures.systemWindow(
                    id: "resident-a",
                    appID: "com.test.native",
                    processIdentifier: nativePID,
                    frame: Fixtures.leftFrame
                ),
                Fixtures.systemWindow(
                    id: "resident-b",
                    appID: "com.test.native",
                    processIdentifier: nativePID,
                    frame: Fixtures.leftFrame
                )
            ]),
            ("app", [Fixtures.systemWindow(
                id: "app-mismatch",
                appID: "com.test.other",
                processIdentifier: nativePID,
                frame: Fixtures.leftFrame
            )]),
            ("pid", [Fixtures.systemWindow(
                id: "pid-mismatch",
                appID: "com.test.native",
                processIdentifier: nativePID + 1,
                frame: Fixtures.leftFrame
            )]),
            ("frame", [Fixtures.systemWindow(
                id: "frame-mismatch",
                appID: "com.test.native",
                processIdentifier: nativePID,
                frame: Fixtures.rightFrame
            )])
        ]

        for (name, residentWindows) in cases {
            let fixture = makeFixture(initialWindows: residentWindows)
            fixture.nativeApplications[nativePID] = NativeWindowApplication(
                appID: "com.test.native",
                appName: "Native",
                isActive: true
            )
            let controller = fixture.makeController()
            try await controller.start()
            fixture.observation.setSnapshot([], completeness: .partial)
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: nativePID,
                    ownerName: "Native",
                    title: "",
                    frame: Fixtures.leftFrame
                )]
            ))

            _ = await controller.refreshWindowInventory()

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
            else {
                XCTFail("\(name) resident source must fail closed")
                continue
            }
            XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, false)
        }
    }

    func testFreshPendingSystemMetadataWinsOverResidentFallback() async throws {
        let processIdentifier = pid_t(4242)
        let resident = Fixtures.systemWindow(
            id: "ax-resident-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: "Native Title"
        )
        let pending = Fixtures.systemWindow(
            id: "ax-pending-window",
            appID: resident.appID,
            processIdentifier: processIdentifier,
            frame: resident.frame,
            isSettable: false,
            title: resident.title
        )
        let fixture = makeFixture(initialWindows: [resident])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: resident.appID,
            appName: resident.appName,
            isActive: true
        )
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.setSnapshot([pending], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: resident.appName,
                title: resident.title,
                frame: resident.frame
            )]
        ))

        _ = await controller.refreshWindowInventory()

        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900"],
            windowID: 900,
            source: pending.binding
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, false)
    }

    func testFreshMismatchedSystemMetadataDoesNotReviveResidentBinding() async throws {
        let processIdentifier = pid_t(4242)
        let resident = Fixtures.systemWindow(
            id: "ax-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame
        )
        let mismatched = Fixtures.systemWindow(
            id: resident.id,
            appID: "com.test.other",
            processIdentifier: processIdentifier,
            frame: resident.frame,
            launchGeneration: "replacement-generation"
        )
        let fixture = makeFixture(initialWindows: [resident])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: resident.appID,
            appName: resident.appName,
            isActive: true
        )
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.setSnapshot([mismatched], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: resident.appName,
                title: resident.title,
                frame: resident.frame
            )]
        ))

        _ = await controller.refreshWindowInventory()

        guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
        else {
            XCTFail("fresh mismatched AX metadata must suppress the resident generation")
            return
        }
    }

    func testFreshTitleConflictSuppressesOlderResidentGeometryFallback() async throws {
        let processIdentifier = pid_t(4242)
        let resident = Fixtures.systemWindow(
            id: "ax-resident-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: "Resident Title"
        )
        let freshConflict = Fixtures.systemWindow(
            id: "ax-fresh-window",
            appID: resident.appID,
            processIdentifier: processIdentifier,
            frame: resident.frame,
            launchGeneration: "fresh-generation",
            title: "Fresh Title"
        )
        let fixture = makeFixture(initialWindows: [resident])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: resident.appID,
            appName: resident.appName,
            isActive: true
        )
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.setSnapshot([freshConflict], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: resident.appName,
                title: "Native Title",
                frame: resident.frame
            )]
        ))

        _ = await controller.refreshWindowInventory()

        guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
        else {
            XCTFail("fresh identity conflict must suppress the older resident source")
            return
        }
    }

    func testResidentSystemBindingRequiresCompatiblePreservedTitle() async throws {
        let processIdentifier = pid_t(4242)
        let resident = Fixtures.systemWindow(
            id: "ax-resident-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: "Resident Title"
        )
        let fixture = makeFixture(initialWindows: [resident])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: resident.appID,
            appName: resident.appName,
            isActive: true
        )
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.setSnapshot([], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: resident.appName,
                title: "Different Native Title",
                frame: resident.frame
            )]
        ))

        _ = await controller.refreshWindowInventory()

        guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
        else {
            XCTFail("resident title must be preserved and checked")
            return
        }
    }

    func testPendingSystemMetadataRequiresExactAppAndCompatibleTitle() async throws {
        let processIdentifier = pid_t(4242)
        let cases = [
            Fixtures.systemWindow(
                id: "app-mismatch",
                appID: "com.test.other",
                processIdentifier: processIdentifier,
                frame: Fixtures.leftFrame
            ),
            Fixtures.systemWindow(
                id: "title-mismatch",
                appID: "com.test.native",
                processIdentifier: processIdentifier,
                frame: Fixtures.leftFrame,
                title: "AX Title"
            )
        ]

        for pending in cases {
            let fixture = makeFixture(initialWindows: [pending])
            fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
                appID: "com.test.native",
                appName: "Native",
                isActive: true
            )
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: "Native",
                    title: "Native Title",
                    frame: Fixtures.leftFrame
                )]
            ))
            let controller = fixture.makeController()

            try await controller.start()

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
            else {
                XCTFail("\(pending.id) must fail closed")
                continue
            }
        }
    }

    func testPendingGeometryBindingRequiresBothRawTitles() async throws {
        let processIdentifier = pid_t(4242)
        for (axTitle, nativeTitle) in [("", "Native Title"), ("AX Title", "")] {
            let pending = Fixtures.systemWindow(
                id: "ax-pending-window",
                appID: "com.test.native",
                processIdentifier: processIdentifier,
                frame: Fixtures.leftFrame,
                title: axTitle
            )
            let fixture = makeFixture(initialWindows: [pending])
            fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
                appID: pending.appID,
                appName: pending.appName,
                isActive: true
            )
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: pending.appName,
                    title: nativeTitle,
                    frame: pending.frame
                )]
            ))
            let controller = fixture.makeController()

            try await controller.start()

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
            else {
                XCTFail("geometry binding must reject missing AX/native raw title")
                continue
            }
        }
    }

    func testResidentGeometryBindingRequiresBothRawTitles() async throws {
        let processIdentifier = pid_t(4242)
        for (axTitle, nativeTitle) in [("", "Native Title"), ("AX Title", "")] {
            let resident = Fixtures.systemWindow(
                id: "ax-resident-window",
                appID: "com.test.native",
                processIdentifier: processIdentifier,
                frame: Fixtures.leftFrame,
                title: axTitle
            )
            let fixture = makeFixture(initialWindows: [resident])
            fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
                appID: resident.appID,
                appName: resident.appName,
                isActive: true
            )
            let controller = fixture.makeController()
            try await controller.start()
            fixture.observation.setSnapshot([], completeness: .partial)
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: resident.appName,
                    title: nativeTitle,
                    frame: resident.frame
                )]
            ))

            _ = await controller.refreshWindowInventory()

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
            else {
                XCTFail("resident geometry must reject missing AX/native raw title")
                continue
            }
        }
    }

    func testCreatedSystemWindowPromotionRequiresBothRawTitles() async throws {
        let processIdentifier = pid_t(4242)
        for (axTitle, nativeTitle) in [("", "Native Title"), ("AX Title", "")] {
            let fixture = makeFixture(initialWindows: [])
            fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
                appID: "com.test.native",
                appName: "Native",
                isActive: true
            )
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: "Native",
                    title: nativeTitle,
                    frame: Fixtures.leftFrame
                )]
            ))
            let controller = fixture.makeController()
            try await controller.start()
            let created = Fixtures.systemWindow(
                id: "ax-created-window",
                appID: "com.test.native",
                processIdentifier: processIdentifier,
                frame: Fixtures.leftFrame,
                title: axTitle
            )

            fixture.observation.emitImmediately(.created(created))

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement
            else {
                XCTFail("promotion must retain the native WindowServer binding without both titles")
                continue
            }
            XCTAssertEqual(controller.bindings[created.id], created.binding)
            XCTAssertEqual(controller.state.windows[created.id]?.isCompatible, true)
        }
    }

    func testResidentDirectSourceHasPriorityOverAmbiguousGeometryFallback() async throws {
        let processIdentifier = pid_t(4242)
        let direct = Fixtures.systemWindow(
            id: "ax-direct-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame
        )
        let distractor = Fixtures.systemWindow(
            id: "ax-distractor-window",
            appID: direct.appID,
            processIdentifier: processIdentifier,
            frame: direct.frame
        )
        let fixture = makeFixture(initialWindows: [direct, distractor])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: direct.appID,
            appName: direct.appName,
            isActive: true
        )
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.setSnapshot([], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                sourceWindowID: direct.id,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: direct.appName,
                title: direct.title,
                frame: direct.frame
            )]
        ))

        _ = await controller.refreshWindowInventory()

        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900"],
            windowID: 900,
            source: direct.binding
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, true)
    }

    func testExactNativeWindowIdentityRetainsAXCapabilityWhenSourceIndexDropsDuringFullscreen() async throws {
        let processIdentifier = pid_t(4242)
        let source = Fixtures.systemWindow(
            id: "ax-fullscreen-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: "Native Title"
        )
        let fixture = makeFixture(initialWindows: [source])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: source.appID,
            appName: source.appName,
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                sourceWindowID: source.id,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: source.appName,
                title: source.title,
                frame: source.frame
            )]
        ))
        let controller = fixture.makeController()
        try await controller.start()
        let retained = try XCTUnwrap(
            controller.bindings["native-window-900"]?.retainedAXElement
        )

        fixture.observation.setSnapshot([], completeness: .partial)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: true),
                .init(id: 42, number: 2, isActive: false)
            ],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [42],
                processIdentifier: processIdentifier,
                ownerName: source.appName,
                title: source.title,
                frame: Fixtures.rightFrame
            )]
        ))

        _ = await controller.refreshWindowInventory()

        XCTAssertTrue(
            controller.bindings["native-window-900"]?.retainedAXElement === retained
        )
        XCTAssertEqual(
            controller.state.windows["native-window-900"]?.canonicalFrame,
            Fixtures.rightFrame
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, true)
    }

    func testCreatedSystemWindowSynchronouslyPromotesUniqueNativeBindingBeforeHUDActivation() async throws {
        let processIdentifier = pid_t(4242)
        let appID = "com.test.native"
        let title = "Native Title"
        let fixture = makeFixture(initialWindows: [])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: appID,
            appName: "Native",
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: "Native",
                title: title,
                frame: Fixtures.leftFrame
            )]
        ))
        let controller = fixture.makeController()
        try await controller.start()
        let windowServerBinding = try XCTUnwrap(controller.bindings["native-window-900"])
        let created = Fixtures.systemWindow(
            id: "ax-created-window",
            appID: appID,
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: title
        )
        fixture.observation.setSnapshot([created])
        fixture.commandService.unavailableBindings.insert(windowServerBinding)
        fixture.commandService.register(
            "native-window-900",
            binding: created.binding,
            frame: created.frame
        )
        await fixture.nativeSpaces.suspendNextSnapshot()
        controller.openSwitcher()

        fixture.observation.emitImmediately(.created(created))

        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900"],
            windowID: 900,
            source: created.binding
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, true)
        XCTAssertNil(controller.bindings[created.id])
        XCTAssertNil(controller.state.windows[created.id])

        fixture.hud.send(.activateWindow("native-window-900"))
        await controller.awaitHUDSelectionForTest()

        XCTAssertEqual(controller.hudActivation.stage, .commit)
        XCTAssertEqual(controller.hudActivation.result, .applied)
        XCTAssertEqual(controller.hudActivation.bindingKind, .windowServer)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)

        await fixture.nativeSpaces.resumeSnapshot()
        await controller.awaitInventoryRefreshForTest()
    }

    func testCreatedSystemWindowFailsClosedWhenDistinctNativeWindowIDsMatch() async throws {
        let processIdentifier = pid_t(4242)
        let appID = "com.test.native"
        let fixture = makeFixture(initialWindows: [])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: appID,
            appName: "Native",
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [900, 901].map { id in
                .init(
                    id: CGWindowID(id),
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: "Native",
                    title: "",
                    frame: Fixtures.leftFrame
                )
            }
        ))
        let controller = fixture.makeController()
        try await controller.start()
        let created = Fixtures.systemWindow(
            id: "ax-created-window",
            appID: appID,
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame
        )

        fixture.observation.emitImmediately(.created(created))

        guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement,
              case .windowServer(901) = controller.bindings["native-window-901"]?.axElement
        else {
            XCTFail("ambiguous distinct CGWindowIDs must retain their WindowServer bindings")
            return
        }
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, false)
        XCTAssertEqual(controller.state.windows["native-window-901"]?.isCompatible, false)
    }

    func testCreatedSystemWindowPromotesAllScopedAliasesForOneNativeWindow() async throws {
        let processIdentifier = pid_t(4242)
        let appID = "com.test.native"
        let title = "Native Title"
        let fixture = makeFixture(initialWindows: [])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: appID,
            appName: "Native",
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: true, memberDesktopIDs: [41, 51]),
                .init(id: 42, number: 2, isActive: false, memberDesktopIDs: [42, 51])
            ],
            visibleDesktopIDs: [41, 51],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [51],
                processIdentifier: processIdentifier,
                ownerName: "Native",
                title: title,
                frame: Fixtures.leftFrame
            )]
        ))
        let controller = fixture.makeController()
        try await controller.start()
        let created = Fixtures.systemWindow(
            id: "ax-created-window",
            appID: appID,
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: title
        )

        fixture.observation.emitImmediately(.created(created))

        for id in [
            "native-window-900-native-space-41",
            "native-window-900-native-space-42"
        ] {
            try assertRetainedWindowServerBinding(
                controller.bindings[id],
                windowID: 900,
                source: created.binding
            )
            XCTAssertEqual(controller.state.windows[id]?.isCompatible, true)
        }
        XCTAssertNil(controller.bindings[created.id])
        XCTAssertNil(controller.state.windows[created.id])
    }

    func testCreatedWindowPromotionRequiresExactAppPIDFrameAndSystemBinding() async throws {
        let processIdentifier = pid_t(4242)
        let appID = "com.test.native"
        let cases: [(String, ObservedWindow)] = [
            ("missing-app", Fixtures.systemWindow(
                id: "missing-app",
                appID: "com.test.other",
                processIdentifier: processIdentifier,
                frame: Fixtures.leftFrame
            )),
            ("pid-mismatch", Fixtures.systemWindow(
                id: "pid-mismatch",
                appID: appID,
                processIdentifier: 4243,
                frame: Fixtures.leftFrame
            )),
            ("frame-mismatch", Fixtures.systemWindow(
                id: "frame-mismatch",
                appID: appID,
                processIdentifier: processIdentifier,
                frame: Fixtures.rightFrame
            )),
            ("non-system", ObservedWindow(
                id: "non-system",
                appID: appID,
                appName: "Native",
                title: "",
                frame: Fixtures.leftFrame,
                isFocused: false,
                isMinimized: false,
                isSettable: true,
                binding: WindowRuntimeBinding(
                    launchGeneration: "non-system-generation",
                    processIdentifier: processIdentifier,
                    element: .injected("non-system")
                )
            ))
        ]

        for (name, created) in cases {
            let fixture = makeFixture(initialWindows: [])
            fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
                appID: appID,
                appName: "Native",
                isActive: true
            )
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: "Native",
                    title: "",
                    frame: Fixtures.leftFrame
                )]
            ))
            let controller = fixture.makeController()
            try await controller.start()

            fixture.observation.emitImmediately(.created(created))

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement else {
                XCTFail("\(name) must not promote the native binding")
                continue
            }
            XCTAssertEqual(
                controller.state.windows["native-window-900"]?.isCompatible,
                false,
                "\(name) must retain fail-closed compatibility"
            )
        }
    }

    func testAuthoritativeNativeInventoryKeepsExactWindowAXGenerationAcrossRefresh() async throws {
        let processIdentifier = pid_t(4242)
        let sourceWindow = Fixtures.systemWindow(
            id: "ax-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [sourceWindow])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: sourceWindow.appID,
            appName: sourceWindow.appName,
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                sourceWindowID: sourceWindow.id,
                desktopIDs: [41],
                processIdentifier: processIdentifier,
                ownerName: sourceWindow.appName,
                title: sourceWindow.title,
                frame: sourceWindow.frame
            )]
        ))
        let controller = fixture.makeController()
        try await controller.start()
        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900"],
            windowID: 900,
            source: sourceWindow.binding
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, true)
        let replacement = Fixtures.systemWindow(
            id: sourceWindow.id,
            appID: sourceWindow.appID,
            processIdentifier: processIdentifier,
            frame: sourceWindow.frame,
            isSettable: false,
            launchGeneration: "replacement-generation"
        )
        fixture.observation.setSnapshot([replacement])

        _ = await controller.refreshWindowInventory()

        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900"],
            windowID: 900,
            source: sourceWindow.binding
        )
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, true)
    }

    func testAuthoritativeNativeInventoryDoesNotReuseOneMetadataBindingAcrossDistinctNativeWindows() async throws {
        let processIdentifier = pid_t(4242)
        let sourceWindow = Fixtures.systemWindow(
            id: "ax-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [sourceWindow])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: sourceWindow.appID,
            appName: sourceWindow.appName,
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [900, 901].map { id in
                .init(
                    id: CGWindowID(id),
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: sourceWindow.appName,
                    title: "Native \(id)",
                    frame: sourceWindow.frame
                )
            }
        ))
        let controller = fixture.makeController()

        try await controller.start()

        guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement,
              case .windowServer(901) = controller.bindings["native-window-901"]?.axElement
        else {
            XCTFail("one empty-title AX metadata record must not bind two distinct CGWindowIDs")
            return
        }
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, false)
        XCTAssertEqual(controller.state.windows["native-window-901"]?.isCompatible, false)
    }

    func testAuthoritativeNativeInventoryDoesNotReuseOneDirectBindingAcrossDistinctNativeWindows() async throws {
        let processIdentifier = pid_t(4242)
        let sourceWindow = Fixtures.systemWindow(
            id: "ax-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [sourceWindow])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: sourceWindow.appID,
            appName: sourceWindow.appName,
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [.init(id: 41, number: 1, isActive: true)],
            windowDesktopIDs: [:],
            windows: [900, 901].map { id in
                .init(
                    id: CGWindowID(id),
                    sourceWindowID: sourceWindow.id,
                    desktopIDs: [41],
                    processIdentifier: processIdentifier,
                    ownerName: sourceWindow.appName,
                    title: sourceWindow.title,
                    frame: sourceWindow.frame
                )
            }
        ))
        let controller = fixture.makeController()

        try await controller.start()

        guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement,
              case .windowServer(901) = controller.bindings["native-window-901"]?.axElement
        else {
            XCTFail("one sourceWindowID AX binding must not bind two distinct CGWindowIDs")
            return
        }
        XCTAssertEqual(controller.state.windows["native-window-900"]?.isCompatible, false)
        XCTAssertEqual(controller.state.windows["native-window-901"]?.isCompatible, false)
    }

    func testAuthoritativeNativeInventoryCanReuseMetadataBindingAcrossScopedIDsForOneNativeWindow() async throws {
        let processIdentifier = pid_t(4242)
        let sourceWindow = Fixtures.systemWindow(
            id: "ax-window",
            appID: "com.test.native",
            processIdentifier: processIdentifier,
            frame: Fixtures.leftFrame,
            title: "Native Title"
        )
        let fixture = makeFixture(initialWindows: [sourceWindow])
        fixture.nativeApplications[processIdentifier] = NativeWindowApplication(
            appID: sourceWindow.appID,
            appName: sourceWindow.appName,
            isActive: true
        )
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: true, memberDesktopIDs: [41, 51]),
                .init(id: 42, number: 2, isActive: false, memberDesktopIDs: [42, 51])
            ],
            visibleDesktopIDs: [41, 51],
            windowDesktopIDs: [:],
            windows: [.init(
                id: 900,
                desktopIDs: [51],
                processIdentifier: processIdentifier,
                ownerName: sourceWindow.appName,
                title: sourceWindow.title,
                frame: sourceWindow.frame
            )]
        ))
        let controller = fixture.makeController()

        try await controller.start()

        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900-native-space-41"],
            windowID: 900,
            source: sourceWindow.binding
        )
        try assertRetainedWindowServerBinding(
            controller.bindings["native-window-900-native-space-42"],
            windowID: 900,
            source: sourceWindow.binding
        )
        XCTAssertEqual(
            controller.state.windows["native-window-900-native-space-41"]?.isCompatible,
            true
        )
        XCTAssertEqual(
            controller.state.windows["native-window-900-native-space-42"]?.isCompatible,
            true
        )
    }

    func testAuthoritativeNativeInventoryFailsClosedForMissingMismatchedOrAmbiguousAXSource() async throws {
        let nativePID = pid_t(4242)
        let cases: [(String, [ObservedWindow])] = [
            ("missing", []),
            ("pid-mismatch", [Fixtures.systemWindow(
                id: "mismatch",
                appID: "com.test.native",
                processIdentifier: 4243,
                frame: Fixtures.leftFrame
            )]),
            ("duplicate", [
                Fixtures.systemWindow(
                    id: "duplicate-a",
                    appID: "com.test.native",
                    processIdentifier: nativePID,
                    frame: Fixtures.leftFrame
                ),
                Fixtures.systemWindow(
                    id: "duplicate-b",
                    appID: "com.test.native",
                    processIdentifier: nativePID,
                    frame: Fixtures.leftFrame
                )
            ]),
            ("window-server", [ObservedWindow(
                id: "window-server",
                appID: "com.test.native",
                appName: "Native",
                title: "",
                frame: Fixtures.leftFrame,
                isFocused: false,
                isMinimized: false,
                isSettable: true,
                binding: WindowRuntimeBinding(
                    launchGeneration: "window-server-generation",
                    processIdentifier: nativePID,
                    element: .windowServer(800)
                )
            )])
        ]

        for (name, observed) in cases {
            let fixture = makeFixture(initialWindows: observed)
            fixture.nativeApplications[nativePID] = NativeWindowApplication(
                appID: "com.test.native",
                appName: "Native",
                isActive: true
            )
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: nativePID,
                    ownerName: "Native",
                    title: "",
                    frame: Fixtures.leftFrame
                )]
            ))
            let controller = fixture.makeController()

            try await controller.start()

            guard case .windowServer(900) = controller.bindings["native-window-900"]?.axElement else {
                XCTFail("\(name) source must fail closed")
                continue
            }
            XCTAssertEqual(
                controller.state.windows["native-window-900"]?.isCompatible,
                false,
                "\(name) source compatibility must fail closed"
            )
        }
    }

    func testNativeScreensCombineAnchorSpacesWithOtherDisplaysCurrentSpace() async throws {
        let fixture = makeFixture(initialWindows: [])
        fixture.nativeApplications[4241] = NativeWindowApplication(
            appID: "com.test.anchor-one", appName: "Anchor One", isActive: true
        )
        fixture.nativeApplications[4242] = NativeWindowApplication(
            appID: "com.test.anchor-two", appName: "Anchor Two", isActive: false
        )
        fixture.nativeApplications[4251] = NativeWindowApplication(
            appID: "com.test.companion-current", appName: "Companion", isActive: false
        )
        fixture.nativeApplications[4252] = NativeWindowApplication(
            appID: "com.test.companion-inactive", appName: "Inactive", isActive: false
        )
        let nativeWindow: (CGWindowID, [UInt64], pid_t) -> NativeDesktopSnapshot.Window = {
            id, desktopIDs, pid in
            .init(
                id: id,
                desktopIDs: desktopIDs,
                processIdentifier: pid,
                ownerName: "",
                title: "",
                frame: Fixtures.leftFrame
            )
        }
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: true, memberDesktopIDs: [41, 51]),
                .init(id: 42, number: 2, isActive: false, memberDesktopIDs: [42, 51])
            ],
            visibleDesktopIDs: [41, 51],
            windowDesktopIDs: [:],
            windows: [
                nativeWindow(801, [41], 4241),
                nativeWindow(802, [42], 4242),
                nativeWindow(851, [51], 4251),
                nativeWindow(852, [52], 4252)
            ]
        ))
        let controller = fixture.makeController()

        try await controller.start()

        XCTAssertEqual(controller.workspaceAppIDsByScreen["native-space-41"], [
            "com.test.anchor-one", "com.test.companion-current"
        ])
        XCTAssertEqual(controller.workspaceAppIDsByScreen["native-space-42"], [
            "com.test.anchor-two", "com.test.companion-current"
        ])
        XCTAssertFalse(controller.state.windows.values.contains {
            $0.appID == "com.test.companion-inactive"
        })
        XCTAssertEqual(
            controller.state.screens.flatMap(\.windowIDs).filter { $0.contains("native-window-851") }.count,
            2
        )
    }

    func testNativeRefreshKeepsExistingWorkspaceOrderWhenSystemReordersSpaces() async throws {
        let fixture = makeFixture(initialWindows: [])
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: true),
                .init(id: 42, number: 2, isActive: false),
                .init(id: 43, number: 3, isActive: false)
            ],
            windowDesktopIDs: [:],
            windows: []
        ))
        let controller = fixture.makeController()
        try await controller.start()
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 43, number: 1, isActive: false),
                .init(id: 41, number: 2, isActive: false),
                .init(id: 42, number: 3, isActive: true)
            ],
            windowDesktopIDs: [:],
            windows: []
        ))

        _ = await controller.refreshWindowInventory()

        XCTAssertEqual(controller.state.screens.map(\.id), [
            "native-space-41", "native-space-42", "native-space-43"
        ])
        XCTAssertEqual(controller.state.screens.map(\.number), [1, 2, 3])
        XCTAssertEqual(controller.state.activeScreenID, "native-space-42")
    }

    func testInvalidatedNativeGenerationCannotCommitOverNewerInventory() async throws {
        let fixture = makeFixture(initialWindows: [])
        fixture.nativeApplications[4241] = NativeWindowApplication(
            appID: "com.test.stale", appName: "Stale", isActive: false
        )
        fixture.nativeApplications[4242] = NativeWindowApplication(
            appID: "com.test.current", appName: "Current", isActive: true
        )
        let snapshot: (CGWindowID, pid_t) -> NativeDesktopSnapshot = { id, pid in
            NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                visibleDesktopIDs: [41],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: id,
                    desktopIDs: [41],
                    processIdentifier: pid,
                    ownerName: "",
                    title: "",
                    frame: Fixtures.leftFrame
                )]
            )
        }
        let controller = fixture.makeController()
        try await controller.start()
        XCTAssertEqual(controller.inventoryRevision, 1)

        await fixture.nativeSpaces.setSnapshot(snapshot(801, 4241))
        await fixture.nativeSpaces.suspendNextSnapshot()
        let expectedCallCount = await fixture.nativeSpaces.snapshotCallCount() + 1
        controller.openSwitcher()
        for _ in 0..<100 {
            if await fixture.nativeSpaces.snapshotCallCount() >= expectedCallCount { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        await fixture.nativeSpaces.setSnapshot(snapshot(802, 4242))
        fixture.workspaceNotificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        await Task.yield()
        await fixture.nativeSpaces.resumeSnapshot()
        for _ in 0..<200 where controller.workspaceAppIDsByScreen["native-space-41"]
            != ["com.test.current"] {
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.workspaceAppIDsByScreen["native-space-41"], ["com.test.current"])
        XCTAssertEqual(controller.inventoryRevision, 2)
        XCTAssertFalse(controller.state.windows.values.contains { $0.appID == "com.test.stale" })
    }

    func testHUDSwitchInvalidatesDelayedOpenInventoryCommit() async throws {
        let w1 = Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        let w2 = Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        let fixture = makeFixture(initialWindows: [w1])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([w1, w2])
        let revisionBeforeSwitch = controller.state.revision

        let nextNativeSnapshotCall = await fixture.nativeSpaces.snapshotCallCount() + 1
        await fixture.nativeSpaces.suspendNextSnapshot()
        controller.openSwitcher()
        await fixture.nativeSpaces.waitForSnapshotCallCount(nextNativeSnapshotCall)

        fixture.hud.send(.activateWindow(w2.id))
        await controller.awaitHUDSelectionForTest()
        XCTAssertEqual(controller.state.activeScreenID, "screen-2")
        XCTAssertEqual(controller.state.revision, revisionBeforeSwitch + 1)

        await fixture.nativeSpaces.resumeSnapshot()
        await controller.awaitInventoryRefreshForTest()

        XCTAssertEqual(controller.state.activeScreenID, "screen-2")
        XCTAssertEqual(controller.state.revision, revisionBeforeSwitch + 1)
        XCTAssertEqual(Set(controller.bindings.keys), [w1.id, w2.id])
        XCTAssertEqual(controller.bindings[w1.id], w1.binding)
        XCTAssertEqual(controller.bindings[w2.id], w2.binding)
    }

    func testStartFailsClosedWithoutAccessibilityAndCanRetryAfterGrant() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        fixture.accessibility.isTrusted = false
        let controller = fixture.makeController()

        do {
            try await controller.start()
            XCTFail("Missing Accessibility must not become a successful empty snapshot")
        } catch {
            XCTAssertEqual(error as? PermissionFailure, .accessibilityMissing)
        }
        XCTAssertEqual(fixture.accessibility.requestCount, 0)
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .accessibilityRequired)
        XCTAssertEqual(controller.state.screens.first?.windowIDs, [])

        fixture.accessibility.isTrusted = true
        try await controller.start()

        XCTAssertEqual(controller.state.screens.first?.windowIDs, ["w1"])
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
    }

    func testPartialEmptyStartupIsUnavailableRatherThanReadyEmpty() async throws {
        let fixture = makeFixture(initialWindows: [])
        fixture.observation.setSnapshot([], completeness: .partial)
        let controller = fixture.makeController()

        try await controller.start()

        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .unavailable)
        XCTAssertEqual(controller.state.screens.first?.windowIDs, [])

        fixture.observation.setSnapshot([], completeness: .complete)
        await controller.refreshWindowInventory()

        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
    }

    // MARK: - Step 2: blank Screen creation

    func testCreateBlankScreenActivatesNewEmptyScreenWithoutMovingWindows() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()

        try controller.createBlankScreen(id: "screen-2")

        XCTAssertEqual(controller.state.screens.count, 2)
        XCTAssertEqual(controller.state.activeScreenID, "screen-2")
        let newScreen = try XCTUnwrap(controller.state.screen(id: "screen-2"))
        XCTAssertTrue(newScreen.windowIDs.isEmpty, "A blank Screen must own no windows")
        XCTAssertEqual(newScreen.lifecycle, .active)
        let oldScreen = try XCTUnwrap(controller.state.screen(id: "screen-1"))
        XCTAssertEqual(oldScreen.lifecycle, .background)
        XCTAssertTrue(fixture.commandService.events.isEmpty,
                      "Creating a blank Screen must not move windows")
    }

    // MARK: - Step 3: newly created window assignment to the Active Screen

    func testNewlyObservedWindowIsAssignedToActiveScreen() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let observation = fixture.observation
        let controller = fixture.makeController()
        try await controller.start()

        observation.emit(.created(Fixtures.window(
            id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame
        )))
        await observation.drain()

        let active = try XCTUnwrap(controller.state.screen(id: controller.state.activeScreenID))
        XCTAssertTrue(active.windowIDs.contains("w2"),
                      "A newly created window must join the Active Screen")
        XCTAssertNotNil(controller.state.windows["w2"])
    }

    // MARK: - Shared scenario: a window arrives on the active Screen-2

    /// Drives the realistic Phase 1A flow that puts `w2` on the background
    /// Screen-2: start with only w1, create blank screen-2 (which becomes
    /// active), then emit a `.created(w2)` observation so w2 is registered to
    /// the now-active Screen-2. Returns to screen-1 afterwards so w2 lives on
    /// the background screen for the focus/switch/recovery scenarios.
    private func stageWindowOnBackgroundScreen(
        _ fixture: ControllerFixture,
        controller: FocusScreenController
    ) async throws {
        try controller.createBlankScreen(id: "screen-2")
        let w2 = Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        // The fake command service must also know about the new window so the
        // switch transaction's pre-snapshot readback resolves it.
        fixture.commandService.register("w2", frame: Fixtures.rightFrame)
        fixture.observation.emit(.created(w2))
        await fixture.observation.drain()
        // w2 now lives on screen-2 (the active screen). Promote screen-1 back
        // to active so screen-2 is the background target.
        if let next = try? FocusScreenReducer.commitSwitch(screenID: "screen-1", in: controller.state) {
            controller.setStateForTest(next)
        }
    }

    // MARK: - Step 4: external focus switches Screen WITHOUT pointer warp

    func testExternalFocusOfBackgroundWindowSwitchesScreenWithoutPointerWarp() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let observation = fixture.observation
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        // Sanity: w2 is on the background screen-2.
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.screen(id: "screen-2")?.windowIDs, ["w2"])

        fixture.commandService.clearEvents()
        fixture.pointer.moves = 0
        // The user clicks/foregrounds w2 externally: the observer reports focus.
        observation.emit(.focused("w2"))
        await observation.drain()

        XCTAssertEqual(controller.state.activeScreenID, "screen-2",
                       "External focus on a background Screen's window must promote that Screen")
        XCTAssertEqual(fixture.pointer.moves, 0,
                       "External focus must never warp the pointer (system-owned focus)")
        XCTAssertTrue(fixture.commandService.events.isEmpty,
                      "External focus must not run a switch transaction")
    }

    // MARK: - Step 5: HUD explicit switch WITH pointer policy

    func testHUDExplicitSwitchRunsTransactionAndAppliesPointerPolicy() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")

        fixture.commandService.clearEvents()
        fixture.pointer.moves = 0
        fixture.pointer.location = Fixtures.leftRegionCenter // pointer sits in region-1

        let result = await controller.switchTo(screenID: "screen-2", targeting: "w2")

        XCTAssertEqual(result, .committed)
        XCTAssertEqual(controller.state.activeScreenID, "screen-2")
        // A switch transaction targeting an exact window must raise+focus it.
        XCTAssertTrue(fixture.commandService.events.contains(.raiseAndFocus("w2")))
        // The pointer policy must relocate the pointer into the target region.
        XCTAssertEqual(fixture.pointer.moves, 1,
                       "An explicit HUD switch must apply the exact-window pointer landing policy")
    }

    func testHUDIntentOnBackgroundScreenLandsPointerExactlyOnce() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.pointer.moves = 0
        fixture.pointer.location = Fixtures.leftRegionCenter

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where controller.state.activeScreenID != "screen-2" {
            await Task.yield()
        }

        XCTAssertEqual(controller.state.activeScreenID, "screen-2")
        XCTAssertTrue(fixture.commandService.events.contains(.raiseAndFocus("w2")))
        XCTAssertEqual(fixture.pointer.moves, 1)
        XCTAssertEqual(fixture.pointer.location, Fixtures.rightRegionCenter)
        XCTAssertEqual(controller.hudActivation.stage, .commit)
        XCTAssertEqual(controller.hudActivation.result, .applied)
    }

    func testNewHUDSelectionCancelsDelayedBackgroundTransaction() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSnapshot("w1")
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        fixture.pointer.attemptedDestinations = []
        let revisionBefore = controller.state.revision

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where fixture.commandService.events != [.snapshot("w1")] {
            await Task.yield()
        }

        controller.openSwitcher()
        fixture.hud.send(.activateWindow("w1"))
        for _ in 0..<100 where !fixture.commandService.events.contains(.raiseAndFocus("w1")) {
            await Task.yield()
        }

        fixture.commandService.resumeSnapshot("w1")
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.revision, revisionBefore + 1)
        XCTAssertEqual(
            fixture.commandService.events,
            [.snapshot("w1"), .raiseAndFocus("w1"), .snapshot("w1")]
        )
        XCTAssertEqual(fixture.pointer.attemptedDestinations, [Fixtures.leftRegionCenter])
        XCTAssertEqual(fixture.pointer.location, Fixtures.leftRegionCenter)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
        XCTAssertEqual(controller.hudActivation.stage, .commit)
        XCTAssertEqual(controller.hudActivation.result, .applied)
    }

    func testLatestHUDSelectionWaitsForStaleMutationRecovery() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSetFrame("w1")
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        fixture.pointer.attemptedDestinations = []
        let latestFocus = expectation(description: "latest selection focused")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == "w1" { latestFocus.fulfill() }
        }

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where fixture.commandService.frame(for: "w1") == Fixtures.leftFrame {
            await Task.yield()
        }
        XCTAssertNotEqual(fixture.commandService.frame(for: "w1"), Fixtures.leftFrame)

        controller.openSwitcher()
        fixture.hud.send(.activateWindow("w1"))
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w1")))
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(fixture.pointer.moves, 0)
        let revisionBeforeLatest = controller.state.revision

        fixture.commandService.resumeSetFrame("w1")
        await fulfillment(of: [latestFocus], timeout: 1)
        for _ in 0..<100 where fixture.pointer.moves == 0 { await Task.yield() }

        XCTAssertEqual(fixture.commandService.frame(for: "w1"), Fixtures.leftFrame)
        XCTAssertEqual(fixture.commandService.frame(for: "w2"), Fixtures.rightFrame)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.revision, revisionBeforeLatest + 1)
        XCTAssertEqual(fixture.pointer.attemptedDestinations, [Fixtures.leftRegionCenter])
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testLatestHUDSelectionWaitsForEarlierFailureRecovery() async throws {
        let w1 = Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        let w2 = Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        let fixture = makeFixture(initialWindows: [w1])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([w1, w2])
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.commandService.snapshotUnavailableIDs = ["w1"]
        fixture.commandService.suspendSetFrame("w1")
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        fixture.pointer.attemptedDestinations = []
        let latestFocus = expectation(description: "latest selection focused after recovery")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == "w1" { latestFocus.fulfill() }
        }

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where !fixture.commandService.events.contains(where: { event in
            if case .setFrame("w1", _) = event { return true }
            return false
        }) {
            await Task.yield()
        }

        controller.openSwitcher()
        fixture.hud.send(.activateWindow("w1"))
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w1")))
        XCTAssertEqual(fixture.pointer.moves, 0)
        let revisionBeforeLatest = controller.state.revision

        fixture.commandService.snapshotUnavailableIDs = []
        fixture.commandService.resumeSetFrame("w1")
        await fulfillment(of: [latestFocus], timeout: 1)
        for _ in 0..<100 where fixture.pointer.moves == 0 { await Task.yield() }

        XCTAssertEqual(fixture.commandService.frame(for: "w1"), Fixtures.leftFrame)
        XCTAssertEqual(fixture.commandService.frame(for: "w2"), Fixtures.rightFrame)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.revision, revisionBeforeLatest + 1)
        XCTAssertEqual(fixture.pointer.attemptedDestinations, [Fixtures.leftRegionCenter])
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testIncompleteCancellationRecoveryBlocksLatestDirectFocusCommit() async throws {
        let w1 = Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        let w2 = Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        let fixture = makeFixture(initialWindows: [w1])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([w1, w2])
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.commandService.setFrameResults["w1"] = [.applied, .failed]
        fixture.commandService.suspendSetFrame("w1")
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        fixture.pointer.attemptedDestinations = []

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where fixture.commandService.frame(for: "w1") == Fixtures.leftFrame {
            await Task.yield()
        }

        controller.openSwitcher()
        fixture.hud.send(.activateWindow("w1"))
        let revisionBeforeLatest = controller.state.revision
        fixture.commandService.resumeSetFrame("w1")
        for _ in 0..<100 where controller.state.windows["w1"]?.isCompatible != false {
            await Task.yield()
        }
        for _ in 0..<100 where fixture.reopenedApplicationIDs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(controller.state.windows["w1"]?.isCompatible, false)
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w1")))
        XCTAssertEqual(controller.state.revision, revisionBeforeLatest)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.pointer.attemptedDestinations.isEmpty)
        XCTAssertEqual(fixture.reopenedApplicationIDs, ["com.test.appA"])
    }

    func testCancellationRecoveryFromReplacedBindingDoesNotBlockLatestDirectFocus() async throws {
        let original = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let replacement = Fixtures.window(
            id: original.id,
            appID: original.appID,
            frame: original.frame,
            launchGeneration: "replacement"
        )
        let fixture = makeFixture(initialWindows: [original])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.commandService.setFrameResults[original.id] = [.applied, .failed]
        fixture.commandService.suspendSetFrame(original.id)
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        fixture.pointer.attemptedDestinations = []

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where fixture.commandService.frame(for: original.id) == Fixtures.leftFrame {
            await Task.yield()
        }

        fixture.observation.emitImmediately(.destroyed(original.id))
        fixture.observation.emitImmediately(.created(replacement))
        fixture.observation.setSnapshot([
            replacement,
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        fixture.commandService.register(replacement.id, frame: replacement.frame)
        controller.openSwitcher()
        let revisionBeforeLatest = controller.state.revision
        let latestFocus = expectation(description: "replacement binding focused")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == replacement.id { latestFocus.fulfill() }
        }
        fixture.hud.send(.activateWindow(replacement.id))

        fixture.commandService.resumeSetFrame(original.id)
        await fulfillment(of: [latestFocus], timeout: 1)
        for _ in 0..<100 where fixture.pointer.moves == 0 { await Task.yield() }

        XCTAssertEqual(controller.bindings[replacement.id], replacement.binding)
        XCTAssertEqual(controller.state.windows[replacement.id]?.isCompatible, true)
        XCTAssertTrue(fixture.commandService.events.contains(.raiseAndFocus(replacement.id)))
        XCTAssertEqual(controller.state.revision, revisionBeforeLatest + 1)
        XCTAssertEqual(fixture.pointer.attemptedDestinations, [Fixtures.leftRegionCenter])
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testBackgroundTransactionCancelsWhenParkedBindingIsReplaced() async throws {
        let original = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let replacement = Fixtures.window(
            id: original.id,
            appID: original.appID,
            frame: original.frame,
            launchGeneration: "replacement"
        )
        let fixture = makeFixture(initialWindows: [original])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([
            original,
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSetFrame(original.id)
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where fixture.commandService.frame(for: original.id) == Fixtures.leftFrame {
            await Task.yield()
        }

        fixture.observation.emitImmediately(.destroyed(original.id))
        fixture.observation.emitImmediately(.created(replacement))
        fixture.commandService.register(replacement.id, frame: replacement.frame)
        fixture.commandService.unavailableBindings.insert(original.binding)
        let revisionAfterReplacement = controller.state.revision
        let eventCountAfterReplacement = fixture.commandService.events.count

        fixture.commandService.resumeSetFrame(original.id)
        for _ in 0..<100 where controller.state.revision != revisionAfterReplacement {
            await Task.yield()
        }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(controller.bindings[replacement.id], replacement.binding)
        XCTAssertEqual(controller.state.windows[replacement.id]?.isCompatible, true)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.revision, revisionAfterReplacement)
        let eventsAfterReplacement = fixture.commandService.events.dropFirst(eventCountAfterReplacement)
        XCTAssertFalse(eventsAfterReplacement.contains { event in
            switch event {
            case let .setFrame(windowID, _), let .setMinimized(windowID, _),
                 let .raiseAndFocus(windowID), let .close(windowID), let .snapshot(windowID):
                return windowID == replacement.id
            }
        })
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w2")))
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testBackgroundTransactionCancelsWhenWindowIsCreatedDuringMutation() async throws {
        let w1 = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let w2 = Fixtures.window(
            id: "w2",
            appID: "com.test.appB",
            frame: Fixtures.rightFrame
        )
        let created = Fixtures.window(
            id: "w3",
            appID: "com.test.appC",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [w1])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([w1, w2])
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSetFrame(w1.id)
        fixture.pointer.moves = 0

        fixture.hud.send(.activateWindow(w2.id))
        for _ in 0..<100 where fixture.commandService.frame(for: w1.id) == Fixtures.leftFrame {
            await Task.yield()
        }

        fixture.commandService.register(created.id, frame: created.frame)
        fixture.observation.emitImmediately(.created(created))
        let revisionAfterCreation = controller.state.revision
        let eventCountAfterCreation = fixture.commandService.events.count

        fixture.commandService.resumeSetFrame(w1.id)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(controller.bindings[created.id], created.binding)
        XCTAssertNotNil(controller.state.windows[created.id])
        XCTAssertEqual(Set(controller.state.windows.keys), Set(controller.bindings.keys))
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.revision, revisionAfterCreation)
        XCTAssertFalse(fixture.commandService.events.dropFirst(eventCountAfterCreation).contains { event in
            switch event {
            case let .setFrame(windowID, _), let .setMinimized(windowID, _),
                 let .raiseAndFocus(windowID), let .close(windowID), let .snapshot(windowID):
                return windowID == created.id
            }
        })
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus(w2.id)))
        XCTAssertEqual(fixture.pointer.moves, 0)
    }

    func testCompleteInventoryRemovalClearsRecoveryBlockWithoutDestroyEvent() async throws {
        let original = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let w2 = Fixtures.window(
            id: "w2",
            appID: "com.test.appB",
            frame: Fixtures.rightFrame
        )
        let fixture = makeFixture(initialWindows: [original])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([original, w2])
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.setFrameResults[original.id] = [.applied, .failed]
        fixture.commandService.suspendSetFrame(original.id)

        fixture.hud.send(.activateWindow(w2.id))
        for _ in 0..<100 where fixture.commandService.frame(for: original.id) == Fixtures.leftFrame {
            await Task.yield()
        }
        controller.closeSwitcher()
        fixture.commandService.resumeSetFrame(original.id)
        for _ in 0..<100 where controller.state.windows[original.id]?.isCompatible != false {
            await Task.yield()
        }

        fixture.observation.setSnapshot([w2])
        _ = await controller.refreshWindowInventory()
        XCTAssertNil(controller.state.windows[original.id])

        fixture.observation.emitImmediately(.created(original))
        fixture.commandService.register(original.id, frame: original.frame)
        fixture.observation.setSnapshot([original, w2])
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        let focused = expectation(description: "reappeared binding focused")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == original.id { focused.fulfill() }
        }

        fixture.hud.send(.activateWindow(original.id))
        await fulfillment(of: [focused], timeout: 1)

        XCTAssertEqual(controller.state.windows[original.id]?.isCompatible, true)
        XCTAssertTrue(fixture.commandService.events.contains(.raiseAndFocus(original.id)))
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    // MARK: - Step 6: permission-loss Reveal All

    func testPermissionLossTriggersRevealAllRestoringEveryWindowCanonicalFrame() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)

        fixture.commandService.clearEvents()
        await controller.handlePermissionLoss()

        // Reveal All must restore every managed window's canonical frame and
        // unminimize it.
        for windowID in ["w1", "w2"] {
            let frame = try XCTUnwrap(controller.state.windows[windowID]?.canonicalFrame)
            XCTAssertTrue(fixture.commandService.events.contains(.setFrame(windowID, frame)),
                          "Reveal All must restore \(windowID)'s canonical frame")
            XCTAssertTrue(fixture.commandService.events.contains(.setMinimized(windowID, false)),
                          "Reveal All must unminimize \(windowID)")
        }
    }

    func testPermissionLossWaitsForInFlightHUDMutationBeforeFinalRevealAll() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame),
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSetFrame("w1")
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        let revisionBefore = controller.state.revision

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where fixture.commandService.frame(for: "w1") == Fixtures.leftFrame {
            await Task.yield()
        }
        var permissionRecoveryCompleted = false
        let permissionRecovery = Task { @MainActor in
            let result = await controller.handlePermissionLoss()
            permissionRecoveryCompleted = true
            return result
        }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(permissionRecoveryCompleted)
        controller.openSwitcher()
        fixture.hud.send(.activateWindow("w1"))
        fixture.commandService.resumeSetFrame("w1")
        _ = await permissionRecovery.value

        XCTAssertEqual(fixture.commandService.frame(for: "w1"), Fixtures.leftFrame)
        XCTAssertEqual(fixture.commandService.frame(for: "w2"), Fixtures.rightFrame)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.revision, revisionBefore)
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w2")))
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w1")))
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)

        fixture.commandService.clearEvents()
        fixture.hud.send(.activateWindow("w1"))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w1")))

        fixture.observation.setSnapshot([
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame),
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        _ = await controller.refreshWindowInventory()
        fixture.commandService.clearEvents()
        controller.openSwitcher()
        let focusedAfterRecovery = expectation(description: "selection enabled after readiness")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == "w1" { focusedAfterRecovery.fulfill() }
        }
        fixture.hud.send(.activateWindow("w1"))
        await fulfillment(of: [focusedAfterRecovery], timeout: 1)
    }

    func testConcurrentPermissionRecoveriesSerializeRevealAllMutations() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSetFrame("w1")

        let first = Task { @MainActor in await controller.handlePermissionLoss() }
        for _ in 0..<100 where fixture.commandService.setFrameEventCount(for: "w1") == 0 {
            await Task.yield()
        }
        let second = Task { @MainActor in await controller.handlePermissionLoss() }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(fixture.commandService.setFrameEventCount(for: "w1"), 1)
        fixture.commandService.resumeSetFrame("w1")
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(fixture.commandService.setFrameEventCount(for: "w1"), 2)
    }

    func testTerminationWaitsForConcurrentPermissionRecoveryAndTearsDownLast() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSetFrame("w1")

        let permissionRecovery = Task { @MainActor in await controller.handlePermissionLoss() }
        for _ in 0..<100 where fixture.commandService.setFrameEventCount(for: "w1") == 0 {
            await Task.yield()
        }
        let termination = Task { @MainActor in await controller.handleApplicationTermination() }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(fixture.commandService.setFrameEventCount(for: "w1"), 1)
        XCTAssertFalse(fixture.observation.didStop)

        fixture.commandService.resumeSetFrame("w1")
        _ = await permissionRecovery.value
        await termination.value

        XCTAssertEqual(fixture.commandService.setFrameEventCount(for: "w1"), 2)
        XCTAssertTrue(fixture.observation.didStop)
    }

    // MARK: - Step 7: app termination Reveal All before observer teardown

    func testApplicationTerminationRunsRevealAllThenTearsDownObservers() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let observation = fixture.observation
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)

        fixture.commandService.clearEvents()
        var commandEventCountAtStop = -1
        observation.onStop = { commandEventCountAtStop = fixture.commandService.events.count }
        await controller.handleApplicationTermination()

        for windowID in ["w1", "w2"] {
            let frame = try XCTUnwrap(controller.state.windows[windowID]?.canonicalFrame)
            XCTAssertTrue(fixture.commandService.events.contains(.setFrame(windowID, frame)),
                          "Termination Reveal All must restore \(windowID)'s canonical frame")
        }
        // The controller must run Reveal All BEFORE stopping observers. The
        // observation service records how many command events had already been
        // issued at the moment stop() ran; that count must cover the restore
        // commands (2 windows => at least 2 setFrame events).
        XCTAssertGreaterThanOrEqual(
            commandEventCountAtStop, 2,
            "Reveal All must run BEFORE observer teardown (commands observed at stop: \(commandEventCountAtStop))"
        )
        XCTAssertTrue(observation.didStop,
                      "Observers must be torn down after Reveal All on termination")
    }

    func testApplicationTerminationWaitsForInFlightHUDMutationBeforeTeardown() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        try await stageWindowOnBackgroundScreen(fixture, controller: controller)
        fixture.observation.setSnapshot([
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame),
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.clearEvents()
        fixture.commandService.suspendSetFrame("w1")
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        let revisionBefore = controller.state.revision

        fixture.hud.send(.activateWindow("w2"))
        for _ in 0..<100 where fixture.commandService.frame(for: "w1") == Fixtures.leftFrame {
            await Task.yield()
        }
        let termination = Task { @MainActor in
            await controller.handleApplicationTermination()
        }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(fixture.observation.didStop)
        controller.openSwitcher()
        fixture.hud.send(.activateWindow("w1"))
        fixture.commandService.resumeSetFrame("w1")
        await termination.value

        XCTAssertEqual(fixture.commandService.frame(for: "w1"), Fixtures.leftFrame)
        XCTAssertEqual(fixture.commandService.frame(for: "w2"), Fixtures.rightFrame)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(controller.state.revision, revisionBefore)
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w2")))
        XCTAssertFalse(fixture.commandService.events.contains(.raiseAndFocus("w1")))
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
        XCTAssertTrue(fixture.observation.didStop)
    }

    // MARK: - openSwitcher / closeSwitcher (SwitcherPanelPresenting conformance)

    func testOpenSwitcherRefreshesHUDProjectionAndPresentsPanelWithoutChangingScreens() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        let activeBefore = controller.state.activeScreenID
        let revisionBefore = controller.state.revision

        controller.openSwitcher()

        XCTAssertTrue(fixture.hud.presented)
        XCTAssertEqual(fixture.hud.presentedInventoryRevision, controller.inventoryRevision)
        XCTAssertEqual(fixture.hud.presentedSafeBounds, fixture.canvas)
        XCTAssertTrue(controller.isHUDVisible)
        XCTAssertEqual(controller.visibleTab, .switch)
        XCTAssertEqual(controller.state.activeScreenID, activeBefore,
                       "openSwitcher must not change the active Screen")
        XCTAssertEqual(controller.state.revision, revisionBefore,
                       "openSwitcher must not mutate domain state")
    }

    func testOpenSwitcherPresentationFailureStaysHiddenWithoutVisibilityOrRefresh() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        fixture.hud.presentationResult = .failure(.keyboardLayoutUnavailable)
        let refreshCountBefore = fixture.observation.snapshotCallCount
        var visibilityEvents: [WorkspaceTab?] = []
        let observation = controller.observeVisibilityChanges { visibilityEvents.append($0) }
        visibilityEvents.removeAll()

        controller.openSwitcher()
        await Task.yield()

        XCTAssertFalse(controller.isHUDVisible)
        XCTAssertNil(controller.visibleTab)
        XCTAssertEqual(controller.lastHUDPresentationError, .keyboardLayoutUnavailable)
        XCTAssertTrue(visibilityEvents.isEmpty)
        XCTAssertEqual(fixture.observation.snapshotCallCount, refreshCountBefore)
        XCTAssertFalse(fixture.hud.presented)
        _ = observation
    }

    func testSecondGlobalCommandTabMovesHUDFocusWithoutActivatingOrClosing() async throws {
        let fixture = makeFixture(initialWindows: [])
        fixture.frontmostApplicationID = "com.test.current"
        let controller = fixture.makeController()
        controller.recordApplicationActivation("com.test.previous")
        controller.recordApplicationActivation("com.test.current")

        controller.openSwitcher()
        controller.toggle(tab: .switch, globalShortcutStartedAtNanoseconds: 2)
        XCTAssertTrue(fixture.activatedApplicationIDs.isEmpty)
        XCTAssertEqual(fixture.hud.advanceFocusCount, 1)
        XCTAssertEqual(controller.visibleTab, .switch)
        XCTAssertFalse(fixture.hud.closed)
    }

    func testDelayedGlobalCommandTabCallbackPresentsHUDWithoutWaitingAgain() async throws {
        let fixture = makeFixture(initialWindows: [])
        fixture.modifierFlags = [.command]
        fixture.monotonicNowNanoseconds = 300_000_001
        let controller = fixture.makeController()
        try await controller.start()

        controller.toggle(tab: .switch, globalShortcutStartedAtNanoseconds: 1)

        XCTAssertTrue(controller.isHUDVisible)
        XCTAssertEqual(controller.visibleTab, .switch)
    }

    func testPreviousApplicationWithoutHistoryOpensHUD() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()

        fixture.hud.send(.activatePreviousApplication)

        XCTAssertTrue(controller.isHUDVisible)
        XCTAssertEqual(controller.visibleTab, .switch)
        XCTAssertTrue(fixture.activatedApplicationIDs.isEmpty)
    }

    func testPreviousApplicationActivationFailureReopensHUD() async throws {
        let fixture = makeFixture(initialWindows: [])
        fixture.applicationActivationSucceeds = false
        let controller = fixture.makeController()
        try await controller.start()
        controller.recordApplicationActivation("com.test.previous")
        controller.recordApplicationActivation("com.test.current")
        controller.openSwitcher()

        fixture.hud.send(.activatePreviousApplication)
        for _ in 0..<100 where fixture.activatedApplicationIDs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(fixture.activatedApplicationIDs, ["com.test.previous"])
        XCTAssertTrue(controller.isHUDVisible)
        XCTAssertEqual(controller.visibleTab, .switch)
    }

    func testPreviousApplicationActivationWaitsForSupersededWindowFocus() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.current",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        controller.recordApplicationActivation("com.test.previous")
        controller.recordApplicationActivation(window.appID)
        controller.openSwitcher()
        fixture.commandService.suspendRaise(window.id)
        fixture.commandService.onRaiseAndFocus = { windowID in
            fixture.physicalApplicationEvents.append("focus:\(windowID)")
        }
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0
        let revisionBefore = controller.state.revision

        fixture.hud.send(.activateWindow(window.id))
        for _ in 0..<100 where !fixture.commandService.events.contains(.raiseAndFocus(window.id)) {
            await Task.yield()
        }
        controller.openSwitcher()
        fixture.hud.send(.activatePreviousApplication)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertTrue(fixture.activatedApplicationIDs.isEmpty)
        fixture.commandService.resumeRaise(window.id)
        for _ in 0..<100 where fixture.physicalApplicationEvents.count < 2 { await Task.yield() }

        XCTAssertEqual(
            fixture.physicalApplicationEvents,
            ["focus:w1", "activate:com.test.previous"]
        )
        XCTAssertEqual(controller.state.revision, revisionBefore)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertEqual(controller.hudActivation.stage, .cancelled)
        XCTAssertEqual(controller.hudActivation.result, .cancelled)
        XCTAssertEqual(controller.hudActivation.blockReason, .selectionSuperseded)
    }

    func testUnresolvedSelectionReopenWaitsForSupersededWindowFocus() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.commandService.suspendRaise(window.id)
        fixture.commandService.onRaiseAndFocus = { windowID in
            fixture.physicalApplicationEvents.append("focus:\(windowID)")
        }
        fixture.pointer.location = Fixtures.rightRegionCenter
        fixture.pointer.moves = 0

        fixture.hud.send(.activateWindow(window.id))
        for _ in 0..<100 where !fixture.commandService.events.contains(.raiseAndFocus(window.id)) {
            await Task.yield()
        }
        controller.openSwitcher()
        fixture.observation.setSnapshot([])
        fixture.observation.emitImmediately(.destroyed(window.id))
        let revisionAfterDestroy = controller.state.revision
        fixture.hud.send(.activateWindow(window.id))

        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
        fixture.commandService.resumeRaise(window.id)
        await controller.awaitHUDSelectionForTest()
        await controller.awaitInventoryRefreshForTest()

        XCTAssertEqual(
            fixture.physicalApplicationEvents,
            ["focus:w1", "reopen:com.test.appA"]
        )
        XCTAssertEqual(controller.state.revision, revisionAfterDestroy)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertEqual(controller.hudActivation.stage, .fallback)
        XCTAssertEqual(controller.hudActivation.result, .applied)
        XCTAssertEqual(controller.hudActivation.blockReason, .targetUnavailable)
    }

    func testOpenSwitcherReconcilesWindowsMissedByTheStartupSnapshot() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        let recovered = Fixtures.window(
            id: "w-recovered",
            appID: "com.test.recovered",
            frame: Fixtures.leftFrame
        )
        fixture.observation.setSnapshot([recovered])
        let refreshed = fixture.observation.expectSnapshotRefresh()

        controller.openSwitcher()
        await fulfillment(of: [refreshed], timeout: 1)
        for _ in 0..<100 where controller.state.windows[recovered.id] == nil
            || fixture.hud.windowDiscoveryStatus != .ready {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state.screens.first?.windowIDs, [recovered.id])
        XCTAssertEqual(fixture.hud.windowDiscoveryStatus, .ready)
        XCTAssertTrue(fixture.hud.presented)
    }

    func testPartialRefreshPreservesOwnershipAndCompleteRefreshRemovesMissingWindow() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        try controller.createBlankScreen(id: "screen-2")

        fixture.observation.setSnapshot([window], completeness: .complete)
        await controller.refreshWindowInventory()

        XCTAssertEqual(controller.state.screen(id: "screen-1")?.windowIDs, [window.id])
        XCTAssertEqual(controller.state.screen(id: "screen-2")?.windowIDs, [])

        fixture.observation.setSnapshot([], completeness: .partial)
        await controller.refreshWindowInventory()

        XCTAssertEqual(controller.state.screen(id: "screen-1")?.windowIDs, [window.id])
        XCTAssertNotNil(controller.state.windows[window.id])

        fixture.observation.setSnapshot([], completeness: .complete)
        await controller.refreshWindowInventory()

        XCTAssertNil(controller.state.windows[window.id])
        XCTAssertEqual(controller.state.screen(id: "screen-1")?.windowIDs, [])
    }

    func testWorkspaceWakeTriggersInventoryReconcile() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        let recovered = Fixtures.window(
            id: "w-after-wake",
            appID: "com.test.wake",
            frame: Fixtures.rightFrame
        )
        fixture.observation.setSnapshot([recovered])
        let refreshed = fixture.observation.expectSnapshotRefresh()

        fixture.workspaceNotificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        await fulfillment(of: [refreshed], timeout: 1)
        for _ in 0..<20 where controller.state.windows[recovered.id] == nil {
            await Task.yield()
        }

        XCTAssertEqual(controller.state.screens.first?.windowIDs, [recovered.id])
    }

    func testAppLaunchReconcilesAgainAfterAXWindowCreationRace() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        let recovered = Fixtures.window(
            id: "w-after-launch",
            appID: "com.test.launch",
            frame: Fixtures.rightFrame
        )
        fixture.observation.queueSnapshots([
            WindowObservationSnapshot(windows: [], completeness: .complete),
            WindowObservationSnapshot(windows: [recovered], completeness: .complete)
        ])

        fixture.workspaceNotificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared
        )
        for _ in 0..<100 where controller.state.windows[recovered.id] == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(fixture.hud.presented)
        XCTAssertEqual(controller.state.screens.first?.windowIDs, [recovered.id])
        XCTAssertGreaterThanOrEqual(fixture.observation.snapshotCallCount, 3)
    }

    func testApplicationActivationRefreshesFocusReadback() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        fixture.observation.setSnapshot([
            Fixtures.window(
                id: window.id,
                appID: window.appID,
                frame: window.frame,
                isFocused: true
            )
        ])
        let refreshed = fixture.observation.expectSnapshotRefresh()

        fixture.workspaceNotificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )

        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertGreaterThanOrEqual(fixture.observation.snapshotCallCount, 2)
    }

    func testNativeSpaceChangeNotificationRefreshesTheActiveDesktop() async throws {
        let fixture = makeFixture(initialWindows: [])
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: true),
                .init(id: 42, number: 2, isActive: false)
            ],
            windowDesktopIDs: [:]
        ))
        let controller = fixture.makeController()
        try await controller.start()
        await fixture.nativeSpaces.suspendNextSnapshot()
        let immediateRefreshCallCount = await fixture.nativeSpaces.snapshotCallCount() + 1
        fixture.workspaceNotificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared
        )
        await fixture.nativeSpaces.waitForSnapshotCallCount(immediateRefreshCallCount)
        await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
            desktops: [
                .init(id: 41, number: 1, isActive: false),
                .init(id: 42, number: 2, isActive: true)
            ],
            windowDesktopIDs: [:]
        ))
        await fixture.nativeSpaces.resumeSnapshot()
        for _ in 0..<100 where controller.state.activeScreenID != "native-space-42" {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state.activeScreenID, "native-space-42")
        XCTAssertEqual(controller.state.inspectedScreenID, "native-space-42")
        let snapshotCallCount = await fixture.nativeSpaces.snapshotCallCount()
        XCTAssertGreaterThanOrEqual(snapshotCallCount, 3)
    }

    func testCloseSwitcherOnlyDismissesHUDAndNeverChangesScreens() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        let activeBefore = controller.state.activeScreenID
        let revisionBefore = controller.state.revision

        controller.openSwitcher()
        controller.closeSwitcher()

        XCTAssertTrue(fixture.hud.closed)
        XCTAssertEqual(controller.state.activeScreenID, activeBefore)
        XCTAssertEqual(controller.state.revision, revisionBefore,
                       "closeSwitcher must never mutate domain state")
    }

    func testPrewarmSwitcherAttachesHUDController() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()

        controller.prewarmSwitcher()

        XCTAssertTrue(fixture.hud.attached,
                      "prewarmSwitcher must attach the HUD controller so the first open is instant")
    }

    func testHUDOutsideCancelClosesOwnerStateAndCanReopen() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        var visibilityEvents: [WorkspaceTab?] = []
        let observation = controller.observeVisibilityChanges { visibilityEvents.append($0) }
        visibilityEvents.removeAll()
        controller.openSwitcher()

        fixture.hud.sendOutsideClick()

        XCTAssertTrue(fixture.hud.closed)
        XCTAssertFalse(controller.isHUDVisible)
        XCTAssertNil(controller.visibleTab)
        XCTAssertEqual(visibilityEvents, [.switch, nil])

        controller.toggle(tab: .switch)

        XCTAssertTrue(controller.isHUDVisible)
        XCTAssertEqual(controller.visibleTab, .switch)
        XCTAssertEqual(fixture.hud.presentCallCount, 2)
        XCTAssertEqual(visibilityEvents, [.switch, nil, .switch])
        _ = observation
    }

    func testHUDSupersedingIntentsReplaceSelectionTokenWhileFocusToggleDoesNot() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        try await controller.start()
        controller.recordApplicationActivation("com.test.previous")
        controller.recordApplicationActivation("com.test.frontmost")
        var tokens = [controller.hudSelectionToken]

        controller.openSwitcher()
        tokens.append(controller.hudSelectionToken)
        fixture.hud.send(.activatePreviousApplication)
        tokens.append(controller.hudSelectionToken)
        for _ in 0..<100 where fixture.activatedApplicationIDs.count < 1 { await Task.yield() }

        controller.openSwitcher()
        tokens.append(controller.hudSelectionToken)
        controller.toggle(tab: .switch, globalShortcutStartedAtNanoseconds: 1)
        tokens.append(controller.hudSelectionToken)
        for _ in 0..<100 where fixture.activatedApplicationIDs.count < 2 { await Task.yield() }

        controller.openSwitcher()
        tokens.append(controller.hudSelectionToken)
        fixture.hud.send(.cancel)
        tokens.append(controller.hudSelectionToken)

        controller.openSwitcher()
        tokens.append(controller.hudSelectionToken)
        controller.closeSwitcher()
        tokens.append(controller.hudSelectionToken)

        XCTAssertEqual(tokens[3], tokens[4])
        tokens.remove(at: 4)
        XCTAssertEqual(Set(tokens).count, tokens.count)
        XCTAssertEqual(fixture.activatedApplicationIDs, ["com.test.previous"])
    }

    func testHUDWindowIntentOnActiveScreenSameRegionFocusesOnlyExactWindow() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame),
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        let activationRevision = controller.hudActivation.revision
        fixture.commandService.clearEvents()
        let focused = expectation(description: "selected window focused")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == "w1" { focused.fulfill() }
        }

        fixture.hud.send(.activateWindow("w1"))
        await fulfillment(of: [focused], timeout: 1)

        XCTAssertTrue(fixture.hud.closed)
        XCTAssertEqual(fixture.commandService.events, [.raiseAndFocus("w1"), .snapshot("w1")])
        XCTAssertEqual(fixture.pointer.locationReads, 1)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertEqual(fixture.pointer.location, Fixtures.leftRegionCenter)
        XCTAssertEqual(controller.state.activeScreenID, "screen-1")
        XCTAssertEqual(
            controller.hudActivation,
            FocusSemanticHUDActivation(
                revision: activationRevision + 1,
                stage: .commit,
                result: .applied,
                bindingKind: .injected,
                selectionCurrent: true,
                bindingCurrent: true,
                blockReason: .none
            )
        )
    }

    func testHUDActivationDiagnosticAdvancesBeforeFrozenMappingGuard() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        let baseline = controller.hudActivation.revision

        fixture.hud.send(.activateWindow("not-in-frozen-hud"))

        XCTAssertEqual(
            controller.hudActivation,
            FocusSemanticHUDActivation(
                revision: baseline + 1,
                stage: .intent,
                result: .blocked,
                bindingKind: .none,
                selectionCurrent: false,
                bindingCurrent: false,
                blockReason: .mappingUnavailable
            )
        )
    }

    func testHUDWindowIntentFocusesActiveWindowWithoutMoveCompatibility() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame,
            isSettable: false
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        let revisionBefore = controller.state.revision
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        let focused = expectation(description: "non-movable window focused")
        let settled = expectation(description: "focused window read back")
        fixture.commandService.onRaiseAndFocus = { _ in focused.fulfill() }
        fixture.commandService.onSnapshot = { _ in settled.fulfill() }

        fixture.hud.send(.activateWindow(window.id))
        await fulfillment(of: [focused, settled], timeout: 1)
        await Task.yield()

        XCTAssertEqual(
            fixture.commandService.events,
            [.raiseAndFocus(window.id), .snapshot(window.id)]
        )
        XCTAssertGreaterThan(controller.state.revision, revisionBefore)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testHUDWindowIntentResolvesSingleReplacementWindowForFrozenApp() async throws {
        let original = Fixtures.window(
            id: "w-old",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let replacement = Fixtures.window(
            id: "w-new",
            appID: original.appID,
            frame: Fixtures.leftFrame,
            launchGeneration: "replacement"
        )
        let fixture = makeFixture(initialWindows: [original])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.observation.emitImmediately(.destroyed(original.id))
        fixture.observation.emitImmediately(.created(replacement))
        fixture.commandService.register(replacement.id, frame: replacement.frame, isFocused: true)
        fixture.commandService.clearEvents()
        let focused = expectation(description: "replacement window focused")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == replacement.id { focused.fulfill() }
        }

        fixture.hud.send(.activateWindow(original.id))
        await fulfillment(of: [focused], timeout: 1)

        XCTAssertEqual(
            fixture.commandService.events,
            [.raiseAndFocus(replacement.id), .snapshot(replacement.id)]
        )
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testHUDWindowIntentOnActiveScreenLandsPointerAcrossHardwareRegions() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame),
            Fixtures.window(id: "w2", appID: "com.test.appB", frame: Fixtures.rightFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.pointer.location = Fixtures.leftRegionCenter
        let focused = expectation(description: "cross-region selected window focused")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == "w2" { focused.fulfill() }
        }

        fixture.hud.send(.activateWindow("w2"))
        await fulfillment(of: [focused], timeout: 1)

        XCTAssertEqual(fixture.commandService.events, [.raiseAndFocus("w2"), .snapshot("w2")])
        XCTAssertEqual(fixture.pointer.moves, 1)
        XCTAssertEqual(fixture.pointer.location, Fixtures.rightRegionCenter)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testHUDWindowIntentLandsOnFrameSettledDuringRaiseAndFocus() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.leftFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.pointer.location = Fixtures.leftRegionCenter
        fixture.commandService.onRaiseAndFocus = { windowID in
            fixture.commandService.register(windowID, frame: Fixtures.rightFrame, isFocused: true)
        }

        fixture.hud.send(.activateWindow("w1"))
        for _ in 0..<100 where fixture.pointer.moves == 0 {
            await Task.yield()
        }

        XCTAssertEqual(
            fixture.commandService.events,
            [.raiseAndFocus("w1"), .snapshot("w1")]
        )
        XCTAssertEqual(fixture.pointer.attemptedDestinations, [Fixtures.rightRegionCenter])
        XCTAssertEqual(fixture.pointer.location, Fixtures.rightRegionCenter)
    }

    func testHUDWindowIntentSkipsLandingWhenBindingChangesDuringSettledReadback() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.rightFrame
        )
        let replacement = Fixtures.window(
            id: "w1",
            appID: window.appID,
            frame: Fixtures.rightFrame,
            launchGeneration: "replacement"
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.clearEvents()
        fixture.commandService.onSnapshot = { _ in
            fixture.observation.emitImmediately(.destroyed(window.id))
            fixture.observation.emitImmediately(.created(replacement))
        }

        fixture.hud.send(.activateWindow(window.id))
        for _ in 0..<100 where !fixture.commandService.events.contains(.snapshot(window.id)) {
            await Task.yield()
        }
        await Task.yield()

        XCTAssertEqual(controller.bindings[window.id], replacement.binding)
        XCTAssertEqual(fixture.pointer.locationReads, 0)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testHUDWindowIntentDoesNotCommitWhenBindingChangesDuringFocus() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.rightFrame
        )
        let replacement = Fixtures.window(
            id: window.id,
            appID: window.appID,
            frame: window.frame,
            launchGeneration: "replacement"
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.clearEvents()
        var revisionAfterReplacement: Int?
        fixture.commandService.onRaiseAndFocus = { _ in
            fixture.observation.emitImmediately(.destroyed(window.id))
            fixture.observation.emitImmediately(.created(replacement))
            revisionAfterReplacement = controller.state.revision
            fixture.commandService.register(
                replacement.id,
                frame: replacement.frame,
                isFocused: false
            )
        }

        fixture.hud.send(.activateWindow(window.id))
        for _ in 0..<100 where controller.bindings[window.id] != replacement.binding {
            await Task.yield()
        }
        await Task.yield()

        XCTAssertEqual(controller.bindings[window.id], replacement.binding)
        XCTAssertEqual(fixture.commandService.events, [.raiseAndFocus(window.id)])
        XCTAssertEqual(Optional(controller.state.revision), revisionAfterReplacement)
        XCTAssertEqual(fixture.pointer.locationReads, 0)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
        XCTAssertEqual(controller.hudActivation.stage, .cancelled)
        XCTAssertEqual(controller.hudActivation.result, .cancelled)
        XCTAssertEqual(controller.hudActivation.bindingKind, .injected)
        XCTAssertTrue(controller.hudActivation.selectionCurrent)
        XCTAssertFalse(controller.hudActivation.bindingCurrent)
        XCTAssertEqual(controller.hudActivation.blockReason, .bindingChanged)
    }

    func testNewHUDSelectionSupersedesDelayedEarlierSelection() async throws {
        let first = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let second = Fixtures.window(
            id: "w2",
            appID: "com.test.appB",
            frame: Fixtures.rightFrame
        )
        let fixture = makeFixture(initialWindows: [first, second])
        let controller = fixture.makeController()
        try await controller.start()
        let inventoryRevision = controller.inventoryRevision
        controller.openSwitcher()
        for _ in 0..<100 where controller.inventoryRevision == inventoryRevision {
            await Task.yield()
        }
        fixture.commandService.clearEvents()
        fixture.commandService.suspendRaise(first.id)
        let firstReturned = expectation(description: "superseded selection returned")
        fixture.commandService.onRaiseAndFocus = { windowID in
            if windowID == first.id { firstReturned.fulfill() }
        }
        let revisionBefore = controller.state.revision

        fixture.hud.send(.activateWindow(first.id))
        for _ in 0..<100 where !fixture.commandService.events.contains(.raiseAndFocus(first.id)) {
            await Task.yield()
        }
        let firstActivationRevision = controller.hudActivation.revision

        controller.openSwitcher()
        fixture.hud.send(.activateWindow(second.id))
        let secondQueuedActivation = controller.hudActivation
        XCTAssertEqual(secondQueuedActivation.revision, firstActivationRevision + 1)
        XCTAssertEqual(secondQueuedActivation.stage, .queued)
        XCTAssertEqual(secondQueuedActivation.result, .pending)
        for _ in 0..<100 where !fixture.commandService.events.contains(.snapshot(second.id)) {
            await Task.yield()
        }

        fixture.commandService.resumeRaise(first.id)
        await fulfillment(of: [firstReturned], timeout: 1)
        await Task.yield()

        XCTAssertEqual(
            fixture.commandService.events,
            [.raiseAndFocus(first.id), .raiseAndFocus(second.id), .snapshot(second.id)]
        )
        XCTAssertEqual(controller.state.revision, revisionBefore + 1)
        XCTAssertEqual(fixture.pointer.attemptedDestinations, [Fixtures.rightRegionCenter])
        XCTAssertEqual(fixture.pointer.location, Fixtures.rightRegionCenter)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
        XCTAssertEqual(controller.hudActivation.revision, secondQueuedActivation.revision)
        XCTAssertEqual(controller.hudActivation.stage, .commit)
        XCTAssertEqual(controller.hudActivation.result, .applied)
    }

    func testSupersededDelayedActivationCannotOverwriteNewBlockedIntentDiagnostic() async throws {
        let first = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [first])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.commandService.suspendRaise(first.id)

        fixture.hud.send(.activateWindow(first.id))
        for _ in 0..<100 where !fixture.commandService.events.contains(.raiseAndFocus(first.id)) {
            await Task.yield()
        }

        controller.openSwitcher()
        fixture.hud.send(.activateWindow("not-in-frozen-hud"))
        let blocked = controller.hudActivation
        XCTAssertEqual(blocked.stage, .intent)
        XCTAssertEqual(blocked.result, .blocked)
        XCTAssertEqual(blocked.blockReason, .mappingUnavailable)

        fixture.commandService.resumeRaise(first.id)
        for _ in 0..<100 where fixture.commandService.events.count == 1 {
            await Task.yield()
        }
        await Task.yield()

        XCTAssertEqual(controller.hudActivation, blocked)
    }

    func testHUDActivationRevisionExhaustionDisablesFurtherIntentsWithoutReuse() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        controller.setHUDActivationForTest(
            FocusSemanticHUDActivation(
                revision: UInt64.max - 1,
                stage: .commit,
                result: .applied,
                bindingKind: .injected,
                selectionCurrent: true,
                bindingCurrent: true,
                blockReason: .none
            )
        )

        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.hud.send(.activateWindow(window.id))
        for _ in 0..<100 where controller.hudActivation.stage != .commit {
            await Task.yield()
        }
        let saturatedTruth = controller.hudActivation
        XCTAssertEqual(saturatedTruth.revision, UInt64.max)
        XCTAssertEqual(saturatedTruth.stage, .commit)
        XCTAssertEqual(saturatedTruth.result, .applied)

        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.hud.send(.activateWindow(window.id))
        await Task.yield()

        XCTAssertEqual(controller.hudActivation, saturatedTruth)
        XCTAssertTrue(fixture.commandService.events.isEmpty)
        XCTAssertTrue(fixture.hud.closed)
    }

    func testHUDWindowIntentSkipsLandingWhenSettledReadbackIsUnavailable() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.rightFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.commandService.clearEvents()
        fixture.commandService.snapshotUnavailableIDs.insert(window.id)

        fixture.hud.send(.activateWindow(window.id))
        for _ in 0..<100 where !fixture.commandService.events.contains(.snapshot(window.id)) {
            await Task.yield()
        }
        await Task.yield()

        XCTAssertEqual(
            fixture.commandService.events,
            [.raiseAndFocus(window.id), .snapshot(window.id)]
        )
        XCTAssertEqual(fixture.pointer.locationReads, 0)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testHUDWindowIntentKeepsExactActivationWhenPointerIsUnavailable() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.rightFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.pointer.location = nil
        let focused = expectation(description: "selected window focused without pointer")
        fixture.commandService.onRaiseAndFocus = { _ in focused.fulfill() }

        fixture.hud.send(.activateWindow("w1"))
        await fulfillment(of: [focused], timeout: 1)

        XCTAssertEqual(fixture.pointer.locationReads, 1)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testHUDWindowIntentKeepsExactActivationWhenPointerMoveDegrades() async throws {
        let fixture = makeFixture(initialWindows: [
            Fixtures.window(id: "w1", appID: "com.test.appA", frame: Fixtures.rightFrame)
        ])
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()
        fixture.pointer.location = Fixtures.leftRegionCenter
        fixture.pointer.moveSucceeds = false
        let focused = expectation(description: "selected window focused before pointer degradation")
        fixture.commandService.onRaiseAndFocus = { _ in focused.fulfill() }

        fixture.hud.send(.activateWindow("w1"))
        await fulfillment(of: [focused], timeout: 1)

        XCTAssertEqual(fixture.pointer.attemptedDestinations, [Fixtures.rightRegionCenter])
        XCTAssertEqual(fixture.pointer.location, Fixtures.leftRegionCenter)
        XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty)
    }

    func testHUDWindowIntentReopensAppWhenRepresentativeWindowVanished() async throws {
        let window = Fixtures.window(
            id: "w1",
            appID: "com.test.appA",
            frame: Fixtures.leftFrame
        )
        let fixture = makeFixture(initialWindows: [window])
        fixture.commandService.detailedFocusOutcome = .resolution(.vanished)
        let controller = fixture.makeController()
        try await controller.start()
        controller.openSwitcher()

        fixture.hud.send(.activateWindow(window.id))
        for _ in 0..<100 where fixture.reopenedApplicationIDs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(fixture.reopenedApplicationIDs, [window.appID])
        XCTAssertEqual(fixture.pointer.locationReads, 0)
        XCTAssertEqual(fixture.pointer.moves, 0)
        XCTAssertEqual(controller.hudActivation.stage, .fallback)
        XCTAssertEqual(controller.hudActivation.result, .applied)
        XCTAssertEqual(controller.hudActivation.bindingKind, .injected)
        XCTAssertTrue(controller.hudActivation.selectionCurrent)
        XCTAssertTrue(controller.hudActivation.bindingCurrent)
        XCTAssertEqual(controller.hudActivation.blockReason, .resolutionUnavailable)
    }

    func testHUDWindowServerExactFocusFailuresStayTypedWithoutReopeningApp() async throws {
        let cases: [(NativeExactWindowFocusFailure, FocusSemanticHUDActivationBlockReason)] = [
            (.symbolUnavailable, .exactFocusSymbolUnavailable),
            (.processResolutionFailed, .exactFocusProcessResolutionFailed),
            (.frontProcessRejected, .exactFocusFrontProcessRejected),
            (.keyEventRejected, .exactFocusKeyEventRejected)
        ]

        for (failure, expectedReason) in cases {
            let fixture = makeFixture(initialWindows: [])
            fixture.nativeApplications[4242] = NativeWindowApplication(
                appID: "com.test.native",
                appName: "Native",
                isActive: false
            )
            let controller = fixture.makeController()
            try await controller.start()
            await fixture.nativeSpaces.setSnapshot(NativeDesktopSnapshot(
                desktops: [.init(id: 41, number: 1, isActive: true)],
                windowDesktopIDs: [:],
                windows: [.init(
                    id: 900,
                    desktopIDs: [41],
                    processIdentifier: 4242,
                    ownerName: "Native",
                    title: "",
                    frame: Fixtures.leftFrame
                )]
            ))
            _ = await controller.refreshWindowInventory()
            fixture.commandService.detailedFocusOutcome = .nativeExact(failure)
            controller.openSwitcher()

            fixture.hud.send(.activateWindow("native-window-900"))
            for _ in 0..<100 where controller.hudActivation.stage != .activate {
                await Task.yield()
            }

            XCTAssertTrue(fixture.reopenedApplicationIDs.isEmpty, failure.rawValue)
            XCTAssertEqual(controller.hudActivation.stage, .activate, failure.rawValue)
            XCTAssertEqual(
                controller.hudActivation.result,
                failure == .symbolUnavailable ? .unsupported : .failed,
                failure.rawValue
            )
            XCTAssertEqual(controller.hudActivation.blockReason, expectedReason, failure.rawValue)
        }
    }

    // MARK: - Conformance declarations

    func testControllerConformsToSwitcherRuntimeStarting() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        // The runtime-starting protocol is the AppDelegate's hook for ordering
        // start() before prewarming and semantic readiness.
        let starter: any SwitcherRuntimeStarting = controller
        XCTAssertNotNil(starter)
        try await starter.start()
    }

    func testControllerConformsToSwitcherPanelPresentingAndPrewarming() async throws {
        let fixture = makeFixture(initialWindows: [])
        let controller = fixture.makeController()
        let presenter: any SwitcherPanelPresenting = controller
        let prewarmer: any SwitcherPanelPrewarming = controller
        XCTAssertNotNil(presenter)
        XCTAssertNotNil(prewarmer)
    }

    // MARK: - Fixtures

    private func makeFixture(initialWindows: [ObservedWindow]) -> ControllerFixture {
        ControllerFixture(initialWindows: initialWindows)
    }

    @MainActor
    final class ControllerFixture {
        fileprivate let observation: RecordingWindowObservationService
        fileprivate let commandService: FocusScreenCommandService
        fileprivate let pointer: RecordingPointerEndpoint
        fileprivate let hud: RecordingFocusHUDController
        fileprivate let accessibility: RecordingAccessibilityChecker
        fileprivate let nativeSpaces: RecordingNativeSpaceCatalog
        fileprivate var nativeApplications: [pid_t: NativeWindowApplication] = [:]
        fileprivate let workspaceNotificationCenter: NotificationCenter
        fileprivate let canvas: CanvasRect
        fileprivate let regions: [FocusSemanticCanvasRegion]
        fileprivate var frontmostApplicationID: String?
        fileprivate var modifierFlags: NSEvent.ModifierFlags = []
        fileprivate var monotonicNowNanoseconds: UInt64 = 0
        fileprivate var applicationActivationSucceeds = true
        fileprivate var activatedApplicationIDs: [String] = []
        fileprivate var reopenedApplicationIDs: [String] = []
        fileprivate var physicalApplicationEvents: [String] = []

        init(initialWindows: [ObservedWindow]) {
            observation = RecordingWindowObservationService(initial: initialWindows)
            commandService = FocusScreenCommandService(
                initialSnapshots: Dictionary(uniqueKeysWithValues: initialWindows.map {
                    ($0.id, WindowCommandSnapshot(frame: $0.frame, isMinimized: $0.isMinimized, isFocused: $0.isFocused))
                })
            )
            pointer = RecordingPointerEndpoint()
            pointer.location = Fixtures.leftRegionCenter
            hud = RecordingFocusHUDController()
            accessibility = RecordingAccessibilityChecker()
            nativeSpaces = RecordingNativeSpaceCatalog()
            workspaceNotificationCenter = NotificationCenter()
            canvas = Fixtures.canvas
            regions = Fixtures.regions
        }

        func makeController() -> FocusScreenController {
            FocusScreenController(
                observationService: observation,
                commandService: commandService,
                pointerLocation: { [pointer] in
                    pointer.locationReads += 1
                    return pointer.location
                },
                pointerMove: { [pointer] point in
                    pointer.moves += 1
                    pointer.attemptedDestinations.append(point)
                    if pointer.moveSucceeds {
                        pointer.location = point
                    }
                    return pointer.moveSucceeds
                },
                canvasProvider: { [canvas] in canvas },
                regionsProvider: { [regions] in regions },
                hudController: hud,
                commandTimeout: 1.0,
                modifierFlagsProvider: { [weak self] in self?.modifierFlags ?? [] },
                monotonicNowNanoseconds: { [weak self] in self?.monotonicNowNanoseconds ?? 0 },
                accessibilityChecker: accessibility,
                nativeSpaceCatalog: nativeSpaces,
                nativeWindowApplication: { [weak self] processIdentifier in
                    self?.nativeApplications[processIdentifier]
                },
                frontmostApplicationID: { [weak self] in
                    self?.frontmostApplicationID
                },
                activateApplication: { [weak self] appID in
                    self?.activatedApplicationIDs.append(appID)
                    self?.physicalApplicationEvents.append("activate:\(appID)")
                    return self?.applicationActivationSucceeds ?? false
                },
                reopenApplication: { [weak self] appID in
                    self?.reopenedApplicationIDs.append(appID)
                    self?.physicalApplicationEvents.append("reopen:\(appID)")
                    return true
                },
                ownApplicationID: "com.test.switcher",
                workspaceNotificationCenter: workspaceNotificationCenter
            )
        }
    }

    enum Fixtures {
        static let canvas = CanvasRect(x: 0, y: 0, width: 2000, height: 1000)
        static let leftFrame = CanvasRect(x: 0, y: 0, width: 1000, height: 1000)
        static let rightFrame = CanvasRect(x: 1000, y: 0, width: 1000, height: 1000)
        static let regions: [FocusSemanticCanvasRegion] = [
            FocusSemanticCanvasRegion(id: "region-1", frame: leftFrame, scale: 1),
            FocusSemanticCanvasRegion(id: "region-2", frame: rightFrame, scale: 1)
        ]
        static var leftRegionCenter: CanvasPoint { leftFrame.center }
        static var rightRegionCenter: CanvasPoint { rightFrame.center }

        static func window(
            id: ManagedWindowID,
            appID: String,
            frame: CanvasRect,
            isFocused: Bool = false,
            isMinimized: Bool = false,
            isSettable: Bool = true,
            launchGeneration: String? = nil
        ) -> ObservedWindow {
            ObservedWindow(
                id: id,
                appID: appID,
                appName: appID,
                title: id,
                frame: frame,
                isFocused: isFocused,
                isMinimized: isMinimized,
                isSettable: isSettable,
                binding: WindowRuntimeBinding(
                    launchGeneration: launchGeneration ?? "launch-\(appID)",
                    processIdentifier: pid_t(abs(appID.hashValue) % 30_000 + 500),
                    element: .injected(id)
                )
            )
        }

        static func systemWindow(
            id: ManagedWindowID,
            appID: String,
            processIdentifier: pid_t,
            frame: CanvasRect,
            isFocused: Bool = false,
            isSettable: Bool = true,
            launchGeneration: String? = nil,
            title: String = ""
        ) -> ObservedWindow {
            ObservedWindow(
                id: id,
                appID: appID,
                appName: "Native",
                title: title,
                frame: frame,
                isFocused: isFocused,
                isMinimized: false,
                isSettable: isSettable,
                binding: WindowRuntimeBinding(
                    launchGeneration: launchGeneration ?? "launch-\(id)",
                    processIdentifier: processIdentifier,
                    element: .system(NativeAXElementBox(
                        AXUIElementCreateApplication(processIdentifier)
                    ))
                )
            )
        }
    }
}

// MARK: - Test fakes

@MainActor
private final class RecordingPointerEndpoint {
    var location: CanvasPoint?
    var locationReads = 0
    var moves = 0
    var moveSucceeds = true
    var attemptedDestinations: [CanvasPoint] = []
}

@MainActor
private final class RecordingAccessibilityChecker: AccessibilityChecking {
    var isTrusted = true
    private(set) var requestCount = 0

    func isAccessibilityTrusted() -> Bool { isTrusted }

    func requestAccessibilityAccess() -> Bool {
        requestCount += 1
        return isTrusted
    }
}

private actor RecordingNativeSpaceCatalog: NativeSpaceCataloging {
    private var currentSnapshot: NativeDesktopSnapshot?
    private var switchedIDs: [UInt64] = []
    private var shouldSuspendNextSnapshot = false
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private var callCount = 0
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func setSnapshot(_ snapshot: NativeDesktopSnapshot?) {
        currentSnapshot = snapshot
    }

    func suspendNextSnapshot() {
        shouldSuspendNextSnapshot = true
    }

    func resumeSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func snapshotCallCount() -> Int { callCount }

    func waitForSnapshotCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((expectedCount, continuation))
        }
    }

    func switchToDesktop(id: UInt64) -> Bool {
        switchedIDs.append(id)
        return true
    }

    func switchedDesktopIDs() -> [UInt64] { switchedIDs }

    func snapshot(
        windowBindings: [ManagedWindowID: WindowRuntimeBinding],
        focusedWindowID: ManagedWindowID?
    ) async -> NativeDesktopSnapshot? {
        _ = windowBindings
        _ = focusedWindowID
        callCount += 1
        let readyWaiters = callCountWaiters.filter { callCount >= $0.count }
        callCountWaiters.removeAll { callCount >= $0.count }
        for waiter in readyWaiters { waiter.continuation.resume() }
        let captured = currentSnapshot
        if shouldSuspendNextSnapshot {
            shouldSuspendNextSnapshot = false
            await withCheckedContinuation { snapshotContinuation = $0 }
        }
        return captured
    }
}

/// Records every command issued through `WindowCommandService`.
@MainActor
private final class FocusScreenCommandService: WindowCommandService {
    enum Event: Equatable {
        case setFrame(ManagedWindowID, CanvasRect)
        case setMinimized(ManagedWindowID, Bool)
        case raiseAndFocus(ManagedWindowID)
        case close(ManagedWindowID)
        case snapshot(ManagedWindowID)
    }

    private(set) var events: [Event] = []
    var onRaiseAndFocus: ((ManagedWindowID) -> Void)?
    var onSnapshot: ((ManagedWindowID) -> Void)?
    var raiseAndFocusResult: WindowCommandResult = .applied
    var detailedFocusOutcome: WindowFocusCommandOutcome?
    var snapshotUnavailableIDs: Set<ManagedWindowID> = []
    var unavailableBindings: Set<WindowRuntimeBinding> = []
    var setFrameResults: [ManagedWindowID: [WindowCommandResult]] = [:]
    private var states: [ManagedWindowID: WindowCommandSnapshot]
    private var suspendedRaiseIDs: Set<ManagedWindowID> = []
    private var raiseContinuations: [ManagedWindowID: CheckedContinuation<Void, Never>] = [:]
    private var suspendedSnapshotIDs: Set<ManagedWindowID> = []
    private var snapshotContinuations: [ManagedWindowID: CheckedContinuation<Void, Never>] = [:]
    private var suspendedSetFrameIDs: Set<ManagedWindowID> = []
    private var setFrameContinuations: [ManagedWindowID: CheckedContinuation<Void, Never>] = [:]
    private var idsByBinding: [WindowRuntimeBinding: ManagedWindowID] = [:]

    init(initialSnapshots: [ManagedWindowID: WindowCommandSnapshot]) {
        states = initialSnapshots
    }

    func clearEvents() {
        events.removeAll()
    }

    func setFrameEventCount(for windowID: ManagedWindowID) -> Int {
        events.reduce(into: 0) { count, event in
            if case .setFrame(windowID, _) = event { count += 1 }
        }
    }

    func suspendRaise(_ windowID: ManagedWindowID) {
        suspendedRaiseIDs.insert(windowID)
    }

    func resumeRaise(_ windowID: ManagedWindowID) {
        suspendedRaiseIDs.remove(windowID)
        raiseContinuations.removeValue(forKey: windowID)?.resume()
    }

    func suspendSnapshot(_ windowID: ManagedWindowID) {
        suspendedSnapshotIDs.insert(windowID)
    }

    func resumeSnapshot(_ windowID: ManagedWindowID) {
        snapshotContinuations.removeValue(forKey: windowID)?.resume()
    }

    func suspendSetFrame(_ windowID: ManagedWindowID) {
        suspendedSetFrameIDs.insert(windowID)
    }

    func resumeSetFrame(_ windowID: ManagedWindowID) {
        setFrameContinuations.removeValue(forKey: windowID)?.resume()
    }

    func frame(for windowID: ManagedWindowID) -> CanvasRect? {
        states[windowID]?.frame
    }

    /// Registers a window's live snapshot so `snapshot(_:)` can read it back.
    /// Mirrors what the real AX command service sees for a newly created
    /// window; the fake must be told explicitly.
    func register(
        _ windowID: ManagedWindowID,
        binding: WindowRuntimeBinding? = nil,
        frame: CanvasRect,
        isMinimized: Bool = false,
        isFocused: Bool = false
    ) {
        if let binding { idsByBinding[binding] = windowID }
        states[windowID] = WindowCommandSnapshot(frame: frame, isMinimized: isMinimized, isFocused: isFocused)
    }

    func setFrame(
        _ frame: CanvasRect,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        guard !unavailableBindings.contains(binding) else { return .vanished }
        guard let id = id(for: binding) else { return .vanished }
        events.append(.setFrame(id, frame))
        var results = setFrameResults[id] ?? []
        let result = results.isEmpty ? .applied : results.removeFirst()
        setFrameResults[id] = results
        if result == .applied {
            let previous = states[id]
            states[id] = WindowCommandSnapshot(frame: frame, isMinimized: previous?.isMinimized ?? false)
        }
        if suspendedSetFrameIDs.remove(id) != nil {
            await withCheckedContinuation { setFrameContinuations[id] = $0 }
        }
        return result
    }

    func raiseAndFocus(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        guard !unavailableBindings.contains(binding) else { return .vanished }
        guard let id = id(for: binding) else { return .vanished }
        events.append(.raiseAndFocus(id))
        if suspendedRaiseIDs.contains(id) {
            await withCheckedContinuation { raiseContinuations[id] = $0 }
        }
        guard raiseAndFocusResult == .applied else { return raiseAndFocusResult }
        onRaiseAndFocus?(id)
        if let previous = states[id] {
            states[id] = WindowCommandSnapshot(frame: previous.frame, isMinimized: previous.isMinimized, isFocused: true)
        }
        return .applied
    }

    func raiseAndFocusOutcome(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval,
        whileCurrent: @escaping @MainActor () -> Bool
    ) async -> WindowFocusCommandOutcome {
        guard whileCurrent() else { return .cancelled }
        let result = await raiseAndFocus(binding, timeout: timeout)
        guard whileCurrent() else { return .cancelled }
        return detailedFocusOutcome ?? (result == .applied ? .applied : .raise(result))
    }

    func setMinimized(
        _ minimized: Bool,
        for binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        guard !unavailableBindings.contains(binding) else { return .vanished }
        guard let id = id(for: binding) else { return .vanished }
        events.append(.setMinimized(id, minimized))
        if let previous = states[id] {
            states[id] = WindowCommandSnapshot(frame: previous.frame, isMinimized: minimized, isFocused: previous.isFocused)
        }
        return .applied
    }

    func close(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandResult {
        guard !unavailableBindings.contains(binding) else { return .vanished }
        guard let id = id(for: binding) else { return .vanished }
        events.append(.close(id))
        states.removeValue(forKey: id)
        return .applied
    }

    func snapshot(
        _ binding: WindowRuntimeBinding,
        timeout: TimeInterval
    ) async -> WindowCommandSnapshot? {
        guard !unavailableBindings.contains(binding) else { return nil }
        guard let id = id(for: binding) else { return nil }
        events.append(.snapshot(id))
        if suspendedSnapshotIDs.remove(id) != nil {
            await withCheckedContinuation { snapshotContinuations[id] = $0 }
        }
        guard !snapshotUnavailableIDs.contains(id) else { return nil }
        let result = states[id]
        onSnapshot?(id)
        return result
    }

    private func id(for binding: WindowRuntimeBinding) -> ManagedWindowID? {
        if let id = idsByBinding[binding] { return id }
        if case let .injected(id) = binding.axElement { return id }
        if case let .windowServer(id) = binding.axElement { return "native-window-\(id)" }
        return nil
    }
}

/// In-memory `WindowObservationService` that lets tests emit events
/// deterministically. `initialSnapshot()` returns the seeded windows so
/// `FocusScreenController.start()` can bootstrap Screen 1; `start(_:)`
/// captures the handler so tests can drive `emit(_:)`.
@MainActor
private final class RecordingWindowObservationService: WindowObservationService {
    private var snapshot: WindowObservationSnapshot
    private var queuedSnapshots: [WindowObservationSnapshot] = []
    private var handler: (@MainActor (ObservedWindowEvent) -> Void)?
    private var continuationQueue: [(@MainActor () async -> Void)] = []
    private(set) var didStop = false
    private(set) var snapshotCallCount = 0
    private var snapshotExpectation: XCTestExpectation?
    private var shouldSuspendNextSnapshot = false
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    var startError: Error?
    /// Invoked synchronously from `stop()` so tests can snapshot cross-service
    /// state (e.g. command-service event count) at the exact moment observers
    /// are torn down, proving ordering.
    var onStop: (@MainActor () -> Void)?

    init(initial: [ObservedWindow]) {
        snapshot = WindowObservationSnapshot(windows: initial, completeness: .complete)
    }

    func initialSnapshot() async throws -> [ObservedWindow] { snapshot.windows }

    func refreshSnapshot() async throws -> WindowObservationSnapshot {
        snapshotCallCount += 1
        snapshotExpectation?.fulfill()
        snapshotExpectation = nil
        if shouldSuspendNextSnapshot {
            shouldSuspendNextSnapshot = false
            await withCheckedContinuation { snapshotContinuation = $0 }
        }
        if !queuedSnapshots.isEmpty {
            return queuedSnapshots.removeFirst()
        }
        return snapshot
    }

    func suspendNextSnapshot() {
        shouldSuspendNextSnapshot = true
    }

    func resumeSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func setSnapshot(
        _ windows: [ObservedWindow],
        completeness: WindowObservationSnapshotCompleteness = .complete
    ) {
        snapshot = WindowObservationSnapshot(windows: windows, completeness: completeness)
    }

    func queueSnapshots(_ snapshots: [WindowObservationSnapshot]) {
        queuedSnapshots.append(contentsOf: snapshots)
    }

    func expectSnapshotRefresh() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "window inventory refreshed")
        snapshotExpectation = expectation
        return expectation
    }

    func start(_ handler: @escaping @MainActor (ObservedWindowEvent) -> Void) throws {
        if let startError { throw startError }
        self.handler = handler
    }

    func stop() {
        onStop?()
        handler = nil
        didStop = true
    }

    func emit(_ event: ObservedWindowEvent) {
        guard let handler else { return }
        continuationQueue.append { handler(event) }
    }

    func emitImmediately(_ event: ObservedWindowEvent) {
        handler?(event)
    }

    /// Awaits every queued event. The controller's own state mutation happens
    /// synchronously inside the handler on the main actor, so a single hop is
    /// enough to observe the post-event state.
    func drain() async {
        let pending = continuationQueue
        continuationQueue.removeAll()
        for work in pending { await work() }
    }
}

/// Stand-in for the HUD controller that records lifecycle calls without
/// touching AppKit panels or event monitors.
@MainActor
private final class RecordingFocusHUDController: FocusHUDControlling {
    var attached = false
    var presented = false
    var closed = false
    var lastRefreshedState: FocusScreenState?
    var windowDiscoveryStatus: FocusHUDWindowDiscoveryStatus = .loading
    private var intentHandler: (@MainActor (FocusHUDOverviewIntent) -> Void)?
    private(set) var presentedInventoryRevision: UInt64?
    private(set) var presentedSafeBounds: CanvasRect?
    var presentationResult: Result<Void, FocusHUDControllerPresentationError> = .success(())
    private(set) var presentCallCount = 0
    private(set) var advanceFocusCount = 0

    func attach() { attached = true }
    func refresh(state: FocusScreenState) { lastRefreshedState = state }
    func present(
        inventoryRevision: UInt64,
        safeBounds: CanvasRect
    ) -> Result<Void, FocusHUDControllerPresentationError> {
        presentCallCount += 1
        presentedInventoryRevision = inventoryRevision
        presentedSafeBounds = safeBounds
        if case .success = presentationResult {
            presented = true
        }
        return presentationResult
    }
    func close() {
        closed = true
        presented = false
    }
    func setIntentHandler(_ handler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void) { intentHandler = handler }
    func setWindowDiscoveryStatus(_ status: FocusHUDWindowDiscoveryStatus) { windowDiscoveryStatus = status }
    func rebuildSnapshotIfNeeded(inventoryRevision: UInt64, safeBounds: CanvasRect) {}
    func setDismissesOnModifierRelease(_ value: Bool) {}
    func advanceFocusToNext() { advanceFocusCount += 1 }
    func activateFocusedApp() {}
    func focusWindow(_ windowID: ManagedWindowID) {}
    var focusedWindowID: ManagedWindowID? { nil }
    func send(_ intent: FocusHUDOverviewIntent) { intentHandler?(intent) }
    func sendOutsideClick() { intentHandler?(.cancel) }
}
