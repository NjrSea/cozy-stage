public enum FocusHUDPhysicalKey: Hashable, Sendable {
    case letter(Character)
    case digit(Int)
}

public struct FocusHUDShortcutChord: Hashable, Sendable {
    public let physicalKey: FocusHUDPhysicalKey
    public let requiresShift: Bool

    public init(physicalKey: FocusHUDPhysicalKey, requiresShift: Bool) {
        self.physicalKey = physicalKey
        self.requiresShift = requiresShift
    }
}

public struct FocusHUDShortcut: Hashable, Sendable {
    public let chord: FocusHUDShortcutChord
    public let label: Character

    public init(chord: FocusHUDShortcutChord, label: Character) {
        self.chord = chord
        self.label = label
    }
}

public enum FocusHUDShortcutAssignmentError: Error, Equatable, Sendable {
    case invalidShiftedDigitSymbolCount(Int)
}

public struct FocusHUDShortcutAssignment: Equatable, Sendable {
    public let windowID: ManagedWindowID
    public let shortcut: FocusHUDShortcut?

    public init(windowID: ManagedWindowID, shortcut: FocusHUDShortcut?) {
        self.windowID = windowID
        self.shortcut = shortcut
    }

    public static func assign(
        windowIDs: [ManagedWindowID],
        shiftedDigitSymbols: [Character]
    ) throws -> [Self] {
        guard shiftedDigitSymbols.count == 10 else {
            throw FocusHUDShortcutAssignmentError.invalidShiftedDigitSymbolCount(shiftedDigitSymbols.count)
        }

        let lowercaseLetters = Array("abcdefghijklmnopqrstuvwxyz")
        let uppercaseLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits = Array(0...9)

        return windowIDs.enumerated().map { index, windowID in
            let shortcut: FocusHUDShortcut?
            switch index {
            case 0..<26:
                shortcut = FocusHUDShortcut(
                    chord: FocusHUDShortcutChord(
                        physicalKey: .letter(lowercaseLetters[index]),
                        requiresShift: false
                    ),
                    label: lowercaseLetters[index]
                )
            case 26..<52:
                let offset = index - 26
                shortcut = FocusHUDShortcut(
                    chord: FocusHUDShortcutChord(
                        physicalKey: .letter(lowercaseLetters[offset]),
                        requiresShift: true
                    ),
                    label: uppercaseLetters[offset]
                )
            case 52..<62:
                let offset = index - 52
                shortcut = FocusHUDShortcut(
                    chord: FocusHUDShortcutChord(
                        physicalKey: .digit(digits[offset]),
                        requiresShift: false
                    ),
                    label: Character(String(digits[offset]))
                )
            case 62..<72:
                let offset = index - 62
                shortcut = FocusHUDShortcut(
                    chord: FocusHUDShortcutChord(
                        physicalKey: .digit(digits[offset]),
                        requiresShift: true
                    ),
                    label: shiftedDigitSymbols[offset]
                )
            default:
                shortcut = nil
            }
            return Self(windowID: windowID, shortcut: shortcut)
        }
    }
}

public struct FocusHUDOverviewInputState: Equatable, Sendable {
    public let rows: [[ManagedWindowID]]
    public let assignments: [FocusHUDShortcutChord: ManagedWindowID]
    public let focusedWindowID: ManagedWindowID?

    public init(
        rows: [[ManagedWindowID]] = [],
        assignments: [FocusHUDShortcutChord: ManagedWindowID] = [:],
        focusedWindowID: ManagedWindowID? = nil
    ) {
        self.rows = rows
        self.assignments = assignments
        self.focusedWindowID = focusedWindowID
    }
}

public enum FocusHUDOverviewKey: Equatable, Sendable {
    case shortcut(FocusHUDPhysicalKey, shifted: Bool)
    case left
    case right
    case up
    case down
    case tab
    case returnKey
    case escape
}

public enum FocusHUDOverviewIntent: Equatable, Sendable {
    case none
    case focusWindow(ManagedWindowID)
    case activateWindow(ManagedWindowID)
    case activatePreviousApplication
    case cancel
}

public enum FocusHUDOverviewInputReducer {
    public static func handle(
        _ key: FocusHUDOverviewKey,
        state: FocusHUDOverviewInputState
    ) -> FocusHUDOverviewIntent {
        switch key {
        case let .shortcut(physicalKey, shifted):
            guard !containsDuplicateWindowIDs(in: state.rows),
                  let chord = canonicalChord(for: physicalKey, shifted: shifted),
                  let windowID = state.assignments[chord],
                  isVisible(windowID, in: state.rows)
            else { return .none }
            return .activateWindow(windowID)
        case .returnKey:
            guard !containsDuplicateWindowIDs(in: state.rows),
                  let windowID = validFocusedWindow(in: state)
            else { return .none }
            return .activateWindow(windowID)
        case .tab:
            return .activatePreviousApplication
        case .escape:
            return .cancel
        case .left:
            guard !containsDuplicateWindowIDs(in: state.rows) else { return .none }
            return move(.left, in: state)
        case .right:
            guard !containsDuplicateWindowIDs(in: state.rows) else { return .none }
            return move(.right, in: state)
        case .up:
            guard !containsDuplicateWindowIDs(in: state.rows) else { return .none }
            return move(.up, in: state)
        case .down:
            guard !containsDuplicateWindowIDs(in: state.rows) else { return .none }
            return move(.down, in: state)
        }
    }

    private enum Direction {
        case left
        case right
        case up
        case down
    }

    private static func canonicalChord(
        for physicalKey: FocusHUDPhysicalKey,
        shifted: Bool
    ) -> FocusHUDShortcutChord? {
        switch physicalKey {
        case let .letter(character):
            let scalars = character.unicodeScalars
            guard scalars.count == 1,
                  let scalar = scalars.first
            else { return nil }

            let lowercaseValue: UInt32
            switch scalar.value {
            case 65...90:
                lowercaseValue = scalar.value + 32
            case 97...122:
                lowercaseValue = scalar.value
            default:
                return nil
            }
            guard let lowercaseScalar = UnicodeScalar(lowercaseValue) else { return nil }
            return FocusHUDShortcutChord(
                physicalKey: .letter(Character(String(lowercaseScalar))),
                requiresShift: shifted
            )
        case let .digit(number):
            guard (0...9).contains(number) else { return nil }
            return FocusHUDShortcutChord(physicalKey: .digit(number), requiresShift: shifted)
        }
    }

    private static func containsDuplicateWindowIDs(in rows: [[ManagedWindowID]]) -> Bool {
        var seen: Set<ManagedWindowID> = []
        for row in rows {
            for windowID in row {
                guard seen.insert(windowID).inserted else { return true }
            }
        }
        return false
    }

    private static func isVisible(
        _ windowID: ManagedWindowID,
        in rows: [[ManagedWindowID]]
    ) -> Bool {
        rows.contains { $0.contains(windowID) }
    }

    private static func move(
        _ direction: Direction,
        in state: FocusHUDOverviewInputState
    ) -> FocusHUDOverviewIntent {
        guard let focus = validFocusedLocation(in: state) else {
            let nonEmptyRows = state.rows.filter { !$0.isEmpty }
            guard let firstRow = nonEmptyRows.first,
                  let lastRow = nonEmptyRows.last
            else { return .none }

            switch direction {
            case .left, .up:
                return .focusWindow(firstRow[0])
            case .right, .down:
                return .focusWindow(lastRow[lastRow.count - 1])
            }
        }

        switch direction {
        case .left:
            guard focus.column > 0 else { return .none }
            return .focusWindow(state.rows[focus.row][focus.column - 1])
        case .right:
            guard focus.column + 1 < state.rows[focus.row].count else { return .none }
            return .focusWindow(state.rows[focus.row][focus.column + 1])
        case .up, .down:
            let rowStep = direction == .up ? -1 : 1
            var row = focus.row + rowStep
            while state.rows.indices.contains(row) {
                let targetRow = state.rows[row]
                if !targetRow.isEmpty {
                    let targetColumn = min(focus.column, targetRow.count - 1)
                    return .focusWindow(targetRow[targetColumn])
                }
                row += rowStep
            }
            return .none
        }
    }

    private static func validFocusedWindow(
        in state: FocusHUDOverviewInputState
    ) -> ManagedWindowID? {
        guard let focus = state.focusedWindowID,
              validFocusedLocation(in: state) != nil
        else { return nil }
        return focus
    }

    private static func validFocusedLocation(
        in state: FocusHUDOverviewInputState
    ) -> (row: Int, column: Int)? {
        guard let focusedWindowID = state.focusedWindowID else { return nil }
        for row in state.rows.indices {
            if let column = state.rows[row].firstIndex(of: focusedWindowID) {
                return (row, column)
            }
        }
        return nil
    }
}
