import XCTest
@testable import ScreenDomainCore

final class FocusPaneModelsTests: XCTestCase {

    // MARK: - LayoutKind

    func testLayoutKindAllCases() {
        XCTAssertEqual(LayoutKind.allCases.map(\.rawValue), ["asIs", "focus", "split", "focusStack"])
    }

    // MARK: - PaneRatio clamping

    func testPaneRatioClampsToZeroToOne() {
        let over = PaneRatio(primary: 1.5, secondary: 2.0)
        XCTAssertEqual(over.primary, 1.0, accuracy: 0.0001)
        XCTAssertEqual(over.secondary ?? -1, 1.0, accuracy: 0.0001)

        let under = PaneRatio(primary: -0.5)
        XCTAssertEqual(under.primary, 0.0, accuracy: 0.0001)
        XCTAssertNil(under.secondary)

        let valid = PaneRatio(primary: 0.6, secondary: 0.4)
        XCTAssertEqual(valid.primary, 0.6, accuracy: 0.0001)
        XCTAssertEqual(valid.secondary ?? -1, 0.4, accuracy: 0.0001)
    }

    // MARK: - FocusTab defaults

    func testFocusTabDefaultsToInactive() {
        let tab = FocusTab(id: "tab-1", windowID: "w1")
        XCTAssertEqual(tab.state, .inactive)
    }

    // MARK: - FocusPane defaults

    func testFocusPaneDefaults() {
        let pane = FocusPane(id: "pane-1")
        XCTAssertEqual(pane.ratio.primary, 0.5, accuracy: 0.0001)
        XCTAssertNil(pane.ratio.secondary)
        XCTAssertTrue(pane.tabIDs.isEmpty)
        XCTAssertNil(pane.activeTabID)
        XCTAssertNil(pane.role)
    }

    // MARK: - FocusLayout defaults

    func testFocusLayoutDefaults() {
        let layout = FocusLayout(kind: .split)
        XCTAssertEqual(layout.kind, .split)
        XCTAssertTrue(layout.panes.isEmpty)
        XCTAssertTrue(layout.tabs.isEmpty)
        XCTAssertEqual(layout.revision, 1)
    }

    // MARK: - FocusScreen layout is nil by default

    func testFocusScreenLayoutDefaultsToNil() {
        let screen = FocusScreen(id: "screen-1", number: 1, lifecycle: .active)
        XCTAssertNil(screen.layout)
    }

    // MARK: - Codable round-trip

    func testFocusLayoutRoundTrip() throws {
        let layout = FocusLayout(
            kind: .focusStack,
            panes: [
                FocusPane(
                    id: "pane-1",
                    role: "primary",
                    ratio: PaneRatio(primary: 0.6, secondary: 0.5),
                    tabIDs: ["tab-1", "tab-2"],
                    activeTabID: "tab-1",
                    frame: CanvasRect(x: 0, y: 0, width: 800, height: 600)
                ),
                FocusPane(
                    id: "pane-2",
                    ratio: PaneRatio(primary: 0.4),
                    tabIDs: ["tab-3"],
                    activeTabID: "tab-3",
                    frame: CanvasRect(x: 800, y: 0, width: 400, height: 300)
                )
            ],
            tabs: [
                "tab-1": FocusTab(id: "tab-1", windowID: "w1", state: .active),
                "tab-2": FocusTab(id: "tab-2", windowID: "w2", state: .inactive),
                "tab-3": FocusTab(id: "tab-3", windowID: "w3", state: .inactive)
            ],
            revision: 5
        )

        let encoded = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(FocusLayout.self, from: encoded)
        XCTAssertEqual(layout, decoded)
    }

    func testFocusLayoutDecodingRejectsUnknownKeys() {
        let json = Data(#"""
        {"kind":"split","panes":[],"tabs":{},"revision":1,"bogus":true}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FocusLayout.self, from: json))
    }

    func testFocusPaneDecodingRejectsUnknownKeys() {
        let json = Data(#"""
        {"id":"p1","role":null,"ratio":{"primary":0.5,"secondary":null},"tabIds":[],"activeTabId":null,"frame":{"x":0,"y":0,"width":1,"height":1},"oops":1}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FocusPane.self, from: json))
    }

    func testFocusTabDecodingRejectsUnknownKeys() {
        let json = Data(#"""
        {"id":"t1","windowId":"w1","state":"active","extra":"x"}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FocusTab.self, from: json))
    }

    func testPaneRatioDecodingRejectsUnknownKeys() {
        let json = Data(#"{"primary":0.5,"secondary":null,"bogus":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PaneRatio.self, from: json))
    }

    // MARK: - Content-free invariant

    func testFocusLayoutDoesNotExposeContent() {
        let layout = FocusLayout(
            kind: .split,
            panes: [FocusPane(id: "pane-1", role: "primary")],
            tabs: ["tab-1": FocusTab(id: "tab-1", windowID: "w1", state: .active)]
        )
        let mirror = String(describing: layout)
        let forbidden = ["password", "screenshot", "documentPath", "axText", "accessToken", "title"]
        for term in forbidden {
            XCTAssertFalse(mirror.contains(term), "FocusLayout must not expose \(term)")
        }
    }
}
