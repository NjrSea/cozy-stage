import Foundation
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class Stage1SemanticAdapterTests: XCTestCase {
    func testWorkspaceAllowlistReturnsSchemaVersionTwoForSuccessAndFailure() async {
        let runtime = Stage1FixtureRuntime()
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")

        let commands = [
            #"{"command":"workspace.snapshot","token":"secret"}"#,
            #"{"command":"workspace.open","token":"secret","tab":"switch"}"#,
            #"{"command":"workspace.key","token":"secret","key":"next_app_page"}"#,
            #"{"command":"workspace.gesture","token":"secret","gesture":{"id":41,"phase":"began","deltaX":0,"deltaY":0,"velocityX":0,"velocityY":0}}"#,
            #"{"command":"workspace.gesture","token":"secret","gesture":{"id":41,"phase":"changed","deltaX":-640,"deltaY":0,"velocityX":-900,"velocityY":0}}"#,
            #"{"command":"workspace.gesture","token":"secret","gesture":{"id":41,"phase":"ended","deltaX":-640,"deltaY":0,"velocityX":-900,"velocityY":0}}"#,
            #"{"command":"workspace.key","token":"secret","key":"app_a"}"#,
            #"{"command":"workspace.executeDryRun","token":"secret"}"#,
            #"{"command":"workspace.close","token":"secret"}"#
        ]
        for request in commands {
            let response = await server.handle(jsonLine: request)
            XCTAssertEqual(response.schemaVersion, 2)
            XCTAssertTrue(response.ok, request)
        }

        for legacy in ["status", "snapshot", "openPanel", "select", "executeSelected", "permissionState", "closePanel"] {
            let response = await server.handle(
                jsonLine: #"{"command":"\#(legacy)","token":"secret"}"#
            )
            XCTAssertEqual(response.schemaVersion, 2)
            XCTAssertEqual(response.error?.code, .unknownCommand)
        }
        XCTAssertEqual(runtime.realInputCount, 0)
        XCTAssertEqual(runtime.dryRunCount, 1)
    }

    func testAppLetterSelectsSanitizedTargetAndDryRunConfirmsWithoutRealInput() async throws {
        let runtime = Stage1FixtureRuntime()
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")
        _ = await server.handle(
            jsonLine: #"{"command":"workspace.open","token":"secret","tab":"switch"}"#
        )

        let selected = await server.handle(
            jsonLine: #"{"command":"workspace.key","token":"secret","key":"app_a"}"#
        )
        let executed = await server.handle(
            jsonLine: #"{"command":"workspace.executeDryRun","token":"secret"}"#
        )

        let selectedSnapshot = try XCTUnwrap(selected.state?.workspace)
        XCTAssertEqual(selectedSnapshot.selectedTargetKind, "app")
        XCTAssertTrue(try XCTUnwrap(selectedSnapshot.selectedTargetIdentity).hasPrefix("bundle:"))
        XCTAssertFalse(selectedSnapshot.dryRunSelectionConfirmed)
        XCTAssertTrue(try XCTUnwrap(executed.state?.workspace).dryRunSelectionConfirmed)
        XCTAssertEqual(runtime.realInputCount, 0)
        XCTAssertEqual(runtime.dryRunCount, 1)
    }

    func testSemanticAppIdentityMatchesProductAXIdentifierWithoutRawBundleID() async throws {
        let runtime = Stage1FixtureRuntime()
        let snapshot = runtime.snapshot()
        let rawBundleID = try XCTUnwrap(snapshot.runningApps.first?.id)
        let presentation = SwitchTabPresentation(
            content: SwitchWorkspaceContent(
                workspaces: snapshot.workspaces,
                selectedDisplayID: snapshot.workspaces.first?.display.id
            ),
            iconProvider: Stage1MissingIconProvider()
        )
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")

        let response = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"secret"}"#
        )

        let semanticIdentity = try XCTUnwrap(response.state?.workspace?.appBundleIdentities.first)
        let appAXIdentifier = try XCTUnwrap(presentation.selectedApps.first?.accessibilityIdentifier)
        XCTAssertEqual(
            appAXIdentifier,
            "screen-switcher.workspace.switch.app.\(semanticIdentity)",
            "Semantic lookup and the rendered App control must share one opaque identity"
        )
        XCTAssertFalse(appAXIdentifier.contains(rawBundleID))
        XCTAssertTrue(semanticIdentity.hasPrefix("bundle:"))
    }

    func testWorkspaceSnapshotContainsRequiredSanitizedFieldsOnly() async throws {
        let runtime = Stage1FixtureRuntime()
        runtime.selectedItemID = "com.private.selected"
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")
        _ = await server.handle(
            jsonLine: #"{"command":"workspace.open","token":"secret","tab":"agents"}"#
        )
        let response = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"secret"}"#
        )

        let snapshot = try XCTUnwrap(response.state?.workspace)
        XCTAssertNil(response.state?.selectedItemID)
        XCTAssertEqual(snapshot.currentTab, "agents")
        XCTAssertEqual(snapshot.overlayDisplayID, "display-2")
        XCTAssertEqual(snapshot.pointerDisplayID, "display-2")
        XCTAssertEqual(snapshot.targetDisplayID, "display-2")
        XCTAssertNotNil(snapshot.focusedAppBundleIdentity)
        XCTAssertEqual(snapshot.dimmedDisplayIDs, ["display-1"])
        XCTAssertEqual(snapshot.overlayFrame.width, 1_920)
        XCTAssertEqual(snapshot.gesturePhase, "idle")
        XCTAssertTrue(snapshot.reducedMotion)
        XCTAssertEqual(snapshot.previewAvailability, "available")
        XCTAssertEqual(snapshot.appPage, 1)
        XCTAssertEqual(snapshot.appBundleIdentities.count, 2)

        let encoded = try JSONEncoder().encode(response)
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in [
            "Private App", "Window title", "/Users/example", "raw-image", "secret",
            "com.private.first", "com.private.second", "pid"
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertFalse(text.contains("com.private.selected"))
    }

    func testOverlayOwnershipAndFrameRemainFrozenWhilePointerDisplayUpdates() async throws {
        let runtime = Stage1FixtureRuntime()
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")
        _ = await server.handle(
            jsonLine: #"{"command":"workspace.open","token":"secret","tab":"switch"}"#
        )

        runtime.pointerDisplayID = "display-1"
        let response = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"secret"}"#
        )
        let snapshot = try XCTUnwrap(response.state?.workspace)

        XCTAssertEqual(snapshot.overlayDisplayID, "display-2")
        XCTAssertEqual(snapshot.pointerDisplayID, "display-1")
        XCTAssertEqual(snapshot.overlayFrame.x, 1_440)
        XCTAssertEqual(snapshot.overlayFrame.width, 1_920)
    }

    func testWorkspaceSnapshotUsesCanonicalFallbackPreviewValue() async throws {
        let runtime = Stage1FixtureRuntime()
        runtime.previewAvailability = .schematicFallback
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")

        let response = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"secret"}"#
        )

        XCTAssertEqual(try XCTUnwrap(response.state?.workspace).previewAvailability, "schematic_fallback")
    }

    func testInvalidWorkspacePayloadsAreTypedAndDoNotMutateRuntime() async {
        let runtime = Stage1FixtureRuntime()
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")

        let invalidTab = await server.handle(
            jsonLine: #"{"command":"workspace.open","token":"secret","tab":"unknown"}"#
        )
        XCTAssertEqual(invalidTab.error?.code, .invalidRequest)
        let invalidKey = await server.handle(
            jsonLine: #"{"command":"workspace.key","token":"secret","key":"launch_app"}"#
        )
        XCTAssertEqual(invalidKey.error?.code, .invalidRequest)
        let invalidGesture = await server.handle(
            jsonLine: #"{"command":"workspace.gesture","token":"secret","gesture":{"phase":"changed","deltaX":0,"deltaY":0,"velocityX":0}}"#
        )
        XCTAssertEqual(invalidGesture.error?.code, .invalidRequest)
        XCTAssertEqual(runtime.openCount, 0)
        XCTAssertEqual(runtime.realInputCount, 0)
    }

    func testReturnAndEnterAreRejectedBeforeRuntimeKeyDispatch() async {
        let runtime = Stage1FixtureRuntime()
        let server = SemanticAdapterServer(runtime: runtime, mode: .devTest, token: "secret")
        _ = await server.handle(
            jsonLine: #"{"command":"workspace.open","token":"secret","tab":"switch"}"#
        )

        for key in ["return", "enter"] {
            let response = await server.handle(
                jsonLine: #"{"command":"workspace.key","token":"secret","key":"\#(key)"}"#
            )
            XCTAssertEqual(response.schemaVersion, 2)
            XCTAssertEqual(response.error?.code, .invalidRequest)
        }

        XCTAssertTrue(runtime.keyCommands.isEmpty)
        XCTAssertEqual(runtime.realInputCount, 0)
    }
}

@MainActor
private final class Stage1FixtureRuntime: SemanticAdapterRuntime {
    private(set) var isPanelOpen = false
    var selectedItemID: String? = "display-2"
    var pointerDisplayID = "display-2"
    var previewAvailability = PreviewAvailability.available
    private(set) var currentTab = WorkspaceTab.switch
    private(set) var openCount = 0
    private(set) var dryRunCount = 0
    private(set) var realInputCount = 0
    private(set) var keyCommands: [WorkspaceKeyCommand] = []
    private var selectedTargetKind: String?
    private var selectedTargetIdentity: String?
    private var dryRunSelectionConfirmed = false

    func state() -> SemanticAdapterRuntimeState {
        SemanticAdapterRuntimeState(
            isPanelOpen: isPanelOpen,
            selectedItemID: selectedItemID,
            permissionState: .granted,
            currentTab: currentTab,
            appPage: 1,
            gesturePhase: "idle",
            reducedMotion: true,
            overlayDisplayID: "display-2",
            pointerDisplayID: pointerDisplayID,
            overlayFrame: SemanticWorkspaceFrame(x: 1_440, y: 0, width: 1_920, height: 1_080),
            selectedTargetKind: selectedTargetKind,
            selectedTargetIdentity: selectedTargetIdentity,
            dryRunSelectionConfirmed: dryRunSelectionConfirmed
        )
    }

    func snapshot() -> SwitcherSnapshot {
        let displays = [
            DisplayDescriptor(
                id: "display-1",
                frame: RectDescriptor(uncheckedX: 0, y: 0, width: 1_440, height: 900),
                isCurrent: pointerDisplayID == "display-1"
            ),
            DisplayDescriptor(
                id: "display-2",
                frame: RectDescriptor(uncheckedX: 1_440, y: 0, width: 1_920, height: 1_080),
                isCurrent: pointerDisplayID == "display-2"
            )
        ]
        let apps = ["com.private.first", "com.private.second"].map {
            RunningAppDescriptor(id: $0, displayName: "Private App", mostRecentWindow: nil)
        }
        return SwitcherSnapshot(
            displays: displays,
            runningApps: apps,
            pointerLocation: PointSnapshot(x: 1_500, y: 200),
            frontmostAppID: "com.private.first",
            workspaces: displays.map { display in
                DisplayWorkspaceSnapshot(
                    display: display,
                    apps: apps,
                    previewAvailability: previewAvailability
                )
            }
        )
    }

    func openPanel() { isPanelOpen = true }
    func select(itemID: String) -> Bool { selectedItemID = itemID; return true }
    func executeSelected() async -> Result<Void, SwitcherActionFailure> {
        realInputCount += 1
        return .success(())
    }
    func permissionState() -> SemanticAdapterPermissionState { .granted }
    func closePanel() { isPanelOpen = false }

    func openWorkspace(tab: WorkspaceTab) {
        openCount += 1
        currentTab = tab
        isPanelOpen = true
    }

    func sendWorkspaceKey(_ key: WorkspaceKeyCommand) -> Bool {
        keyCommands.append(key)
        return isPanelOpen
    }
    func selectWorkspaceDryRunTarget(_ key: WorkspaceKeyCommand) -> Bool {
        guard isPanelOpen else { return false }
        switch key {
        case .appLetter(0):
            selectedTargetKind = "app"
            selectedTargetIdentity = "com.private.first"
            dryRunSelectionConfirmed = false
            return true
        case .displayIndex(1):
            selectedTargetKind = "display"
            selectedTargetIdentity = "display-1"
            dryRunSelectionConfirmed = false
            return true
        default:
            return false
        }
    }
    func sendWorkspaceGesture(_ gesture: SemanticWorkspaceGesture) -> Bool { isPanelOpen }
    func executeWorkspaceDryRun() -> Bool {
        guard isPanelOpen else { return false }
        guard selectedTargetIdentity != nil else { return false }
        dryRunCount += 1
        dryRunSelectionConfirmed = true
        return true
    }
}

@MainActor
private struct Stage1MissingIconProvider: RunningAppIconProviding {
    func icon(for bundleIdentifier: String) -> NSImage? { nil }
}
