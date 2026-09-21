import XCTest
@testable import ScreenDomainCore

final class FocusScreenSemanticV3SpaceTests: XCTestCase {

    // MARK: - FocusSemanticSpace round-trip

    func testSemanticSpaceRoundTrip() throws {
        let space = FocusSemanticSpace(
            id: "space-1",
            number: 2,
            namePresent: true,
            lifecycle: "open",
            layoutRevision: 5,
            windowSlotCount: 3,
            resolvedSlotCount: 2,
            boundScreenID: "screen-2",
            autoSaveSuspended: false
        )
        let encoded = try JSONEncoder().encode(space)
        let decoded = try JSONDecoder().decode(FocusSemanticSpace.self, from: encoded)
        XCTAssertEqual(space, decoded)
    }

    func testSemanticSpaceRejectsUnknownKeys() {
        let json = Data(#"{"id":"s1","number":1,"namePresent":false,"lifecycle":"restorable","layoutRevision":1,"windowSlotCount":0,"resolvedSlotCount":0,"boundScreenId":null,"autoSaveSuspended":false,"oops":true}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FocusSemanticSpace.self, from: json))
    }

    // MARK: - FocusSemanticSeam round-trip

    func testSemanticSeamRoundTrip() throws {
        let seam = FocusSemanticSeam(regionIDs: ["r1", "r2"], edge: "vertical")
        let encoded = try JSONEncoder().encode(seam)
        let decoded = try JSONDecoder().decode(FocusSemanticSeam.self, from: encoded)
        XCTAssertEqual(seam, decoded)
    }

    // MARK: - FocusSemanticCanvasTopology round-trip

    func testSemanticCanvasTopologyRoundTrip() throws {
        let topology = FocusSemanticCanvasTopology(
            regions: [
                FocusSemanticCanvasRegion(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900), scale: 2),
                FocusSemanticCanvasRegion(id: "r2", frame: CanvasRect(x: 1440, y: 0, width: 1920, height: 900), scale: 2)
            ],
            seams: [FocusSemanticSeam(regionIDs: ["r1", "r2"], edge: "vertical")],
            revision: 3
        )
        let encoded = try JSONEncoder().encode(topology)
        let decoded = try JSONDecoder().decode(FocusSemanticCanvasTopology.self, from: encoded)
        XCTAssertEqual(topology, decoded)
    }

    // MARK: - Snapshot with spaces

    func testSnapshotWithSpacesRoundTrip() throws {
        let space = FocusSemanticSpace(
            id: "space-1",
            number: 1,
            namePresent: false,
            lifecycle: "open",
            layoutRevision: 1,
            windowSlotCount: 2,
            resolvedSlotCount: 2,
            boundScreenID: "screen-1",
            autoSaveSuspended: false
        )
        let snapshot = FocusScreenSemanticSnapshotV3(
            hud: FocusSemanticHUD(visible: true, inspectedScreenID: "screen-1", page: 0, keyAssignmentRevision: 0, presentationRevision: 1, settledRevision: 1),
            screens: [],
            windows: [],
            canvasRegions: [FocusSemanticCanvasRegion(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1, height: 1), scale: 1)],
            spaces: [space],
            canvasTopology: nil,
            pointer: FocusSemanticPointer(regionID: nil, position: nil, intendedWindowID: nil, landingRevision: 0),
            stateRevision: 1
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FocusScreenSemanticSnapshotV3.self, from: encoded)
        XCTAssertEqual(snapshot, decoded)
        XCTAssertEqual(decoded.spaces.count, 1)
        XCTAssertEqual(decoded.spaces[0].id, "space-1")
    }

    func testSnapshotWithEmptySpacesBackwardCompatible() throws {
        // A snapshot without spaces field should decode with empty spaces.
        let json = Data(#"""
        {"schemaVersion":3,"hud":{"visible":false,"inspectedScreenID":null,"page":0,"keyAssignmentRevision":0,"presentationRevision":0,"settledRevision":0},"screens":[],"windows":[],"canvasRegions":[],"pointer":{"regionID":null,"position":null,"intendedWindowID":null,"landingRevision":0},"stateRevision":0}
        """#.utf8)
        let decoded = try JSONDecoder().decode(FocusScreenSemanticSnapshotV3.self, from: json)
        XCTAssertTrue(decoded.spaces.isEmpty)
        XCTAssertNil(decoded.canvasTopology)
    }

    func testSnapshotRejectsUnknownKeys() {
        let json = Data(#"""
        {"schemaVersion":3,"hud":{"visible":false,"inspectedScreenID":null,"page":0,"keyAssignmentRevision":0,"presentationRevision":0,"settledRevision":0},"screens":[],"windows":[],"canvasRegions":[],"spaces":[],"pointer":{"regionID":null,"position":null,"intendedWindowID":null,"landingRevision":0},"stateRevision":0,"bogus":1}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FocusScreenSemanticSnapshotV3.self, from: json))
    }

    // MARK: - Commands

    func testSpaceCommandsExistInAllowlist() {
        XCTAssertNotNil(FocusSemanticCommand(rawValue: "space.save"))
        XCTAssertNotNil(FocusSemanticCommand(rawValue: "space.restore"))
        XCTAssertTrue(FocusSemanticCommand.allCases.contains(.spaceSave))
        XCTAssertTrue(FocusSemanticCommand.allCases.contains(.spaceRestore))
    }

    // MARK: - Content-free invariant

    func testSemanticSpaceDoesNotExposeContent() {
        let space = FocusSemanticSpace(
            id: "space-1", number: 1, namePresent: true, lifecycle: "open",
            layoutRevision: 1, windowSlotCount: 1, resolvedSlotCount: 1,
            boundScreenID: "screen-1", autoSaveSuspended: false
        )
        let mirror = String(describing: space)
        // namePresent is projected, not the name value itself.
        XCTAssertTrue(mirror.contains("namePresent"))
        let forbidden = ["password", "screenshot", "documentPath", "axText", "accessToken", "title"]
        for term in forbidden {
            XCTAssertFalse(mirror.contains(term), "FocusSemanticSpace must not expose \(term)")
        }
    }
}
