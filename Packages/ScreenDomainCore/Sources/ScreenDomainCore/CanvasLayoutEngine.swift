import Foundation

// MARK: - Phase 1C: Canvas layout engine

/// Computes Pane frames from layout kind, normalized ratios, available region,
/// and minimum sizes.
///
/// Ratios are normalized (0.0–1.0), not stored as absolute pixels. Minimum-size
/// constraints clamp the legal range so dividers cannot force panes below their
/// minimum ("App minimum sizes constrain divider movement").
public enum CanvasLayoutEngine {

    /// The default preset ratio for each layout kind (double-click
    /// restores the preset default).
    public static func defaultRatio(for kind: LayoutKind) -> PaneRatio {
        switch kind {
        case .asIs, .focus:
            return PaneRatio(primary: 1.0)
        case .split:
            return PaneRatio(primary: 0.5)
        case .focusStack:
            return PaneRatio(primary: 0.6, secondary: 0.5)
        }
    }

    /// Computes Pane frames for a layout, clamping to minimum sizes.
    public static func compute(
        kind: LayoutKind,
        ratios: [PaneID: PaneRatio],
        availableRegion: CanvasRect,
        minSizes: [PaneID: CGSize] = [:]
    ) -> ComputedLayout {
        switch kind {
        case .asIs, .focus:
            // Single pane fills the entire region.
            let paneID = ratios.keys.first ?? "pane-1"
            return ComputedLayout(
                paneFrames: [paneID: availableRegion],
                clamped: false
            )

        case .split:
            // Two side-by-side panes. Primary ratio = left pane width fraction.
            let paneIDs = sortedPaneIDs(from: ratios, expected: 2, fallback: ["pane-1", "pane-2"])
            let leftID = paneIDs[0]
            let rightID = paneIDs[1]
            let ratio = ratios[leftID] ?? defaultRatio(for: .split)

            let totalWidth = availableRegion.width
            let leftMinWidth = minSizes[leftID]?.width ?? 100
            let rightMinWidth = minSizes[rightID]?.width ?? 100

            // Clamp the split point to respect minimums.
            let minWidthFraction = leftMinWidth / totalWidth
            let maxWidthFraction = 1.0 - (rightMinWidth / totalWidth)
            let clampedFraction = min(max(ratio.primary, minWidthFraction), maxWidthFraction)
            let clamped = clampedFraction != ratio.primary

            let leftWidth = totalWidth * clampedFraction
            let leftFrame = CanvasRect(x: availableRegion.x, y: availableRegion.y, width: leftWidth, height: availableRegion.height)
            let rightFrame = CanvasRect(x: availableRegion.x + leftWidth, y: availableRegion.y, width: totalWidth - leftWidth, height: availableRegion.height)

            return ComputedLayout(
                paneFrames: [leftID: leftFrame, rightID: rightFrame],
                clamped: clamped
            )

        case .focusStack:
            // Primary pane + two stacked secondary panes.
            let paneIDs = sortedPaneIDs(from: ratios, expected: 3, fallback: ["pane-1", "pane-2", "pane-3"])
            let primaryID = paneIDs[0]
            let topID = paneIDs[1]
            let bottomID = paneIDs[2]
            let ratio = ratios[primaryID] ?? defaultRatio(for: .focusStack)

            let totalWidth = availableRegion.width
            let primaryMinWidth = minSizes[primaryID]?.width ?? 100
            let secondaryMinWidth = minSizes[topID]?.width ?? 100

            let minPrimaryFraction = primaryMinWidth / totalWidth
            let maxPrimaryFraction = 1.0 - (secondaryMinWidth / totalWidth)
            let clampedPrimary = min(max(ratio.primary, minPrimaryFraction), maxPrimaryFraction)
            let primaryClamped = clampedPrimary != ratio.primary

            let primaryWidth = totalWidth * clampedPrimary
            let secondaryWidth = totalWidth - primaryWidth

            // Vertical split of the secondary region.
            let secondaryRatio = ratio.secondary ?? 0.5
            let secondaryHeight = availableRegion.height
            let topMinHeight = minSizes[topID]?.height ?? 100
            let bottomMinHeight = minSizes[bottomID]?.height ?? 100

            let minTopFraction = topMinHeight / secondaryHeight
            let maxTopFraction = 1.0 - (bottomMinHeight / secondaryHeight)
            let clampedSecondary = min(max(secondaryRatio, minTopFraction), maxTopFraction)
            let secondaryClamped = clampedSecondary != secondaryRatio

            let topHeight = secondaryHeight * clampedSecondary
            let primaryFrame = CanvasRect(x: availableRegion.x, y: availableRegion.y, width: primaryWidth, height: availableRegion.height)
            let topFrame = CanvasRect(x: availableRegion.x + primaryWidth, y: availableRegion.y, width: secondaryWidth, height: topHeight)
            let bottomFrame = CanvasRect(x: availableRegion.x + primaryWidth, y: availableRegion.y + topHeight, width: secondaryWidth, height: secondaryHeight - topHeight)

            return ComputedLayout(
                paneFrames: [primaryID: primaryFrame, topID: topFrame, bottomID: bottomFrame],
                clamped: primaryClamped || secondaryClamped
            )
        }
    }

    /// Clamps a frame to a continuous Canvas region so it doesn't cross a
    /// physical bezel (delegates to CanvasRemappingEngine).
    public static func clampToContinuousRegion(
        _ frame: CanvasRect,
        across regions: [CanvasRegionIdentity]
    ) -> CanvasRect {
        CanvasRemappingEngine.clampToContinuousRegion(frame, across: regions)
    }

    /// Computes a stable divider position when minimum-size constraints conflict.
    /// When min sizes conflict (left min + right min > total), the divider settles
    /// at a stable midpoint instead of oscillating ("when constraints
    /// conflict, the layout stops at a stable bound instead of oscillating").
    public static func settleConflictingMinSizes(
        leftMin: CGFloat,
        rightMin: CGFloat,
        total: CGFloat
    ) -> CGFloat {
        if leftMin + rightMin <= total {
            // No conflict — normal range.
            return leftMin
        }
        // Conflict: settle at the midpoint of the overlap region.
        return total / 2
    }

    // MARK: - Private helpers

    private static func sortedPaneIDs(from ratios: [PaneID: PaneRatio], expected: Int, fallback: [PaneID]) -> [PaneID] {
        let ids = Array(ratios.keys).sorted()
        return ids.count == expected ? ids : fallback
    }
}

/// The result of a Canvas layout computation.
public struct ComputedLayout: Equatable, Sendable {
    public let paneFrames: [PaneID: CanvasRect]
    /// `true` if a minimum-size constraint clamped the ratio away from the
    /// requested value.
    public let clamped: Bool

    public init(paneFrames: [PaneID: CanvasRect], clamped: Bool) {
        self.paneFrames = paneFrames
        self.clamped = clamped
    }
}

// MARK: - CGFloat alias for CGSize compatibility with CoreGraphics

#if canImport(CoreGraphics)
import CoreGraphics
public typealias ScreenCGFloat = CGFloat
#else
public typealias ScreenCGFloat = Double
#endif
