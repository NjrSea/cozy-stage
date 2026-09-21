import Foundation
import XCTest
@testable import ScreenDomainCore

final class FocusScreenSemanticV3Tests: XCTestCase {
    func testSnapshotEncodesExactSchemaVersionAndClosedContentFreeRecords() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["schemaVersion"] as? Int, 3)
        XCTAssertEqual(root["spaces"] as? [String], [])
        // canvasTopology/panes/tabs use encodeIfPresent or default to [], so
        // they may be present or absent depending on the test data.
        let requiredKeys: Set<String> = [
            "schemaVersion", "hud", "screens", "windows", "canvasRegions",
            "spaces", "panes", "tabs", "pointer", "stateRevision"
        ]
        XCTAssertTrue(Set(root.keys).isSuperset(of: requiredKeys),
                       "Missing required keys. Got: \(root.keys)")
        // No unknown keys beyond the allowlist (canvasTopology may be absent when nil).
        let allowedKeys = requiredKeys.union(["canvasTopology"])
        XCTAssertEqual(root.keys.filter { !allowedKeys.contains($0) }, [],
                       "Unexpected keys present")
        XCTAssertEqual(Set(try XCTUnwrap(root["hud"] as? [String: Any]).keys), [
            "visible", "inspectedScreenID", "page", "keyAssignmentRevision",
            "presentationRevision", "settledRevision", "interactionRevision", "inventoryStatus",
            "renderedPresentationRevision", "renderedInteractionRevision", "renderedLayoutState",
            "renderedAppTargetCount", "renderedDismissTargetCount", "renderedEmptyWorkspaceCount",
            "inventoryRevision", "appIdentityHashes",
            "workspaceAppIdentityHashes", "layoutMode", "workspaceSections",
            "hoverRevision", "renderedHoverRevision", "visibleNameCount", "nameFocusSource",
            "isKeyWindow", "lastCloseReason", "lastMouseRoute", "matchedFocusAttempt", "activation"
        ])
        XCTAssertEqual(
            Set(try XCTUnwrap((root["hud"] as? [String: Any])?["activation"] as? [String: Any]).keys),
            ["revision", "stage", "result", "bindingKind", "selectionCurrent", "bindingCurrent", "blockReason"]
        )
        XCTAssertEqual(Set(try XCTUnwrap((root["screens"] as? [[String: Any]])?.first).keys), [
            "id", "number", "lifecycle", "windowIDs", "activeWindowID", "layoutRevision"
        ])
        XCTAssertEqual(Set(try XCTUnwrap((root["windows"] as? [[String: Any]])?.first).keys), [
            "id", "appIdentityHash", "screenID", "visible", "minimized", "focused",
            "frame", "compatibility", "transactionRevision"
        ])
        XCTAssertEqual(Set(try XCTUnwrap((root["canvasRegions"] as? [[String: Any]])?.first).keys), [
            "id", "frame", "scale"
        ])
        XCTAssertEqual(Set(try XCTUnwrap(root["pointer"] as? [String: Any]).keys), [
            "regionID", "position", "intendedWindowID", "landingRevision"
        ])

        let text = String(decoding: data, as: UTF8.self)
        for forbidden in [
            "\"title\":", "axrole", "axidentifier", "\"pid\":", "\"token\":", "/users/",
            "\"path\":", "\"payload\":", "\"content\":", "\"screenshot\":"
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
    }

    func testAllSemanticCommandsHaveExactWireValuesAndRoundTrip() throws {
        let expected = [
            "screen.snapshot", "hud.open", "hud.close", "hud.close-owned", "hud.key", "screen.create",
            "screen.switch", "screen.close", "screen.close-owned", "recovery.revealAll",
            "space.save", "space.restore",
            "tab.activate", "tab.move", "tab.close", "pane.resize", "layout.set"
        ]

        XCTAssertEqual(FocusSemanticCommand.allCases.map(\.rawValue), expected)
        for command in FocusSemanticCommand.allCases {
            try assertRoundTrip(command)
        }
    }

    func testHUDFocusSourceIsClosedAndRejectsUnknownWireValues() throws {
        XCTAssertEqual(FocusSemanticHUDNameFocusSource.pointerHover.rawValue, "pointer_hover")
        XCTAssertEqual(FocusSemanticHUDNameFocusSource.keyboardFocus.rawValue, "keyboard_focus")
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusSemanticHUDNameFocusSource.self,
            from: Data("\"intent_only\"".utf8)
        ))
    }

    func testHUDRenderedVisualContractIsClosedAndLegacyDefaultsAreEmpty() throws {
        let hud = FocusSemanticHUD(
            visible: true,
            inspectedScreenID: "screen-1",
            page: 0,
            keyAssignmentRevision: 1,
            presentationRevision: 8,
            settledRevision: 8,
            interactionRevision: 3,
            renderedPresentationRevision: 8,
            renderedInteractionRevision: 3,
            renderedLayoutState: .overview,
            renderedCellSize: 40,
            renderedVisibleIconSize: 32,
            renderedNameFontSize: 8,
            renderedBadgeSize: 16,
            renderedBadgeFontSize: 10,
            renderedAppTargetCount: 2,
            renderedDismissTargetCount: 0,
            renderedEmptyWorkspaceCount: 1
        )
        let roundTrip = try JSONDecoder().decode(
            FocusSemanticHUD.self,
            from: JSONEncoder().encode(hud)
        )
        XCTAssertEqual(roundTrip, hud)
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusSemanticHUDRenderedLayoutState.self,
            from: Data("\"private_layout\"".utf8)
        ))

        var root = try encodedSnapshotObject()
        var legacyHUD = try XCTUnwrap(root["hud"] as? [String: Any])
        for key in [
            "renderedPresentationRevision", "renderedInteractionRevision",
            "renderedLayoutState", "renderedCellSize", "renderedVisibleIconSize",
            "renderedNameFontSize", "renderedBadgeSize", "renderedBadgeFontSize",
            "renderedAppTargetCount", "renderedDismissTargetCount",
            "renderedEmptyWorkspaceCount",
        ] {
            legacyHUD.removeValue(forKey: key)
        }
        root["hud"] = legacyHUD
        let legacy = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: try JSONSerialization.data(withJSONObject: root)
        ).hud
        XCTAssertEqual(legacy.renderedPresentationRevision, 0)
        XCTAssertEqual(legacy.renderedInteractionRevision, 0)
        XCTAssertEqual(legacy.renderedLayoutState, .none)
        XCTAssertNil(legacy.renderedCellSize)
        XCTAssertNil(legacy.renderedVisibleIconSize)
        XCTAssertNil(legacy.renderedNameFontSize)
        XCTAssertNil(legacy.renderedBadgeSize)
        XCTAssertNil(legacy.renderedBadgeFontSize)
        XCTAssertEqual(legacy.renderedAppTargetCount, 0)
        XCTAssertEqual(legacy.renderedDismissTargetCount, 0)
        XCTAssertEqual(legacy.renderedEmptyWorkspaceCount, 0)
    }

    func testHUDLastCloseReasonIsClosedAndLegacyDefaultsToNone() throws {
        XCTAssertEqual(FocusSemanticHUDLastCloseReason.outsideClick.rawValue, "outside_click")
        XCTAssertEqual(FocusSemanticHUDLastCloseReason.applicationTermination.rawValue, "application_termination")
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusSemanticHUDLastCloseReason.self,
            from: Data("\"private_window_reason\"".utf8)
        ))

        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "lastCloseReason")
        root["hud"] = hud

        let decoded = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: try JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertEqual(decoded.hud.lastCloseReason, .none)

        hud["visible"] = false
        hud["isKeyWindow"] = false
        hud["lastCloseReason"] = "outside_click"
        root["hud"] = hud
        let closed = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: try JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertEqual(closed.hud.lastCloseReason, .outsideClick)
    }

    func testHUDLastMouseRouteIsClosedAndLegacyDefaultsToStaleIgnored() throws {
        XCTAssertEqual(FocusSemanticHUDLastMouseRoute.localHUD.rawValue, "local_hud")
        XCTAssertEqual(FocusSemanticHUDLastMouseRoute.globalHUDTopmost.rawValue, "global_hud_topmost")
        XCTAssertEqual(FocusSemanticHUDLastMouseRoute.globalUnresolved.rawValue, "global_unresolved")
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusSemanticHUDLastMouseRoute.self,
            from: Data("\"window_42\"".utf8)
        ))

        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "lastMouseRoute")
        root["hud"] = hud
        let legacy = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: try JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertEqual(legacy.hud.lastMouseRoute, .staleIgnored)
    }

    func testHUDFocusAttemptAttributionIsContentFreeAndLegacyDefaultsFalse() throws {
        XCTAssertNotEqual(FocusSemanticHUDFocusAttemptMarker.eventSourceUserData, 0)

        let attributedData = try JSONEncoder().encode(FocusSemanticHUD(
            visible: true,
            inspectedScreenID: nil,
            page: 0,
            keyAssignmentRevision: 0,
            presentationRevision: 1,
            settledRevision: 1,
            matchedFocusAttempt: true
        ))
        let attributed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: attributedData) as? [String: Any]
        )
        XCTAssertEqual(attributed["matchedFocusAttempt"] as? Bool, true)
        XCTAssertNil(attributed["focusAttemptMarker"])

        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "matchedFocusAttempt")
        root["hud"] = hud
        let legacy = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: try JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertFalse(legacy.hud.matchedFocusAttempt)
    }

    func testHUDActivationUsesClosedContentFreeEnumsAndStrictCombinations() throws {
        let activation = FocusSemanticHUDActivation(
            revision: 8,
            stage: .commit,
            result: .applied,
            bindingKind: .windowServer,
            selectionCurrent: true,
            bindingCurrent: true,
            blockReason: .none
        )
        try assertRoundTrip(activation)
        XCTAssertTrue(activation.isValidCombination)

        for raw in ["window:123", "pid:42", "/private/path"] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                FocusSemanticHUDActivationStage.self,
                from: Data("\"\(raw)\"".utf8)
            ))
        }

        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud["activation"] = [
            "revision": 8,
            "stage": "commit",
            "result": "failed",
            "bindingKind": "window_server",
            "selectionCurrent": true,
            "bindingCurrent": true,
            "blockReason": "none"
        ] as [String: Any]
        root["hud"] = hud
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        ))

        hud["activation"] = [
            "revision": 0,
            "stage": "commit",
            "result": "applied",
            "bindingKind": "window_server",
            "selectionCurrent": true,
            "bindingCurrent": true,
            "blockReason": "none"
        ] as [String: Any]
        root["hud"] = hud
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        ))

        hud["activation"] = [
            "revision": 8,
            "stage": "commit",
            "result": "applied",
            "bindingKind": "window_server",
            "selectionCurrent": true,
            "bindingCurrent": true,
            "blockReason": "none",
            "privateIdentity": "window:123"
        ] as [String: Any]
        root["hud"] = hud
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        ))

        let exactFocusReasons: [FocusSemanticHUDActivationBlockReason] = [
            .exactFocusSymbolUnavailable,
            .exactFocusProcessResolutionFailed,
            .exactFocusFrontProcessRejected,
            .exactFocusKeyEventRejected
        ]
        XCTAssertEqual(exactFocusReasons.map(\.rawValue), [
            "exact_focus_symbol_unavailable",
            "exact_focus_process_resolution_failed",
            "exact_focus_front_process_rejected",
            "exact_focus_key_event_rejected"
        ])
        for reason in exactFocusReasons {
            let blocked = FocusSemanticHUDActivation(
                revision: 8,
                stage: .activate,
                result: reason == .exactFocusSymbolUnavailable ? .unsupported : .failed,
                bindingKind: .windowServer,
                selectionCurrent: true,
                bindingCurrent: true,
                blockReason: reason
            )
            XCTAssertTrue(blocked.isValidCombination, reason.rawValue)
            try assertRoundTrip(blocked)
        }
    }

    func testLegacyV3HUDDefaultsMissingHoverRenderTruthFieldsToClosedEmptyState() throws {
        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        for key in ["hoverRevision", "renderedHoverRevision", "visibleNameCount", "nameFocusSource"] {
            hud.removeValue(forKey: key)
        }
        root["hud"] = hud
        let decoded = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: try JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertEqual(decoded.hud.hoverRevision, 0)
        XCTAssertEqual(decoded.hud.renderedHoverRevision, 0)
        XCTAssertEqual(decoded.hud.visibleNameCount, 0)
        XCTAssertEqual(decoded.hud.nameFocusSource, .none)
    }

    func testLegacyV3HUDDefaultsMissingActivationToIdle() throws {
        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "activation")
        root["hud"] = hud

        let decoded = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertEqual(decoded.hud.activation, .idle)
    }

    func testAllSemanticV3RecordsRoundTrip() throws {
        let snapshot = makeSnapshot()

        try assertRoundTrip(snapshot.hud)
        try assertRoundTrip(snapshot.hud.activation)
        try assertRoundTrip(try XCTUnwrap(snapshot.hud.workspaceSections.first))
        try assertRoundTrip(try XCTUnwrap(snapshot.screens.first))
        try assertRoundTrip(try XCTUnwrap(snapshot.windows.first))
        try assertRoundTrip(try XCTUnwrap(snapshot.canvasRegions.first))
        try assertRoundTrip(snapshot.pointer)
        try assertRoundTrip(snapshot)
    }

    func testSnapshotDecodingRejectsUnknownContentKeysAtEveryV3RecordBoundary() throws {
        let boundaries = [
            "root", "hud", "hud.workspaceSection", "screen", "window", "window.frame", "canvasRegion",
            "canvasRegion.frame", "pointer", "pointer.position"
        ]
        let forbiddenKeys = ["title", "path", "rawAXText"]

        for boundary in boundaries {
            for forbiddenKey in forbiddenKeys {
                var root = try encodedSnapshotObject()
                inject(
                    key: forbiddenKey,
                    value: "private-content",
                    at: boundary,
                    into: &root
                )
                let data = try JSONSerialization.data(withJSONObject: root)

                XCTAssertThrowsError(
                    try JSONDecoder().decode(FocusScreenSemanticSnapshotV3.self, from: data),
                    "\(boundary).\(forbiddenKey)"
                )
            }
        }
    }

    func testSnapshotDecodingRetainsExactVersionAndEmptySpacesRequirements() throws {
        var wrongVersion = try encodedSnapshotObject()
        wrongVersion["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: wrongVersion)
        ))

        var nonemptySpaces = try encodedSnapshotObject()
        nonemptySpaces["spaces"] = ["space-1"]
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: nonemptySpaces)
        ))
    }

    func testOlderHUDSnapshotDefaultsMissingInventoryFieldsToNotReady() throws {
        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "inventoryStatus")
        hud.removeValue(forKey: "inventoryRevision")
        root["hud"] = hud

        let decoded = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertEqual(decoded.hud.inventoryStatus, "loading")
        XCTAssertEqual(decoded.hud.inventoryRevision, 0)
    }

    func testLegacyV3HUDDefaultsMissingOverviewFields() throws {
        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "layoutMode")
        hud.removeValue(forKey: "workspaceSections")
        root["hud"] = hud

        let decoded = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertEqual(decoded.hud.layoutMode, .segmented)
        XCTAssertEqual(decoded.hud.workspaceSections, [])
    }

    func testLegacyV3HUDDefaultsMissingInteractionRevisionWithoutWeakeningUnknownKeyRejection() throws {
        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "interactionRevision")
        root["hud"] = hud

        let decoded = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertEqual(decoded.hud.interactionRevision, 0)

        hud["focusedWindowID"] = "private-window"
        root["hud"] = hud
        XCTAssertThrowsError(try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        ))
    }

    func testLegacyV3HUDDefaultsMissingKeyWindowTruthToFalse() throws {
        var root = try encodedSnapshotObject()
        var hud = try XCTUnwrap(root["hud"] as? [String: Any])
        hud.removeValue(forKey: "isKeyWindow")
        root["hud"] = hud

        let decoded = try JSONDecoder().decode(
            FocusScreenSemanticSnapshotV3.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertFalse(decoded.hud.isKeyWindow)
    }

    func testWorkspaceOverviewKeepsCompatibilityFieldsAndOrderedOpaqueSections() throws {
        let hud = FocusSemanticHUD(
            visible: true,
            inspectedScreenID: "screen-active",
            page: 0,
            keyAssignmentRevision: 21,
            presentationRevision: 22,
            settledRevision: 22,
            inventoryStatus: "ready",
            inventoryRevision: 20,
            appIdentityHashes: ["opaque-a", "opaque-b", "opaque-c"],
            workspaceAppIdentityHashes: ["opaque-b"],
            layoutMode: .workspaceOverview,
            workspaceSections: [
                .init(
                    screenID: "screen-background",
                    appIdentityHashes: ["opaque-a", "opaque-c"],
                    shortcutCount: 2,
                    rowCount: 2
                ),
                .init(
                    screenID: "screen-active",
                    appIdentityHashes: ["opaque-b"],
                    shortcutCount: 1,
                    rowCount: 1
                ),
            ]
        )

        XCTAssertEqual(hud.layoutMode, .workspaceOverview)
        XCTAssertEqual(hud.page, 0)
        XCTAssertEqual(hud.inspectedScreenID, "screen-active")
        XCTAssertEqual(
            hud.workspaceSections.map(\.screenID),
            ["screen-background", "screen-active"]
        )
        try assertRoundTrip(hud)
    }

    private func makeSnapshot() -> FocusScreenSemanticSnapshotV3 {
        FocusScreenSemanticSnapshotV3(
            hud: FocusSemanticHUD(
                visible: true,
                inspectedScreenID: "screen-1",
                page: 2,
                keyAssignmentRevision: 11,
                presentationRevision: 12,
                settledRevision: 12,
                interactionRevision: 7,
                inventoryStatus: "ready",
                inventoryRevision: 9,
                appIdentityHashes: ["sha256:abc123"],
                workspaceAppIdentityHashes: ["sha256:abc123"],
                layoutMode: .workspaceOverview,
                workspaceSections: [
                    .init(
                        screenID: "screen-1",
                        appIdentityHashes: ["sha256:abc123"],
                        shortcutCount: 1,
                        rowCount: 1
                    )
                ]
            ),
            screens: [
                FocusSemanticScreen(
                    id: "screen-1",
                    number: 1,
                    lifecycle: "active",
                    windowIDs: ["window-1"],
                    activeWindowID: "window-1",
                    layoutRevision: 21
                )
            ],
            windows: [
                FocusSemanticWindow(
                    id: "window-1",
                    appIdentityHash: "sha256:abc123",
                    screenID: "screen-1",
                    visible: true,
                    minimized: false,
                    focused: true,
                    frame: CanvasRect(x: 10, y: 20, width: 800, height: 600),
                    compatibility: "supported",
                    transactionRevision: 31
                )
            ],
            canvasRegions: [
                FocusSemanticCanvasRegion(
                    id: "region-1",
                    frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900),
                    scale: 2
                )
            ],
            pointer: FocusSemanticPointer(
                regionID: "region-1",
                position: CanvasPoint(x: 400, y: 300),
                intendedWindowID: "window-1",
                landingRevision: 41
            ),
            stateRevision: 51
        )
    }

    private func encodedSnapshotObject() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(makeSnapshot())
            ) as? [String: Any]
        )
    }

    private func inject(
        key: String,
        value: String,
        at boundary: String,
        into root: inout [String: Any]
    ) {
        switch boundary {
        case "root":
            root[key] = value
        case "hud":
            var record = root["hud"] as! [String: Any]
            record[key] = value
            root["hud"] = record
        case "hud.workspaceSection":
            var hud = root["hud"] as! [String: Any]
            var records = hud["workspaceSections"] as! [[String: Any]]
            records[0][key] = value
            hud["workspaceSections"] = records
            root["hud"] = hud
        case "screen":
            var records = root["screens"] as! [[String: Any]]
            records[0][key] = value
            root["screens"] = records
        case "window":
            var records = root["windows"] as! [[String: Any]]
            records[0][key] = value
            root["windows"] = records
        case "window.frame":
            var records = root["windows"] as! [[String: Any]]
            var frame = records[0]["frame"] as! [String: Any]
            frame[key] = value
            records[0]["frame"] = frame
            root["windows"] = records
        case "canvasRegion":
            var records = root["canvasRegions"] as! [[String: Any]]
            records[0][key] = value
            root["canvasRegions"] = records
        case "canvasRegion.frame":
            var records = root["canvasRegions"] as! [[String: Any]]
            var frame = records[0]["frame"] as! [String: Any]
            frame[key] = value
            records[0]["frame"] = frame
            root["canvasRegions"] = records
        case "pointer":
            var record = root["pointer"] as! [String: Any]
            record[key] = value
            root["pointer"] = record
        case "pointer.position":
            var record = root["pointer"] as! [String: Any]
            var position = record["position"] as! [String: Any]
            position[key] = value
            record["position"] = position
            root["pointer"] = record
        default:
            XCTFail("unknown test boundary \(boundary)")
        }
    }

    private func assertRoundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(
            try JSONDecoder().decode(T.self, from: data),
            value,
            file: file,
            line: line
        )
    }
}
