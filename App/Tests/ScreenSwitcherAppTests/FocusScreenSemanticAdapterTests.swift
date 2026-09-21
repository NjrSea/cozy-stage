import AppKit
import ScreenDomainCore
@preconcurrency import Network
import XCTest
@testable import ScreenSwitcherApp

/// Task 10 server-side tests for the v3 semantic focus-screen server.
///
/// These prove the v3 wire contract:
///   - The closed `FocusSemanticCommand` allowlist commands are accepted.
///   - Old `workspace.*` commands are rejected with `unknown_command`.
///   - Mutation without execution authorization is rejected.
///   - `schemaVersion == 3` and the response carries the content-free
///     `FocusScreenSemanticSnapshotV3` with no title, path, token, PID, or raw
///     App bundle identifier.
@MainActor
final class FocusScreenSemanticAdapterTests: XCTestCase {
    private let token = "v3-secret"

    // MARK: - Allowlist + envelope

    func testV3AllowlistCommandsSucceedWithSchemaVersionThree() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        try await fixture.controller.start()
        let server = makeServer(fixture: fixture, executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]))

        for request in [
            #"{"command":"screen.snapshot","token":"v3-secret"}"#,
            #"{"command":"hud.open","token":"v3-secret"}"#,
            #"{"command":"hud.close","token":"v3-secret"}"#,
            #"{"command":"recovery.revealAll","token":"v3-secret"}"#
        ] {
            let response = await server.handle(jsonLine: request)
            XCTAssertTrue(response.ok, request)
            XCTAssertEqual(response.schemaVersion, 3, request)
            XCTAssertEqual(response.command, commandValue(request), request)
            XCTAssertNil(response.error, request)
            XCTAssertNotNil(response.snapshot, request)
        }
    }

    func testScreenSnapshotIsAlwaysReadOnlyAndBypassesExecutionGate() async throws {
        // Dry-run policy: no execution allowed. screen.snapshot must still succeed.
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(fixture: fixture, executionPolicy: ExecutionPolicy(mode: .dryRun))

        let response = await server.handle(jsonLine: #"{"command":"screen.snapshot","token":"v3-secret"}"#)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.schemaVersion, 3)
        XCTAssertNotNil(response.snapshot)
        XCTAssertNil(response.error)
    }

    func testHUDSnapshotReportsTheExactDeduplicatedWorkspaceAppSet() {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(
                id: "w1",
                appID: "app:alpha",
                frame: SemanticFixture.leftFrame
            ),
            SemanticFixture.window(
                id: "w2",
                appID: "app:alpha",
                frame: SemanticFixture.rightFrame
            ),
            SemanticFixture.window(
                id: "w3",
                appID: "app:beta",
                frame: SemanticFixture.rightFrame
            )
        ])
        let runtime = FocusScreenSemanticRuntime(
            controller: fixture.controller,
            identityHasher: { $0 }
        )

        let snapshot = runtime.snapshot()

        XCTAssertEqual(snapshot.hud.appIdentityHashes, ["app:alpha", "app:beta"])
        XCTAssertEqual(
            snapshot.hud.workspaceAppIdentityHashes,
            snapshot.hud.appIdentityHashes
        )
    }

    func testOpenHUDProjectsFrozenWorkspaceOverviewAndTruthfulRevisions() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame),
            SemanticFixture.window(id: "w2", appID: "app-b", frame: SemanticFixture.rightFrame),
            SemanticFixture.window(id: "w3", appID: "app-c", frame: SemanticFixture.rightFrame),
        ], panelKeyWindowReader: { _ in true })
        try await fixture.controller.start()
        fixture.installState(
            screens: [
                FocusScreen(id: "screen-one", number: 1, lifecycle: .background, windowIDs: ["w1", "w2"], lastActiveWindowID: "w2"),
                FocusScreen(id: "screen-two", number: 2, lifecycle: .active, windowIDs: ["w3"], lastActiveWindowID: "w3"),
            ],
            activeScreenID: "screen-two"
        )
        let runtime = FocusScreenSemanticRuntime(
            controller: fixture.controller,
            identityHasher: { "runtime:\($0)" }
        )

        fixture.controller.openSwitcher()
        defer { fixture.controller.closeSwitcher() }
        let frozen = try XCTUnwrap(fixture.overviewViewModel?.snapshot)
        let hud = runtime.snapshot().hud

        XCTAssertEqual(hud.layoutMode, .workspaceOverview)
        XCTAssertEqual(hud.page, 0)
        XCTAssertEqual(hud.inspectedScreenID, "screen-two")
        XCTAssertEqual(hud.workspaceSections.map(\.screenID), ["screen-one", "screen-two"])
        XCTAssertEqual(hud.workspaceSections.map(\.appIdentityHashes), [
            ["opaque-a", "opaque-b"],
            ["opaque-c"],
        ])
        XCTAssertEqual(hud.workspaceSections.map(\.shortcutCount), [2, 1])
        XCTAssertEqual(hud.workspaceSections.map(\.rowCount), [1, 1])
        XCTAssertEqual(hud.appIdentityHashes, ["opaque-a", "opaque-b", "opaque-c"])
        XCTAssertEqual(hud.workspaceAppIdentityHashes, ["opaque-c"])
        XCTAssertEqual(hud.inventoryRevision, frozen.inventoryRevision)
        XCTAssertEqual(hud.keyAssignmentRevision, frozen.keyAssignmentRevision)
        XCTAssertEqual(hud.presentationRevision, frozen.presentationRevision)
        XCTAssertEqual(hud.settledRevision, frozen.presentationRevision)
        XCTAssertTrue(hud.isKeyWindow)
        let encoded = String(decoding: try JSONEncoder().encode(hud), as: UTF8.self)
        for privateValue in ["private-name", "private-title", "app-a", "app-b", "app-c", "runtime:"] {
            XCTAssertFalse(encoded.contains(privateValue), privateValue)
        }
    }

    func testHiddenHUDProjectsProgrammaticCloseReasonAndReopenResetsIt() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)
        ])
        try await fixture.controller.start()
        let runtime = FocusScreenSemanticRuntime(controller: fixture.controller, identityHasher: { $0 })
        runtime.openHUD()
        runtime.closeHUD()
        let closed = runtime.snapshot().hud
        XCTAssertFalse(closed.visible)
        XCTAssertEqual(closed.lastCloseReason, .programmatic)
        XCTAssertEqual(closed.lastMouseRoute, .staleIgnored)
        XCTAssertFalse(closed.matchedFocusAttempt)

        runtime.openHUD()
        XCTAssertTrue(runtime.snapshot().hud.visible)
        XCTAssertEqual(runtime.snapshot().hud.lastCloseReason, .none)
        XCTAssertEqual(runtime.snapshot().hud.lastMouseRoute, .staleIgnored)
        XCTAssertFalse(runtime.snapshot().hud.matchedFocusAttempt)
        runtime.closeHUD()
    }

    func testSemanticHUDInteractionRevisionComesOnlyFromRealFocusMovement() async throws {
        let fixture = makeOverviewFixture(
            initialWindows: [
                SemanticFixture.window(
                    id: "w1",
                    appID: "app-a",
                    frame: SemanticFixture.leftFrame,
                    isFocused: true
                ),
                SemanticFixture.window(id: "w2", appID: "app-b", frame: SemanticFixture.rightFrame)
            ],
            panelKeyWindowReader: { _ in true }
        )
        try await fixture.controller.start()
        let runtime = FocusScreenSemanticRuntime(controller: fixture.controller, identityHasher: { $0 })
        runtime.openHUD()
        defer { runtime.closeHUD() }

        let viewModel = try XCTUnwrap(fixture.overviewViewModel)
        viewModel.dismiss()
        try viewModel.present(
            constraints: FocusHUDController.layoutConstraints(in: SemanticFixture.canvas),
            shiftedDigitSymbols: Array(")!@#$%^&*("),
            inventoryRevision: 1
        )
        viewModel.setFocusedWindowID("w1")
        let baseline = runtime.snapshot().hud.interactionRevision
        XCTAssertEqual(viewModel.handle(key: .right), .focusWindow("w2"))
        let moved = runtime.snapshot().hud.interactionRevision
        XCTAssertGreaterThan(moved, baseline)

        _ = viewModel.handle(key: .right)
        XCTAssertEqual(runtime.snapshot().hud.interactionRevision, moved)
        viewModel.setHoveredWindowID("w1")
        let renderedState = FocusHUDRenderedState(
            layoutState: .overview,
            cellSize: 40,
            visibleIconSize: 32,
            nameFontSize: 8,
            badgeSize: 16,
            badgeFontSize: 10,
            appTargetCount: 1,
            dismissTargetCount: 0,
            emptyWorkspaceCount: 0
        )
        viewModel.acknowledgeRenderedHUD(
            presentationRevision: try XCTUnwrap(viewModel.snapshot?.presentationRevision),
            interactionRevision: moved,
            state: renderedState
        )
        let hovered = runtime.snapshot().hud
        XCTAssertEqual(hovered.hoverRevision, 1)
        XCTAssertEqual(hovered.visibleNameCount, 1)
        XCTAssertEqual(hovered.nameFocusSource, .pointerHover)
        XCTAssertEqual(hovered.renderedPresentationRevision, hovered.presentationRevision)
        XCTAssertEqual(hovered.renderedInteractionRevision, moved)
        XCTAssertEqual(hovered.renderedLayoutState, .overview)
        XCTAssertEqual(hovered.renderedCellSize, 40)
        XCTAssertEqual(hovered.renderedVisibleIconSize, 32)
        XCTAssertEqual(hovered.renderedNameFontSize, 8)
        XCTAssertEqual(hovered.renderedBadgeSize, 16)
        XCTAssertEqual(hovered.renderedBadgeFontSize, 10)
        XCTAssertEqual(hovered.renderedAppTargetCount, 1)
        XCTAssertEqual(hovered.renderedDismissTargetCount, 0)
        XCTAssertEqual(hovered.renderedEmptyWorkspaceCount, 0)
        let encoded = String(decoding: try JSONEncoder().encode(runtime.snapshot().hud), as: UTF8.self)
        XCTAssertFalse(encoded.contains("w1"), "semantic HUD must not leak focused identity")
    }

    func testSemanticHUDActivationPersistsAfterExactShortcutClosesHUD() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)
        ])
        try await fixture.controller.start()
        let runtime = FocusScreenSemanticRuntime(controller: fixture.controller, identityHasher: { $0 })
        runtime.openHUD()
        let baselineRevision = runtime.snapshot().hud.activation.revision

        XCTAssertEqual(runtime.sendHUDKey(.shortcut(.letter("a"), shifted: false)), .activateWindow("w1"))
        for _ in 0..<20 where runtime.snapshot().hud.activation.stage != .commit {
            await Task.yield()
        }

        let hud = runtime.snapshot().hud
        XCTAssertFalse(hud.visible)
        XCTAssertGreaterThan(hud.activation.revision, baselineRevision)
        XCTAssertEqual(hud.activation.stage, .commit)
        XCTAssertEqual(hud.activation.result, .applied)
        XCTAssertTrue(hud.activation.selectionCurrent)
        XCTAssertTrue(hud.activation.bindingCurrent)
        XCTAssertEqual(hud.activation.blockReason, .none)

        let encoded = String(decoding: try JSONEncoder().encode(hud.activation), as: UTF8.self)
        for privateValue in ["w1", "app-a", "private-name", "private-title", "launch-app-a"] {
            XCTAssertFalse(encoded.contains(privateValue), privateValue)
        }
    }

    func testVisibleInventoryUpdateKeepsSemanticOverviewFrozenUntilReopen() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame),
            SemanticFixture.window(id: "w2", appID: "app-b", frame: SemanticFixture.rightFrame),
            SemanticFixture.window(id: "w3", appID: "app-c", frame: SemanticFixture.rightFrame),
        ])
        try await fixture.controller.start()
        fixture.installState(
            screens: [
                FocusScreen(id: "screen-one", number: 1, lifecycle: .background, windowIDs: ["w1", "w2"], lastActiveWindowID: "w2"),
                FocusScreen(id: "screen-two", number: 2, lifecycle: .active, windowIDs: ["w3"], lastActiveWindowID: "w3"),
            ],
            activeScreenID: "screen-two"
        )
        let runtime = FocusScreenSemanticRuntime(controller: fixture.controller, identityHasher: { $0 })
        fixture.controller.openSwitcher()
        let first = runtime.snapshot().hud

        fixture.installState(
            screens: [
                FocusScreen(id: "screen-two", number: 2, lifecycle: .background, windowIDs: ["w3"], lastActiveWindowID: "w3"),
                FocusScreen(id: "screen-one", number: 1, lifecycle: .active, windowIDs: ["w2", "w1"], lastActiveWindowID: "w1"),
            ],
            activeScreenID: "screen-one"
        )
        let whileVisible = runtime.snapshot().hud

        XCTAssertEqual(whileVisible.workspaceSections, first.workspaceSections)
        XCTAssertEqual(whileVisible.appIdentityHashes, first.appIdentityHashes)
        XCTAssertEqual(whileVisible.workspaceAppIdentityHashes, first.workspaceAppIdentityHashes)
        XCTAssertEqual(whileVisible.inspectedScreenID, first.inspectedScreenID)
        XCTAssertEqual(whileVisible.inventoryRevision, first.inventoryRevision)
        XCTAssertEqual(whileVisible.keyAssignmentRevision, first.keyAssignmentRevision)
        XCTAssertEqual(whileVisible.presentationRevision, first.presentationRevision)
        XCTAssertEqual(whileVisible.settledRevision, first.settledRevision)

        fixture.controller.closeSwitcher()
        fixture.controller.openSwitcher()
        defer { fixture.controller.closeSwitcher() }
        let reopened = runtime.snapshot().hud
        XCTAssertEqual(reopened.workspaceSections.map(\.screenID), ["screen-two", "screen-one"])
        XCTAssertEqual(reopened.inspectedScreenID, "screen-one")
        XCTAssertGreaterThan(reopened.presentationRevision, first.presentationRevision)
        XCTAssertEqual(reopened.settledRevision, reopened.presentationRevision)
    }

    func testClosedNonReadyAndUnavailableHUDsDoNotFabricateOverviewSections() async throws {
        let ready = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)
        ])
        let readyRuntime = FocusScreenSemanticRuntime(controller: ready.controller, identityHasher: { $0 })
        let closed = readyRuntime.snapshot().hud
        XCTAssertEqual(closed.layoutMode, .segmented)
        XCTAssertEqual(closed.workspaceSections, [])
        XCTAssertEqual(closed.keyAssignmentRevision, 0)
        XCTAssertEqual(closed.presentationRevision, 0)
        XCTAssertEqual(closed.settledRevision, 0)
        XCTAssertFalse(closed.isKeyWindow)

        let loading = makeOverviewFixture(
            initialWindows: [SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)],
            status: .loading
        )
        loading.controller.openSwitcher()
        defer { loading.controller.closeSwitcher() }
        let nonReady = FocusScreenSemanticRuntime(controller: loading.controller, identityHasher: { $0 }).snapshot().hud
        XCTAssertTrue(nonReady.visible)
        XCTAssertEqual(nonReady.layoutMode, .segmented)
        XCTAssertEqual(nonReady.workspaceSections, [])
        XCTAssertEqual(nonReady.keyAssignmentRevision, 0)
        XCTAssertEqual(nonReady.presentationRevision, 0)
        XCTAssertEqual(nonReady.settledRevision, 0)

        let unavailable = makeOverviewFixture(
            initialWindows: [SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)],
            safeBounds: CanvasRect(x: 0, y: 0, width: 100, height: 100)
        )
        try await unavailable.controller.start()
        unavailable.controller.openSwitcher()
        defer { unavailable.controller.closeSwitcher() }
        let unavailableSnapshot = try XCTUnwrap(unavailable.overviewViewModel?.snapshot)
        XCTAssertNil(unavailableSnapshot.layout.availableLayout)
        let unavailableHUD = FocusScreenSemanticRuntime(controller: unavailable.controller, identityHasher: { $0 }).snapshot().hud
        XCTAssertTrue(unavailableHUD.visible)
        XCTAssertEqual(unavailableHUD.layoutMode, .workspaceOverview)
        XCTAssertEqual(unavailableHUD.workspaceSections.map(\.screenID), ["screen-1"])
        XCTAssertEqual(unavailableHUD.workspaceSections.map(\.appIdentityHashes), [["opaque-a"]])
        XCTAssertEqual(unavailableHUD.workspaceSections.map(\.shortcutCount), [1])
        XCTAssertEqual(unavailableHUD.workspaceSections.map(\.rowCount), [0])
        XCTAssertEqual(unavailableHUD.presentationRevision, unavailableSnapshot.presentationRevision)
        XCTAssertEqual(unavailableHUD.settledRevision, unavailableSnapshot.presentationRevision)
    }

    // MARK: - hud.key

    func testHUDKeyRequiresOpenOverlayAndAcceptedKey() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(fixture: fixture, executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]))

        // Without opening the HUD first, hud.key must fail.
        let closedKey = await server.handle(jsonLine: #"{"command":"hud.key","token":"v3-secret","key":"down"}"#)
        XCTAssertFalse(closedKey.ok)
        XCTAssertEqual(closedKey.error?.code, .panelNotOpen)
        XCTAssertNil(closedKey.snapshot)

        _ = await server.handle(jsonLine: #"{"command":"hud.open","token":"v3-secret"}"#)

        let unknownKey = await server.handle(jsonLine: #"{"command":"hud.key","token":"v3-secret","key":"summon_demons"}"#)
        XCTAssertFalse(unknownKey.ok)
        XCTAssertEqual(unknownKey.error?.code, .invalidRequest)

        let validKey = await server.handle(jsonLine: #"{"command":"hud.key","token":"v3-secret","key":"down"}"#)
        XCTAssertTrue(validKey.ok)
        XCTAssertEqual(validKey.command, "hud.key")
    }

    func testHUDKeyUsesPhysicalShortcutGrammarAndRejectsLegacyCommands() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(
            fixture: fixture,
            executionPolicy: ExecutionPolicy(
                mode: .execute,
                environment: ["CS_DIAG_ALLOW_INPUT": "1"]
            )
        )
        _ = await server.handle(jsonLine: #"{"command":"hud.open","token":"v3-secret"}"#)

        for key in ["a", "shift+a", "0", "shift+0", "left", "right", "up", "down", "return", "escape", "tab"] {
            let response = await server.handle(
                jsonLine: #"{"command":"hud.key","token":"v3-secret","key":"\#(key)"}"#
            )
            XCTAssertTrue(response.ok, key)
        }
        for key in [")", "A", "shift+)", "previousPage", "previous_page", "nextPage", "next_page", "enter"] {
            let response = await server.handle(
                jsonLine: #"{"command":"hud.key","token":"v3-secret","key":"\#(key)"}"#
            )
            XCTAssertFalse(response.ok, key)
            XCTAssertEqual(response.error?.code, .invalidRequest, key)
        }
    }

    // MARK: - Real loopback binding (Fix 1)

    /// The v3 server must bind a real localhost NWListener (not just expose
    /// `handle(jsonLine:)`), so the scenario client (Task 11) can reach it over
    /// Network.framework. Mirrors the v2 server's loopback test.
    func testV3ServerBindsLoopbackAndServesAuthenticatedJSONLine() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "screen-switcher-v3-loopback-\(UUID().uuidString)",
                isDirectory: true
            )
        let metadataURL = directory.appendingPathComponent("focus-runtime.json")
        let server = SemanticFocusScreenServer(
            runtime: makeRuntime(fixture: fixture),
            mode: .devTest,
            token: token,
            executionPolicy: ExecutionPolicy(mode: .dryRun),
            metadataURL: metadataURL
        )
        let metadata = try await server.start()
        defer { server.stop() }

        XCTAssertGreaterThan(metadata.port, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: metadata.port)!
            ),
            using: .tcp
        )
        let responseData = try await sendAndReceiveJSONLine(
            connection: connection,
            request: Data(
                "{\"command\":\"screen.snapshot\",\"token\":\"\(token)\"}\n".utf8
            )
        )
        let response = try JSONDecoder().decode(FocusScreenSemanticResponse.self, from: responseData)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.command, "screen.snapshot")
        XCTAssertEqual(response.schemaVersion, 3)
        XCTAssertNotNil(response.snapshot)
        // Content-free contract holds over the wire: no raw token leaks.
        XCTAssertFalse(String(decoding: responseData, as: UTF8.self).contains(token))
        connection.cancel()
    }

    /// `start()` must throw `productionDisabled` in production mode and never
    /// bind a socket — the dev-test gate keeps packaged production inert.
    func testV3ServerStartThrowsInProductionMode() async throws {
        let fixture = makeFixture(initialWindows: [])
        let server = SemanticFocusScreenServer(
            runtime: makeRuntime(fixture: fixture),
            mode: .productionDisabled,
            token: token
        )
        do {
            _ = try await server.start()
            XCTFail("start() should throw productionDisabled in production mode")
        } catch {
            XCTAssertEqual(error as? SemanticAdapterServerError, .productionDisabled)
        }
    }

    private func sendAndReceiveJSONLine(
        connection: NWConnection,
        request: Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: request,
                        completion: .contentProcessed { error in
                            if let error {
                                finish(.failure(error))
                                return
                            }
                            connection.receive(
                                minimumIncompleteLength: 1,
                                maximumLength: 64 * 1024
                            ) { data, _, _, error in
                                if let error {
                                    finish(.failure(error))
                                } else if let data {
                                    finish(.success(data))
                                } else {
                                    finish(.failure(SemanticAdapterServerError.listenerFailed))
                                }
                            }
                        }
                    )
                case let .failed(error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(SemanticAdapterServerError.listenerFailed))
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    // MARK: - screen mutation commands

    func testScreenCreateRequiresExecutionAuthorization() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])

        // Dry-run policy: mutation must be rejected.
        let dryRunServer = makeServer(fixture: fixture, executionPolicy: ExecutionPolicy(mode: .dryRun))
        let rejected = await dryRunServer.handle(
            jsonLine: #"{"command":"screen.create","token":"v3-secret","screenID":"screen-2"}"#
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.error?.code, .executeNotAllowed)

        // Execute policy: mutation is accepted.
        let executeServer = makeServer(fixture: fixture, executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]))
        let accepted = await executeServer.handle(
            jsonLine: #"{"command":"screen.create","token":"v3-secret","screenID":"screen-2"}"#
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(accepted.command, "screen.create")
        XCTAssertNotNil(accepted.snapshot)
    }

    func testScreenSwitchRequiresWindowIDAndExecuteAuthorization() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame),
            SemanticFixture.window(id: "w2", appID: "com.private.beta", frame: SemanticFixture.rightFrame)
        ])
        let server = makeServer(fixture: fixture, executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]))
        // Start the controller so the observation service populates the AX
        // bindings the switch transaction requires.
        try await fixture.controller.start()

        // Stage a two-screen topology: screen-1 (active) owns w1; screen-2
        // (background) owns w2. We build this via the controller's test seam
        // because the Phase 1A reducer does not expose a single transition that
        // moves a window to a background screen.
        let staged = FocusScreenState(
            screens: [
                FocusScreen(id: "screen-1", number: 1, lifecycle: .active, windowIDs: ["w1"], lastActiveWindowID: "w1"),
                FocusScreen(id: "screen-2", number: 2, lifecycle: .background, windowIDs: ["w2"], lastActiveWindowID: "w2")
            ],
            windows: fixture.controller.state.windows,
            activeScreenID: "screen-1",
            inspectedScreenID: "screen-1",
            revision: fixture.controller.state.revision + 1
        )
        fixture.controller.setStateForTest(staged)

        let missingWindow = await server.handle(
            jsonLine: #"{"command":"screen.switch","token":"v3-secret","screenID":"screen-2"}"#
        )
        XCTAssertFalse(missingWindow.ok)
        XCTAssertEqual(missingWindow.error?.code, .invalidRequest)

        let switched = await server.handle(
            jsonLine: #"{"command":"screen.switch","token":"v3-secret","screenID":"screen-2","windowID":"w2"}"#
        )
        XCTAssertTrue(switched.ok)
        XCTAssertEqual(switched.command, "screen.switch")
    }

    func testScreenCloseRequiresExecutionAuthorization() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(fixture: fixture, executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]))
        _ = await server.handle(jsonLine: #"{"command":"screen.create","token":"v3-secret","screenID":"screen-2"}"#)

        let closed = await server.handle(
            jsonLine: #"{"command":"screen.close","token":"v3-secret","screenID":"screen-2"}"#
        )
        XCTAssertTrue(closed.ok)
        XCTAssertEqual(closed.command, "screen.close")
        XCTAssertNil(fixture.controller.state.screen(id: "screen-2"))
    }

    func testOwnedScreenCloseAtomicallyPreservesSameIDReplacement() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(
            fixture: fixture,
            executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"])
        )
        _ = await server.handle(
            jsonLine: #"{"command":"screen.create","token":"v3-secret","screenID":"screen-2"}"#
        )
        let expected = try XCTUnwrap(
            makeRuntime(fixture: fixture).snapshot().screens.first(where: { $0.id == "screen-2" })
        )
        let replacement = FocusScreen(
            id: "screen-2",
            number: expected.number + 1,
            lifecycle: .active
        )
        fixture.controller.setStateForTest(FocusScreenState(
            screens: [
                FocusScreen(id: "screen-1", number: 1, lifecycle: .background, windowIDs: ["w1"], lastActiveWindowID: "w1"),
                replacement,
            ],
            windows: fixture.controller.state.windows,
            activeScreenID: replacement.id,
            inspectedScreenID: replacement.id,
            revision: fixture.controller.state.revision + 1
        ))
        let response = await server.handle(jsonLine: try ownedScreenCloseRequest(expected))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code.rawValue, "screen_ownership_lost")
        XCTAssertEqual(fixture.controller.state.screen(id: replacement.id), replacement)
    }

    func testOwnedScreenCloseReportsClosedNotFoundAndFailedOutcomes() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(
            fixture: fixture,
            executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"])
        )
        _ = await server.handle(
            jsonLine: #"{"command":"screen.create","token":"v3-secret","screenID":"screen-2"}"#
        )
        let expected = try XCTUnwrap(
            makeRuntime(fixture: fixture).snapshot().screens.first(where: { $0.id == "screen-2" })
        )

        let closed = await server.handle(jsonLine: try ownedScreenCloseRequest(expected))
        XCTAssertTrue(closed.ok)
        XCTAssertNil(fixture.controller.state.screen(id: expected.id))

        let notFound = await server.handle(jsonLine: try ownedScreenCloseRequest(expected))
        XCTAssertEqual(notFound.error?.code.rawValue, "screen_not_found")

        let soleFixture = makeFixture(initialWindows: [])
        let soleServer = makeServer(
            fixture: soleFixture,
            executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"])
        )
        let sole = try XCTUnwrap(makeRuntime(fixture: soleFixture).snapshot().screens.first)
        let failed = await soleServer.handle(jsonLine: try ownedScreenCloseRequest(sole))
        XCTAssertEqual(failed.error?.code, .runtimeFailure)
        XCTAssertNotNil(soleFixture.controller.state.screen(id: sole.id))
    }

    func testOwnedScreenCloseRejectsNonEmptyFingerprintAtPrivateBoundary() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(
            fixture: fixture,
            executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"])
        )
        let expected = try XCTUnwrap(makeRuntime(fixture: fixture).snapshot().screens.first)

        let response = await server.handle(jsonLine: try ownedScreenCloseRequest(expected))

        XCTAssertEqual(response.error?.code, .invalidRequest)
        XCTAssertNotNil(fixture.controller.state.screen(id: expected.id))
    }

    func testOwnedScreenCloseRejectsMissingForeignDuplicateAndWrongTypedFingerprint() async {
        let fixture = makeFixture(initialWindows: [])
        let server = makeServer(
            fixture: fixture,
            executionPolicy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"])
        )
        for request in [
            #"{"command":"screen.close-owned","token":"v3-secret"}"#,
            #"{"command":"screen.close-owned","token":"v3-secret","expectedScreen":{},"screenID":"screen-1"}"#,
            #"{"command":"screen.close-owned","token":"v3-secret","expectedScreen":{},"expectedScreen":{}}"#,
            #"{"command":"screen.close-owned","token":"v3-secret","expectedScreen":"screen-1"}"#,
        ] {
            let response = await server.handle(jsonLine: request)
            XCTAssertEqual(response.error?.code, .invalidRequest, request)
            XCTAssertNotNil(fixture.controller.state.screen(id: "screen-1"), request)
        }
    }

    // MARK: - Legacy command rejection

    func testWorkspaceCommandsAreRejectedAsUnknown() async {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(fixture: fixture)

        for legacy in [
            "workspace.snapshot",
            "workspace.open",
            "workspace.close",
            "workspace.key",
            "workspace.gesture",
            "workspace.executeDryRun"
        ] {
            let response = await server.handle(
                jsonLine: #"{"command":"\#(legacy)","token":"v3-secret"}"#
            )
            XCTAssertFalse(response.ok, legacy)
            XCTAssertEqual(response.error?.code, .unknownCommand, legacy)
            XCTAssertEqual(response.schemaVersion, 3, legacy)
        }
    }

    func testLegacyPanelCommandsAreRejectedAsUnknown() async {
        let fixture = makeFixture(initialWindows: [])
        let server = makeServer(fixture: fixture)

        for legacy in ["status", "snapshot", "openPanel", "select", "executeSelected", "permissionState", "closePanel"] {
            let response = await server.handle(
                jsonLine: #"{"command":"\#(legacy)","token":"v3-secret"}"#
            )
            XCTAssertEqual(response.error?.code, .unknownCommand, legacy)
        }
    }

    // MARK: - Auth gating

    func testMissingTokenInvalidTokenAndProductionDisabledAreTyped() async {
        let fixture = makeFixture(initialWindows: [])
        let server = makeServer(fixture: fixture)

        let missing = await server.handle(jsonLine: #"{"command":"screen.snapshot"}"#)
        XCTAssertEqual(missing.error?.code, .missingToken)

        let invalid = await server.handle(jsonLine: #"{"command":"screen.snapshot","token":"wrong"}"#)
        XCTAssertEqual(invalid.error?.code, .invalidToken)

        let malformed = await server.handle(jsonLine: "not-json")
        XCTAssertEqual(malformed.error?.code, .invalidRequest)

        let productionServer = SemanticFocusScreenServer(
            runtime: makeRuntime(fixture: fixture),
            mode: .productionDisabled,
            token: token
        )
        let production = await productionServer.handle(
            jsonLine: #"{"command":"screen.snapshot","token":"v3-secret"}"#
        )
        XCTAssertEqual(production.error?.code, .productionDisabled)
    }

    // MARK: - Content-free snapshot

    func testSnapshotContainsNoTitlePathTokenPidOrRawBundleID() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.sensitive.app", frame: SemanticFixture.leftFrame),
            SemanticFixture.window(id: "w2", appID: "com.another.private.bundle", frame: SemanticFixture.rightFrame)
        ])
        let server = makeServer(fixture: fixture)

        let response = await server.handle(jsonLine: #"{"command":"screen.snapshot","token":"v3-secret"}"#)
        let snapshot = try XCTUnwrap(response.snapshot)
        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertEqual(snapshot.spaces, [])

        // Every window identity must be hashed, never the raw bundle id.
        for window in snapshot.windows {
            XCTAssertTrue(window.appIdentityHash.hasPrefix("bundle:"), "window identity must be hashed: \(window.appIdentityHash)")
            XCTAssertFalse(window.appIdentityHash.contains("com.private"), "raw bundle id leaked: \(window.appIdentityHash)")
            XCTAssertFalse(window.appIdentityHash.contains("com.another"), "raw bundle id leaked: \(window.appIdentityHash)")
        }

        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)
        let forbidden = [
            "com.private.sensitive.app",
            "com.another.private.bundle",
            "Sensitive",
            "title",
            "/Users/",
            token,
            "v3-secret",
            "pid",
            "processIdentifier"
        ]
        for term in forbidden {
            XCTAssertFalse(text.contains(term), "forbidden content in v3 snapshot: \(term)")
        }
    }

    func testResponseEnvelopeContainsOnlyV3Keys() async throws {
        let fixture = makeFixture(initialWindows: [])
        let server = makeServer(fixture: fixture)

        let response = await server.handle(jsonLine: #"{"command":"screen.snapshot","token":"v3-secret"}"#)
        let encoded = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let allowedKeys: Set<String> = ["schemaVersion", "ok", "command", "snapshot", "error"]
        XCTAssertTrue(Set(object.keys).isSubset(of: allowedKeys), "unexpected keys: \(object.keys)")
        XCTAssertNotNil(response.snapshot)

        let errorResponse = await server.handle(jsonLine: #"{"command":"workspace.snapshot","token":"v3-secret"}"#)
        let errorEncoded = try JSONEncoder().encode(errorResponse)
        let errorObject = try XCTUnwrap(JSONSerialization.jsonObject(with: errorEncoded) as? [String: Any])
        XCTAssertTrue(Set(errorObject.keys).isSubset(of: allowedKeys), "unexpected keys: \(errorObject.keys)")
        XCTAssertNil(errorResponse.snapshot)
        XCTAssertNotNil(errorResponse.error)
    }

    func testSnapshotReflectsHUDOpenClose() async throws {
        let fixture = makeFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        let server = makeServer(fixture: fixture)

        let closedResponse = await server.handle(jsonLine: #"{"command":"screen.snapshot","token":"v3-secret"}"#)
        let closed = try XCTUnwrap(closedResponse.snapshot)
        XCTAssertFalse(closed.hud.visible)

        _ = await server.handle(jsonLine: #"{"command":"hud.open","token":"v3-secret"}"#)
        let openedResponse = await server.handle(jsonLine: #"{"command":"screen.snapshot","token":"v3-secret"}"#)
        let opened = try XCTUnwrap(openedResponse.snapshot)
        XCTAssertTrue(opened.hud.visible)

        _ = await server.handle(jsonLine: #"{"command":"hud.close","token":"v3-secret"}"#)
        let reclosedResponse = await server.handle(jsonLine: #"{"command":"screen.snapshot","token":"v3-secret"}"#)
        let reclosed = try XCTUnwrap(reclosedResponse.snapshot)
        XCTAssertFalse(reclosed.hud.visible)
    }

    func testHUDOpenReturnsAtomicOwnershipSnapshotAndRejectsAlreadyOpenPresentation() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "com.private.alpha", frame: SemanticFixture.leftFrame)
        ])
        try await fixture.controller.start()
        let server = makeServer(fixture: fixture)

        let opened = await server.handle(jsonLine: #"{"command":"hud.open","token":"v3-secret"}"#)
        XCTAssertTrue(opened.ok)
        XCTAssertTrue(try XCTUnwrap(opened.snapshot).hud.visible)
        XCTAssertGreaterThan(try XCTUnwrap(opened.snapshot).hud.presentationRevision, 0)

        let alreadyOpen = await server.handle(jsonLine: #"{"command":"hud.open","token":"v3-secret"}"#)
        XCTAssertFalse(alreadyOpen.ok)
        XCTAssertEqual(alreadyOpen.error?.code, .panelAlreadyOpen)
        XCTAssertNil(alreadyOpen.snapshot)
    }

    func testHUDOpenRejectsForeignDuplicateMissingAndWrongTypedFieldsWithoutOpening() async throws {
        let invalidRequests: [(String, SemanticAdapterErrorCode)] = [
            (#"{"command":"hud.open","token":"v3-secret","key":"right"}"#, .invalidRequest),
            (#"{"command":"hud.open","token":"v3-secret","screenID":"screen-1"}"#, .invalidRequest),
            (#"{"command":"hud.open","command":"hud.open","token":"v3-secret"}"#, .invalidRequest),
            (#"{"command":"hud.open","token":"v3-secret","token":"v3-secret"}"#, .invalidRequest),
            (#"{"command":1,"token":"v3-secret"}"#, .invalidRequest),
            (#"{"command":"hud.open","token":1}"#, .invalidRequest),
            (#"{"token":"v3-secret"}"#, .invalidRequest),
            (#"{"command":"hud.open"}"#, .missingToken),
        ]

        for (request, expectedCode) in invalidRequests {
            let fixture = makeOverviewFixture(initialWindows: [
                SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)
            ])
            try await fixture.controller.start()
            let response = await makeServer(fixture: fixture).handle(jsonLine: request)

            XCTAssertFalse(response.ok, request)
            XCTAssertEqual(response.error?.code, expectedCode, request)
            XCTAssertFalse(fixture.controller.isHUDVisible, request)
        }
    }

    func testOwnedHUDCloseIsAtomicAndNeverClosesAReplacementPresentation() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)
        ])
        try await fixture.controller.start()
        let server = makeServer(fixture: fixture)
        let opened = await server.handle(jsonLine: #"{"command":"hud.open","token":"v3-secret"}"#)
        let ownedRevision = try XCTUnwrap(opened.snapshot).hud.presentationRevision

        let missingRevision = await server.handle(
            jsonLine: #"{"command":"hud.close-owned","token":"v3-secret"}"#
        )
        XCTAssertFalse(missingRevision.ok)
        XCTAssertEqual(missingRevision.error?.code, .invalidRequest)
        XCTAssertTrue(fixture.controller.isHUDVisible)

        let mismatch = await server.handle(
            jsonLine: #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":\#(ownedRevision + 1)}"#
        )
        XCTAssertFalse(mismatch.ok)
        XCTAssertEqual(mismatch.error?.code, .panelOwnershipLost)
        XCTAssertTrue(fixture.controller.isHUDVisible)

        let closed = await server.handle(
            jsonLine: #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":\#(ownedRevision)}"#
        )
        XCTAssertTrue(closed.ok)
        XCTAssertFalse(try XCTUnwrap(closed.snapshot).hud.visible)

        let missingWhileClosed = await server.handle(
            jsonLine: #"{"command":"hud.close-owned","token":"v3-secret"}"#
        )
        XCTAssertFalse(missingWhileClosed.ok)
        XCTAssertEqual(missingWhileClosed.error?.code, .invalidRequest)

        let alreadyClosed = await server.handle(
            jsonLine: #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":\#(ownedRevision)}"#
        )
        XCTAssertFalse(alreadyClosed.ok)
        XCTAssertEqual(alreadyClosed.error?.code, .panelAlreadyClosed)
    }

    func testOwnedHUDCloseRejectsForeignDuplicateAndWrongTypedFieldsWithoutClosing() async throws {
        let fixture = makeOverviewFixture(initialWindows: [
            SemanticFixture.window(id: "w1", appID: "app-a", frame: SemanticFixture.leftFrame)
        ])
        try await fixture.controller.start()
        let server = makeServer(fixture: fixture)
        let opened = await server.handle(jsonLine: #"{"command":"hud.open","token":"v3-secret"}"#)
        let ownedRevision = try XCTUnwrap(opened.snapshot).hud.presentationRevision

        let invalidRequests = [
            #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":\#(ownedRevision),"screenID":"screen-1"}"#,
            #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":\#(ownedRevision),"key":"right"}"#,
            #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":\#(ownedRevision),"ratioPrimary":0.5}"#,
            #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":\#(ownedRevision),"expectedPresentationRevision":\#(ownedRevision)}"#,
            #"{"command":"hud.close-owned","token":"v3-secret","expectedPresentationRevision":"\#(ownedRevision)"}"#,
        ]
        for request in invalidRequests {
            let response = await server.handle(jsonLine: request)
            XCTAssertFalse(response.ok, request)
            XCTAssertEqual(response.error?.code, .invalidRequest, request)
            XCTAssertTrue(fixture.controller.isHUDVisible, request)
        }
    }

    // MARK: - Helpers

    private func makeServer(
        fixture: SemanticFixture,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(mode: .dryRun)
    ) -> SemanticFocusScreenServer {
        SemanticFocusScreenServer(
            runtime: makeRuntime(fixture: fixture),
            mode: .devTest,
            token: token,
            executionPolicy: executionPolicy
        )
    }

    private func makeRuntime(fixture: SemanticFixture) -> FocusScreenSemanticRuntime {
        FocusScreenSemanticRuntime(controller: fixture.controller)
    }

    private func makeFixture(initialWindows: [ObservedWindow]) -> SemanticFixture {
        SemanticFixture(initialWindows: initialWindows)
    }

    private func makeOverviewFixture(
        initialWindows: [ObservedWindow],
        status: FocusHUDWindowDiscoveryStatus = .ready,
        safeBounds: CanvasRect = CanvasRect(x: 0, y: 0, width: 2000, height: 1000),
        panelKeyWindowReader: @escaping @MainActor (NSPanel) -> Bool = { $0.isKeyWindow }
    ) -> SemanticFixture {
        SemanticFixture(
            initialWindows: initialWindows,
            overviewStatus: status,
            hudSafeBounds: safeBounds,
            panelKeyWindowReader: panelKeyWindowReader
        )
    }

    private func commandValue(_ request: String) -> String {
        // Extract the "command" field value from a single-line JSON request.
        guard let openRange = request.range(of: "\"command\":\""),
              let closeRange = request.range(of: "\"", range: openRange.upperBound..<request.endIndex)
        else {
            return ""
        }
        return String(request[openRange.upperBound..<closeRange.lowerBound])
    }

    private func ownedScreenCloseRequest(_ expected: FocusSemanticScreen) throws -> String {
        let expectedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        let data = try JSONSerialization.data(withJSONObject: [
            "command": "screen.close-owned",
            "token": token,
            "expectedScreen": expectedObject,
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Test fixture

@MainActor
private final class SemanticFixture {
    let controller: FocusScreenController
    let observation: RecordingWindowObservationService
    let commandService: FocusScreenCommandService
    let pointer: RecordingPointerEndpoint
    let overviewViewModel: FocusHUDViewModel?

    init(
        initialWindows: [ObservedWindow],
        overviewStatus: FocusHUDWindowDiscoveryStatus? = nil,
        hudSafeBounds: CanvasRect = CanvasRect(x: 0, y: 0, width: 2000, height: 1000),
        panelKeyWindowReader: @escaping @MainActor (NSPanel) -> Bool = { $0.isKeyWindow }
    ) {
        observation = RecordingWindowObservationService(initial: initialWindows)
        commandService = FocusScreenCommandService(
            initialSnapshots: Dictionary(uniqueKeysWithValues: initialWindows.map {
                ($0.id, WindowCommandSnapshot(frame: $0.frame, isMinimized: $0.isMinimized, isFocused: $0.isFocused))
            })
        )
        pointer = RecordingPointerEndpoint()
        pointer.location = Self.leftRegionCenter
        let managed = initialWindows.map { window in
            ManagedWindow(
                id: window.id,
                appID: window.appID,
                canonicalFrame: window.frame,
                isCompatible: window.isSettable
            )
        }
        let seededState = (try? FocusScreenReducer.bootstrap(currentWindows: managed, id: "screen-1"))
            ?? FocusScreenState(
                screens: [FocusScreen(id: "screen-1", number: 1, lifecycle: .active)],
                windows: [:],
                activeScreenID: "screen-1",
                inspectedScreenID: "screen-1",
                revision: 1
            )
        let hudController: any FocusHUDControlling
        if let overviewStatus {
            let viewModel = FocusHUDViewModel(
                state: seededState,
                metadataProvider: SemanticWindowMetadataProvider(),
                intentHandler: { _ in },
                appIdentityHasher: {
                    ["app-a": "opaque-a", "app-b": "opaque-b", "app-c": "opaque-c"][$0]
                        ?? "opaque-other"
                }
            )
            viewModel.setWindowDiscoveryStatus(overviewStatus)
            overviewViewModel = viewModel
            hudController = FocusHUDController(
                viewModel: viewModel,
                shiftedDigitSymbolsProvider: { Array(")!@#$%^&*(") },
                panelKeyWindowReader: panelKeyWindowReader
            )
        } else {
            overviewViewModel = nil
            hudController = RecordingFocusHUDController()
        }
        controller = FocusScreenController(
            observationService: observation,
            commandService: commandService,
            pointerLocation: { [pointer] in pointer.location },
            pointerMove: { [pointer] point in
                pointer.location = point
                pointer.moves += 1
                return true
            },
            canvasProvider: { Self.canvas },
            hudSafeBoundsProvider: { hudSafeBounds },
            regionsProvider: { Self.regions },
            hudController: hudController,
            commandTimeout: 1.0
        )
        // Bootstrap synchronously so screen.snapshot has real state without
        // awaiting start(). We seed state directly via the test seam to avoid
        // the live AX observation dependency.
        controller.setStateForTest(seededState)
    }

    func installState(screens: [FocusScreen], activeScreenID: FocusScreenID) {
        let next = FocusScreenState(
            screens: screens,
            windows: controller.state.windows,
            activeScreenID: activeScreenID,
            inspectedScreenID: activeScreenID,
            revision: controller.state.revision + 1
        )
        controller.setStateForTest(next)
        overviewViewModel?.update(state: next)
    }

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
        isMinimized: Bool = false
    ) -> ObservedWindow {
        ObservedWindow(
            id: id,
            appID: appID,
            appName: appID,
            title: id,
            frame: frame,
            isFocused: isFocused,
            isMinimized: isMinimized,
            isSettable: true,
            binding: WindowRuntimeBinding(
                launchGeneration: "launch-\(appID)",
                processIdentifier: pid_t(abs(appID.hashValue) % 30_000 + 500),
                element: .injected(id)
            )
        )
    }
}

@MainActor
private final class SemanticWindowMetadataProvider: FocusHUDWindowMetadataProviding {
    func metadata(for window: ManagedWindow) -> FocusHUDWindowMetadata {
        FocusHUDWindowMetadata(appName: "private-name", appIcon: nil, windowTitle: "private-title")
    }
}

// MARK: - Test fakes (file-private; mirror the FocusScreenControllerTests fakes)

@MainActor
private final class RecordingPointerEndpoint {
    var location: CanvasPoint?
    var moves = 0
}

@MainActor
private final class FocusScreenCommandService: WindowCommandService {
    private var states: [ManagedWindowID: WindowCommandSnapshot]

    init(initialSnapshots: [ManagedWindowID: WindowCommandSnapshot]) {
        states = initialSnapshots
    }

    func register(_ windowID: ManagedWindowID, frame: CanvasRect, isMinimized: Bool = false, isFocused: Bool = false) {
        states[windowID] = WindowCommandSnapshot(frame: frame, isMinimized: isMinimized, isFocused: isFocused)
    }

    private func key(for binding: WindowRuntimeBinding) -> ManagedWindowID? {
        guard case let .injected(key) = binding.axElement else { return nil }
        return key
    }

    func setFrame(_ frame: CanvasRect, for binding: WindowRuntimeBinding, timeout: TimeInterval) async -> WindowCommandResult {
        guard let key = key(for: binding), var current = states[key] else { return .vanished }
        current = WindowCommandSnapshot(frame: frame, isMinimized: current.isMinimized, isFocused: current.isFocused)
        states[key] = current
        return .applied
    }

    func raiseAndFocus(_ binding: WindowRuntimeBinding, timeout: TimeInterval) async -> WindowCommandResult {
        guard let key = key(for: binding), var current = states[key] else { return .vanished }
        current = WindowCommandSnapshot(frame: current.frame, isMinimized: current.isMinimized, isFocused: true)
        states[key] = current
        return .applied
    }

    func setMinimized(_ minimized: Bool, for binding: WindowRuntimeBinding, timeout: TimeInterval) async -> WindowCommandResult {
        guard let key = key(for: binding), var current = states[key] else { return .vanished }
        current = WindowCommandSnapshot(frame: current.frame, isMinimized: minimized, isFocused: current.isFocused)
        states[key] = current
        return .applied
    }

    func close(_ binding: WindowRuntimeBinding, timeout: TimeInterval) async -> WindowCommandResult {
        return .applied
    }

    func snapshot(_ binding: WindowRuntimeBinding, timeout: TimeInterval) async -> WindowCommandSnapshot? {
        guard let key = key(for: binding) else { return nil }
        return states[key]
    }
}

@MainActor
private final class RecordingWindowObservationService: WindowObservationService {
    private let initial: [ObservedWindow]
    private var handler: (@MainActor (ObservedWindowEvent) -> Void)?

    init(initial: [ObservedWindow]) {
        self.initial = initial
    }

    func initialSnapshot() async throws -> [ObservedWindow] { initial }

    func start(_ handler: @escaping @MainActor (ObservedWindowEvent) -> Void) throws {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }
}

@MainActor
private final class RecordingFocusHUDController: FocusHUDControlling {
    private(set) var isAttached = false
    private(set) var isPresented = false
    private(set) var refreshCount = 0

    func attach() { isAttached = true }
    func refresh(state: FocusScreenState) { refreshCount += 1 }
    func present(
        inventoryRevision: UInt64,
        safeBounds: CanvasRect
    ) -> Result<Void, FocusHUDControllerPresentationError> {
        isPresented = true
        return .success(())
    }
    func close() { isPresented = false }
    func setIntentHandler(_ handler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void) {}
    func setWindowDiscoveryStatus(_ status: FocusHUDWindowDiscoveryStatus) {}
    func rebuildSnapshotIfNeeded(inventoryRevision: UInt64, safeBounds: CanvasRect) {}
    func setDismissesOnModifierRelease(_ value: Bool) {}
    func advanceFocusToNext() {}
    func activateFocusedApp() {}
    func focusWindow(_ windowID: ManagedWindowID) {}
    var focusedWindowID: ManagedWindowID? { nil }
}
