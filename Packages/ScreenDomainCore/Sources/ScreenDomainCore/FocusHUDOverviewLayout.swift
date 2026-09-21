public struct FocusHUDOverviewLayoutConstraints: Equatable, Sendable {
    public let safeWidth: Double
    public let safeHeight: Double
    public let outerMargin: Double
    public let relaxedCellSize: Double
    public let minimumCellSize: Double
    public let horizontalGap: Double
    public let verticalGap: Double
    public let groupHeaderHeight: Double
    public let emptyWorkspaceHeight: Double
    public let groupGap: Double
    public let minimumPanelWidth: Double
    public let contentInset: Double

    public init(
        safeWidth: Double,
        safeHeight: Double,
        outerMargin: Double,
        relaxedCellSize: Double,
        minimumCellSize: Double,
        horizontalGap: Double,
        verticalGap: Double,
        groupHeaderHeight: Double,
        emptyWorkspaceHeight: Double,
        groupGap: Double,
        minimumPanelWidth: Double = 0,
        contentInset: Double = 0
    ) {
        self.safeWidth = safeWidth
        self.safeHeight = safeHeight
        self.outerMargin = outerMargin
        self.relaxedCellSize = relaxedCellSize
        self.minimumCellSize = minimumCellSize
        self.horizontalGap = horizontalGap
        self.verticalGap = verticalGap
        self.groupHeaderHeight = groupHeaderHeight
        self.emptyWorkspaceHeight = emptyWorkspaceHeight
        self.groupGap = groupGap
        self.minimumPanelWidth = minimumPanelWidth
        self.contentInset = contentInset
    }
}

public struct FocusHUDWorkspaceLayout: Equatable, Sendable {
    public let appCount: Int
    public let columnCount: Int
    public let rowCount: Int
    public let cellSize: Double

    public init(appCount: Int, columnCount: Int, rowCount: Int, cellSize: Double) {
        self.appCount = appCount
        self.columnCount = columnCount
        self.rowCount = rowCount
        self.cellSize = cellSize
    }
}

public struct FocusHUDOverviewLayout: Equatable, Sendable {
    public let panelWidth: Double
    public let panelHeight: Double
    public let cellSize: Double
    public let workspaceLayouts: [FocusHUDWorkspaceLayout]
    public let contentInset: Double
    public var contentWidth: Double { panelWidth - 2 * contentInset }
    public var contentHeight: Double { panelHeight - 2 * contentInset }

    public init(
        panelWidth: Double,
        panelHeight: Double,
        cellSize: Double,
        workspaceLayouts: [FocusHUDWorkspaceLayout],
        contentInset: Double = 0
    ) {
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
        self.cellSize = cellSize
        self.workspaceLayouts = workspaceLayouts
        self.contentInset = contentInset
    }
}

public enum FocusHUDOverviewLayoutFailure: String, Equatable, Sendable {
    case layoutUnavailable = "layout_unavailable"
}

public enum FocusHUDOverviewLayoutResult: Equatable, Sendable {
    case available(FocusHUDOverviewLayout)
    case unavailable(FocusHUDOverviewLayoutFailure)

    public var availableLayout: FocusHUDOverviewLayout? {
        guard case let .available(layout) = self else { return nil }
        return layout
    }
}

public enum FocusHUDOverviewLayoutEngine {
    /// An empty list has no content height and uses the configured minimum width.
    public static func compute(
        appCounts: [Int],
        constraints: FocusHUDOverviewLayoutConstraints
    ) -> FocusHUDOverviewLayoutResult {
        guard valid(constraints), !appCounts.contains(where: { $0 < 0 }),
              let availableWidth = available(constraints.safeWidth, margin: constraints.outerMargin),
              let availableHeight = available(constraints.safeHeight, margin: constraints.outerMargin)
        else {
            return .unavailable(.layoutUnavailable)
        }

        if let layout = layout(
            appCounts: appCounts,
            cellSize: constraints.relaxedCellSize,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            constraints: constraints
        ) {
            return .available(layout)
        }
        guard let minimumLayout = layout(
            appCounts: appCounts,
            cellSize: constraints.minimumCellSize,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            constraints: constraints
        ) else {
            return .unavailable(.layoutUnavailable)
        }

        var lower = constraints.minimumCellSize
        var upper = constraints.relaxedCellSize
        // Binary64 needs at most 2,098 halvings across its positive finite exponent range.
        for _ in 0..<2_100 {
            let midpoint = lower + (upper - lower) / 2
            guard midpoint > lower, midpoint < upper else { break }
            if layout(
                appCounts: appCounts,
                cellSize: midpoint,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                constraints: constraints
            ) != nil {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }

        let candidate = phaseCandidate(
            atOrBelow: upper,
            relaxedCellSize: constraints.relaxedCellSize
        )
        if candidate >= constraints.minimumCellSize,
           let currentLayout = layout(
                appCounts: appCounts,
                cellSize: candidate,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                constraints: constraints
           ) {
            let next = nextPhaseCandidate(after: candidate)
            if next <= constraints.relaxedCellSize,
               let nextLayout = layout(
                    appCounts: appCounts,
                    cellSize: next,
                    availableWidth: availableWidth,
                    availableHeight: availableHeight,
                    constraints: constraints
               ) {
                return .available(nextLayout)
            }
            return .available(currentLayout)
        }
        let previous = previousPhaseCandidate(before: candidate)
        if previous >= constraints.minimumCellSize,
           let layout = layout(
                appCounts: appCounts,
                cellSize: previous,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                constraints: constraints
           ) {
            return .available(layout)
        }
        return .available(minimumLayout)
    }

    private static func valid(_ constraints: FocusHUDOverviewLayoutConstraints) -> Bool {
        let values = [
            constraints.safeWidth, constraints.safeHeight, constraints.outerMargin,
            constraints.relaxedCellSize, constraints.minimumCellSize,
            constraints.horizontalGap, constraints.verticalGap,
            constraints.groupHeaderHeight, constraints.emptyWorkspaceHeight,
            constraints.groupGap, constraints.minimumPanelWidth,
            constraints.contentInset
        ]
        return values.allSatisfy(\.isFinite)
            && constraints.safeWidth > 0
            && constraints.safeHeight > 0
            && constraints.relaxedCellSize > 0
            && constraints.minimumCellSize > 0
            && constraints.outerMargin >= 0
            && constraints.horizontalGap >= 0
            && constraints.verticalGap >= 0
            && constraints.groupHeaderHeight >= 0
            && constraints.emptyWorkspaceHeight >= 0
            && constraints.groupGap >= 0
            && constraints.minimumPanelWidth >= 0
            && constraints.contentInset >= 0
            && constraints.relaxedCellSize >= constraints.minimumCellSize
    }

    private static func available(_ safeSize: Double, margin: Double) -> Double? {
        let size = safeSize - 2 * margin
        return size.isFinite && size >= 0 ? size : nil
    }

    private static func phaseCandidate(atOrBelow maximum: Double, relaxedCellSize: Double) -> Double {
        let phase = relaxedCellSize.truncatingRemainder(dividingBy: 1)
        let candidate = (maximum - phase).rounded(.down) + phase
        return candidate <= maximum ? candidate : previousPhaseCandidate(before: candidate)
    }

    private static func previousPhaseCandidate(before candidate: Double) -> Double {
        let previous = candidate - 1
        return previous < candidate ? previous : candidate.nextDown
    }

    private static func nextPhaseCandidate(after candidate: Double) -> Double {
        let next = candidate + 1
        return next > candidate ? next : candidate.nextUp
    }

    private static func layout(
        appCounts: [Int],
        cellSize: Double,
        availableWidth: Double,
        availableHeight: Double,
        constraints: FocusHUDOverviewLayoutConstraints
    ) -> FocusHUDOverviewLayout? {
        guard let availableContentWidth = available(
            availableWidth,
            margin: constraints.contentInset
        ), let availableContentHeight = available(
            availableHeight,
            margin: constraints.contentInset
        ) else {
            return nil
        }
        let insetExtent = 2 * constraints.contentInset
        var workspaceLayouts: [FocusHUDWorkspaceLayout] = []
        var contentWidth = max(0, constraints.minimumPanelWidth - insetExtent)
        var contentHeight = 0.0

        for (index, appCount) in appCounts.enumerated() {
            if index > 0, !add(constraints.groupGap, to: &contentHeight) {
                return nil
            }
            guard add(constraints.groupHeaderHeight, to: &contentHeight) else { return nil }

            if appCount == 0 {
                guard add(constraints.emptyWorkspaceHeight, to: &contentHeight) else { return nil }
                workspaceLayouts.append(FocusHUDWorkspaceLayout(
                    appCount: 0, columnCount: 0, rowCount: 0, cellSize: cellSize
                ))
                continue
            }

            guard let grid = grid(
                appCount: appCount,
                cellSize: cellSize,
                availableWidth: availableContentWidth,
                horizontalGap: constraints.horizontalGap,
                verticalGap: constraints.verticalGap
            ), add(grid.height, to: &contentHeight) else {
                return nil
            }
            contentWidth = max(contentWidth, grid.width)
            workspaceLayouts.append(FocusHUDWorkspaceLayout(
                appCount: appCount,
                columnCount: grid.columns,
                rowCount: grid.rows,
                cellSize: cellSize
            ))
        }

        var panelWidth = contentWidth
        var panelHeight = contentHeight
        guard add(insetExtent, to: &panelWidth),
              add(insetExtent, to: &panelHeight),
              contentWidth <= availableContentWidth,
              contentHeight <= availableContentHeight,
              panelWidth <= availableWidth,
              panelHeight <= availableHeight
        else { return nil }
        return FocusHUDOverviewLayout(
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            cellSize: cellSize,
            workspaceLayouts: workspaceLayouts,
            contentInset: constraints.contentInset
        )
    }

    private static func grid(
        appCount: Int,
        cellSize: Double,
        availableWidth: Double,
        horizontalGap: Double,
        verticalGap: Double
    ) -> (columns: Int, rows: Int, width: Double, height: Double)? {
        for rows in 1...3 {
            let columns = appCount / rows + (appCount % rows == 0 ? 0 : 1)
            guard let width = extent(count: columns, size: cellSize, gap: horizontalGap),
                  width <= availableWidth,
                  let height = extent(count: rows, size: cellSize, gap: verticalGap)
            else {
                continue
            }
            return (columns, rows, width, height)
        }
        return nil
    }

    private static func extent(count: Int, size: Double, gap: Double) -> Double? {
        let extent = Double(count) * size + Double(count - 1) * gap
        return extent.isFinite ? extent : nil
    }

    private static func add(_ value: Double, to total: inout Double) -> Bool {
        let result = total + value
        guard result.isFinite else { return false }
        total = result
        return true
    }
}
