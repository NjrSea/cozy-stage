import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class SwitcherHeadlessSessionTests: XCTestCase {
    func testSelectionUsesFrozenSnapshotWithoutRingGeometry() throws {
        let session = SwitcherHeadlessSession()
        session.open(snapshot: try snapshot(appIDs: ["app-a", "app-b"], displayIDs: ["display-a"]))

        XCTAssertTrue(session.select(itemID: "app-b"))
        XCTAssertEqual(session.selectedItemID, "app-b")
        XCTAssertFalse(session.select(itemID: "missing"))
        XCTAssertEqual(session.selectedItemID, "app-b")
    }

    func testOutsideCloseClearsSelectionAndCannotExecute() async throws {
        let session = SwitcherHeadlessSession()
        session.open(snapshot: try snapshot(appIDs: ["app-a"], displayIDs: []))
        XCTAssertTrue(session.select(itemID: "app-a"))

        session.close(reason: .outsideClick)

        XCTAssertFalse(session.isOpen)
        XCTAssertNil(session.selectedItemID)
        guard case .failure(.panelNotOpen) = await session.executeSelected() else {
            return XCTFail("A closed semantic session must not execute")
        }
    }

    private func snapshot(
        appIDs: [String],
        displayIDs: [String]
    ) throws -> SwitcherSnapshot {
        let frame = try RectDescriptor(x: 0, y: 0, width: 1280, height: 800)
        return SwitcherSnapshot(
            displays: displayIDs.enumerated().map { index, id in
                DisplayDescriptor(id: id, frame: frame, isCurrent: index == 0)
            },
            runningApps: appIDs.map {
                RunningAppDescriptor(id: $0, displayName: $0, mostRecentWindow: nil)
            },
            pointerLocation: nil,
            frontmostAppID: nil
        )
    }
}
