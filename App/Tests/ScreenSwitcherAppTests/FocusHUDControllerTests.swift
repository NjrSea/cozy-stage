import AppKit
import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class FocusHUDControllerTests: XCTestCase {
    private let safeBounds = CanvasRect(x: 100, y: 50, width: 1_000, height: 700)

    func testPanelIsStrictlyAboveFloatingAndDoesNotHideOnDeactivate() {
        let panel = FocusHUDPanel()
        defer { panel.orderOut(nil) }
        XCTAssertEqual(panel.level.rawValue, NSWindow.Level.floating.rawValue + 1)
        XCTAssertEqual(panel.level, FocusHUDPanel.hudWindowLevel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testPresentedHUDRootHitViewAllowsNonactivatingPanelToBecomeKey() throws {
        let controller = makeController(
            windows: makeWindows(count: 1),
            panelKeyWindowReader: { _ in true }
        )
        defer { controller.close(reason: .programmatic) }

        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))

        let panel = try XCTUnwrap(controller.panel)
        let contentView = try XCTUnwrap(panel.contentView)
        let hitView = try XCTUnwrap(contentView.hitTest(
            CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        ))
        XCTAssertTrue(contentView is FocusHUDHostingView)
        XCTAssertTrue(contentView.needsPanelToBecomeKey)
        XCTAssertTrue(hitView.needsPanelToBecomeKey)
        XCTAssertTrue(controller.isPanelKeyWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testNarrowWorkspaceHeaderSafePointConsumesClickWithoutActivatingApp() throws {
        var intents: [FocusHUDOverviewIntent] = []
        var keyReassertionCount = 0
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { _ in
            keyReassertionCount += 1
        })
        let controller = makeController(
            windows: makeWindows(count: 1),
            workspaceName: "I",
            intentHandler: { intents.append($0) },
            hudPanel: panel
        )
        defer { controller.close(reason: .programmatic) }
        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        let contentView = try XCTUnwrap(panel.contentView)
        contentView.layoutSubtreeIfNeeded()
        let headerSafePoint = CGPoint(
            x: FocusHUDDesign.contentInset + FocusHUDDesign.headerHeight / 2,
            y: FocusHUDDesign.contentInset + FocusHUDDesign.headerHeight / 2
        )
        let baselineInteractionRevision = controller.viewModel.interactionRevision
        let baselinePresentationRevision = try XCTUnwrap(
            controller.viewModel.snapshot?.presentationRevision
        )

        XCTAssertNotNil(contentView.hitTest(headerSafePoint))
        panel.sendEvent(try makeMouseEvent(
            windowNumber: panel.windowNumber,
            location: headerSafePoint
        ))
        panel.sendEvent(try makeMouseEvent(
            windowNumber: panel.windowNumber,
            location: headerSafePoint,
            type: .leftMouseUp
        ))

        XCTAssertEqual(keyReassertionCount, 2)
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(controller.viewModel.isPresented)
        XCTAssertEqual(intents, [])
        XCTAssertEqual(controller.viewModel.interactionRevision, baselineInteractionRevision)
        XCTAssertEqual(
            controller.viewModel.snapshot?.presentationRevision,
            baselinePresentationRevision
        )
    }

    func testPresentationBuildsSnapshotWithRealRevisionBeforeSizingPanel() throws {
        let controller = makeController(windows: makeWindows(count: 6))
        defer { controller.close(reason: .programmatic) }
        assertSuccess(controller.present(inventoryRevision: 42, safeBounds: safeBounds))

        let snapshot = try XCTUnwrap(controller.viewModel.snapshot)
        let layout = try XCTUnwrap(snapshot.layout.availableLayout)
        let frame = try XCTUnwrap(controller.panel).frame
        XCTAssertEqual(snapshot.inventoryRevision, 42)
        XCTAssertEqual(layout.contentInset, 16)
        XCTAssertEqual(layout.panelWidth, layout.contentWidth + 2 * layout.contentInset)
        XCTAssertEqual(layout.panelHeight, layout.contentHeight + 2 * layout.contentInset)
        XCTAssertEqual(frame.size, CGSize(width: layout.panelWidth, height: layout.panelHeight))
        XCTAssertEqual(frame.midX, safeBounds.x + safeBounds.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.midY, safeBounds.y + safeBounds.height / 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minX, safeBounds.x + 32)
        XCTAssertLessThanOrEqual(frame.maxX, safeBounds.x + safeBounds.width - 32)
        XCTAssertGreaterThanOrEqual(frame.minY, safeBounds.y + 32)
        XCTAssertLessThanOrEqual(frame.maxY, safeBounds.y + safeBounds.height - 32)
    }

    func testLayoutConstraintsFreezeUniformContentInsetIntoSnapshotGeometry() {
        let constraints = FocusHUDController.layoutConstraints(in: safeBounds)

        XCTAssertEqual(constraints.contentInset, 16)
        XCTAssertEqual(constraints.outerMargin, 32)
    }

    func testOwnedMinimumMetricVisualQualificationPinsWideDisplayToRealMinimum() throws {
        let environment = [
            "CS_DIAG_DOGFOOD": "1",
            "CS_DIAG_RUNTIME": "1",
            "CS_DIAG_GUI_SMOKE": "1",
            "CS_DIAG_CAPTURE_MODE": "full",
            "CS_DIAG_CAPTURE_DIRECTORY": "/owned/evidence",
            "SCREEN_SWITCHER_HUD_VISUAL_STATE": "minimum-metric",
        ]
        let controller = makeController(
            windows: makeWindows(count: 96),
            visualQualificationEnvironment: environment
        )
        defer { controller.close(reason: .programmatic) }
        assertSuccess(controller.present(
            inventoryRevision: 1,
            safeBounds: CanvasRect(x: 0, y: 0, width: 3_008, height: 1_692)
        ))

        let layout = try XCTUnwrap(controller.viewModel.snapshot?.layout.availableLayout)
        XCTAssertEqual(layout.cellSize, 40)
        XCTAssertEqual(layout.workspaceLayouts.reduce(0) { $0 + $1.appCount }, 96)
    }

    func testMinimumMetricEnvironmentCannotChangeNormalProductLayout() {
        let complete = [
            "CS_DIAG_DOGFOOD": "1",
            "CS_DIAG_RUNTIME": "1",
            "CS_DIAG_GUI_SMOKE": "1",
            "CS_DIAG_CAPTURE_MODE": "full",
            "CS_DIAG_CAPTURE_DIRECTORY": "/owned/evidence",
            "SCREEN_SWITCHER_HUD_VISUAL_STATE": "minimum-metric",
        ]
        for omitted in complete.keys {
            var incomplete = complete
            incomplete.removeValue(forKey: omitted)
            XCTAssertEqual(
                FocusHUDController.layoutConstraints(in: safeBounds, environment: incomplete)
                    .relaxedCellSize,
                100,
                "missing gate: \(omitted)"
            )
        }
        for state in [
            "sparse", "wrapped", "maximum-three-row-hovered", "empty-workspace",
            "keyboard-focus", "layout-unavailable",
        ] {
            XCTAssertEqual(
                FocusHUDController.layoutConstraints(
                    in: safeBounds,
                    environment: complete.merging(["SCREEN_SWITCHER_HUD_VISUAL_STATE": state]) { _, new in new }
                ).relaxedCellSize,
                100,
                state
            )
        }
    }

    func testPresentationStartsTriggeredProductCaptureAndCloseCancelsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-hud-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduledCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: [
                "CS_DIAG_GUI_SMOKE": "1",
                "CS_DIAG_CAPTURE_MODE": "full"
            ],
            scheduler: { _, _ in scheduledCount += 1 },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in true }
        )
        let controller = makeController(windows: makeWindows(count: 1), evidenceCapture: capture)
        defer { controller.close(reason: .programmatic) }

        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))

        XCTAssertEqual(scheduledCount, 1)
        let triggerURL = directory.appendingPathComponent(
            ProductWorkspaceEvidenceCapture.hudTriggerFileName
        )
        try Data().write(to: triggerURL, options: .atomic)

        controller.close(reason: .programmatic)

        XCTAssertFalse(FileManager.default.fileExists(atPath: triggerURL.path))
    }

    func testControllerDeinitCancelsTriggeredProductCaptureAndRemovesMarker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-hud-deinit-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var capture: ProductWorkspaceEvidenceCapture? = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: [
                "CS_DIAG_GUI_SMOKE": "1",
                "CS_DIAG_CAPTURE_MODE": "full"
            ],
            scheduler: { _, _ in },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in true }
        )
        var controller: FocusHUDController? = makeController(
            windows: makeWindows(count: 1),
            evidenceCapture: try XCTUnwrap(capture)
        )
        capture = nil
        assertSuccess(try XCTUnwrap(controller).present(
            inventoryRevision: 1,
            safeBounds: safeBounds
        ))
        let triggerURL = directory.appendingPathComponent(
            ProductWorkspaceEvidenceCapture.hudTriggerFileName
        )
        try Data().write(to: triggerURL, options: .atomic)
        weak var releasedController = controller

        controller = nil
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(releasedController)
        XCTAssertFalse(FileManager.default.fileExists(atPath: triggerURL.path))
    }

    func testLayoutUnavailableUsesDeterministicCompactFrameAndDismissalOnly() throws {
        let controller = makeController(windows: makeWindows(count: 73))
        defer { controller.close(reason: .programmatic) }
        assertSuccess(controller.present(
            inventoryRevision: 1,
            safeBounds: CanvasRect(x: 10, y: 20, width: 454, height: 176)
        ))

        XCTAssertEqual(try XCTUnwrap(controller.viewModel.snapshot).layout, .unavailable(.layoutUnavailable))
        XCTAssertEqual(try XCTUnwrap(controller.panel).frame.size, CGSize(width: 390, height: 112))
        XCTAssertEqual(controller.viewModel.handle(key: .left), .none)
        XCTAssertEqual(controller.viewModel.handle(key: .returnKey), .none)
        XCTAssertEqual(controller.viewModel.handle(key: .escape), .cancel)
    }

    func testVisibleRefreshQueuesStateWithoutMovingOrResizingPanel() throws {
        let controller = makeController(windows: makeWindows(count: 3))
        defer { controller.close(reason: .programmatic) }
        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        let initialFrame = try XCTUnwrap(controller.panel).frame
        let initialRevision = try XCTUnwrap(controller.viewModel.snapshot).inventoryRevision

        controller.refresh(state: try FocusScreenReducer.bootstrap(currentWindows: makeWindows(count: 12)))

        XCTAssertEqual(try XCTUnwrap(controller.panel).frame, initialFrame)
        XCTAssertEqual(try XCTUnwrap(controller.viewModel.snapshot).inventoryRevision, initialRevision)
    }

    func testDidBecomeActiveReassertsLevelWithoutCreatingAnotherPanel() throws {
        let notifications = NotificationCenter()
        let controller = makeController(notificationCenter: notifications)
        defer { controller.close(reason: .programmatic) }
        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        let panel = try XCTUnwrap(controller.panel)
        panel.level = .normal

        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(panel.level, FocusHUDPanel.hudWindowLevel)
        XCTAssertEqual(controller.presentedWindowCount, 1)
        XCTAssertEqual(controller.scrimWindowCount, 0)
    }

    func testDidResignActiveReactivatesApplicationAndExactPanel() throws {
        let notifications = NotificationCenter()
        var activationCount = 0
        var keyReassertionCount = 0
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { _ in
            keyReassertionCount += 1
        })
        let controller = makeController(
            notificationCenter: notifications,
            hudPanel: panel,
            applicationActivator: { activationCount += 1 }
        )
        defer { controller.close(reason: .programmatic) }
        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        let activationBaseline = activationCount
        let reassertionBaseline = keyReassertionCount
        panel.level = .normal

        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)

        XCTAssertEqual(activationCount, activationBaseline + 1)
        XCTAssertEqual(keyReassertionCount, reassertionBaseline + 1)
        XCTAssertEqual(panel.level, FocusHUDPanel.hudWindowLevel)

        controller.close(reason: .programmatic)
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(activationCount, activationBaseline + 1)
        XCTAssertEqual(keyReassertionCount, reassertionBaseline + 1)
    }

    func testPresentationInstallsActivationObserverAndStateBeforeActivatingApplication() throws {
        let notifications = NotificationCenter()
        var keyReassertionCount = 0
        var reassertedPanels: [ObjectIdentifier] = []
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { candidate in
            reassertedPanels.append(ObjectIdentifier(candidate))
            keyReassertionCount += 1
        })
        weak var observedController: FocusHUDController?
        let controller = makeController(
            notificationCenter: notifications,
            hudPanel: panel,
            applicationActivator: {
                XCTAssertEqual(observedController?.isPresented, true)
                notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            }
        )
        observedController = controller
        defer { controller.close(reason: .programmatic) }

        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))

        XCTAssertEqual(keyReassertionCount, 2)
        XCTAssertEqual(reassertedPanels, [ObjectIdentifier(panel), ObjectIdentifier(panel)])
        XCTAssertTrue(controller.panel === panel)
    }

    func testDelayedActivationMakesExactPanelKeyAfterInitialReassertionIsNoOp() throws {
        let notifications = NotificationCenter()
        var keyReassertionCount = 0
        var simulatedKeyPanel: FocusHUDPanel?
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { candidate in
            keyReassertionCount += 1
            if keyReassertionCount > 1 {
                simulatedKeyPanel = candidate
            }
        })
        let controller = makeController(
            notificationCenter: notifications,
            panelKeyWindowReader: { candidate in
                candidate === simulatedKeyPanel
            },
            hudPanel: panel
        )
        defer { controller.close(reason: .programmatic) }

        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        XCTAssertFalse(controller.isPanelKeyWindow)

        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(controller.isPanelKeyWindow)
        XCTAssertTrue(controller.panel === panel)
        XCTAssertEqual(keyReassertionCount, 2)
    }

    func testPanelMouseDownReassertsKeyBeforeDispatchingEvent() throws {
        var keyWasReasserted = false
        var keyPanel: FocusHUDPanel?
        var dispatched = false
        let panel = FocusHUDPanel(
            keyAndOrderFrontAction: { candidate in
                keyPanel = candidate
                keyWasReasserted = true
            },
            eventDispatchAction: { _ in
                XCTAssertTrue(keyWasReasserted)
                dispatched = true
            }
        )
        panel.setPresentationEnabled(true)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        panel.sendEvent(event)

        XCTAssertTrue(keyWasReasserted)
        XCTAssertTrue(keyPanel === panel)
        XCTAssertTrue(dispatched)
    }

    func testLocalMouseMonitorKeepsExactHUDClicksAndClosesOverlappingOtherWindowWithoutConsuming() throws {
        let fixture = makeLifecycleFixture()
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        let panel = try XCTUnwrap(fixture.controller.panel)
        let panelEvent = try makeMouseEvent(windowNumber: panel.windowNumber)

        XCTAssertTrue(fixture.local.activeMask.contains(.leftMouseDown))
        XCTAssertTrue(fixture.local.activeMask.contains(.rightMouseDown))
        XCTAssertTrue(fixture.local.activeMask.contains(.otherMouseDown))
        XCTAssertTrue(fixture.local.emit(panelEvent) === panelEvent)
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .localHUD)

        let otherWindow = NSWindow(
            contentRect: panel.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let otherEvent = try makeMouseEvent(
            windowNumber: otherWindow.windowNumber,
            location: CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        )

        XCTAssertTrue(fixture.local.emit(otherEvent) === otherEvent)
        assertClosed(fixture)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .localOutside)
    }

    func testLocalWindowlessMouseInsideHUDFramePassesAndReassertsExactPanelKey() throws {
        var keyReassertionCount = 0
        weak var reassertedPanel: FocusHUDPanel?
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { candidate in
            reassertedPanel = candidate
            keyReassertionCount += 1
        })
        let fixture = makeLifecycleFixture(hudPanel: panel)
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        XCTAssertEqual(keyReassertionCount, 1)
        let windowlessInside = try makeMouseEvent(
            windowNumber: 0,
            location: CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        )

        XCTAssertNil(windowlessInside.window)
        XCTAssertTrue(fixture.local.emit(windowlessInside) === windowlessInside)
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertEqual(keyReassertionCount, 2)
        XCTAssertTrue(reassertedPanel === panel)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .localHUD)
    }

    func testLocalMouseMonitorTreatsWindowlessStatusOrMenuClickAsOutsideWithoutConsuming() throws {
        let fixture = makeLifecycleFixture()
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        let statusOrMenuEvent = try makeMouseEvent(windowNumber: 0)

        XCTAssertTrue(fixture.local.emit(statusOrMenuEvent) === statusOrMenuEvent)
        assertClosed(fixture)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .localOutside)
    }

    func testGlobalClickGuardRequiresExactHUDOrEventHandlingWindowIdentity() {
        let hud = FocusHUDWindowServerRecord(
            windowNumber: 41,
            ownerProcessIdentifier: 111,
            layer: FocusHUDPanel.hudWindowLevel.rawValue,
            bounds: CGRect(x: -1_300, y: -400, width: 300, height: 200),
            isOnscreen: true,
            alpha: 1
        )
        let foreign = FocusHUDWindowServerRecord(
            windowNumber: 99,
            ownerProcessIdentifier: 222,
            layer: NSWindow.Level.statusBar.rawValue,
            bounds: hud.bounds,
            isOnscreen: true,
            alpha: 0
        )
        let expected = FocusHUDWindowServerIdentity(
            windowNumber: hud.windowNumber,
            ownerProcessIdentifier: hud.ownerProcessIdentifier,
            layer: hud.layer
        )

        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: hud.windowNumber,
            eventHandlingWindowNumber: nil,
            windowServerRecords: nil,
            expectedHUD: expected
        ))
        XCTAssertTrue(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: foreign.windowNumber,
            eventHandlingWindowNumber: hud.windowNumber,
            windowServerRecords: [hud],
            expectedHUD: expected
        ), "NSEvent.windowNumber is diagnostic; field 92 owns the click")
        XCTAssertTrue(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: hud.windowNumber,
            windowServerRecords: [foreign, hud],
            expectedHUD: expected
        ), "a click-through overlay cannot override the CGEvent handling window")
        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: foreign.windowNumber,
            windowServerRecords: [foreign, hud],
            expectedHUD: expected
        ), "an alpha-zero foreign event target still owns the click")
        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: nil,
            windowServerRecords: [hud],
            expectedHUD: expected
        ))
        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: 0,
            windowServerRecords: [hud],
            expectedHUD: expected
        ))
        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: Int(UInt32.max) + 1,
            windowServerRecords: [hud],
            expectedHUD: expected
        ))
        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: hud.windowNumber,
            windowServerRecords: nil,
            expectedHUD: expected
        ))
        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: hud.windowNumber,
            windowServerRecords: [FocusHUDWindowServerRecord(
                windowNumber: hud.windowNumber,
                ownerProcessIdentifier: foreign.ownerProcessIdentifier,
                layer: hud.layer,
                bounds: hud.bounds,
                isOnscreen: true,
                alpha: 1
            )],
            expectedHUD: expected
        ))
        XCTAssertEqual(FocusHUDGlobalClickGuard.route(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: hud.windowNumber,
            windowServerRecords: [FocusHUDWindowServerRecord(
                windowNumber: hud.windowNumber,
                ownerProcessIdentifier: foreign.ownerProcessIdentifier,
                layer: hud.layer,
                bounds: hud.bounds,
                isOnscreen: true,
                alpha: 1
            )],
            expectedHUD: expected
        ), .unresolved)
        XCTAssertFalse(FocusHUDGlobalClickGuard.keepsHUD(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: hud.windowNumber,
            windowServerRecords: [hud, hud],
            expectedHUD: expected
        ))
        XCTAssertEqual(FocusHUDGlobalClickGuard.route(
            eventWindowNumber: 0,
            eventHandlingWindowNumber: hud.windowNumber,
            windowServerRecords: [hud, hud],
            expectedHUD: expected
        ), .unresolved)
    }

    func testExactHUDGlobalEventReassertsKeyWithoutClosing() throws {
        var keyReassertionCount = 0
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { _ in
            keyReassertionCount += 1
        })
        var records: [FocusHUDWindowServerRecord]?
        let fixture = makeLifecycleFixture(
            hudPanel: panel,
            windowServerRecordsProvider: { records },
            globalEventHandlingWindowNumberProvider: { _ in panel.windowNumber }
        )
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        records = [windowServerRecord(
            windowNumber: panel.windowNumber,
            ownerProcessIdentifier: NSRunningApplication.current.processIdentifier,
            layer: FocusHUDPanel.hudWindowLevel.rawValue,
            bounds: panel.frame
        )]

        fixture.global.emit(try makeMouseEvent(windowNumber: panel.windowNumber))

        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertEqual(keyReassertionCount, 2)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .globalHUDExact)
    }

    func testGlobalEventRekeysVerifiedHUDWhenNSEventWindowNumberIsForeign() throws {
        var records: [FocusHUDWindowServerRecord]?
        var keyReassertionCount = 0
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { _ in
            keyReassertionCount += 1
        })
        let fixture = makeLifecycleFixture(
            hudPanel: panel,
            windowServerRecordsProvider: { records },
            globalEventHandlingWindowNumberProvider: { _ in panel.windowNumber }
        )
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        records = [windowServerRecord(
            windowNumber: panel.windowNumber,
            ownerProcessIdentifier: NSRunningApplication.current.processIdentifier,
            layer: FocusHUDPanel.hudWindowLevel.rawValue,
            bounds: panel.frame
        )]
        let event = try makeMouseEvent(windowNumber: panel.windowNumber + 100)
        XCTAssertNotEqual(event.windowNumber, panel.windowNumber)

        fixture.global.emit(event)

        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertEqual(keyReassertionCount, 2)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .globalHUDTopmost)
    }

    func testWindowServerGlobalEventUsesEmbeddedHandlingWindowIdentity() throws {
        var records: [FocusHUDWindowServerRecord]?
        var keyReassertionCount = 0
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { _ in
            keyReassertionCount += 1
        })
        let fixture = makeLifecycleFixture(
            hudPanel: panel,
            windowServerRecordsProvider: { records }
        )
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        records = [windowServerRecord(
            windowNumber: panel.windowNumber,
            ownerProcessIdentifier: NSRunningApplication.current.processIdentifier,
            layer: FocusHUDPanel.hudWindowLevel.rawValue,
            bounds: CGRect(x: -1_300, y: -400, width: 300, height: 200)
        )]
        let event = try makeGlobalMouseEvent(handlingWindowNumber: panel.windowNumber)
        XCTAssertEqual(event.windowNumber, 0)

        fixture.global.emit(event)

        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertEqual(keyReassertionCount, 2)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .globalHUDTopmost)
    }

    func testGlobalFocusAttemptMarkerAttributesOnlyMatchingDiagnosticsClick() throws {
        var records: [FocusHUDWindowServerRecord]?
        let panel = FocusHUDPanel()
        let fixture = makeLifecycleFixture(hudPanel: panel, windowServerRecordsProvider: { records })
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        records = [windowServerRecord(
            windowNumber: panel.windowNumber,
            ownerProcessIdentifier: NSRunningApplication.current.processIdentifier,
            layer: FocusHUDPanel.hudWindowLevel.rawValue,
            bounds: panel.frame
        )]

        fixture.global.emit(try makeGlobalMouseEvent(handlingWindowNumber: panel.windowNumber))
        XCTAssertFalse(fixture.controller.matchedFocusAttempt)

        fixture.controller.close(reason: .programmatic)
        assertSuccess(fixture.controller.present(inventoryRevision: 2, safeBounds: safeBounds))
        fixture.global.emit(try makeGlobalMouseEvent(
            handlingWindowNumber: panel.windowNumber,
            marksFocusAttempt: true
        ))
        XCTAssertTrue(fixture.controller.matchedFocusAttempt)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .globalHUDTopmost)
    }

    func testWindowServerGlobalEventClosesForActualForeignTargetOrUnavailableList() throws {
        for recordsAvailable in [true, false] {
            var records: [FocusHUDWindowServerRecord]?
            let panel = FocusHUDPanel()
            let fixture = makeLifecycleFixture(
                hudPanel: panel,
                windowServerRecordsProvider: { records }
            )
            assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
            if recordsAvailable {
                let bounds = CGRect(x: -1_300, y: -400, width: 300, height: 200)
                records = [
                    windowServerRecord(
                        windowNumber: panel.windowNumber + 1,
                        ownerProcessIdentifier: 999,
                        layer: NSWindow.Level.statusBar.rawValue,
                        bounds: bounds
                    ),
                    windowServerRecord(
                        windowNumber: panel.windowNumber,
                        ownerProcessIdentifier: NSRunningApplication.current.processIdentifier,
                        layer: FocusHUDPanel.hudWindowLevel.rawValue,
                        bounds: bounds
                    ),
                ]
            }

            fixture.global.emit(try makeGlobalMouseEvent(
                handlingWindowNumber: recordsAvailable ? panel.windowNumber + 1 : panel.windowNumber
            ))

            assertClosed(fixture)
            XCTAssertEqual(
                fixture.controller.lastMouseRoute,
                recordsAvailable ? .globalOutsideTopmost : .globalUnresolved
            )
        }
    }

    func testWindowServerRecordsRejectMalformedInputBeforeHitTesting() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let valid: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 41),
            kCGWindowOwnerPID as String: NSNumber(value: 111),
            kCGWindowLayer as String: NSNumber(value: FocusHUDPanel.hudWindowLevel.rawValue),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowAlpha as String: NSNumber(value: 1.0),
        ]
        XCTAssertEqual(FocusHUDGlobalClickGuard.records(from: [valid])?.count, 1)

        var malformed = valid
        malformed.removeValue(forKey: kCGWindowBounds as String)
        XCTAssertNil(FocusHUDGlobalClickGuard.records(from: [valid, malformed]))
    }

    func testRemovedMonitorHandlersCannotAffectReplacementPresentation() throws {
        var keyReassertionCount = 0
        let panel = FocusHUDPanel(keyAndOrderFrontAction: { _ in
            keyReassertionCount += 1
        })
        let fixture = makeLifecycleFixture(hudPanel: panel)
        defer { fixture.controller.close(reason: .programmatic) }
        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        let oldLocalHandler = try XCTUnwrap(fixture.local.retainedHandlers.first)
        let oldGlobalHandler = try XCTUnwrap(fixture.global.retainedHandlers.first)

        fixture.controller.close(reason: .programmatic)
        assertSuccess(fixture.controller.present(inventoryRevision: 2, safeBounds: safeBounds))
        let replacementReassertionCount = keyReassertionCount
        XCTAssertEqual(fixture.controller.lastMouseRoute, .staleIgnored)

        let hudEvent = try makeMouseEvent(windowNumber: panel.windowNumber)
        XCTAssertTrue(oldLocalHandler(hudEvent) === hudEvent)
        oldGlobalHandler(hudEvent)

        let otherWindow = NSWindow(
            contentRect: panel.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let outsideEvent = try makeMouseEvent(windowNumber: otherWindow.windowNumber)
        XCTAssertTrue(oldLocalHandler(outsideEvent) === outsideEvent)
        oldGlobalHandler(outsideEvent)

        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertEqual(keyReassertionCount, replacementReassertionCount)
        XCTAssertEqual(fixture.controller.lastMouseRoute, .staleIgnored)
        XCTAssertEqual(fixture.controller.lastCloseReason, .none)
    }

    func testClosedPanelLateMouseDownDispatchesWithoutReassertingKeyOrShowingGhostHUD() throws {
        var keyReassertionCount = 0
        var dispatchCount = 0
        let panel = FocusHUDPanel(
            keyAndOrderFrontAction: { _ in keyReassertionCount += 1 },
            eventDispatchAction: { _ in dispatchCount += 1 }
        )
        let controller = makeController(windows: makeWindows(count: 1), hudPanel: panel)
        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        XCTAssertEqual(keyReassertionCount, 1)
        let lateEvent = try makeMouseEvent(windowNumber: panel.windowNumber)

        controller.close(reason: .programmatic)
        panel.sendEvent(lateEvent)

        XCTAssertEqual(keyReassertionCount, 1)
        XCTAssertEqual(dispatchCount, 1)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(panel.isVisible)
    }

    func testLastCloseReasonTracksClosedCauseAndResetsOnNextPresentation() {
        let cases: [(FocusHUDCloseReason, FocusSemanticHUDLastCloseReason)] = [
            (.escape, .escape),
            (.outsideClick, .outsideClick),
            (.programmatic, .programmatic),
            (.applicationTermination, .applicationTermination),
        ]

        for (closeReason, semanticReason) in cases {
            let controller = makeController()
            assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))
            XCTAssertEqual(controller.lastCloseReason, .none)
            controller.close(reason: closeReason)
            XCTAssertEqual(controller.lastCloseReason, semanticReason)

            assertSuccess(controller.present(inventoryRevision: 2, safeBounds: safeBounds))
            XCTAssertEqual(controller.lastCloseReason, .none)
            controller.close(reason: .programmatic)
        }
    }

    func testPhysicalDismissCauseSurvivesOwnerProgrammaticCloseCallback() throws {
        for physicalCause in [FocusHUDCloseReason.outsideClick, .escape] {
            weak var owner: FocusHUDController?
            let fixture = makeLifecycleFixture(intentHandler: { _ in
                owner?.close(reason: .programmatic)
            })
            owner = fixture.controller
            assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))

            if physicalCause == .outsideClick {
                fixture.global.emitMouseDown()
            } else {
                _ = fixture.local.emit(try makeKeyEvent(keyCode: 53, characters: "\u{1b}"))
            }

            assertClosed(fixture)
            XCTAssertEqual(
                fixture.controller.lastCloseReason,
                physicalCause == .outsideClick ? .outsideClick : .escape
            )
        }
    }

    func testEveryClosePathRemovesMonitorsAndActivationObserver() throws {
        for reason in [FocusHUDCloseReason.programmatic, .applicationTermination] {
            let fixture = makeLifecycleFixture()
            assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
            let panel = try XCTUnwrap(fixture.controller.panel)
            reason == .applicationTermination
                ? fixture.controller.handleApplicationTermination()
                : fixture.controller.close(reason: reason)
            assertClosed(fixture)
            panel.level = .normal
            fixture.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            XCTAssertEqual(panel.level, .normal)
        }

        var outsideIntents: [FocusHUDOverviewIntent] = []
        let outside = makeLifecycleFixture(intentHandler: { outsideIntents.append($0) })
        assertSuccess(outside.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        outside.global.emitMouseDown()
        assertClosed(outside)
        XCTAssertEqual(outsideIntents, [.cancel])
        XCTAssertEqual(outside.controller.lastCloseReason, .outsideClick)

        let escape = makeLifecycleFixture()
        assertSuccess(escape.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        _ = escape.local.emit(try makeKeyEvent(keyCode: 53, characters: "\u{1b}"))
        assertClosed(escape)
        XCTAssertEqual(escape.controller.lastCloseReason, .escape)
    }

    func testKeyboardLayoutFailureIsTypedAndFailClosed() {
        let fixture = makeLifecycleFixture(shiftedDigitSymbolsProvider: { nil })
        let result = fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds)
        assertFailure(result, equals: .keyboardLayoutUnavailable)
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertFalse(fixture.controller.viewModel.isPresented)
        XCTAssertNil(fixture.controller.panel)
        XCTAssertFalse(fixture.controller.isPanelVisible)
        XCTAssertEqual(fixture.local.activeCount, 0)
        XCTAssertEqual(fixture.global.activeCount, 0)
    }

    func testSnapshotFailureReturnsTypedErrorWithoutPresentingOrInstallingMonitors() {
        let fixture = makeLifecycleFixture()
        fixture.controller.viewModel.setPresentationRevisionForTest(.max)

        let result = fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds)

        assertFailure(result, equals: .snapshot(.revisionExhausted))
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertFalse(fixture.controller.viewModel.isPresented)
        XCTAssertNil(fixture.controller.panel)
        XCTAssertFalse(fixture.controller.isPanelVisible)
        XCTAssertEqual(fixture.local.activeCount, 0)
        XCTAssertEqual(fixture.global.activeCount, 0)
    }

    func testPresentIsIdempotentSuccessWithoutInstallingDuplicateMonitors() {
        let fixture = makeLifecycleFixture()
        defer { fixture.controller.close(reason: .programmatic) }

        assertSuccess(fixture.controller.present(inventoryRevision: 1, safeBounds: safeBounds))
        assertSuccess(fixture.controller.present(inventoryRevision: 2, safeBounds: safeBounds))
        XCTAssertEqual(fixture.local.activeCount, 1)
        XCTAssertEqual(fixture.global.activeCount, 1)
    }

    func testNonReadyStatusStillPresentsWithoutInventingKeyboardSymbols() {
        let controller = makeController(shiftedDigitSymbolsProvider: { nil })
        controller.viewModel.setWindowDiscoveryStatus(.accessibilityRequired)
        defer { controller.close(reason: .programmatic) }

        assertSuccess(controller.present(inventoryRevision: 1, safeBounds: safeBounds))

        XCTAssertTrue(controller.isPresented)
        XCTAssertNil(controller.viewModel.snapshot)
        XCTAssertNil(controller.lastPresentationError)
    }

    func testTranslatorUsesPhysicalKeysAndOnlyShiftForAssignments() throws {
        let physicalLetters: [(UInt16, Character)] = [
            (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"),
            (6, "z"), (7, "x"), (8, "c"), (9, "v"), (11, "b"), (12, "q"),
            (13, "w"), (14, "e"), (15, "r"), (16, "y"), (17, "t"),
            (31, "o"), (32, "u"), (34, "i"), (35, "p"), (37, "l"),
            (38, "j"), (40, "k"), (45, "n"), (46, "m"),
        ]
        for (keyCode, letter) in physicalLetters {
            XCTAssertEqual(translate(keyCode, "?"), .shortcut(.letter(letter), shifted: false))
            XCTAssertEqual(translate(keyCode, "?", [.shift]), .shortcut(.letter(letter), shifted: true))
            XCTAssertEqual(translate(keyCode, "?", [.capsLock]), .shortcut(.letter(letter), shifted: false))
        }
        XCTAssertEqual(translate(0, "q"), .shortcut(.letter("a"), shifted: false))
        XCTAssertEqual(translate(12, "a"), .shortcut(.letter("q"), shifted: false))
        XCTAssertNil(translate(10, "a"))
        let physicalDigits: [(UInt16, Int)] = [
            (29, 0), (18, 1), (19, 2), (20, 3), (21, 4),
            (23, 5), (22, 6), (26, 7), (28, 8), (25, 9),
        ]
        for (keyCode, digit) in physicalDigits {
            XCTAssertEqual(translate(keyCode, ""), .shortcut(.digit(digit), shifted: false))
            XCTAssertEqual(translate(keyCode, "", [.shift]), .shortcut(.digit(digit), shifted: true))
        }
    }

    func testTranslatorKeepsNavigationAndRejectsLegacyPageKeysAndKeyUp() throws {
        XCTAssertEqual(translate(123, ""), .left)
        XCTAssertEqual(translate(124, ""), .right)
        XCTAssertEqual(translate(125, ""), .down)
        XCTAssertEqual(translate(126, ""), .up)
        XCTAssertEqual(translate(36, "\r"), .returnKey)
        XCTAssertEqual(translate(48, "\t"), .tab)
        XCTAssertEqual(translate(53, "\u{1b}"), .escape)
        XCTAssertNil(translate(33, "["))
        XCTAssertNil(translate(30, "]"))
        XCTAssertNil(FocusHUDPhysicalKeyTranslator.translate(try makeKeyEvent(keyCode: 0, characters: "a", type: .keyUp)))
    }

    func testShiftedDigitProviderUsesPhysicalOrderAndExplicitShiftModifier() {
        let expectedKeyCodes: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        let expectedSymbols = Array(")!@#$%^&*(")
        var translations: [(keyCode: UInt16, modifierState: UInt32)] = []

        let symbols = PhysicalDigitKeyboardLayoutTranslator.shiftedDigitSymbols { keyCode, modifierState in
            translations.append((keyCode, modifierState))
            return expectedSymbols[expectedKeyCodes.firstIndex(of: keyCode)!]
        }

        XCTAssertEqual(symbols, expectedSymbols)
        XCTAssertEqual(translations.map(\.keyCode), expectedKeyCodes)
        XCTAssertEqual(
            translations.map(\.modifierState),
            Array(repeating: PhysicalDigitKeyboardLayoutTranslator.shiftModifierState, count: 10)
        )
    }

    func testProductionShiftedDigitProviderUsesActiveKeyboardLayout() {
        let symbols = PhysicalDigitKeyboardLayoutTranslator.activeShiftedDigitSymbols()
        XCTAssertEqual(symbols?.count, 10)
    }

    private func translate(
        _ keyCode: UInt16,
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags = []
    ) -> FocusHUDOverviewKey? {
        FocusHUDPhysicalKeyTranslator.translate(
            try! makeKeyEvent(keyCode: keyCode, characters: characters, modifiers: modifiers)
        )
    }

    private func assertSuccess(
        _ result: Result<Void, FocusHUDControllerPresentationError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .success = result else {
            return XCTFail("Expected presentation success, got \(result)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: Result<Void, FocusHUDControllerPresentationError>,
        equals expected: FocusHUDControllerPresentationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("Expected presentation failure, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    private func makeController(
        windows: [ManagedWindow] = [],
        workspaceName: String? = nil,
        intentHandler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void = { _ in },
        notificationCenter: NotificationCenter = NotificationCenter(),
        shiftedDigitSymbolsProvider: @escaping @MainActor () -> [Character]? = { Array(")!@#$%^&*(") },
        panelKeyWindowReader: @escaping @MainActor (NSPanel) -> Bool = { $0.isKeyWindow },
        evidenceCapture: ProductWorkspaceEvidenceCapture? = nil,
        hudPanel: FocusHUDPanel? = nil,
        visualQualificationEnvironment: [String: String] = [:],
        applicationActivator: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) -> FocusHUDController {
        var state = try! FocusScreenReducer.bootstrap(currentWindows: windows)
        state.screens[0].name = workspaceName
        let viewModel = FocusHUDViewModel(
            state: state,
            metadataProvider: StubWindowMetadataProvider(),
            intentHandler: intentHandler
        )
        viewModel.setWindowDiscoveryStatus(.ready)
        return FocusHUDController(
            viewModel: viewModel,
            notificationCenter: notificationCenter,
            shiftedDigitSymbolsProvider: shiftedDigitSymbolsProvider,
            panelKeyWindowReader: panelKeyWindowReader,
            evidenceCapture: evidenceCapture,
            hudPanel: hudPanel,
            visualQualificationEnvironment: visualQualificationEnvironment,
            applicationActivator: applicationActivator
        )
    }

    private func makeLifecycleFixture(
        intentHandler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void = { _ in },
        shiftedDigitSymbolsProvider: @escaping @MainActor () -> [Character]? = { Array(")!@#$%^&*(") },
        hudPanel: FocusHUDPanel? = nil,
        windowServerRecordsProvider: @escaping @MainActor () -> [FocusHUDWindowServerRecord]? = { [] },
        globalEventHandlingWindowNumberProvider: @escaping @MainActor (NSEvent) -> Int? = {
            FocusHUDController.eventHandlingWindowNumber(from: $0)
        }
    ) -> LifecycleFixture {
        let local = CountingLocalMonitorRegistrar()
        let global = CountingGlobalEventRegistrar()
        let notifications = NotificationCenter()
        let viewModel = FocusHUDViewModel(
            state: try! FocusScreenReducer.bootstrap(currentWindows: []),
            metadataProvider: StubWindowMetadataProvider(),
            intentHandler: intentHandler
        )
        viewModel.setWindowDiscoveryStatus(.ready)
        return LifecycleFixture(controller: FocusHUDController(
            viewModel: viewModel,
            localMonitorRegistrar: local,
            globalEventRegistrar: global,
            notificationCenter: notifications,
            shiftedDigitSymbolsProvider: shiftedDigitSymbolsProvider,
            hudPanel: hudPanel,
            windowServerRecordsProvider: windowServerRecordsProvider,
            globalEventHandlingWindowNumberProvider: globalEventHandlingWindowNumberProvider
        ), local: local, global: global, notifications: notifications)
    }

    private func assertClosed(_ fixture: LifecycleFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.controller.isPresented, file: file, line: line)
        XCTAssertEqual(fixture.local.activeCount, 0, file: file, line: line)
        XCTAssertEqual(fixture.global.activeCount, 0, file: file, line: line)
    }

    private func makeWindows(count: Int) -> [ManagedWindow] {
        (0..<count).map { ManagedWindow(
            id: "w-\($0)", appID: "com.test.app-\($0)",
            canonicalFrame: CanvasRect(x: 0, y: 0, width: 100, height: 100)
        ) }
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters.lowercased(), isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func makeMouseEvent(
        windowNumber: Int,
        location: CGPoint = .zero,
        type: NSEvent.EventType = .leftMouseDown
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func makeGlobalMouseEvent(
        handlingWindowNumber: Int,
        marksFocusAttempt: Bool = false
    ) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        cgEvent.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(handlingWindowNumber)
        )
        if marksFocusAttempt {
            cgEvent.setIntegerValueField(
                .eventSourceUserData,
                value: FocusSemanticHUDFocusAttemptMarker.eventSourceUserData
            )
        }
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    private func windowServerRecord(
        windowNumber: Int,
        ownerProcessIdentifier: Int32,
        layer: Int,
        bounds: CGRect
    ) -> FocusHUDWindowServerRecord {
        FocusHUDWindowServerRecord(
            windowNumber: windowNumber,
            ownerProcessIdentifier: ownerProcessIdentifier,
            layer: layer,
            bounds: bounds,
            isOnscreen: true,
            alpha: 1
        )
    }
}

@MainActor
private struct LifecycleFixture {
    let controller: FocusHUDController
    let local: CountingLocalMonitorRegistrar
    let global: CountingGlobalEventRegistrar
    let notifications: NotificationCenter
}

@MainActor
private final class StubWindowMetadataProvider: FocusHUDWindowMetadataProviding {
    func metadata(for window: ManagedWindow) -> FocusHUDWindowMetadata {
        FocusHUDWindowMetadata(appName: window.appID, appIcon: nil, windowTitle: "Window")
    }
}

@MainActor
private final class CountingLocalMonitorRegistrar: FocusHUDLocalMonitorRegistering {
    private var handlers: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]
    private(set) var retainedHandlers: [(NSEvent) -> NSEvent?] = []
    var activeCount: Int { handlers.count }
    private(set) var activeMask: NSEvent.EventTypeMask = []
    func addLocalMonitor(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        activeMask = mask
        retainedHandlers.append(handler)
        let token = ObjectToken(); handlers[ObjectIdentifier(token)] = handler; return token
    }
    func removeMonitor(_ monitor: Any) {
        guard let token = monitor as? ObjectToken else { return }
        handlers.removeValue(forKey: ObjectIdentifier(token))
        if handlers.isEmpty { activeMask = [] }
    }
    func emit(_ event: NSEvent) -> NSEvent? { handlers.values.first?(event) }
}

@MainActor
private final class CountingGlobalEventRegistrar: FocusHUDGlobalEventRegistering {
    private var handlers: [ObjectIdentifier: (NSEvent) -> Void] = [:]
    private(set) var retainedHandlers: [(NSEvent) -> Void] = []
    var activeCount: Int { handlers.count }
    func addGlobalMonitor(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
        retainedHandlers.append(handler)
        let token = ObjectToken(); handlers[ObjectIdentifier(token)] = handler; return token
    }
    func removeMonitor(_ monitor: Any) {
        guard let token = monitor as? ObjectToken else { return }
        handlers.removeValue(forKey: ObjectIdentifier(token))
    }
    func emitMouseDown() {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ) else { return }
        handlers.values.first?(event)
    }
    func emit(_ event: NSEvent) { handlers.values.first?(event) }
}

private final class ObjectToken {}
