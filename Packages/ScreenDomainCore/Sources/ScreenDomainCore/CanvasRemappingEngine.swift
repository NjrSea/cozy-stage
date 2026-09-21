// MARK: - Phase 1B: Canvas remapping engine

/// All connected extended displays form one stitched Canvas in macOS global
/// coordinates. Layout geometry is saved relative to the Canvas and re-mapped
/// when the connected topology changes.
///
/// Hardware rectangles are invisible layout constraints: a Pane may not cross a
/// physical bezel or occupy a discontinuous region.
public enum CanvasRemappingEngine {

    /// Computes the bounding box of all regions — the stitched Canvas.
    /// Returns a 1×1 degenerate rect if regions is empty.
    public static func rebuildCanvas(from regions: [CanvasRegionIdentity]) -> CanvasRect {
        guard !regions.isEmpty else {
            return CanvasRect(x: 0, y: 0, width: 1, height: 1)
        }
        let minX = regions.map(\.frame.x).min() ?? 0
        let minY = regions.map(\.frame.y).min() ?? 0
        let maxX = regions.map { $0.frame.x + $0.frame.width }.max() ?? 1
        let maxY = regions.map { $0.frame.y + $0.frame.height }.max() ?? 1
        return CanvasRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Detects seams between adjacent regions in a topology. A seam is a shared
    /// edge between two regions.
    public static func detectSeams(in regions: [CanvasRegionIdentity]) -> [CanvasSeam] {
        var seams: [CanvasSeam] = []
        for i in 0..<regions.count {
            for j in (i + 1)..<regions.count {
                let a = regions[i].frame
                let b = regions[j].frame
                // Vertical seam: a's right edge == b's left edge (or vice versa), overlapping Y.
                if isVerticalSeam(a, b), let pos = verticalSeamPosition(a, b) {
                    seams.append(CanvasSeam(regionIDs: [regions[i].id, regions[j].id], edge: .vertical, position: pos))
                }
                // Horizontal seam: a's bottom edge == b's top edge (or vice versa), overlapping X.
                if isHorizontalSeam(a, b), let pos = horizontalSeamPosition(a, b) {
                    seams.append(CanvasSeam(regionIDs: [regions[i].id, regions[j].id], edge: .horizontal, position: pos))
                }
            }
        }
        return seams
    }

    /// Remaps saved Canvas-relative frames into a new topology, preserving
    /// relative positions and Pane ratios when possible.
    ///
    /// The result is **temporary** (`isConfirmed == false`) until the user
    /// confirms it should replace the saved geometry.
    public static func remap(
        savedLayout: SavedCanvasLayout,
        oldTopology: CanvasTopologyMapping,
        newRegions: [CanvasRegionIdentity]
    ) -> CanvasRemapResult {
        let newCanvas = rebuildCanvas(from: newRegions)
        let oldCanvas = rebuildCanvas(from: oldTopology.regions)

        // Remap each saved frame proportionally from old canvas to new canvas.
        var remapped: [String: CanvasRect] = [:]
        for (slotID, oldFrame) in savedLayout.windowFrames {
            let relativeX = oldCanvas.width > 0 ? (oldFrame.x - oldCanvas.x) / oldCanvas.width : 0
            let relativeY = oldCanvas.height > 0 ? (oldFrame.y - oldCanvas.y) / oldCanvas.height : 0
            let relativeW = oldCanvas.width > 0 ? oldFrame.width / oldCanvas.width : 1
            let relativeH = oldCanvas.height > 0 ? oldFrame.height / oldCanvas.height : 1

            let newX = newCanvas.x + relativeX * newCanvas.width
            let newY = newCanvas.y + relativeY * newCanvas.height
            let newW = relativeW * newCanvas.width
            let newH = relativeH * newCanvas.height

            // Clamp to positive dimensions (CanvasRect requires width/height > 0).
            let clampedW = max(newW, 1)
            let clampedH = max(newH, 1)

            remapped[slotID] = CanvasRect(x: newX, y: newY, width: clampedW, height: clampedH)
        }

        let newMapping = CanvasTopologyMapping(
            regions: newRegions,
            seams: detectSeams(in: newRegions),
            revision: oldTopology.revision + 1
        )

        return CanvasRemapResult(mapping: newMapping, remappedFrames: remapped, isConfirmed: false)
    }

    /// Checks whether a frame fits entirely within a single continuous region,
    /// without crossing a seam (a Pane may not cross a physical bezel).
    public static func isContinuousRegion(
        _ frame: CanvasRect,
        across regions: [CanvasRegionIdentity]
    ) -> Bool {
        // A frame is continuous if it fits entirely within at least one region.
        regions.contains { region in
            frame.x >= region.frame.x
                && frame.y >= region.frame.y
                && frame.x + frame.width <= region.frame.x + region.frame.width + 0.5
                && frame.y + frame.height <= region.frame.y + region.frame.height + 0.5
        }
    }

    /// Clamps a frame to the nearest containing region so it doesn't cross a
    /// seam.
    public static func clampToContinuousRegion(
        _ frame: CanvasRect,
        across regions: [CanvasRegionIdentity]
    ) -> CanvasRect {
        // If already continuous, return as-is.
        if isContinuousRegion(frame, across: regions) {
            return frame
        }
        // Find the region whose center is closest to the frame's center.
        let frameCenter = frame.center
        guard let nearest = regions.min(by: { lhs, rhs in
            distanceSquared(from: frameCenter, to: lhs.frame.center)
                < distanceSquared(from: frameCenter, to: rhs.frame.center)
        }) else {
            return frame
        }
        // Clamp to the nearest region bounds.
        let clampedX = max(frame.x, nearest.frame.x)
        let clampedY = max(frame.y, nearest.frame.y)
        let clampedRight = min(frame.x + frame.width, nearest.frame.x + nearest.frame.width)
        let clampedBottom = min(frame.y + frame.height, nearest.frame.y + nearest.frame.height)
        let clampedW = max(clampedRight - clampedX, 1)
        let clampedH = max(clampedBottom - clampedY, 1)
        return CanvasRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }

    // MARK: - Private seam detection helpers

    private static func isVerticalSeam(_ a: CanvasRect, _ b: CanvasRect) -> Bool {
        // A is left of B: a.right ≈ b.left, Y ranges overlap
        let aRight = a.x + a.width
        let bRight = b.x + b.width
        let xAdjacent = abs(aRight - b.x) < 1 || abs(bRight - a.x) < 1
        let yOverlap = !(a.y + a.height <= b.y + 1 || b.y + b.height <= a.y + 1)
        return xAdjacent && yOverlap
    }

    private static func isHorizontalSeam(_ a: CanvasRect, _ b: CanvasRect) -> Bool {
        let aBottom = a.y + a.height
        let bBottom = b.y + b.height
        let yAdjacent = abs(aBottom - b.y) < 1 || abs(bBottom - a.y) < 1
        let xOverlap = !(a.x + a.width <= b.x + 1 || b.x + b.width <= a.x + 1)
        return yAdjacent && xOverlap
    }

    private static func verticalSeamPosition(_ a: CanvasRect, _ b: CanvasRect) -> Double? {
        let aRight = a.x + a.width
        if abs(aRight - b.x) < 1 { return aRight }
        let bRight = b.x + b.width
        if abs(bRight - a.x) < 1 { return bRight }
        return nil
    }

    private static func horizontalSeamPosition(_ a: CanvasRect, _ b: CanvasRect) -> Double? {
        let aBottom = a.y + a.height
        if abs(aBottom - b.y) < 1 { return aBottom }
        let bBottom = b.y + b.height
        if abs(bBottom - a.y) < 1 { return bBottom }
        return nil
    }

    private static func distanceSquared(from a: CanvasPoint, to b: CanvasPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

/// The result of a Canvas remap operation.
public struct CanvasRemapResult: Equatable, Sendable {
    public let mapping: CanvasTopologyMapping
    public let remappedFrames: [String: CanvasRect]
    /// `false` = temporary preview until the user confirms.
    public let isConfirmed: Bool

    public init(mapping: CanvasTopologyMapping, remappedFrames: [String: CanvasRect], isConfirmed: Bool) {
        self.mapping = mapping
        self.remappedFrames = remappedFrames
        self.isConfirmed = isConfirmed
    }
}
