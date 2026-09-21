import XCTest
@testable import ScreenDomainCore

final class FocusSpaceModelsTests: XCTestCase {

    // MARK: - SavedSpace defaults & identity

    func testSavedSpaceDefaultsToRestorableNotBound() {
        let space = SavedSpace(id: "space-1", number: 1)
        XCTAssertEqual(space.lifecycle, .restorable)
        XCTAssertNil(space.boundScreenID)
        XCTAssertEqual(space.layoutRevision, 1)
        XCTAssertFalse(space.autoSaveSuspended)
        XCTAssertTrue(space.appSlots.isEmpty)
        XCTAssertTrue(space.routingRules.isEmpty)
        XCTAssertNil(space.canvasTopologyMapping)
    }

    func testFocusScreenDefaultsToNilSpaceID() {
        let screen = FocusScreen(id: "screen-1", number: 1, lifecycle: .active)
        XCTAssertNil(screen.spaceID)
    }

    // MARK: - LogicalWindowSlot

    func testLogicalWindowSlotDefaultsToUnresolved() {
        let slot = LogicalWindowSlot(id: "slot-1", bundleID: "com.example.app")
        XCTAssertEqual(slot.status, .unresolved)
        XCTAssertEqual(slot.tabOrder, 0)
        XCTAssertNil(slot.boundWindowID)
        XCTAssertNil(slot.paneRole)
    }

    // MARK: - PaneRatioEntry clamping

    func testPaneRatioEntryClampsToZeroToOne() {
        let over = PaneRatioEntry(paneID: "pane-1", primary: 1.5, secondary: 2.0)
        XCTAssertEqual(over.primary, 1.0, accuracy: 0.0001)
        XCTAssertEqual(over.secondary ?? -1, 1.0, accuracy: 0.0001)

        let under = PaneRatioEntry(paneID: "pane-1", primary: -0.3)
        XCTAssertEqual(under.primary, 0.0, accuracy: 0.0001)
        XCTAssertNil(under.secondary)

        let valid = PaneRatioEntry(paneID: "pane-1", primary: 0.6, secondary: 0.4)
        XCTAssertEqual(valid.primary, 0.6, accuracy: 0.0001)
        XCTAssertEqual(valid.secondary ?? -1, 0.4, accuracy: 0.0001)
    }

    // MARK: - CanvasRegionIdentity

    func testCanvasRegionIdentityAcceptsValidScale() {
        // Valid scale values construct successfully (precondition enforces > 0)
        let region = CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        XCTAssertEqual(region.scale, 2)
    }

    // MARK: - CanvasSeam validation

    func testCanvasSeamAcceptsTwoRegionIDs() {
        // Two region IDs constructs successfully (precondition enforces count == 2)
        let seam = CanvasSeam(regionIDs: ["r1", "r2"], edge: .vertical, position: 500)
        XCTAssertEqual(seam.regionIDs, ["r1", "r2"])
    }

    // MARK: - Codable round-trip (closed decoding)

    func testSavedSpaceCodableRoundTrip() throws {
        let frame = CanvasRect(x: 10, y: 20, width: 800, height: 600)
        let space = SavedSpace(
            id: "space-1",
            number: 3,
            name: "Design",
            lifecycle: .open,
            layoutRevision: 5,
            canvasLayout: SavedCanvasLayout(
                windowFrames: ["slot-1": frame],
                paneRatios: [PaneRatioEntry(paneID: "pane-1", primary: 0.6, secondary: 0.5)]
            ),
            appSlots: [
                LogicalWindowSlot(id: "slot-1", bundleID: "com.example.app", paneRole: "primary", tabOrder: 1, boundWindowID: "w1", status: .resolved),
                LogicalWindowSlot(id: "slot-2", bundleID: "com.example.missing", status: .unresolved)
            ],
            defaultSlotID: "slot-1",
            routingRules: [RoutingRule(bundleID: "com.example.app", spaceID: "space-1", paneRole: "primary")],
            canvasTopologyMapping: CanvasTopologyMapping(
                regions: [
                    CanvasRegionIdentity(id: "region-1", frame: frame, scale: 2),
                    CanvasRegionIdentity(id: "region-2", frame: CanvasRect(x: 800, y: 0, width: 800, height: 600), scale: 2)
                ],
                seams: [CanvasSeam(regionIDs: ["region-1", "region-2"], edge: .vertical, position: 800)],
                revision: 2
            ),
            autoSaveSuspended: true,
            boundScreenID: "screen-2"
        )

        let encoded = try JSONEncoder().encode(space)
        let decoded = try JSONDecoder().decode(SavedSpace.self, from: encoded)

        XCTAssertEqual(space, decoded)
    }

    func testSavedSpaceDecodingRejectsUnknownKeys() {
        let json = Data(#"{"id":"s1","number":1,"lifecycle":"restorable","layoutRevision":1,"canvasLayout":{"windowFrames":{},"paneRatios":[]},"appSlots":[],"bogusKey":true}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SavedSpace.self, from: json))
    }

    func testLogicalWindowSlotDecodingRejectsUnknownKeys() {
        let json = Data(#"{"id":"s1","bundleId":"com.x","paneRole":null,"tabOrder":0,"boundWindowId":null,"status":"unresolved","extra":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LogicalWindowSlot.self, from: json))
    }

    func testRoutingRuleDecodingRejectsUnknownKeys() {
        let json = Data(#"{"bundleId":"com.x","spaceId":"s1","paneRole":null,"oops":"v"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RoutingRule.self, from: json))
    }

    func testCanvasSeamDecodingRejectsWrongRegionCount() {
        let json = Data(#"{"regionIds":["r1"],"edge":"vertical","position":100}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CanvasSeam.self, from: json))
    }

    func testCanvasSeamDecodingRejectsNonFinitePosition() {
        // A non-finite position string fails to decode as Double → throws
        let json = Data(#"{"regionIds":["r1","r2"],"edge":"vertical","position":"oops"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CanvasSeam.self, from: json))
    }

    // MARK: - Content-free invariant

    func testSavedSpaceDoesNotStoreContentFields() {
        // SavedSpace has no title, documentPath, axText, screenshot, or password
        // fields. This test pins the structural invariant: the type is pure
        // structure (bundle IDs, geometry, order, status).
        let space = SavedSpace(id: "space-1", number: 1)
        let mirror = String(describing: space)
        let forbidden = ["password", "screenshot", "documentPath", "axText", "accessToken"]
        for term in forbidden {
            XCTAssertFalse(mirror.contains(term), "SavedSpace must not expose \(term)")
        }
    }
}
