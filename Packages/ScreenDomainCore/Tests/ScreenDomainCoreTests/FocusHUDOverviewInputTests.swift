import XCTest
@testable import ScreenDomainCore

final class FocusHUDOverviewInputTests: XCTestCase {
    private let shiftedSymbols = Array(")!@#$%^&*(")

    func testShortcutAssignmentUsesGlobalVisualOrderAndExpectedBoundaryLabels() throws {
        let windowIDs = (0..<73).map { "w\($0)" }
        let assignments = try FocusHUDShortcutAssignment.assign(
            windowIDs: windowIDs,
            shiftedDigitSymbols: shiftedSymbols
        )

        XCTAssertEqual(assignments[0], assignment("w0", .letter("a"), false, "a"))
        XCTAssertEqual(assignments[25], assignment("w25", .letter("z"), false, "z"))
        XCTAssertEqual(assignments[26], assignment("w26", .letter("a"), true, "A"))
        XCTAssertEqual(assignments[51], assignment("w51", .letter("z"), true, "Z"))
        XCTAssertEqual(assignments[52], assignment("w52", .digit(0), false, "0"))
        XCTAssertEqual(assignments[61], assignment("w61", .digit(9), false, "9"))
        XCTAssertEqual(assignments[62], assignment("w62", .digit(0), true, ")"))
        XCTAssertEqual(assignments[71], assignment("w71", .digit(9), true, "("))
        XCTAssertEqual(assignments[72], FocusHUDShortcutAssignment(windowID: "w72", shortcut: nil))
    }

    func testShortcutAssignmentRejectsAnyShiftedDigitSymbolCountOtherThanTen() {
        for count in [0, 9, 11] {
            XCTAssertThrowsError(
                try FocusHUDShortcutAssignment.assign(
                    windowIDs: ["w1"],
                    shiftedDigitSymbols: Array(repeating: "x", count: count)
                )
            ) { error in
                XCTAssertEqual(error as? FocusHUDShortcutAssignmentError, .invalidShiftedDigitSymbolCount(count))
            }
        }
    }

    func testShortcutChordsActivateLowercaseUppercaseDigitAndShiftedDigitWindows() throws {
        let windowIDs = (0..<72).map { "w\($0)" }
        let assignments = try FocusHUDShortcutAssignment.assign(
            windowIDs: windowIDs,
            shiftedDigitSymbols: shiftedSymbols
        )
        let state = FocusHUDOverviewInputState(
            rows: [windowIDs],
            assignments: Dictionary(uniqueKeysWithValues: assignments.compactMap { assignment in
                guard let shortcut = assignment.shortcut else { return nil }
                return (shortcut.chord, assignment.windowID)
            }),
            focusedWindowID: nil
        )

        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("a"), shifted: false), state: state),
            .activateWindow("w0")
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("a"), shifted: true), state: state),
            .activateWindow("w26")
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.digit(0), shifted: false), state: state),
            .activateWindow("w52")
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.digit(0), shifted: true), state: state),
            .activateWindow("w62")
        )
    }

    func testUppercaseInputNormalizesToTheSamePhysicalLetter() {
        let state = FocusHUDOverviewInputState(
            rows: [["lower", "upper"]],
            assignments: [
                FocusHUDShortcutChord(physicalKey: .letter("a"), requiresShift: false): "lower",
                FocusHUDShortcutChord(physicalKey: .letter("a"), requiresShift: true): "upper"
            ]
        )

        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("a"), shifted: false), state: state),
            .activateWindow("lower")
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("A"), shifted: false), state: state),
            .activateWindow("lower")
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("A"), shifted: true), state: state),
            .activateWindow("upper")
        )
    }

    func testNonASCIILettersAndOutOfRangeDigitsFailClosed() {
        let state = FocusHUDOverviewInputState(
            rows: [["target"]],
            assignments: [FocusHUDShortcutChord(physicalKey: .letter("a"), requiresShift: false): "target"]
        )

        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("é"), shifted: false), state: state),
            .none
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter(Character("a\u{301}")), shifted: false), state: state),
            .none
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.digit(-1), shifted: false), state: state),
            .none
        )
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.digit(10), shifted: false), state: state),
            .none
        )
    }

    func testStaleShortcutAssignmentTargetIsRejected() {
        let state = FocusHUDOverviewInputState(
            rows: [["visible"]],
            assignments: [FocusHUDShortcutChord(physicalKey: .letter("a"), requiresShift: false): "stale"]
        )

        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("a"), shifted: false), state: state),
            .none
        )
    }

    func testDuplicateWindowIDsFailClosedForShortcutAndNavigation() {
        let state = FocusHUDOverviewInputState(
            rows: [["a", "b"], ["c", "a"]],
            assignments: [FocusHUDShortcutChord(physicalKey: .letter("a"), requiresShift: false): "b"],
            focusedWindowID: "b"
        )

        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.shortcut(.letter("a"), shifted: false), state: state),
            .none
        )
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.right, state: state), .none)
        XCTAssertEqual(
            FocusHUDOverviewInputReducer.handle(.tab, state: state),
            .activatePreviousApplication
        )
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.escape, state: state), .cancel)
    }

    func testReturnTabAndEscapeProduceExpectedIntents() {
        let state = FocusHUDOverviewInputState(
            rows: [["w1"]],
            assignments: [:],
            focusedWindowID: "w1"
        )

        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.returnKey, state: state), .activateWindow("w1"))
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.tab, state: state), .activatePreviousApplication)
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.escape, state: state), .cancel)
    }

    func testLeftAndRightStopAtCurrentRowEdges() {
        let middle = FocusHUDOverviewInputState(rows: [["a", "b", "c"]], assignments: [:], focusedWindowID: "b")
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.left, state: middle), .focusWindow("a"))
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.right, state: middle), .focusWindow("c"))

        let first = FocusHUDOverviewInputState(rows: [["a", "b", "c"]], assignments: [:], focusedWindowID: "a")
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.left, state: first), .none)
        let last = FocusHUDOverviewInputState(rows: [["a", "b", "c"]], assignments: [:], focusedWindowID: "c")
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.right, state: last), .none)
    }

    func testUpAndDownClampColumnsAndSkipEmptyRows() {
        let state = FocusHUDOverviewInputState(
            rows: [["a", "b", "c"], [], ["d"]],
            assignments: [:],
            focusedWindowID: "c"
        )
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.down, state: state), .focusWindow("d"))

        let lowerState = FocusHUDOverviewInputState(
            rows: [["a", "b", "c"], [], ["d"]],
            assignments: [:],
            focusedWindowID: "d"
        )
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.up, state: lowerState), .focusWindow("a"))
    }

    func testDirectionalInputWithoutValidFocusUsesDeterministicVisualTargets() {
        let state = FocusHUDOverviewInputState(
            rows: [[], ["a", "b"], [], ["c"]],
            assignments: [:],
            focusedWindowID: nil
        )

        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.left, state: state), .focusWindow("a"))
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.up, state: state), .focusWindow("a"))
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.right, state: state), .focusWindow("c"))
        XCTAssertEqual(FocusHUDOverviewInputReducer.handle(.down, state: state), .focusWindow("c"))
    }

    func testEmptyStateAndEmptyRowsAreSafe() {
        let state = FocusHUDOverviewInputState(rows: [[], []], assignments: [:], focusedWindowID: nil)
        for key in [FocusHUDOverviewKey.left, .right, .up, .down, .returnKey] {
            XCTAssertEqual(FocusHUDOverviewInputReducer.handle(key, state: state), .none)
        }
        XCTAssertNil(state.focusedWindowID)
    }

    private func assignment(
        _ windowID: ManagedWindowID,
        _ physicalKey: FocusHUDPhysicalKey,
        _ requiresShift: Bool,
        _ label: Character
    ) -> FocusHUDShortcutAssignment {
        FocusHUDShortcutAssignment(
            windowID: windowID,
            shortcut: FocusHUDShortcut(
                chord: FocusHUDShortcutChord(physicalKey: physicalKey, requiresShift: requiresShift),
                label: label
            )
        )
    }
}
