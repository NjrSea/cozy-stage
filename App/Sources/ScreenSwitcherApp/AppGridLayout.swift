public struct AppGridItem: Equatable, Sendable {
    public let absoluteIndex: Int
    public let row: Int
    public let column: Int
    public let shortcut: String

    public init(absoluteIndex: Int, row: Int, column: Int, shortcut: String) {
        self.absoluteIndex = absoluteIndex
        self.row = row
        self.column = column
        self.shortcut = shortcut
    }
}

public struct AppGridLayout: Equatable, Sendable {
    public static let cellSize: Double = 64
    public static let minimumColumnGap: Double = 12
    public static let iconSize: Double = 48

    public let columns: Int
    /// Minimum container width needed to render all fixed cells with the minimum gap.
    ///
    /// Consumers, including the Stage 1 Task 7 UI, must size the rendered grid to at
    /// least this width rather than treating the initializer's cell budget as the
    /// final container width.
    public let requiredRenderedWidth: Double
    public let pageCapacity: Int
    public let pageCount: Int

    private let itemCount: Int

    /// Creates a semantic grid from the width budget available to its 64pt cells.
    ///
    /// `availableWidth` intentionally excludes inter-column gaps so the approved
    /// `680 -> 10 columns` case remains stable. Rendering uses fixed 48pt icons,
    /// fixed 64pt cells, and gaps of at least 12pt; use `requiredRenderedWidth` for
    /// the actual container requirement.
    public init(availableWidth: Double, itemCount: Int) {
        columns = Self.columnCount(for: availableWidth)
        requiredRenderedWidth = Double(columns) * Self.cellSize
            + Double(columns - 1) * Self.minimumColumnGap
        pageCapacity = min(columns * 3, 26)
        self.itemCount = max(0, itemCount)
        pageCount = self.itemCount == 0
            ? 0
            : 1 + (self.itemCount - 1) / pageCapacity
    }

    public func items(onPage page: Int) -> [AppGridItem] {
        guard page >= 0, page < pageCount else {
            return []
        }

        let startIndex = page * pageCapacity
        let count = min(pageCapacity, itemCount - startIndex)
        return (0..<count).map { localIndex in
            AppGridItem(
                absoluteIndex: startIndex + localIndex,
                row: localIndex / columns,
                column: localIndex % columns,
                shortcut: Self.shortcut(for: localIndex)
            )
        }
    }

    public func rowCount(onPage page: Int) -> Int {
        guard let lastItem = items(onPage: page).last else {
            return 0
        }
        return lastItem.row + 1
    }

    private static func columnCount(for availableWidth: Double) -> Int {
        guard availableWidth.isFinite, availableWidth >= 0 else {
            return 8
        }

        let proposed = availableWidth / cellSize
        if proposed <= 8 {
            return 8
        }
        if proposed >= 12 {
            return 12
        }
        return Int(proposed.rounded(.down))
    }

    private static func shortcut(for localIndex: Int) -> String {
        String(UnicodeScalar(65 + localIndex)!)
    }
}
