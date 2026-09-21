import XCTest
@testable import ScreenDomainCore

final class CanvasRemappingEngineTests: XCTestCase {

    // MARK: - rebuildCanvas (stitched bounding box)

    func testRebuildCanvasComputesBoundingBox() {
        let regions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900)),
            CanvasRegionIdentity(id: "r2", frame: CanvasRect(x: 1440, y: 0, width: 1920, height: 900))
        ]
        let canvas = CanvasRemappingEngine.rebuildCanvas(from: regions)
        XCTAssertEqual(canvas.x, 0)
        XCTAssertEqual(canvas.y, 0)
        XCTAssertEqual(canvas.width, 3360, accuracy: 0.5)
        XCTAssertEqual(canvas.height, 900, accuracy: 0.5)
    }

    func testRebuildCanvasDegenerateWhenEmpty() {
        let canvas = CanvasRemappingEngine.rebuildCanvas(from: [])
        XCTAssertEqual(canvas, CanvasRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - detectSeams

    func testDetectVerticalSeamBetweenAdjacentRegions() {
        let regions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900)),
            CanvasRegionIdentity(id: "r2", frame: CanvasRect(x: 1440, y: 0, width: 1920, height: 900))
        ]
        let seams = CanvasRemappingEngine.detectSeams(in: regions)
        XCTAssertEqual(seams.count, 1)
        XCTAssertEqual(seams[0].edge, .vertical)
        XCTAssertEqual(seams[0].position, 1440, accuracy: 0.5)
        XCTAssertEqual(Set(seams[0].regionIDs), Set(["r1", "r2"]))
    }

    func testNoSeamBetweenNonAdjacentRegions() {
        let regions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            CanvasRegionIdentity(id: "r2", frame: CanvasRect(x: 500, y: 500, width: 100, height: 100))
        ]
        let seams = CanvasRemappingEngine.detectSeams(in: regions)
        XCTAssertTrue(seams.isEmpty)
    }

    // MARK: - remap preserves ratios

    func testRemapPreservesRelativePositions() throws {
        let oldRegions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1000, height: 1000))
        ]
        let oldTopology = CanvasTopologyMapping(regions: oldRegions)
        let savedLayout = SavedCanvasLayout(
            windowFrames: ["slot-1": CanvasRect(x: 100, y: 100, width: 200, height: 200)]
        )

        // New topology: canvas doubles in size.
        let newRegions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 2000, height: 2000))
        ]
        let result = CanvasRemappingEngine.remap(savedLayout: savedLayout, oldTopology: oldTopology, newRegions: newRegions)

        let remapped = try XCTUnwrap(result.remappedFrames["slot-1"])
        // The relative position (10%, 10%) and size (20%, 20%) should be preserved.
        XCTAssertEqual(remapped.x, 200, accuracy: 1)
        XCTAssertEqual(remapped.y, 200, accuracy: 1)
        XCTAssertEqual(remapped.width, 400, accuracy: 1)
        XCTAssertEqual(remapped.height, 400, accuracy: 1)
    }

    func testRemapResultIsTemporaryUntilConfirmed() {
        let oldTopology = CanvasTopologyMapping(regions: [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1000, height: 1000))
        ])
        let result = CanvasRemappingEngine.remap(
            savedLayout: SavedCanvasLayout(),
            oldTopology: oldTopology,
            newRegions: [CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 2000, height: 2000))]
        )
        XCTAssertFalse(result.isConfirmed)
        XCTAssertEqual(result.mapping.revision, 2)
    }

    // MARK: - isContinuousRegion (no seam-crossing)

    func testIsContinuousRegionWithinSingleRegion() {
        let regions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900)),
            CanvasRegionIdentity(id: "r2", frame: CanvasRect(x: 1440, y: 0, width: 1920, height: 900))
        ]
        let frame = CanvasRect(x: 100, y: 100, width: 500, height: 500)
        XCTAssertTrue(CanvasRemappingEngine.isContinuousRegion(frame, across: regions))
    }

    func testIsNotContinuousWhenCrossingSeam() {
        let regions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900)),
            CanvasRegionIdentity(id: "r2", frame: CanvasRect(x: 1440, y: 0, width: 1920, height: 900))
        ]
        // This frame straddles the seam at x=1440.
        let frame = CanvasRect(x: 1000, y: 100, width: 1000, height: 500)
        XCTAssertFalse(CanvasRemappingEngine.isContinuousRegion(frame, across: regions))
    }

    // MARK: - clampToContinuousRegion

    func testClampPullsCrossingFrameIntoNearestRegion() {
        let regions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900)),
            CanvasRegionIdentity(id: "r2", frame: CanvasRect(x: 1440, y: 0, width: 1920, height: 900))
        ]
        // Frame crosses the seam at x=1440, centered slightly left.
        let frame = CanvasRect(x: 1300, y: 100, width: 400, height: 500)
        let clamped = CanvasRemappingEngine.clampToContinuousRegion(frame, across: regions)

        // Should now fit within r1 (nearest by center).
        XCTAssertTrue(CanvasRemappingEngine.isContinuousRegion(clamped, across: regions))
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, 1440 + 0.5)
    }

    func testClampLeavesContinuousFrameUnchanged() {
        let regions = [
            CanvasRegionIdentity(id: "r1", frame: CanvasRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        let frame = CanvasRect(x: 100, y: 100, width: 500, height: 500)
        let clamped = CanvasRemappingEngine.clampToContinuousRegion(frame, across: regions)
        XCTAssertEqual(clamped, frame)
    }
}
