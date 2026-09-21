import AppKit
import KeyboardShortcuts
import os
import SwiftUI
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class FullscreenWorkspaceControllerTests: XCTestCase {
    func testAppKitWorkspaceWindowCompletesFirstFrameObservationOnWindowUpdate() {
        let window = AppKitWorkspaceWindow(configuration: WorkspaceWindowConfiguration(
            displayID: "display-main",
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            role: .interactive,
            rootView: AnyView(EmptyView())
        ))
        defer { window.close() }
        var completionCount = 0
        let observation = window.observeFirstExposure {
            completionCount += 1
        }

        NotificationCenter.default.post(
            name: NSWindow.didUpdateNotification,
            object: window.panel
        )

        XCTAssertNotNil(observation)
        XCTAssertEqual(completionCount, 1)
    }

    func testAppKitWorkspaceWindowExposesStableInteractiveWindowAccessibilityIdentityOnly() throws {
        let interactive = AppKitWorkspaceWindow(configuration: WorkspaceWindowConfiguration(
            displayID: "display-main",
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            role: .interactive,
            rootView: AnyView(EmptyView())
        ))
        let dimming = AppKitWorkspaceWindow(configuration: WorkspaceWindowConfiguration(
            displayID: "display-secondary",
            frame: CGRect(x: 640, y: 0, width: 640, height: 480),
            role: .dimming,
            rootView: nil
        ))
        defer {
            interactive.close()
            dimming.close()
        }

        XCTAssertEqual(interactive.panel.accessibilityRole()?.rawValue, "AXWindow")
        XCTAssertEqual(
            interactive.panel.accessibilityIdentifier(),
            "screen-switcher.workspace.window"
        )
        XCTAssertEqual(interactive.panel.accessibilityLabel(), "Screen Switcher Workspace")
        XCTAssertNotEqual(
            dimming.panel.accessibilityIdentifier(),
            "screen-switcher.workspace.window"
        )
    }

    func testDeferredPrewarmDoesNotRunAfterApplicationWillTerminate() {
        let panel = FixturePrewarmingPanelPresenter()
        var deferredActions: [@MainActor () -> Void] = []
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: FixturePrewarmSettingsPresenter(),
            applicationTerminator: FixturePrewarmApplicationTerminator(),
            deferredMainActionScheduler: { deferredActions.append($0) }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertEqual(deferredActions.count, 1)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        deferredActions.removeFirst()()

        XCTAssertEqual(panel.prewarmCount, 0)
        XCTAssertEqual(panel.closeCount, 1)
    }

    func testPrewarmBuildsAndClosesHiddenWorkspaceWithoutActivationOrInputMonitoring() {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let activator = FixtureWorkspaceApplicationActivator()
        let sessions = SequenceWorkspacePanelSessionManager(
            snapshots: [fixtureWorkspaceSnapshot(appCount: 3)]
        )
        let inputSource = CountingWorkspaceInputSource()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: activator,
            sessionManager: sessions,
            inputMonitor: WorkspaceInputMonitor(source: inputSource)
        )

        controller.prewarmSwitcher()

        XCTAssertNil(controller.visibleTab)
        XCTAssertEqual(activator.activationCount, 0)
        XCTAssertEqual(inputSource.startCount, 0)
        XCTAssertEqual(sessions.beginCount, 1)
        XCTAssertEqual(sessions.endCount, 1)
        XCTAssertEqual(windows.created.count, 1)
        XCTAssertEqual(windows.created[0].showAsKeyValues, [])
        XCTAssertEqual(windows.created[0].closeCount, 1)
        XCTAssertNil(controller.activeInteractionModel)
    }

    func testPrewarmNeverStartsGlobalShortcutExposureTrace() {
        let trace = FixtureProductWorkspacePerformanceTrace()
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            performanceTrace: trace
        )

        controller.prewarmSwitcher()

        XCTAssertTrue(trace.starts.isEmpty)
    }

    func testPrewarmDoesNotResolveIcons() {
        let icons = CountingWorkspaceAppIconProvider(
            availableBundleIdentifiers: ["app-app-0"]
        )
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: SequenceWorkspacePanelSessionManager(
                snapshots: [fixtureWorkspaceSnapshot(appCount: 2)]
            ),
            iconProvider: icons
        )

        controller.prewarmSwitcher()

        XCTAssertEqual(icons.counts, [:])
    }

    func testFirstOpenAfterPrewarmResolvesEachIconOnce() {
        let icons = CountingWorkspaceAppIconProvider(
            availableBundleIdentifiers: ["app-app-0"]
        )
        let snapshot = fixtureWorkspaceSnapshot(appCount: 2)
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            sessionManager: SequenceWorkspacePanelSessionManager(
                snapshots: [snapshot, snapshot]
            ),
            iconProvider: icons
        )

        controller.prewarmSwitcher()
        controller.toggle(tab: .switch)

        XCTAssertEqual(icons.counts, ["app-app-0": 1, "app-app-1": 1])
    }

    func testStatusMenuSchedulesRealFullscreenPanelAfterCancellingMenuTracking() async throws {
        let application = NSApplication.shared
        var cancelledMenuCount = 0
        var deferredActions: [@MainActor () -> Void] = []
        let topology = FixtureScreenTopologyProvider(topology: WorkspaceScreenTopology(
            screens: [
                WorkspaceScreen(
                    id: "display-main",
                    frame: CGRect(x: 0, y: 0, width: 640, height: 480)
                )
            ],
            pointerScreenID: "display-main"
        ))
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: AppKitWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: SequenceWorkspacePanelSessionManager(
                snapshots: [fixtureWorkspaceSnapshot(appCount: 1)]
            )
        )
        let delegate = AppDelegate(
            panelPresenter: controller,
            settingsPresenter: MenuLifecycleSettingsPresenter(),
            applicationTerminator: MenuLifecycleApplicationTerminator(),
            deferredMainActionScheduler: { deferredActions.append($0) },
            menuTrackingCanceller: { _ in cancelledMenuCount += 1 }
        )
        defer { controller.close(reason: .programmatic) }

        delegate.menu.delegate?.menuWillOpen?(delegate.menu)
        let openItem = try XCTUnwrap(delegate.menuItems.first {
            $0.identifier?.rawValue == AppDelegate.MenuAction.openSwitcher.rawValue
        })
        let action = try XCTUnwrap(openItem.action)
        XCTAssertTrue(application.sendAction(action, to: openItem.target, from: openItem))

        XCTAssertNil(
            controller.visibleTab,
            "The fullscreen workspace must not open inside the status menu tracking loop"
        )
        XCTAssertEqual(cancelledMenuCount, 1)
        XCTAssertEqual(deferredActions.count, 1)

        delegate.menu.delegate?.menuDidClose?(delegate.menu)
        XCTAssertEqual(deferredActions.count, 1, "menuDidClose must not schedule a duplicate open")
        deferredActions.removeFirst()()
        await drainMainQueue()

        XCTAssertEqual(controller.visibleTab, .switch)
        let visiblePanel = try XCTUnwrap(application.windows.compactMap { $0 as? WorkspacePanel }.first(where: \.isVisible))
        XCTAssertEqual(visiblePanel.level, .floating)
    }

    func testDefaultBootstrapRetainsHeadlessSemanticAssemblyWithoutProcessOrGUIEffects() throws {
        let fullscreen = FixtureFullscreenPresenter()
        let shortcutStorage = FixtureBootstrapShortcutStorage()
        weak var retainedSemanticModel: SwitcherSemanticModel?
        var builtRuntime: FullscreenHeadlessSemanticRuntime?
        var builtServer: FixtureBootstrapSemanticServer?
        var builderInvocationCount = 0
        let environment: [String: String] = [
            RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: RuntimeAdapterStartupPolicy.enabledValue,
            "SCREEN_SWITCHER_RUNTIME_TOKEN": "explicit-bootstrap-token"
        ]
        let defaultsName = "fullscreen-bootstrap-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsName)!
        defer { userDefaults.removePersistentDomain(forName: defaultsName) }
        let bootstrap = DefaultAppDelegateBootstrap.make(
            environment: environment,
            bundleURL: URL(fileURLWithPath: "/Applications-under-test/ScreenSwitcher"),
            workspaceFactory: { fullscreen },
            semanticModelFactory: { captureDirectory in
                XCTAssertNil(captureDirectory)
                let model = SwitcherSemanticModel()
                retainedSemanticModel = model
                return model
            },
            semanticServerBuilder: { runtime, token, policy, metadataURL in
                builderInvocationCount += 1
                XCTAssertEqual(token, "explicit-bootstrap-token")
                XCTAssertEqual(policy.mode, .dryRun)
                XCTAssertNil(metadataURL)
                builtRuntime = runtime
                let server = FixtureBootstrapSemanticServer(runtime: runtime)
                builtServer = server
                return server
            },
            shortcutStorage: shortcutStorage,
            userDefaults: userDefaults
        )

        XCTAssertTrue(bootstrap.runtimeAdapterStartupPolicy.isEnabled)
        XCTAssertTrue(bootstrap.panelPresenter === fullscreen)
        XCTAssertNotNil(retainedSemanticModel, "The adapter factory must strongly retain its semantic assembly")
        XCTAssertEqual(builderInvocationCount, 0)

        let server = try XCTUnwrap(bootstrap.semanticAdapterServerFactory())
        let expectedServer = try XCTUnwrap(builtServer)
        XCTAssertTrue(server === expectedServer)
        XCTAssertEqual(builderInvocationCount, 1)
        let runtime = try XCTUnwrap(builtRuntime)

        runtime.openPanel()

        XCTAssertEqual(fullscreen.visibleTab, .switch)
        XCTAssertTrue(runtime.state().isPanelOpen)
        server.stop()
    }

    func testOpeningCreatesOneInteractivePointerWindowAndDimsEveryOtherScreenAtExactFrames() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider()
        )

        controller.toggle(tab: .switch)

        XCTAssertEqual(controller.visibleTab, .switch)
        XCTAssertEqual(windows.created.count, 3)
        let interactive = try XCTUnwrap(windows.created.first { $0.role == .interactive })
        XCTAssertEqual(interactive.displayID, "display-pointer")
        XCTAssertEqual(interactive.frames, [CGRect(x: 0, y: 0, width: 1512, height: 982)])
        XCTAssertEqual(interactive.showAsKeyValues, [true])
        XCTAssertEqual(interactive.rootViewInstallCount, 1)

        let dimming = windows.created.filter { $0.role == .dimming }
        XCTAssertEqual(Set(dimming.map(\.displayID)), ["display-left", "display-right"])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: dimming.map { ($0.displayID, $0.frames) }),
            [
                "display-left": [CGRect(x: -1280, y: 0, width: 1280, height: 800)],
                "display-right": [CGRect(x: 1512, y: 0, width: 1920, height: 1080)]
            ]
        )
        XCTAssertTrue(dimming.allSatisfy { $0.showAsKeyValues == [false] })
        XCTAssertTrue(dimming.allSatisfy { $0.rootViewInstallCount == 0 })
    }

    func testOpeningActivatesApplicationBeforeCreatingWorkspaceWindows() {
        var events: [String] = []
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory {
            events.append("create-window")
        }
        let applicationActivator = FixtureWorkspaceApplicationActivator {
            events.append("activate")
        }
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: applicationActivator
        )

        controller.toggle(tab: .switch)

        XCTAssertEqual(events.first, "activate")
        XCTAssertEqual(applicationActivator.activationCount, 1)
    }

    func testInteractiveFullscreenWindowStartsEvidenceProducerButDimmingWindowsDoNot() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let evidenceCapture = FixtureProductWorkspaceEvidenceCapture()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            evidenceCapture: evidenceCapture
        )

        controller.toggle(tab: .switch)

        XCTAssertEqual(evidenceCapture.startedWindows.count, 1)
        XCTAssertEqual(evidenceCapture.startedWindows.first?.role, .interactive)
        XCTAssertEqual(evidenceCapture.startedWindows.first?.displayID, "display-pointer")
        XCTAssertFalse(evidenceCapture.startedWindows.contains { $0.role == .dimming })
    }

    func testOpeningRecordsEveryShownDimmingWindowAfterWindowReconciliation() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let dimmingEvidence = FixtureProductWorkspaceDimmingPresentationRecorder()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            dimmingPresentationEvidence: dimmingEvidence
        )

        controller.toggle(tab: .switch)

        XCTAssertEqual(dimmingEvidence.records.count, 1)
        let record = try XCTUnwrap(dimmingEvidence.records.first)
        XCTAssertEqual(record.map(\.displayID), ["display-left", "display-right"])
        XCTAssertEqual(record.map(\.expectedFrame), [
            CGRect(x: -1280, y: 0, width: 1280, height: 800),
            CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        ])
        XCTAssertTrue(record.allSatisfy { context in
            context.window.role == .dimming
                && (context.window as? FixtureWorkspaceWindow)?.showAsKeyValues == [false]
        })
    }

    func testCloseCancelsFullscreenCaptureAndReopenReplacesItWithANewToken() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let evidenceCapture = FixtureProductWorkspaceEvidenceCapture()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            evidenceCapture: evidenceCapture
        )

        controller.toggle(tab: .switch)
        let first = try XCTUnwrap(evidenceCapture.tokens.first)

        controller.close(reason: .programmatic)

        XCTAssertEqual(first.cancelCount, 1)
        controller.toggle(tab: .switch)
        let second = try XCTUnwrap(evidenceCapture.tokens.last)
        XCTAssertFalse(first === second)
        XCTAssertEqual(evidenceCapture.startedWindows.count, 2)
        XCTAssertEqual(second.cancelCount, 0)
    }

    func testPresentationTransitionsRearmCaptureForTheCurrentInteractiveSession() throws {
        let windows = FixtureWorkspaceWindowFactory()
        let evidenceCapture = FixtureProductWorkspaceEvidenceCapture()
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            sessionManager: SequenceWorkspacePanelSessionManager(
                snapshots: [fixtureWorkspaceSnapshot(appCount: 1)]
            ),
            evidenceCapture: evidenceCapture
        )

        controller.toggle(tab: .switch)
        let interactive = try XCTUnwrap(windows.created.first { $0.role == .interactive })
        let initialToken = try XCTUnwrap(evidenceCapture.tokens.first)

        XCTAssertTrue(controller.sendInteraction(.selectTab(.agents)))
        XCTAssertTrue(controller.sendInteraction(.selectTab(.switch)))
        XCTAssertTrue(controller.sendInteraction(.selectDisplay("display-b")))

        XCTAssertEqual(evidenceCapture.startedWindows.count, 4)
        XCTAssertTrue(evidenceCapture.startedWindows.allSatisfy { ($0 as AnyObject) === interactive })
        XCTAssertEqual(initialToken.cancelCount, 1)
        XCTAssertEqual(evidenceCapture.tokens.dropLast().map(\.cancelCount), [1, 1, 1])
        XCTAssertEqual(evidenceCapture.tokens.last?.cancelCount, 0)
    }

    func testPausedGestureDoesNotRearmCaptureUntilTheGestureTerminates() {
        let evidenceCapture = FixtureProductWorkspaceEvidenceCapture()
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            sessionManager: SequenceWorkspacePanelSessionManager(
                snapshots: [fixtureWorkspaceSnapshot(appCount: 27)]
            ),
            evidenceCapture: evidenceCapture
        )
        let gesture = WorkspaceGestureSessionID(rawValue: 42)

        controller.toggle(tab: .switch)
        XCTAssertEqual(evidenceCapture.startedWindows.count, 1)

        XCTAssertTrue(controller.sendInteraction(.gesture(.began(
            sessionID: gesture, dx: -12, dy: 0, velocityX: 0, velocityY: 0
        ))))
        XCTAssertTrue(controller.sendInteraction(.gesture(.changed(
            sessionID: gesture, dx: -36, dy: 0, velocityX: 0, velocityY: 0
        ))))
        XCTAssertEqual(
            evidenceCapture.tokens.first?.cancelCount,
            1,
            "Beginning a live gesture must invalidate the already scheduled capture"
        )
        XCTAssertEqual(
            evidenceCapture.startedWindows.count,
            1,
            "A paused live gesture must not schedule an unsettled product capture"
        )

        XCTAssertTrue(controller.sendInteraction(.gesture(.ended(sessionID: gesture))))
        XCTAssertEqual(evidenceCapture.startedWindows.count, 2)
        XCTAssertEqual(evidenceCapture.tokens.first?.cancelCount, 1)
        XCTAssertEqual(evidenceCapture.tokens.last?.cancelCount, 0)
    }

    func testSameTabToggleClosesWhileDifferentTabChangesTheVisibleTabWithoutClosing() {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let controller = makeController(topology: topology, windows: windows)

        controller.toggle(tab: .switch)
        controller.toggle(tab: .agents)

        XCTAssertEqual(controller.visibleTab, .agents)
        XCTAssertTrue(windows.created.allSatisfy { !$0.isClosed })
        XCTAssertEqual(windows.created.first(where: { $0.role == .interactive })?.rootViewInstallCount, 1)

        controller.toggle(tab: .agents)

        XCTAssertNil(controller.visibleTab)
        XCTAssertTrue(windows.created.allSatisfy(\.isClosed))
    }

    func testGlobalShortcutTraceStartsOnlyForClosedWorkspaceAndCloseClearsStaleStart() throws {
        let trace = FixtureProductWorkspacePerformanceTrace()
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            performanceTrace: trace
        )

        controller.toggle(tab: .switch, globalShortcutStartedAtNanoseconds: 10)
        XCTAssertEqual(trace.starts.map(\.startNanoseconds), [10])
        XCTAssertEqual(trace.starts.map(\.role), [.interactive])
        XCTAssertEqual(trace.starts.map(\.wasShown), [false])

        controller.toggle(tab: .agents, globalShortcutStartedAtNanoseconds: 20)
        controller.toggle(tab: .agents, globalShortcutStartedAtNanoseconds: 30)
        XCTAssertEqual(trace.starts.map(\.startNanoseconds), [10])
        XCTAssertEqual(try XCTUnwrap(trace.tokens.first).cancelCount, 1)

        controller.toggle(tab: .switch, globalShortcutStartedAtNanoseconds: 40)
        XCTAssertEqual(trace.starts.map(\.startNanoseconds), [10, 40])
    }

    func testFirstOpenSessionConvergesToAXDisplayAssociationAfterColdCacheRefresh() async throws {
        let displays = [
            DisplaySource(
                id: "display-pointer",
                frame: try RectDescriptor(x: 0, y: 0, width: 1_512, height: 982)
            ),
            DisplaySource(
                id: "display-right",
                frame: try RectDescriptor(x: 1_512, y: 0, width: 1_920, height: 1_080)
            )
        ]
        let pointer = FirstOpenPointerProvider(location: PointSnapshot(x: 100, y: 100))
        let permissionService = PermissionService(
            accessibilityChecker: FixtureGrantedAccessibilityChecker(),
        )
        let refreshScheduler = FirstOpenQueuedRefreshScheduler()
        let windowReader = AppKitWindowMetadataReader(
            permissionService: permissionService,
            processIdentifierProvider: FirstOpenProcessProvider(),
            candidateReader: FirstOpenAXCandidateReader(candidate: AXWindowMetadataCandidate(
                id: "right-window",
                axFrame: try RectDescriptor(x: 1_600, y: 100, width: 200, height: 200),
                isFocused: true,
                isMain: true,
                isMinimized: false
            )),
            appKitMainDisplayMaxY: 982,
            refreshScheduler: refreshScheduler
        )
        let catalog = RunningAppCatalog(
            discovery: FirstOpenRunningAppDiscovery(),
            windowReader: windowReader,
            activationObserver: FixtureHeadlessActivationObserver(),
            permissionService: permissionService,
            iconProvider: FixtureUnavailableAppIconProvider()
        )
        let runtimeState = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: FirstOpenDisplayDiscovery(displays: displays),
                pointerLocation: pointer
            ),
            runningAppCatalog: catalog,
            pointerLocation: pointer,
            frontmostState: FixtureHeadlessFrontmostState()
        )
        let topology = FixtureScreenTopologyProvider(topology: WorkspaceScreenTopology(
            screens: displays.map {
                WorkspaceScreen(
                    id: $0.id,
                    frame: CGRect(
                        x: $0.frame.x,
                        y: $0.frame.y,
                        width: $0.frame.width,
                        height: $0.frame.height
                    )
                )
            },
            pointerScreenID: "display-pointer"
        ))
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: runtimeState,
            iconProvider: catalog.iconProvider
        )

        controller.openSwitcher()

        let coldSnapshot = try XCTUnwrap(controller.frozenSessionSnapshot)
        XCTAssertEqual(coldSnapshot.workspaces[0].apps.map(\.id), ["com.example.editor"])
        XCTAssertTrue(coldSnapshot.workspaces[1].apps.isEmpty)
        XCTAssertEqual(refreshScheduler.pendingCount, 1)

        refreshScheduler.runAll()
        await settleControllerTasks()

        let refreshedSnapshot = try XCTUnwrap(controller.frozenSessionSnapshot)
        XCTAssertTrue(refreshedSnapshot.workspaces[0].apps.isEmpty)
        XCTAssertEqual(refreshedSnapshot.workspaces[1].apps.map(\.id), ["com.example.editor"])
        XCTAssertTrue(
            try XCTUnwrap(controller.activeInteractionModel)
                .selectedContent().selectedWorkspace.apps.isEmpty
        )
    }

    func testAXContentRefreshDoesNotOrphanPendingExecutionCompletion() throws {
        let sessions = RefreshingWorkspacePanelSessionManager(
            initialSnapshot: fixtureWorkspaceSnapshot(appCount: 1)
        )
        var requests: [WorkspaceExecutionRequest] = []
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: sessions,
            executionRequestHandler: { requests.append($0) }
        )

        controller.openSwitcher()
        XCTAssertTrue(controller.sendInteraction(.activateApp("app-app-0")))
        let request = try XCTUnwrap(requests.first)

        sessions.publish(fixtureWorkspaceSnapshot(appCount: 0))

        XCTAssertFalse(
            controller.sendInteraction(.activateDisplay),
            "A passive refresh must preserve the in-flight admission and reject concurrent execution"
        )

        XCTAssertTrue(
            controller.completeExecution(.init(
                id: request.id,
                target: request.target,
                outcome: .success
            )),
            "A passive AX content refresh must not clear the in-flight request"
        )
        XCTAssertNil(controller.visibleTab, "The matching success must retain its close semantics")
    }

    func testAXContentRefreshPreservesPendingExecutionFailurePresentation() throws {
        let sessions = RefreshingWorkspacePanelSessionManager(
            initialSnapshot: fixtureWorkspaceSnapshot(appCount: 1)
        )
        var requests: [WorkspaceExecutionRequest] = []
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: sessions,
            executionRequestHandler: { requests.append($0) }
        )

        controller.openSwitcher()
        XCTAssertTrue(controller.sendInteraction(.activateApp("app-app-0")))
        let request = try XCTUnwrap(requests.first)
        sessions.publish(fixtureWorkspaceSnapshot(appCount: 0))

        XCTAssertTrue(controller.completeExecution(.init(
            id: request.id,
            target: request.target,
            outcome: .failure(.appActivationFailed)
        )))
        XCTAssertEqual(
            controller.interactionPresentation?.executionFailure,
            .appActivationFailed,
            "A matching failure must remain visible after passive content refresh"
        )
        XCTAssertEqual(controller.visibleTab, .switch)
    }

    func testColdCacheRefreshKeepsFallbackAppsOnOpeningPointerDisplayAfterPointerMoves() async throws {
        let displays = [
            DisplaySource(
                id: "display-a",
                frame: try RectDescriptor(x: 0, y: 0, width: 1_512, height: 982)
            ),
            DisplaySource(
                id: "display-b",
                frame: try RectDescriptor(x: 1_512, y: 0, width: 1_512, height: 982)
            )
        ]
        let pointer = MutableFirstOpenPointerProvider(location: PointSnapshot(x: 100, y: 100))
        let permissionService = PermissionService(
            accessibilityChecker: FixtureGrantedAccessibilityChecker(),
        )
        let refreshScheduler = FirstOpenQueuedRefreshScheduler()
        let windowReader = AppKitWindowMetadataReader(
            permissionService: permissionService,
            processIdentifierProvider: FirstOpenProcessProvider(),
            candidateReader: FirstOpenEmptyAXCandidateReader(),
            appKitMainDisplayMaxY: 982,
            refreshScheduler: refreshScheduler
        )
        let catalog = RunningAppCatalog(
            discovery: FirstOpenRunningAppDiscovery(),
            windowReader: windowReader,
            activationObserver: FixtureHeadlessActivationObserver(),
            permissionService: permissionService,
            iconProvider: FixtureUnavailableAppIconProvider()
        )
        let runtimeState = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: FirstOpenDisplayDiscovery(displays: displays),
                pointerLocation: pointer
            ),
            runningAppCatalog: catalog,
            pointerLocation: pointer,
            frontmostState: FixtureHeadlessFrontmostState()
        )

        let coldSnapshot = runtimeState.beginPanelSession()
        XCTAssertEqual(coldSnapshot.workspaces[0].apps.map(\.id), ["com.example.editor"])
        XCTAssertTrue(coldSnapshot.workspaces[1].apps.isEmpty)
        XCTAssertEqual(refreshScheduler.pendingCount, 1)

        pointer.location = PointSnapshot(x: 1_600, y: 100)
        refreshScheduler.runAll()
        await settleControllerTasks()

        let refreshedSnapshot = runtimeState.snapshot()
        XCTAssertEqual(
            refreshedSnapshot.workspaces[0].apps.map(\.id),
            ["com.example.editor"],
            "Fallback placement belongs to the pointer context captured when this panel session opened"
        )
        XCTAssertTrue(refreshedSnapshot.workspaces[1].apps.isEmpty)
    }

    func testEscapeClosesTheWholeSession() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let controller = makeController(topology: topology, windows: windows)
        controller.toggle(tab: .switch)

        try XCTUnwrap(windows.created.first { $0.role == .interactive }).sendEscape()

        XCTAssertNil(controller.visibleTab)
        XCTAssertTrue(windows.created.allSatisfy(\.isClosed))
        XCTAssertEqual(topology.observations.last?.cancelCount, 1)
    }

    func testDisplayRemovalClosesStaleWindowAndReconcilesRemainingExactFrames() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let controller = makeController(topology: topology, windows: windows)
        controller.toggle(tab: .switch)
        let removedWindow = try XCTUnwrap(windows.created.first { $0.displayID == "display-left" })

        topology.topology = WorkspaceScreenTopology(
            screens: [
                WorkspaceScreen(id: "display-pointer", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
                WorkspaceScreen(id: "display-right", frame: CGRect(x: 1600, y: 0, width: 1920, height: 1080))
            ],
            pointerScreenID: "display-pointer"
        )
        topology.notifyChange()

        XCTAssertTrue(removedWindow.isClosed)
        XCTAssertEqual(windows.created.first { $0.displayID == "display-pointer" }?.frames.last,
                       CGRect(x: 0, y: 0, width: 1600, height: 1000))
        XCTAssertEqual(windows.created.first { $0.displayID == "display-right" }?.frames.last,
                       CGRect(x: 1600, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(windows.created.filter { !$0.isClosed }.count, 2)
    }

    func testDuplicateAndInvalidDisplayIDsNeverCreateDuplicateOrInvalidWindows() {
        let topology = FixtureScreenTopologyProvider(topology: WorkspaceScreenTopology(
            screens: [
                WorkspaceScreen(id: "   ", frame: CGRect(x: -100, y: 0, width: 100, height: 100)),
                WorkspaceScreen(id: "display-duplicate", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                WorkspaceScreen(id: "display-duplicate", frame: CGRect(x: 100, y: 0, width: 100, height: 100)),
                WorkspaceScreen(id: "display-valid", frame: CGRect(x: 200, y: 0, width: 100, height: 100)),
                WorkspaceScreen(id: "", frame: CGRect(x: 300, y: 0, width: 100, height: 100)),
                WorkspaceScreen(id: "display-zero", frame: CGRect(x: 400, y: 0, width: 0, height: 100))
            ],
            pointerScreenID: "display-duplicate"
        ))
        let windows = FixtureWorkspaceWindowFactory()
        let controller = makeController(topology: topology, windows: windows)

        controller.toggle(tab: .switch)

        XCTAssertEqual(windows.created.map(\.displayID), ["display-duplicate", "display-valid"])
        XCTAssertEqual(windows.created.filter { $0.role == .interactive }.map(\.displayID), ["display-duplicate"])
    }

    func testPointerScreenMigrationKeepsSessionOverlayFrozenAndLeavesExactlyOneKeyInteractiveWindow() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let controller = makeController(topology: topology, windows: windows)
        controller.toggle(tab: .switch)
        let oldInteractive = try XCTUnwrap(windows.created.first { $0.displayID == "display-pointer" })
        let oldRightDimming = try XCTUnwrap(windows.created.first { $0.displayID == "display-right" })

        topology.topology = WorkspaceScreenTopology(
            screens: makeTopology().screens,
            pointerScreenID: "display-right"
        )
        topology.notifyChange()

        XCTAssertFalse(oldInteractive.isClosed)
        XCTAssertFalse(oldRightDimming.isClosed)
        let active = windows.created.filter { !$0.isClosed }
        XCTAssertEqual(active.count, 3)
        XCTAssertEqual(Set(active.map(\.displayID)), ["display-left", "display-pointer", "display-right"])
        XCTAssertEqual(active.filter { $0.role == .interactive }.map(\.displayID), ["display-pointer"])
        XCTAssertEqual(active.filter { $0.showAsKeyValues == [true] }.map(\.displayID), ["display-pointer"])
        XCTAssertTrue(active.filter { $0.role == .dimming }.allSatisfy { $0.showAsKeyValues != [true] })
    }

    func testTopologyWithoutValidScreensClosesSessionAndCancelsObservation() {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let controller = makeController(topology: topology, windows: windows)
        controller.toggle(tab: .focus)

        topology.topology = WorkspaceScreenTopology(
            screens: [
                WorkspaceScreen(id: "", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                WorkspaceScreen(id: "   ", frame: CGRect(x: 100, y: 0, width: 100, height: 100)),
                WorkspaceScreen(id: "display-zero", frame: CGRect(x: 200, y: 0, width: 0, height: 100))
            ],
            pointerScreenID: nil
        )
        topology.notifyChange()

        XCTAssertNil(controller.visibleTab)
        XCTAssertTrue(windows.created.allSatisfy(\.isClosed))
        XCTAssertEqual(topology.observations.last?.cancelCount, 1)
    }

    func testSemanticAssemblyRetainsModelRunsHeadlessSessionAndRoutesOnlyToFullscreenPresenter() async throws {
        let fullscreen = FixtureFullscreenPresenter()
        var semanticModel: SwitcherSemanticModel? = SwitcherSemanticModel()
        let retainedSemanticModel = try XCTUnwrap(semanticModel)
        let sessionManager = CountingPanelSessionManager(
            base: retainedSemanticModel.runtimeState,
            snapshotOverride: fixtureWorkspaceSnapshot(appCount: 1, prefix: "semantic")
        )
        let headlessSession = makeHeadlessSemanticSession(
            runtimeState: retainedSemanticModel.runtimeState
        )
        weak var retainedModel = semanticModel
        let assembly = FullscreenSemanticAdapterAssembly(
            workspacePresenter: fullscreen,
            semanticModel: retainedSemanticModel,
            sessionManager: sessionManager,
            headlessSessionFactory: { _ in headlessSession }
        )
        semanticModel = nil

        XCTAssertNotNil(retainedModel)
        let runtime = assembly.makeRuntime()
        XCTAssertFalse(runtime.state().isPanelOpen)
        runtime.openPanel()

        XCTAssertEqual(fullscreen.toggledTabs, [.switch])
        XCTAssertEqual(fullscreen.visibleTab, .switch)
        XCTAssertTrue(runtime.state().isPanelOpen)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 0))
        XCTAssertTrue(runtime.select(itemID: "semantic-app-0"))
        let execution = await runtime.executeSelected()
        guard case .success = execution else {
            return XCTFail("A selected headless item must execute without panelNotOpen: \(execution)")
        }
        XCTAssertNil(fullscreen.visibleTab)
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 1))

        runtime.openPanel()
        runtime.openPanel()
        XCTAssertTrue(runtime.state().isPanelOpen)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 2, end: 1))
        runtime.closePanel()
        runtime.closePanel()
        _ = runtime.state()

        XCTAssertEqual(fullscreen.toggledTabs, [.switch, .switch])
        XCTAssertEqual(fullscreen.closeReasons, [.programmatic, .programmatic])
        XCTAssertNil(fullscreen.visibleTab)
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 2, end: 2))
    }

    func testShortcutEscapeAndTopologyCloseSynchronizeHeadlessSemanticState() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let workspaceWindows = FixtureWorkspaceWindowFactory()
        let fullscreen = makeController(topology: topology, windows: workspaceWindows)
        let semanticModel = SwitcherSemanticModel()
        let sessionManager = CountingPanelSessionManager(base: semanticModel.runtimeState)
        let headlessSession = makeHeadlessSemanticSession(
            runtimeState: semanticModel.runtimeState,
            actionService: semanticModel.actionService
        )
        let runtime = FullscreenSemanticAdapterAssembly(
            workspacePresenter: fullscreen,
            semanticModel: semanticModel,
            sessionManager: sessionManager,
            headlessSessionFactory: { _ in headlessSession }
        ).makeRuntime()

        runtime.openPanel()
        XCTAssertTrue(runtime.state().isPanelOpen)
        fullscreen.toggle(tab: .switch)
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 1))

        runtime.openPanel()
        XCTAssertTrue(runtime.state().isPanelOpen)
        try XCTUnwrap(workspaceWindows.created.last { !$0.isClosed && $0.role == .interactive }).sendEscape()
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 2, end: 2))

        runtime.openPanel()
        XCTAssertTrue(runtime.state().isPanelOpen)
        topology.topology = WorkspaceScreenTopology(screens: [], pointerScreenID: nil)
        topology.notifyChange()
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertNil(fullscreen.visibleTab)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 3, end: 3))

    }

    func testHeadlessSemanticSessionExistsOnlyOnSwitchAndRebuildsAfterAgentsAndFocus() async throws {
        let fullscreen = FixtureFullscreenPresenter()
        let appDiscovery = MutableHeadlessRunningAppDiscovery(appID: "app-a")
        let permissionService = PermissionService(
            accessibilityChecker: FixtureGrantedAccessibilityChecker(),
        )
        let runtimeState = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: FixtureHeadlessDisplayDiscovery(),
                pointerLocation: FixtureHeadlessPointer()
            ),
            runningAppCatalog: RunningAppCatalog(
                discovery: appDiscovery,
                windowReader: EmptyWindowMetadataReader(),
                activationObserver: FixtureHeadlessActivationObserver(),
                permissionService: permissionService,
                iconProvider: FixtureUnavailableAppIconProvider()
            ),
            pointerLocation: FixtureHeadlessPointer(),
            frontmostState: FixtureHeadlessFrontmostState()
        )
        let semanticModel = SwitcherSemanticModel(
            runtimeState: runtimeState,
            permissionService: permissionService
        )
        let actionService = SwitcherActionService(
            policy: ExecutionPolicy(mode: .dryRun),
            liveSnapshotProvider: runtimeState,
            permissionService: permissionService
        )
        let sessionManager = CountingPanelSessionManager(base: runtimeState)
        var factoryCount = 0
        weak var firstSession: SwitcherHeadlessSession?
        weak var secondSession: SwitcherHeadlessSession?
        let assembly = FullscreenSemanticAdapterAssembly(
            workspacePresenter: fullscreen,
            semanticModel: semanticModel,
            sessionManager: sessionManager,
            headlessSessionFactory: { _ in
                factoryCount += 1
                let session = SwitcherHeadlessSession(
                    runtimeState: runtimeState,
                    actionService: actionService
                )
                if factoryCount == 1 {
                    firstSession = session
                } else if factoryCount == 2 {
                    secondSession = session
                }
                return session
            }
        )
        let runtime = assembly.makeRuntime()

        XCTAssertEqual(factoryCount, 0, "No headless controller should exist before a fullscreen session opens")
        runtime.openPanel()
        runtime.openPanel()

        XCTAssertEqual(factoryCount, 1, "Repeated open inside one visible session must reuse its controller")
        XCTAssertEqual(runtime.snapshot().runningApps.map { $0.id }, ["app-a"])
        XCTAssertTrue(runtime.select(itemID: "app-a"))

        fullscreen.toggle(tab: .agents)

        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertFalse(runtime.select(itemID: "app-a"))
        guard case .failure(.panelNotOpen) = await runtime.executeSelected() else {
            return XCTFail("Agents must not retain an executable Switch session")
        }
        XCTAssertNil(firstSession, "Leaving Switch must discard its session")
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 1))

        appDiscovery.appID = "app-b"
        fullscreen.toggle(tab: .focus)
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 1))

        fullscreen.toggle(tab: .switch)

        XCTAssertEqual(factoryCount, 2, "Returning to Switch must build exactly one fresh controller")
        XCTAssertEqual(runtime.snapshot().runningApps.map { $0.id }, ["app-b"])
        XCTAssertTrue(runtime.select(itemID: "app-b"))
        XCTAssertFalse(runtime.select(itemID: "app-a"))
        let execution = await runtime.executeSelected()
        guard case .success = execution else {
            return XCTFail("Fresh target B must execute without panelNotOpen: \(execution)")
        }
        XCTAssertNil(secondSession, "Execution completion must close and discard the current session")
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertNil(fullscreen.visibleTab)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 2, end: 2))
    }

    func testSemanticAdapterLifecycleStopsFailedRuntimeOnceAndCanRestartWithNewServer() async {
        let fullscreen = FixtureFullscreenPresenter()
        let semanticModel = SwitcherSemanticModel()
        let sessionManager = CountingPanelSessionManager(base: semanticModel.runtimeState)
        let runtime = FullscreenSemanticAdapterAssembly(
            workspacePresenter: fullscreen,
            semanticModel: semanticModel,
            sessionManager: sessionManager,
            headlessSessionFactory: { _ in
                SwitcherHeadlessSession(
                    runtimeState: semanticModel.runtimeState,
                    actionService: semanticModel.actionService
                )
            }
        ).makeRuntime()
        runtime.openPanel()
        XCTAssertEqual(fullscreen.observerCount, 1)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 0))

        let failedServerStopped = expectation(description: "failed adapter is stopped")
        let replacementStarted = expectation(description: "replacement adapter starts")
        let failedServer = FixtureFailingRuntimeServer(
            runtime: runtime,
            onStop: { failedServerStopped.fulfill() }
        )
        let replacementServer = FixtureSuccessfulLifecycleServer(
            onStart: { replacementStarted.fulfill() }
        )
        var factoryCount = 0
        let serverFactory: SemanticAdapterServerFactory = {
            factoryCount += 1
            if factoryCount == 1 { return failedServer }
            if factoryCount == 2 { return replacementServer }
            return nil
        }
        let lifecycle = SemanticAdapterLifecycleController(
            startupPolicy: RuntimeAdapterStartupPolicy(
                environment: [RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1"],
                isPackagedProduction: false
            ),
            serverFactory: serverFactory
        )

        lifecycle.start()
        await fulfillment(of: [failedServerStopped], timeout: 1)

        XCTAssertEqual(failedServer.startCount, 1)
        XCTAssertEqual(failedServer.stopCount, 1)
        XCTAssertEqual(fullscreen.observerCount, 0)
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 1))

        lifecycle.stop()
        lifecycle.stop()
        XCTAssertEqual(failedServer.stopCount, 1)

        lifecycle.start()
        await fulfillment(of: [replacementStarted], timeout: 1)
        lifecycle.start()
        XCTAssertEqual(factoryCount, 2)
        XCTAssertEqual(replacementServer.startCount, 1)

        lifecycle.stop()
        lifecycle.stop()
        XCTAssertEqual(replacementServer.stopCount, 1)
    }

    func testSemanticAdapterLifecycleCancellationRaceDoesNotDoubleStop() async {
        let started = expectation(description: "pending adapter starts")
        let cancelled = expectation(description: "pending adapter observes cancellation")
        let server = FixturePendingLifecycleServer(
            onStart: { started.fulfill() },
            onCancellation: { cancelled.fulfill() }
        )
        let lifecycle = SemanticAdapterLifecycleController(
            startupPolicy: RuntimeAdapterStartupPolicy(
                environment: [RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1"],
                isPackagedProduction: false
            ),
            serverFactory: { server }
        )

        lifecycle.start()
        await fulfillment(of: [started], timeout: 1)
        lifecycle.stop()
        await fulfillment(of: [cancelled], timeout: 1)
        await Task.yield()

        lifecycle.stop()
        XCTAssertEqual(server.startCount, 1)
        XCTAssertEqual(server.stopCount, 1)
    }

    func testSemanticAdapterLifecycleReleaseCancelsPendingStartAndReleasesRuntimeOnce() async {
        let started = expectation(description: "pending adapter starts")
        let cancelled = expectation(description: "pending adapter observes release cancellation")
        let fullscreen = FixtureFullscreenPresenter()
        weak var weakSemanticModel: SwitcherSemanticModel?
        var assembly: FullscreenSemanticAdapterAssembly?
        do {
            let semanticModel = SwitcherSemanticModel()
            weakSemanticModel = semanticModel
            assembly = FullscreenSemanticAdapterAssembly(
                workspacePresenter: fullscreen,
                semanticModel: semanticModel
            )
        }
        weak var weakAssembly = assembly
        var runtime: FullscreenHeadlessSemanticRuntime? = assembly?.makeRuntime()
        weak var weakRuntime = runtime
        let server = FixturePendingLifecycleServer(
            runtime: runtime,
            onStart: { started.fulfill() },
            onCancellation: { cancelled.fulfill() }
        )
        runtime = nil
        assembly = nil
        XCTAssertNil(weakAssembly)
        XCTAssertNotNil(weakRuntime, "The pending server owns the semantic runtime until lifecycle cleanup")

        var lifecycle: SemanticAdapterLifecycleController? = SemanticAdapterLifecycleController(
            startupPolicy: RuntimeAdapterStartupPolicy(
                environment: [RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1"],
                isPackagedProduction: false
            ),
            serverFactory: { server }
        )
        weak var weakLifecycle = lifecycle
        lifecycle?.start()
        await fulfillment(of: [started], timeout: 1)

        lifecycle = nil

        XCTAssertNil(weakLifecycle)
        await fulfillment(of: [cancelled], timeout: 1)
        await Task.yield()
        XCTAssertEqual(server.stopCount, 1)
        XCTAssertNil(weakRuntime)
        XCTAssertNil(weakSemanticModel)

        await Task.yield()
        XCTAssertEqual(server.stopCount, 1, "Task completion must not stop the released lifecycle twice")
    }

    func testHeadlessSemanticTeardownDiscardsSessionAndObservationWithoutReopening() {
        let fullscreen = FixtureFullscreenPresenter()
        let semanticModel = SwitcherSemanticModel()
        let sessionManager = CountingPanelSessionManager(base: semanticModel.runtimeState)
        var factoryCount = 0
        weak var session: SwitcherHeadlessSession?
        let assembly = FullscreenSemanticAdapterAssembly(
            workspacePresenter: fullscreen,
            semanticModel: semanticModel,
            sessionManager: sessionManager,
            headlessSessionFactory: { _ in
                factoryCount += 1
                let created = SwitcherHeadlessSession(
                    runtimeState: semanticModel.runtimeState,
                    actionService: semanticModel.actionService
                )
                session = created
                return created
            }
        )
        var runtime: FullscreenHeadlessSemanticRuntime? = assembly.makeRuntime()
        weak var weakRuntime = runtime

        runtime?.openPanel()
        XCTAssertEqual(fullscreen.observerCount, 1)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertNotNil(session)

        runtime?.teardown()
        runtime?.teardown()

        XCTAssertEqual(fullscreen.observerCount, 0)
        XCTAssertNil(session)
        XCTAssertFalse(runtime?.state().isPanelOpen == true)
        XCTAssertEqual(factoryCount, 1, "A torn-down runtime must not recreate a semantic session")
        XCTAssertEqual(sessionManager.counts, SessionCallCounts(begin: 1, end: 1))

        runtime = nil
        XCTAssertNil(weakRuntime, "The visibility observation must not retain the runtime")
    }

    func testExplicitTeardownClosesWindowsAndCancelsTopologyObservationExactlyOnce() {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let controller = makeController(topology: topology, windows: windows)
        controller.toggle(tab: .focus)

        controller.close(reason: .applicationTermination)
        controller.close(reason: .applicationTermination)

        XCTAssertNil(controller.visibleTab)
        XCTAssertTrue(windows.created.allSatisfy(\.isClosed))
        XCTAssertTrue(windows.created.allSatisfy { $0.closeCount == 1 })
        XCTAssertEqual(topology.observations.last?.cancelCount, 1)
    }

    func testAppKitFactoryCreatesAConfiguredBorderlessPanelAndOnlyInteractiveCanBecomeKey() throws {
        let factory = AppKitWorkspaceWindowFactory()
        let interactive = try XCTUnwrap(factory.makeWindow(configuration: WorkspaceWindowConfiguration(
            displayID: "display-main",
            frame: CGRect(x: 10, y: 20, width: 400, height: 300),
            role: .interactive,
            rootView: AnyView(EmptyView())
        )) as? AppKitWorkspaceWindow)
        let dimming = try XCTUnwrap(factory.makeWindow(configuration: WorkspaceWindowConfiguration(
            displayID: "display-secondary",
            frame: CGRect(x: 410, y: 20, width: 400, height: 300),
            role: .dimming,
            rootView: nil
        )) as? AppKitWorkspaceWindow)
        defer {
            interactive.close()
            dimming.close()
        }

        XCTAssertEqual(interactive.panel.styleMask, [.borderless])
        XCTAssertEqual(interactive.panel.level, .floating)
        XCTAssertNotEqual(interactive.panel.level, .popUpMenu)
        XCTAssertTrue(interactive.panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(interactive.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(interactive.panel.canBecomeKey)
        XCTAssertFalse(interactive.panel.ignoresMouseEvents)
        XCTAssertTrue(interactive.panel.contentView is NSHostingView<AnyView>)

        XCTAssertFalse(dimming.panel.canBecomeKey)
        XCTAssertTrue(dimming.panel.ignoresMouseEvents)
        XCTAssertFalse(dimming.panel.contentView is NSHostingView<AnyView>)
        XCTAssertEqual(dimming.panel.frame, CGRect(x: 410, y: 20, width: 400, height: 300))
    }

    func testBackdropFallsBackWithoutExposingWallpaperSource() {
        let provider = WorkspaceBackdropProvider(
            accessibilityPreferences: FixtureWorkspaceAccessibilityPreferencesForFullscreenTests(
                reduceTransparencyEnabled: false
            ),
            wallpaperURL: { _ in nil },
            imageLoader: { _ in XCTFail("No image should be loaded without a wallpaper URL"); return nil },
            imageProcessor: { _ in XCTFail("No image should be processed without a wallpaper URL"); return nil }
        )

        let backdrop = provider.resolveBackdrop(for: "display-main", screen: nil) { _ in
            XCTFail("No asynchronous result is expected without a wallpaper URL")
        }
        guard case .semanticGradient = backdrop else {
            return XCTFail("Unavailable wallpaper should use the semantic gradient")
        }
        XCTAssertFalse(String(reflecting: WorkspaceBackdrop.self).contains("URL"))
        XCTAssertFalse(String(reflecting: WorkspaceBackdrop.self).contains("Data"))
    }

    func testScreenTopologyObservationRemovesNotificationObserverWhenReleasedWithoutCancel() {
        let center = NotificationCenter()
        let provider = NSScreenTopologyProvider(notificationCenter: center)
        var callbackCount = 0
        var observation: (any WorkspaceScreenTopologyObserving)? = provider.observeChanges {
            callbackCount += 1
        }

        observation = nil
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertNil(observation)
        XCTAssertEqual(callbackCount, 0)
    }

    func testAsyncBackdropCannotUpdateAClosedReplacedOrDifferentTabWindow() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let backdrops = DeferredWorkspaceBackdropProvider()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: backdrops
        )

        controller.toggle(tab: .switch)
        let firstInteractive = try XCTUnwrap(windows.created.first { $0.role == .interactive })
        XCTAssertEqual(firstInteractive.rootViewInstallCount, 1)

        controller.toggle(tab: .agents)
        XCTAssertEqual(firstInteractive.rootViewInstallCount, 1)
        backdrops.completeRequest(at: 0, with: .image(NSImage(size: NSSize(width: 2, height: 2))))
        XCTAssertEqual(firstInteractive.rootViewInstallCount, 1, "A Switch result must not update the Agents tab")

        topology.topology = WorkspaceScreenTopology(
            screens: makeTopology().screens,
            pointerScreenID: "display-right"
        )
        topology.notifyChange()
        XCTAssertFalse(firstInteractive.isClosed)
        backdrops.completeRequest(at: 1, with: .image(NSImage(size: NSSize(width: 2, height: 2))))
        XCTAssertGreaterThan(firstInteractive.rootViewInstallCount, 1, "The frozen overlay may accept current-tab work")

        let replacement = firstInteractive
        topology.notifyChange()
        let replacementInstalls = replacement.rootViewInstallCount
        let requestIndex = backdrops.requests.count - 1
        controller.close(reason: .programmatic)
        backdrops.completeRequest(at: requestIndex, with: .image(NSImage(size: NSSize(width: 2, height: 2))))
        XCTAssertEqual(
            replacement.rootViewInstallCount,
            replacementInstalls,
            "A closed session must reject stale work"
        )
    }

    func testGesturePresentationChangesDoNotReinstallRootOrRetainSessionModel() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let backdrops = DeferredWorkspaceBackdropProvider()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: backdrops,
            sessionManager: SequenceWorkspacePanelSessionManager(
                snapshots: [fixtureWorkspaceSnapshot(appCount: 27)]
            )
        )

        controller.toggle(tab: .switch)
        let interactive = try XCTUnwrap(windows.created.first { $0.role == .interactive })
        var model: WorkspaceInteractionModel? = try XCTUnwrap(controller.activeInteractionModel)
        weak var weakModel = model
        let rootInstalls = interactive.rootViewInstallCount
        let backdropRequests = backdrops.requests.count
        let topologyQueries = topology.currentTopologyCount
        let gesture = WorkspaceGestureSessionID(rawValue: 7)

        XCTAssertTrue(controller.sendInteraction(.gesture(.began(
            sessionID: gesture, dx: -12, dy: 0, velocityX: 0, velocityY: 0
        ))))
        for offset in [18.0, 24.0, 30.0, 36.0] {
            XCTAssertTrue(controller.sendInteraction(.gesture(.changed(
                sessionID: gesture, dx: -offset, dy: 0, velocityX: 0, velocityY: 0
            ))))
        }
        XCTAssertNotEqual(model?.presentation.motionOffset, 0)
        XCTAssertEqual(interactive.rootViewInstallCount, rootInstalls)
        XCTAssertEqual(backdrops.requests.count, backdropRequests)
        XCTAssertEqual(topology.currentTopologyCount, topologyQueries)

        controller.close(reason: .programmatic)
        model = nil
        XCTAssertNil(weakModel)
    }

    func testReconcileTabChangeAndReopenReuseOneBackdropProcessingPipeline() async {
        let processed = expectation(description: "backdrop processed")
        let probe = OSAllocatedUnfairLock(initialState: FullscreenBackdropProbe())
        let provider = WorkspaceBackdropProvider(
            accessibilityPreferences: FixtureWorkspaceAccessibilityPreferencesForFullscreenTests(
                reduceTransparencyEnabled: false
            ),
            wallpaperURL: { _ in URL(fileURLWithPath: "/private/shared-wallpaper") },
            imageLoader: { _ in
                probe.withLock { $0.loadCount += 1 }
                return NSImage(size: NSSize(width: 2, height: 2))
            },
            imageProcessor: { image in
                probe.withLock { $0.processCount += 1 }
                processed.fulfill()
                return image
            }
        )
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: provider
        )

        controller.toggle(tab: .switch)
        topology.notifyChange()
        controller.toggle(tab: .agents)

        await fulfillment(of: [processed], timeout: 1)
        await Task.yield()
        controller.close(reason: .programmatic)
        controller.toggle(tab: .switch)
        await Task.yield()

        XCTAssertEqual(probe.withLock { $0.loadCount }, 1)
        XCTAssertEqual(probe.withLock { $0.processCount }, 1)
    }

    func testUIBindingsKeyboardAndControllerShareOneReducerOwnedPresentation() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let sessions = SequenceWorkspacePanelSessionManager(snapshots: [fixtureWorkspaceSnapshot(appCount: 27)])
        let inputSource = CountingWorkspaceInputSource()
        var requests: [WorkspaceExecutionRequest] = []
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: sessions,
            inputMonitor: WorkspaceInputMonitor(source: inputSource),
            executionRequestHandler: { requests.append($0) }
        )

        controller.toggle(tab: .switch)
        let model = try XCTUnwrap(controller.activeInteractionModel)
        model.selectedDisplayBinding.wrappedValue = "display-b"
        XCTAssertEqual(model.presentation.selectedDisplayID, "display-b")
        XCTAssertEqual(controller.interactionPresentation?.selectedDisplayID, "display-b")

        XCTAssertTrue(controller.sendInteraction(.selectDisplay("display-a")))
        XCTAssertTrue(controller.sendInteraction(.selectAppPage(1)))
        XCTAssertEqual(model.presentation.selectedAppPage, 1)
        XCTAssertEqual(controller.interactionPresentation?.selectedAppPage, 1)

        model.selectedTabBinding.wrappedValue = .agents
        XCTAssertEqual(controller.visibleTab, .agents)
        XCTAssertEqual(controller.interactionPresentation?.selectedTab, .agents)
        XCTAssertEqual(inputSource.startCount, 1)

        XCTAssertTrue(controller.sendInteraction(.selectTab(.switch)))
        XCTAssertTrue(controller.sendInteraction(.activateApp("app-app-26")))
        XCTAssertEqual(requests.map(\.target), [.app(displayID: "display-a", appID: "app-app-26")])
        XCTAssertEqual(controller.visibleTab, .switch, "Task 7 hands off intent without executing or closing")
        let firstRequest = try XCTUnwrap(requests.first)
        XCTAssertTrue(controller.completeExecution(.init(
            id: firstRequest.id,
            target: firstRequest.target,
            outcome: .failure(.appActivationFailed)
        )))
        XCTAssertTrue(controller.sendInteraction(.activateApp("app-app-26")))
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].id, requests[1].id)

        controller.close(reason: .programmatic)
        controller.close(reason: .programmatic)
        XCTAssertEqual(inputSource.stopCount, 1)
        XCTAssertEqual(sessions.beginCount, 1)
        XCTAssertEqual(sessions.endCount, 1)
    }

    func testCompletionIsBoundToOriginatingSessionAcrossCloseAndReopen() async throws {
        let firstStarted = expectation(description: "first execution started")
        let secondStarted = expectation(description: "second execution started")
        let executor = DeferredControllerExecutionExecutor(
            startedExpectations: [firstStarted, secondStarted]
        )
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: SequenceWorkspacePanelSessionManager(snapshots: [
                fixtureWorkspaceSnapshot(appCount: 1),
                fixtureWorkspaceSnapshot(appCount: 1),
            ]),
            executionExecutor: executor
        )

        controller.toggle(tab: .switch)
        let firstModel = try XCTUnwrap(controller.activeInteractionModel)
        XCTAssertTrue(firstModel.send(.activateApp("app-app-0")))
        await fulfillment(of: [firstStarted], timeout: 1)
        let firstRequest = try XCTUnwrap(firstModel.pendingExecutionRequest)

        controller.close(reason: .programmatic)
        controller.toggle(tab: .switch)
        let secondModel = try XCTUnwrap(controller.activeInteractionModel)
        XCTAssertTrue(secondModel.send(.activateApp("app-app-0")))
        await fulfillment(of: [secondStarted], timeout: 1)
        let secondRequest = try XCTUnwrap(secondModel.pendingExecutionRequest)
        XCTAssertEqual(firstRequest.id, secondRequest.id, "request IDs may restart per session")

        executor.completeNext(with: .success(()))
        await settleControllerTasks()
        XCTAssertTrue(controller.activeInteractionModel === secondModel)
        XCTAssertEqual(secondModel.pendingExecutionRequest, secondRequest)
        XCTAssertEqual(controller.visibleTab, .switch)

        executor.completeNext(with: .failure(.appActivationFailed))
        await settleControllerTasks()
        XCTAssertNil(secondModel.pendingExecutionRequest)
        XCTAssertEqual(secondModel.presentation.executionFailure, .appActivationFailed)
        XCTAssertEqual(controller.visibleTab, .switch)

        _ = firstModel // Retain the old model to prove identity guarding, not deallocation.
    }

    func testEscapeCancelsPendingExecutionWithoutMutatingReopenedSession() async throws {
        let started = expectation(description: "execution started")
        let cancelled = expectation(description: "execution cancelled")
        let executor = CancellationAwareControllerExecutionExecutor(
            started: started,
            cancelled: cancelled
        )
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: SequenceWorkspacePanelSessionManager(snapshots: [
                fixtureWorkspaceSnapshot(appCount: 1),
                fixtureWorkspaceSnapshot(appCount: 1),
            ]),
            executionExecutor: executor
        )

        controller.toggle(tab: .switch)
        XCTAssertTrue(try XCTUnwrap(controller.activeInteractionModel).send(
            .activateApp("app-app-0")
        ))
        await fulfillment(of: [started], timeout: 1)

        controller.close(reason: .escape)
        controller.toggle(tab: .switch)
        let reopenedModel = try XCTUnwrap(controller.activeInteractionModel)
        await fulfillment(of: [cancelled], timeout: 1)
        await settleControllerTasks()

        XCTAssertTrue(controller.activeInteractionModel === reopenedModel)
        XCTAssertNil(reopenedModel.pendingExecutionRequest)
        XCTAssertNil(reopenedModel.presentation.executionFailure)
        XCTAssertEqual(controller.visibleTab, .switch)
    }

    func testNarrowViewportCapacityIsReadyBeforeInputMonitorActivation() throws {
        let topology = FixtureScreenTopologyProvider(topology: WorkspaceScreenTopology(
            screens: [WorkspaceScreen(
                id: "display-pointer",
                frame: CGRect(x: 0, y: 0, width: 320, height: 800)
            )],
            pointerScreenID: "display-pointer"
        ))
        let inputSource = CountingWorkspaceInputSource()
        var requests: [WorkspaceExecutionRequest] = []
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: SequenceWorkspacePanelSessionManager(
                snapshots: [fixtureWorkspaceSnapshot(appCount: 27)]
            ),
            inputMonitor: WorkspaceInputMonitor(source: inputSource),
            executionRequestHandler: { requests.append($0) }
        )

        controller.toggle(tab: .switch)

        XCTAssertEqual(inputSource.startCount, 1)
        XCTAssertEqual(topology.currentTopologyCount, 1)
        XCTAssertFalse(inputSource.send(.key(character: "y", keyCode: 0, modifiers: .none)))
        XCTAssertTrue(inputSource.send(.key(character: "x", keyCode: 0, modifiers: .none)))
        XCTAssertEqual(requests.map(\.target), [
            .app(displayID: "display-a", appID: "app-app-23")
        ])
    }

    func testProductionSemanticRuntimeReadsAndMutatesTheControllersSharedInteractionSession() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let sessions = SequenceWorkspacePanelSessionManager(snapshots: [fixtureWorkspaceSnapshot(appCount: 2)])
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: sessions
        )
        let semanticModel = SwitcherSemanticModel()
        let runtime = FullscreenSemanticAdapterAssembly(
            workspacePresenter: controller,
            semanticModel: semanticModel
        ).makeRuntime()

        runtime.openPanel()
        XCTAssertEqual(runtime.state().selectedItemID, "display-a")
        XCTAssertEqual(runtime.snapshot(), controller.frozenSessionSnapshot)

        XCTAssertTrue(runtime.select(itemID: "display-b"))
        XCTAssertEqual(controller.interactionPresentation?.selectedDisplayID, "display-b")
        XCTAssertEqual(runtime.state().selectedItemID, "display-b")

        runtime.closePanel()
        XCTAssertFalse(runtime.state().isPanelOpen)
        XCTAssertEqual(sessions.beginCount, 1)
        XCTAssertEqual(sessions.endCount, 1)
    }

    func testOpenAndRefreshSynchronizeFrozenAndSemanticIconAvailabilityWithPanelSession() {
        let snapshot = fixtureWorkspaceSnapshot(appCount: 2)
        let sessions = RefreshingWorkspacePanelSessionManager(initialSnapshot: snapshot)
        let controller = FullscreenWorkspaceController(
            topologyProvider: FixtureScreenTopologyProvider(topology: makeTopology()),
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            sessionManager: sessions,
            iconProvider: CountingWorkspaceAppIconProvider(
                availableBundleIdentifiers: ["app-app-0"]
            )
        )
        let runtime = FullscreenSemanticAdapterAssembly(
            workspacePresenter: controller,
            semanticModel: SwitcherSemanticModel()
        ).makeRuntime()

        runtime.openPanel()

        assertIconAvailabilityTruth(controller.frozenSessionSnapshot)
        assertIconAvailabilityTruth(runtime.snapshot())

        sessions.publish(snapshot)

        assertIconAvailabilityTruth(controller.frozenSessionSnapshot)
        assertIconAvailabilityTruth(runtime.snapshot())
    }

    func testExternalCloseResetsSemanticGestureAndSelectionBeforeReopen() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let sessions = SequenceWorkspacePanelSessionManager(
            snapshots: [
                fixtureWorkspaceSnapshot(appCount: 2),
                fixtureWorkspaceSnapshot(appCount: 2)
            ]
        )
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: sessions
        )
        let runtime = FullscreenSemanticAdapterAssembly(
            workspacePresenter: controller,
            semanticModel: SwitcherSemanticModel()
        ).makeRuntime()

        runtime.openPanel()
        XCTAssertTrue(runtime.selectWorkspaceDryRunTarget(.appLetter(0)))
        XCTAssertTrue(runtime.executeWorkspaceDryRun())
        XCTAssertTrue(runtime.sendWorkspaceGesture(.init(
            id: 41,
            phase: .began,
            deltaX: 0,
            deltaY: 0,
            velocityX: 0,
            velocityY: 0
        )))
        XCTAssertEqual(runtime.state().gesturePhase, "began")
        XCTAssertNotNil(runtime.state().selectedTargetIdentity)
        XCTAssertTrue(runtime.state().dryRunSelectionConfirmed)

        controller.close(reason: .escape)

        XCTAssertEqual(runtime.state().gesturePhase, "idle")
        XCTAssertNil(runtime.state().selectedTargetKind)
        XCTAssertNil(runtime.state().selectedTargetIdentity)
        XCTAssertFalse(runtime.state().dryRunSelectionConfirmed)

        runtime.closePanel()
        runtime.openPanel()
        XCTAssertTrue(runtime.sendWorkspaceGesture(.init(
            id: 42,
            phase: .began,
            deltaX: 0,
            deltaY: 0,
            velocityX: 0,
            velocityY: 0
        )))
        XCTAssertEqual(runtime.state().gesturePhase, "began")
    }

    func testProductionSemanticRuntimeAllAllowedCommandsAndReturnCauseZeroExecutionRequests() async throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let sessions = SequenceWorkspacePanelSessionManager(snapshots: [fixtureWorkspaceSnapshot(appCount: 27)])
        let realInputExecutor = CountingControllerExecutionExecutor()
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: FixtureWorkspaceWindowFactory(),
            backdropProvider: FixtureWorkspaceBackdropProvider(),
            sessionManager: sessions,
            executionExecutor: realInputExecutor
        )
        let semanticModel = SwitcherSemanticModel()
        let runtime = FullscreenSemanticAdapterAssembly(
            workspacePresenter: controller,
            semanticModel: semanticModel
        ).makeRuntime()
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")

        let requests = [
            #"{"command":"workspace.snapshot","token":"secret"}"#,
            #"{"command":"workspace.open","token":"secret","tab":"switch"}"#,
            #"{"command":"workspace.key","token":"secret","key":"next_app_page"}"#,
            #"{"command":"workspace.gesture","token":"secret","gesture":{"id":41,"phase":"began","deltaX":0,"deltaY":0,"velocityX":0,"velocityY":0}}"#,
            #"{"command":"workspace.gesture","token":"secret","gesture":{"id":41,"phase":"changed","deltaX":-320,"deltaY":0,"velocityX":-500,"velocityY":0}}"#,
            #"{"command":"workspace.gesture","token":"secret","gesture":{"id":41,"phase":"ended","deltaX":-320,"deltaY":0,"velocityX":-500,"velocityY":0}}"#,
            #"{"command":"workspace.open","token":"secret","tab":"switch"}"#,
            #"{"command":"workspace.key","token":"secret","key":"app_a"}"#,
            #"{"command":"workspace.executeDryRun","token":"secret"}"#
        ]
        var responses: [SemanticAdapterResponse] = []
        for request in requests {
            let response = await server.handle(jsonLine: request)
            XCTAssertTrue(response.ok, request)
            responses.append(response)
        }

        XCTAssertEqual(responses[7].state?.workspace?.selectedTargetKind, "app")
        XCTAssertNotNil(responses[7].state?.workspace?.selectedTargetIdentity)
        XCTAssertFalse(responses[7].state?.workspace?.dryRunSelectionConfirmed ?? true)
        XCTAssertTrue(responses[8].state?.workspace?.dryRunSelectionConfirmed ?? false)

        let returnResponse = await server.handle(
            jsonLine: #"{"command":"workspace.key","token":"secret","key":"return"}"#
        )
        XCTAssertEqual(returnResponse.error?.code, .invalidRequest)
        let closeResponse = await server.handle(
            jsonLine: #"{"command":"workspace.close","token":"secret"}"#
        )
        XCTAssertTrue(closeResponse.ok)
        await settleControllerTasks()
        XCTAssertEqual(realInputExecutor.executeCount, 0)
    }

    func testBackdropCompletionKeepsFrozenAppsOrderAndSelectionAndReopenUsesFreshSnapshot() throws {
        let topology = FixtureScreenTopologyProvider(topology: makeTopology())
        let windows = FixtureWorkspaceWindowFactory()
        let backdrops = DeferredWorkspaceBackdropProvider()
        let first = fixtureWorkspaceSnapshot(appCount: 27, prefix: "first")
        let second = fixtureWorkspaceSnapshot(appCount: 1, prefix: "second")
        let sessions = SequenceWorkspacePanelSessionManager(snapshots: [first, second])
        let controller = FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: backdrops,
            applicationActivator: FixtureWorkspaceApplicationActivator(),
            sessionManager: sessions
        )

        controller.toggle(tab: .switch)
        let firstModel = try XCTUnwrap(controller.activeInteractionModel)
        let firstWindow = try XCTUnwrap(windows.created.first { $0.role == .interactive })
        XCTAssertTrue(controller.sendInteraction(.selectDisplay("display-b")))
        XCTAssertEqual(firstWindow.rootViewInstallCount, 1)
        XCTAssertEqual(backdrops.requests.count, 1)
        let frozenIDs = try XCTUnwrap(controller.frozenSessionSnapshot).runningApps.map(\.id)
        backdrops.completeRequest(at: 0, with: .image(NSImage(size: NSSize(width: 20, height: 20))))

        XCTAssertTrue(controller.activeInteractionModel === firstModel)
        XCTAssertEqual(firstWindow.rootViewInstallCount, 2)
        XCTAssertEqual(controller.frozenSessionSnapshot?.runningApps.map(\.id), frozenIDs)
        XCTAssertEqual(controller.interactionPresentation?.selectedDisplayID, "display-b")
        XCTAssertEqual(sessions.beginCount, 1)

        controller.close(reason: .programmatic)
        XCTAssertNil(controller.visibleTab)
        XCTAssertNil(controller.activeInteractionModel)
        controller.toggle(tab: .switch)

        XCTAssertEqual(controller.visibleTab, .switch)
        XCTAssertEqual(controller.frozenSessionSnapshot?.runningApps.map(\.id), ["second-app-0"])
        XCTAssertEqual(sessions.beginCount, 2)
        XCTAssertEqual(sessions.endCount, 1)
    }

    private func fixtureWorkspaceSnapshot(appCount: Int, prefix: String = "app") -> SwitcherSnapshot {
        let displays = [
            DisplayDescriptor(
                id: "display-a",
                frame: try! RectDescriptor(x: 0, y: 0, width: 1_512, height: 982),
                isCurrent: true
            ),
            DisplayDescriptor(
                id: "display-b",
                frame: try! RectDescriptor(x: 1_512, y: 0, width: 1_512, height: 982),
                isCurrent: false
            )
        ]
        let apps = (0..<appCount).map { index in
            RunningAppDescriptor(
                id: "\(prefix)-app-\(index)",
                displayName: "App \(index)",
                mostRecentWindow: nil
            )
        }
        return SwitcherSnapshot(
            displays: displays,
            runningApps: apps,
            pointerLocation: PointSnapshot(x: 10, y: 10),
            frontmostAppID: nil,
            workspaces: [
                DisplayWorkspaceSnapshot(display: displays[0], apps: apps, previewAvailability: .schematicFallback),
                DisplayWorkspaceSnapshot(display: displays[1], apps: apps, previewAvailability: .schematicFallback)
            ]
        )
    }

    private func makeController(
        topology: FixtureScreenTopologyProvider,
        windows: FixtureWorkspaceWindowFactory
    ) -> FullscreenWorkspaceController {
        FullscreenWorkspaceController(
            topologyProvider: topology,
            windowFactory: windows,
            backdropProvider: FixtureWorkspaceBackdropProvider()
        )
    }

    private func makeTopology() -> WorkspaceScreenTopology {
        WorkspaceScreenTopology(
            screens: [
                WorkspaceScreen(id: "display-left", frame: CGRect(x: -1280, y: 0, width: 1280, height: 800)),
                WorkspaceScreen(id: "display-pointer", frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                WorkspaceScreen(id: "display-right", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
            ],
            pointerScreenID: "display-pointer"
        )
    }

    private func settleControllerTasks() async {
        for _ in 0..<12 { await Task.yield() }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeHeadlessSemanticSession(
        runtimeState: SwitcherRuntimeState? = nil,
        actionService: SwitcherActionService? = nil
    ) -> SwitcherHeadlessSession {
        SwitcherHeadlessSession(
            runtimeState: runtimeState,
            actionService: actionService
        )
    }

    private func assertIconAvailabilityTruth(
        _ snapshot: SwitcherSnapshot?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let runningApps = Dictionary(uniqueKeysWithValues: (snapshot?.runningApps ?? []).map {
            ($0.id, $0.iconAvailability)
        })
        let workspaceApps = Dictionary(uniqueKeysWithValues: (
            snapshot?.workspaces.first?.apps ?? []
        ).map { ($0.id, $0.iconAvailability) })
        let expected: [String: RunningAppIconAvailability] = [
            "app-app-0": .available,
            "app-app-1": .fallback
        ]
        XCTAssertEqual(runningApps, expected, file: file, line: line)
        XCTAssertEqual(workspaceApps, expected, file: file, line: line)
    }
}

@MainActor
private final class MenuLifecycleSettingsPresenter: SwitcherSettingsPresenting {
    func openSettings() {}
}

@MainActor
private final class MenuLifecycleApplicationTerminator: ApplicationTerminating {
    func terminate() {}
}

@MainActor
private final class DeferredControllerExecutionExecutor: WorkspaceExecutionExecuting {
    private let startedExpectations: [XCTestExpectation]
    private var requests: [WorkspaceExecutionRequest] = []
    private var continuations: [CheckedContinuation<Result<Void, SwitcherActionFailure>, Never>] = []

    init(startedExpectations: [XCTestExpectation]) {
        self.startedExpectations = startedExpectations
    }

    func execute(_ request: WorkspaceExecutionRequest) async -> Result<Void, SwitcherActionFailure> {
        let index = requests.count
        requests.append(request)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            if startedExpectations.indices.contains(index) {
                startedExpectations[index].fulfill()
            }
        }
    }

    func completeNext(with result: Result<Void, SwitcherActionFailure>) {
        continuations.removeFirst().resume(returning: result)
    }
}

@MainActor
private final class CountingControllerExecutionExecutor: WorkspaceExecutionExecuting {
    private(set) var executeCount = 0

    func execute(_ request: WorkspaceExecutionRequest) async -> Result<Void, SwitcherActionFailure> {
        executeCount += 1
        return .success(())
    }
}

@MainActor
private final class CancellationAwareControllerExecutionExecutor: WorkspaceExecutionExecuting {
    private let started: XCTestExpectation
    private let cancelled: XCTestExpectation

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func execute(_ request: WorkspaceExecutionRequest) async -> Result<Void, SwitcherActionFailure> {
        started.fulfill()
        do {
            try await Task.sleep(for: .seconds(10))
            return .success(())
        } catch {
            cancelled.fulfill()
            return .failure(.actionOverloaded)
        }
    }
}

@MainActor
private final class FixtureScreenTopologyProvider: ScreenTopologyProviding {
    var topology: WorkspaceScreenTopology
    private(set) var observations: [FixtureScreenTopologyObservation] = []
    private var handlers: [@MainActor () -> Void] = []
    private(set) var currentTopologyCount = 0

    init(topology: WorkspaceScreenTopology) {
        self.topology = topology
    }

    func currentTopology() -> WorkspaceScreenTopology {
        currentTopologyCount += 1
        return topology
    }

    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any WorkspaceScreenTopologyObserving {
        let observation = FixtureScreenTopologyObservation()
        observations.append(observation)
        handlers.append(handler)
        return observation
    }

    func notifyChange() {
        handlers.forEach { $0() }
    }
}

@MainActor
private final class FixtureScreenTopologyObservation: WorkspaceScreenTopologyObserving {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class FixtureWorkspaceWindowFactory: WorkspaceWindowCreating {
    private(set) var created: [FixtureWorkspaceWindow] = []
    private let onCreate: @MainActor () -> Void

    init(onCreate: @escaping @MainActor () -> Void = {}) {
        self.onCreate = onCreate
    }

    func makeWindow(configuration: WorkspaceWindowConfiguration) -> any WorkspaceWindowControlling {
        onCreate()
        let window = FixtureWorkspaceWindow(configuration: configuration)
        created.append(window)
        return window
    }
}

@MainActor
private final class FixtureWorkspaceApplicationActivator: WorkspaceApplicationActivating {
    private(set) var activationCount = 0
    private let onActivate: @MainActor () -> Void

    init(onActivate: @escaping @MainActor () -> Void = {}) {
        self.onActivate = onActivate
    }

    func activate() {
        activationCount += 1
        onActivate()
    }
}

@MainActor
private final class FixturePrewarmingPanelPresenter: SwitcherPanelPresenting, SwitcherPanelPrewarming {
    private(set) var closeCount = 0
    private(set) var prewarmCount = 0

    func openSwitcher() {}

    func closeSwitcher() {
        closeCount += 1
    }

    func prewarmSwitcher() {
        prewarmCount += 1
    }
}

@MainActor
private final class FixturePrewarmSettingsPresenter: SwitcherSettingsPresenting {
    func openSettings() {}
}

@MainActor
private final class FixturePrewarmApplicationTerminator: ApplicationTerminating {
    func terminate() {}
}

@MainActor
private final class FixtureWorkspaceWindow: WorkspaceWindowControlling {
    let displayID: String
    let role: WorkspaceWindowRole
    private(set) var frames: [CGRect]
    private(set) var showAsKeyValues: [Bool] = []
    private(set) var rootViewInstallCount: Int
    private(set) var closeCount = 0
    private(set) var isClosed = false
    var escapeHandler: (@MainActor () -> Void)?

    init(configuration: WorkspaceWindowConfiguration) {
        displayID = configuration.displayID
        role = configuration.role
        frames = [configuration.frame]
        rootViewInstallCount = configuration.rootView == nil ? 0 : 1
    }

    func setFrame(_ frame: CGRect) {
        frames.append(frame)
    }

    func setRootView(_ rootView: AnyView) {
        rootViewInstallCount += 1
    }

    func show(makeKey: Bool) {
        showAsKeyValues.append(makeKey)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        closeCount += 1
    }

    func sendEscape() {
        escapeHandler?()
    }
}

@MainActor
private final class FixtureProductWorkspaceEvidenceCapture: ProductWorkspaceEvidenceCapturing {
    private(set) var startedWindows: [any WorkspaceWindowControlling] = []
    private(set) var tokens: [FixtureProductWorkspaceEvidenceCaptureToken] = []

    func startCapture(
        for window: any WorkspaceWindowControlling
    ) -> (any ProductWorkspaceEvidenceCaptureToken)? {
        startedWindows.append(window)
        let token = FixtureProductWorkspaceEvidenceCaptureToken()
        tokens.append(token)
        return token
    }
}

@MainActor
private final class FixtureProductWorkspaceEvidenceCaptureToken: ProductWorkspaceEvidenceCaptureToken {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class FixtureProductWorkspaceDimmingPresentationRecorder:
    ProductWorkspaceDimmingPresentationRecording {
    private(set) var records: [[ProductWorkspaceDimmingWindow]] = []

    func record(_ windows: [ProductWorkspaceDimmingWindow]) {
        records.append(windows)
    }
}

@MainActor
private final class FixtureProductWorkspacePerformanceTrace: ProductWorkspacePerformanceTracing {
    struct Start {
        let startNanoseconds: UInt64
        let role: WorkspaceWindowRole
        let wasShown: Bool
    }

    private(set) var starts: [Start] = []
    private(set) var tokens: [FixtureProductWorkspacePerformanceTraceToken] = []

    func beginGlobalShortcutFirstExposure(
        startNanoseconds: UInt64,
        for window: any WorkspaceWindowControlling
    ) -> (any ProductWorkspacePerformanceTraceToken)? {
        starts.append(Start(
            startNanoseconds: startNanoseconds,
            role: window.role,
            wasShown: (window as? FixtureWorkspaceWindow)?.showAsKeyValues.isEmpty == false
        ))
        let token = FixtureProductWorkspacePerformanceTraceToken()
        tokens.append(token)
        return token
    }
}

@MainActor
private final class FixtureProductWorkspacePerformanceTraceToken: ProductWorkspacePerformanceTraceToken {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private struct FixtureWorkspaceBackdropProvider: WorkspaceBackdropProviding {
    func resolveBackdrop(
        for displayID: String,
        screen: NSScreen?,
        completion: @escaping @MainActor (WorkspaceBackdrop) -> Void
    ) -> WorkspaceBackdrop {
        .semanticGradient
    }
}

@MainActor
private final class DeferredWorkspaceBackdropProvider: WorkspaceBackdropProviding {
    struct Request {
        let displayID: String
        let completion: @MainActor (WorkspaceBackdrop) -> Void
    }

    private(set) var requests: [Request] = []

    func resolveBackdrop(
        for displayID: String,
        screen: NSScreen?,
        completion: @escaping @MainActor (WorkspaceBackdrop) -> Void
    ) -> WorkspaceBackdrop {
        requests.append(Request(displayID: displayID, completion: completion))
        return .semanticGradient
    }

    func completeRequest(at index: Int, with backdrop: WorkspaceBackdrop) {
        requests[index].completion(backdrop)
    }
}

@MainActor
private final class FixtureFullscreenPresenter: FullscreenWorkspacePresenting, FullscreenWorkspaceVisibilityObserving, SwitcherPanelPresenting {
    private(set) var visibleTab: WorkspaceTab?
    private(set) var toggledTabs: [WorkspaceTab] = []
    private(set) var closeReasons: [WorkspaceCloseReason] = []
    private var observers: [UUID: @MainActor (WorkspaceTab?) -> Void] = [:]

    var observerCount: Int { observers.count }

    func toggle(tab: WorkspaceTab) {
        toggledTabs.append(tab)
        visibleTab = tab
        observers.values.forEach { $0(visibleTab) }
    }

    func close(reason: WorkspaceCloseReason) {
        closeReasons.append(reason)
        visibleTab = nil
        observers.values.forEach { $0(visibleTab) }
    }

    func openSwitcher() {
        toggle(tab: .switch)
    }

    func closeSwitcher() {
        close(reason: .programmatic)
    }

    func observeVisibilityChanges(
        _ observer: @escaping @MainActor (WorkspaceTab?) -> Void
    ) -> WorkspaceVisibilityObservation {
        let id = UUID()
        observers[id] = observer
        return WorkspaceVisibilityObservation { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }
}

@MainActor
private struct FixtureHeadlessPointer: PointerLocationProviding {
    func currentPointerLocation() -> PointSnapshot? { PointSnapshot(x: 0, y: 0) }
}

@MainActor
private final class MutableHeadlessRunningAppDiscovery: RunningAppDiscovering {
    var appID: String

    init(appID: String) {
        self.appID = appID
    }

    func discoverRunningApps() -> [RunningAppSource] {
        [RunningAppSource(id: appID, displayName: appID, activationPolicy: .regular)]
    }
}

@MainActor
private struct FixtureHeadlessDisplayDiscovery: DisplayDiscovering {
    func discoverDisplays() -> [DisplaySource] {
        [DisplaySource(
            id: "display-main",
            frame: try! RectDescriptor(x: 0, y: 0, width: 1512, height: 982)
        )]
    }
}

@MainActor
private struct FixtureHeadlessFrontmostState: FrontmostStateProviding {
    func frontmostApplicationID() -> String? { nil }
}

@MainActor
private final class FixtureHeadlessActivationObserver: RunningAppActivationObserving {
    func startObserving(
        _ handler: @escaping @MainActor (String) -> Void
    ) -> RunningAppActivationObservation {
        FixtureHeadlessActivationObservation()
    }
}

@MainActor
private final class FixtureHeadlessActivationObservation: RunningAppActivationObservation {
    func cancel() {}
}

@MainActor
private struct FixtureGrantedAccessibilityChecker: AccessibilityChecking {
    func isAccessibilityTrusted() -> Bool { true }
    func requestAccessibilityAccess() -> Bool { true }
}

@MainActor
private struct FixtureGrantedScreenRecordingChecker {
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
}

@MainActor
private struct FixtureUnavailableAppIconProvider: RunningAppIconProviding {
    func icon(for bundleIdentifier: String) -> NSImage? { nil }
}

@MainActor
private final class CountingWorkspaceAppIconProvider: RunningAppIconProviding {
    private let availableBundleIdentifiers: Set<String>
    private(set) var counts: [String: Int] = [:]

    init(availableBundleIdentifiers: Set<String>) {
        self.availableBundleIdentifiers = availableBundleIdentifiers
    }

    func icon(for bundleIdentifier: String) -> NSImage? {
        counts[bundleIdentifier, default: 0] += 1
        guard availableBundleIdentifiers.contains(bundleIdentifier) else { return nil }
        return NSImage(size: NSSize(width: 48, height: 48))
    }
}

@MainActor
private struct FirstOpenDisplayDiscovery: DisplayDiscovering {
    let displays: [DisplaySource]

    func discoverDisplays() -> [DisplaySource] { displays }
}

@MainActor
private struct FirstOpenPointerProvider: PointerLocationProviding {
    let location: PointSnapshot

    func currentPointerLocation() -> PointSnapshot? { location }
}

@MainActor
private final class MutableFirstOpenPointerProvider: PointerLocationProviding {
    var location: PointSnapshot?

    init(location: PointSnapshot?) {
        self.location = location
    }

    func currentPointerLocation() -> PointSnapshot? { location }
}

@MainActor
private struct FirstOpenRunningAppDiscovery: RunningAppDiscovering {
    func discoverRunningApps() -> [RunningAppSource] {
        [RunningAppSource(
            id: "com.example.editor",
            displayName: "Editor",
            activationPolicy: .regular
        )]
    }
}

@MainActor
private struct FirstOpenProcessProvider:
    RunningAppProcessIdentifierProviding,
    RunningAppProcessGenerationProviding {
    func processIdentifier(for appID: String) -> pid_t? { 42 }

    func activeProcessGenerations() -> [RunningAppProcessGeneration] {
        [RunningAppProcessGeneration(
            bundleIdentifier: "com.example.editor",
            processIdentifier: 42,
            launchIdentity: "first-open-generation"
        )]
    }
}

private struct FirstOpenAXCandidateReader: AXWindowMetadataCandidateReading {
    let candidate: AXWindowMetadataCandidate

    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        [candidate]
    }
}

private struct FirstOpenEmptyAXCandidateReader: AXWindowMetadataCandidateReading {
    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        []
    }
}

private final class FirstOpenQueuedRefreshScheduler: @unchecked Sendable,
    WindowMetadataRefreshScheduling {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { operations.count } }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    func runAll() {
        let pending = lock.withLock {
            let pending = operations
            operations.removeAll()
            return pending
        }
        pending.forEach { $0() }
    }
}

private struct SessionCallCounts: Equatable {
    let begin: Int
    let end: Int
}

private struct FullscreenBackdropProbe {
    var loadCount = 0
    var processCount = 0
}

@MainActor
private final class CountingPanelSessionManager: SwitcherPanelSessionManaging {
    private let base: SwitcherRuntimeState
    private let snapshotOverride: SwitcherSnapshot?
    private(set) var beginCount = 0
    private(set) var endCount = 0

    init(base: SwitcherRuntimeState, snapshotOverride: SwitcherSnapshot? = nil) {
        self.base = base
        self.snapshotOverride = snapshotOverride
    }

    var counts: SessionCallCounts {
        SessionCallCounts(begin: beginCount, end: endCount)
    }

    func beginPanelSession() -> SwitcherSnapshot {
        beginCount += 1
        return snapshotOverride ?? base.beginPanelSession()
    }

    func endPanelSession() {
        endCount += 1
        if snapshotOverride == nil {
            base.endPanelSession()
        }
    }
}

@MainActor
private final class SequenceWorkspacePanelSessionManager: SwitcherPanelSessionManaging {
    private var snapshots: [SwitcherSnapshot]
    private(set) var beginCount = 0
    private(set) var endCount = 0

    init(snapshots: [SwitcherSnapshot]) {
        self.snapshots = snapshots
    }

    func beginPanelSession() -> SwitcherSnapshot {
        let index = min(beginCount, max(snapshots.count - 1, 0))
        beginCount += 1
        return snapshots[index]
    }

    func endPanelSession() {
        endCount += 1
    }
}

@MainActor
private final class RefreshingWorkspacePanelSessionManager: SwitcherPanelSessionManaging {
    private var snapshot: SwitcherSnapshot
    private var observers: [UUID: @MainActor (SwitcherSnapshot) -> Void] = [:]

    init(initialSnapshot: SwitcherSnapshot) {
        snapshot = initialSnapshot
    }

    func beginPanelSession() -> SwitcherSnapshot { snapshot }

    func endPanelSession() {}

    func observePanelSessionSnapshots(
        _ observer: @escaping @MainActor (SwitcherSnapshot) -> Void
    ) -> SwitcherPanelSessionSnapshotObservation {
        let id = UUID()
        observers[id] = observer
        return SwitcherPanelSessionSnapshotObservation { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    func publish(_ snapshot: SwitcherSnapshot) {
        self.snapshot = snapshot
        observers.values.forEach { $0(snapshot) }
    }
}

@MainActor
private final class CountingWorkspaceInputSource: WorkspaceInputEventSourcing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: ((WorkspaceInputEvent) -> Bool)?

    func start(handler: @escaping (WorkspaceInputEvent) -> Bool) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        guard handler != nil else { return }
        stopCount += 1
        handler = nil
    }

    func send(_ event: WorkspaceInputEvent) -> Bool {
        handler?(event) ?? false
    }
}

@MainActor
private final class FixtureFailingRuntimeServer: SemanticAdapterServerControlling {
    private let runtime: FullscreenHeadlessSemanticRuntime
    private let onStop: () -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(runtime: FullscreenHeadlessSemanticRuntime, onStop: @escaping () -> Void) {
        self.runtime = runtime
        self.onStop = onStop
    }

    func start() async throws -> SemanticAdapterRuntimeMetadata {
        startCount += 1
        throw SemanticAdapterServerError.listenerFailed
    }

    func stop() {
        stopCount += 1
        runtime.teardown()
        onStop()
    }
}

@MainActor
private final class FixtureSuccessfulLifecycleServer: SemanticAdapterServerControlling {
    private let onStart: () -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    func start() async throws -> SemanticAdapterRuntimeMetadata {
        startCount += 1
        onStart()
        return fixtureSemanticAdapterMetadata()
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FixturePendingLifecycleServer: SemanticAdapterServerControlling {
    private var runtime: FullscreenHeadlessSemanticRuntime?
    private let onStart: () -> Void
    private let onCancellation: () -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        runtime: FullscreenHeadlessSemanticRuntime? = nil,
        onStart: @escaping () -> Void,
        onCancellation: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.onStart = onStart
        self.onCancellation = onCancellation
    }

    func start() async throws -> SemanticAdapterRuntimeMetadata {
        startCount += 1
        onStart()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return fixtureSemanticAdapterMetadata()
        } catch {
            onCancellation()
            throw error
        }
    }

    func stop() {
        stopCount += 1
        runtime?.teardown()
        runtime = nil
    }
}

@MainActor
private struct FixtureWorkspaceAccessibilityPreferencesForFullscreenTests: WorkspaceAccessibilityPreferencesProviding {
    let reduceTransparencyEnabled: Bool
}

private func fixtureSemanticAdapterMetadata() -> SemanticAdapterRuntimeMetadata {
    SemanticAdapterRuntimeMetadata(
        pid: 1,
        port: 43123,
        tokenReference: "sha256:test",
        bundle: "test.ScreenSwitcher",
        version: "test",
        logPath: "<artifact-root>/runtime.log"
    )
}

@MainActor
private final class FixtureBootstrapShortcutStorage: ShortcutStorage {
    var shortcut: KeyboardShortcuts.Shortcut?

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        self.shortcut = shortcut
    }
}

@MainActor
private final class FixtureBootstrapSemanticServer: SemanticAdapterServerControlling {
    private let runtime: FullscreenHeadlessSemanticRuntime

    init(runtime: FullscreenHeadlessSemanticRuntime) {
        self.runtime = runtime
    }

    func start() async throws -> SemanticAdapterRuntimeMetadata {
        XCTFail("The bootstrap dependency test must not bind a network listener")
        throw SemanticAdapterServerError.listenerFailed
    }

    func stop() {
        runtime.teardown()
    }
}
