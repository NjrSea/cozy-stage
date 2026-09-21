import XCTest
@testable import ScreenDomainCore

final class FocusScreenSemanticV3PaneTests: XCTestCase {

    // MARK: - FocusSemanticPane round-trip

    func testSemanticPaneRoundTrip() throws {
        let pane = FocusSemanticPane(
            id: "pane-1",
            screenID: "screen-1",
            role: "primary",
            ratioPrimary: 0.6,
            ratioSecondary: 0.5,
            tabIDs: ["tab-1", "tab-2"],
            activeTabID: "tab-1",
            frame: CanvasRect(x: 0, y: 0, width: 500, height: 400)
        )
        let encoded = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(FocusSemanticPane.self, from: encoded)
        XCTAssertEqual(pane, decoded)
    }

    func testSemanticPaneRejectsUnknownKeys() {
        let json = Data(#"""
        {"id":"p1","screenID":"s1","role":null,"ratioPrimary":0.5,"ratioSecondary":null,"tabIDs":[],"activeTabID":null,"frame":{"x":0,"y":0,"width":1,"height":1},"oops":true}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FocusSemanticPane.self, from: json))
    }

    // MARK: - FocusSemanticTab round-trip

    func testSemanticTabRoundTrip() throws {
        let tab = FocusSemanticTab(id: "tab-1", windowID: "w1", paneID: "pane-1", state: "active", order: 0)
        let encoded = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(FocusSemanticTab.self, from: encoded)
        XCTAssertEqual(tab, decoded)
    }

    func testSemanticTabRejectsUnknownKeys() {
        let json = Data(#"{"id":"t1","windowId":"w1","paneId":"p1","state":"active","order":0,"bogus":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FocusSemanticTab.self, from: json))
    }

    // MARK: - Snapshot with panes and tabs

    func testSnapshotWithPanesAndTabsRoundTrip() throws {
        let pane = FocusSemanticPane(
            id: "pane-1", screenID: "screen-1", role: "primary",
            ratioPrimary: 0.5, ratioSecondary: nil,
            tabIDs: ["tab-1"], activeTabID: "tab-1",
            frame: CanvasRect(x: 0, y: 0, width: 500, height: 400)
        )
        let tab = FocusSemanticTab(id: "tab-1", windowID: "w1", paneID: "pane-1", state: "active", order: 0)
        let snapshot = FocusScreenSemanticSnapshotV3(
            hud: FocusSemanticHUD(visible: true, inspectedScreenID: "screen-1", page: 0, keyAssignmentRevision: 0, presentationRevision: 1, settledRevision: 1),
            screens: [],
            windows: [],
            canvasRegions: [],
            panes: [pane],
            tabs: [tab],
            pointer: FocusSemanticPointer(regionID: nil, position: nil, intendedWindowID: nil, landingRevision: 0),
            stateRevision: 1
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FocusScreenSemanticSnapshotV3.self, from: encoded)
        XCTAssertEqual(snapshot, decoded)
        XCTAssertEqual(decoded.panes.count, 1)
        XCTAssertEqual(decoded.tabs.count, 1)
    }

    func testSnapshotWithEmptyPanesBackwardCompatible() throws {
        let json = Data(#"""
        {"schemaVersion":3,"hud":{"visible":false,"inspectedScreenID":null,"page":0,"keyAssignmentRevision":0,"presentationRevision":0,"settledRevision":0},"screens":[],"windows":[],"canvasRegions":[],"spaces":[],"pointer":{"regionID":null,"position":null,"intendedWindowID":null,"landingRevision":0},"stateRevision":0}
        """#.utf8)
        let decoded = try JSONDecoder().decode(FocusScreenSemanticSnapshotV3.self, from: json)
        XCTAssertTrue(decoded.panes.isEmpty)
        XCTAssertTrue(decoded.tabs.isEmpty)
    }

    // MARK: - Commands

    func testPhase1CCommandsExistInAllowlist() {
        XCTAssertNotNil(FocusSemanticCommand(rawValue: "tab.activate"))
        XCTAssertNotNil(FocusSemanticCommand(rawValue: "tab.move"))
        XCTAssertNotNil(FocusSemanticCommand(rawValue: "tab.close"))
        XCTAssertNotNil(FocusSemanticCommand(rawValue: "pane.resize"))
        XCTAssertNotNil(FocusSemanticCommand(rawValue: "layout.set"))
    }

    // MARK: - Content-free invariant

    func testSemanticPaneDoesNotExposeContent() {
        let pane = FocusSemanticPane(
            id: "pane-1", screenID: "screen-1", role: "primary",
            ratioPrimary: 0.5, ratioSecondary: nil,
            tabIDs: ["tab-1"], activeTabID: "tab-1",
            frame: CanvasRect(x: 0, y: 0, width: 100, height: 100)
        )
        let mirror = String(describing: pane)
        let forbidden = ["password", "screenshot", "documentPath", "axText", "accessToken", "title"]
        for term in forbidden {
            XCTAssertFalse(mirror.contains(term), "FocusSemanticPane must not expose \(term)")
        }
    }
}
