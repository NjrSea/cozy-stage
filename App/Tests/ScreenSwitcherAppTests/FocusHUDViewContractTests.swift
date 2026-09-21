import AppKit
import QuartzCore
import ScreenDomainCore
import SwiftUI
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class FocusHUDViewContractTests: XCTestCase {
    func testRenderModelKeepsWorkspaceOrderAndHeadersNonActionable() {
        let model = FocusHUDRenderModel(snapshot: snapshot())

        XCTAssertEqual(model.sections.map(\.title), ["Deep Work", "Comms", "Research"])
        XCTAssertEqual(model.sections.map(\.currentLabel), ["Current", nil, nil])
        XCTAssertTrue(model.sections.flatMap(\.actions).allSatisfy { $0.kind == .activateApp })
        XCTAssertEqual(model.sections.flatMap(\.actions).compactMap(\.windowID), ["w1", "w2", "w3", "w4"])
    }

    func testRenderModelUsesSnapshotRowsAndKeepsNamesAndOptionalShortcuts() {
        let model = FocusHUDRenderModel(snapshot: snapshot())
        let firstSection = model.sections[0]

        XCTAssertEqual(firstSection.rows.map(\.count), [2])
        XCTAssertEqual(model.sections[1].rows.map(\.count), [1])
        XCTAssertEqual(model.sections[2].rows.map(\.count), [1])
        XCTAssertEqual(firstSection.rows.flatMap { $0 }.map(\.appName), ["Mail", "Editor"])
        XCTAssertEqual(firstSection.rows.flatMap { $0 }.map(\.shortcutLabel), ["a", nil])
    }

    func testHoverTakesNameDisplayPrecedenceOverKeyboardFocus() {
        XCTAssertEqual(FocusHUDNameDisplay.visibleWindowID(hovered: "hovered", focused: "focused"), "hovered")
        XCTAssertEqual(FocusHUDNameDisplay.visibleWindowID(hovered: nil, focused: "focused"), "focused")
        XCTAssertNil(FocusHUDNameDisplay.visibleWindowID(hovered: nil, focused: nil))
    }

    func testAppSelectionEmphasisRequiresExactHoverOrKeyboardFocus() {
        XCTAssertFalse(FocusHUDNameDisplay.isHighlighted(windowID: "target", hovered: nil, focused: nil))
        XCTAssertTrue(FocusHUDNameDisplay.isHighlighted(windowID: "target", hovered: "target", focused: nil))
        XCTAssertTrue(FocusHUDNameDisplay.isHighlighted(windowID: "target", hovered: nil, focused: "target"))
        XCTAssertFalse(FocusHUDNameDisplay.isHighlighted(windowID: "target", hovered: "other", focused: "target"))
    }

    func testRenderModelPreservesThreeRowMajorRowsFromSnapshotLayout() {
        let apps = (1...5).map {
            app("w\($0)", screenID: "one", name: "App \($0)", shortcut: nil)
        }
        let snapshot = FocusHUDPresentationSnapshot(
            sections: [section("one", name: "Deep Work", apps: apps)],
            layout: .available(.init(
                panelWidth: 84,
                panelHeight: 128,
                cellSize: 40,
                workspaceLayouts: [.init(appCount: 5, columnCount: 2, rowCount: 3, cellSize: 40)]
            )),
            inventoryRevision: 1,
            keyAssignmentRevision: 1,
            presentationRevision: 1
        )

        XCTAssertEqual(FocusHUDRenderModel(snapshot: snapshot).sections[0].rows.map(\.count), [2, 2, 1])
    }

    func testRenderModelPreservesFrozenContentGeometry() throws {
        let model = FocusHUDRenderModel(snapshot: snapshot(layout: .available(.init(
            panelWidth: 132,
            panelHeight: 232,
            cellSize: 40,
            workspaceLayouts: [
                .init(appCount: 2, columnCount: 2, rowCount: 1, cellSize: 40),
                .init(appCount: 1, columnCount: 1, rowCount: 1, cellSize: 40),
                .init(appCount: 1, columnCount: 1, rowCount: 1, cellSize: 40),
            ],
            contentInset: 24
        ))))

        let layout = try XCTUnwrap(model.layout)
        XCTAssertEqual(layout.contentInset, 24)
        XCTAssertEqual(layout.contentWidth, 84)
        XCTAssertEqual(layout.contentHeight, 184)
    }

    func testUnavailableLayoutHasDismissOnly() {
        let model = FocusHUDRenderModel(snapshot: snapshot(layout: .unavailable(.layoutUnavailable)))

        XCTAssertEqual(model.state, .layoutUnavailable)
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertEqual(model.actions, [.dismiss])
    }

    func testMinimumMetricPreservesVisibleIconAndBadgeSizes() {
        let metrics = FocusHUDDesign.appMetrics(cellSize: 40)

        XCTAssertGreaterThanOrEqual(metrics.visibleIconSize, 32)
        XCTAssertEqual(metrics.nameFontSize, 8)
        XCTAssertEqual(metrics.nameRegionHeight, 0)
        XCTAssertEqual(metrics.badgeFontSize, 11)
    }

    func testLowercaseShortcutBadgeUsesRegularWeight() {
        XCTAssertEqual(FocusHUDDesign.shortcutBadgeWeight(for: "a"), .regular)
        XCTAssertEqual(FocusHUDDesign.shortcutBadgeWeight(for: "A"), .bold)
        XCTAssertEqual(FocusHUDDesign.shortcutBadgeWeight(for: "1"), .bold)
    }

    func testAppLogosUseWorkspaceTitleLeadingEdge() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { _ in
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSColor.red.setFill()
            NSRect(x: 2, y: 0, width: 6, height: 8).fill()
            return true
        }

        XCTAssertEqual(FocusHUDIconArtwork.leadingInsetFraction(for: image), 0.25, accuracy: 1.0 / 32.0)

        let metadata = LogoAlignmentMetadataProvider(image: image)
        let window = ManagedWindow(
            id: "window",
            appID: "app",
            canonicalFrame: CanvasRect(x: 0, y: 0, width: 100, height: 100)
        )
        let screen = FocusScreen(
            id: "screen",
            number: 1,
            lifecycle: .background,
            windowIDs: [window.id],
            lastActiveWindowID: window.id
        )
        let viewModel = FocusHUDViewModel(
            state: FocusScreenState(
                screens: [screen],
                windows: [window.id: window],
                activeScreenID: screen.id,
                inspectedScreenID: screen.id,
                revision: 1
            ),
            metadataProvider: metadata,
            intentHandler: { _ in }
        )
        viewModel.setWindowDiscoveryStatus(.ready)
        try viewModel.present(
            constraints: .init(
                safeWidth: 1_000,
                safeHeight: 1_000,
                outerMargin: 0,
                relaxedCellSize: 100,
                minimumCellSize: 100,
                horizontalGap: 4,
                verticalGap: 4,
                groupHeaderHeight: 20,
                emptyWorkspaceHeight: 24,
                groupGap: 6,
                minimumPanelWidth: 390,
                contentInset: 16
            ),
            shiftedDigitSymbols: Array(")!@#$%^&*("),
            inventoryRevision: 1
        )
        let layout = try XCTUnwrap(viewModel.snapshot?.layout.availableLayout)
        let size = NSSize(width: layout.panelWidth, height: layout.panelHeight)
        let hostingView = NSHostingView(rootView: FocusHUDView(viewModel: viewModel))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let redLeadingPixel = try XCTUnwrap((0..<bitmap.pixelsWide).first { x in
            (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
            }
        })
        let scale = CGFloat(bitmap.pixelsWide) / hostingView.bounds.width
        XCTAssertEqual(
            CGFloat(redLeadingPixel) / scale,
            CGFloat(layout.contentInset) + 6,
            accuracy: 1
        )
    }

    func testWorkspaceLayoutReservesVerticalInsetBelowHeader() {
        let constraints = FocusHUDController.layoutConstraints(
            in: CanvasRect(x: 0, y: 0, width: 1_000, height: 700)
        )

        XCTAssertEqual(constraints.groupHeaderHeight, 20)
    }

    func testViewSourceContainsNoWorkspaceNavigationOrHiddenOverflow() throws {
        let source = try String(contentsOf: focusHUDViewSourceURL())

        for forbidden in ["ScrollView(", "LazyVGrid(", "private var paginationControls", "private var screenRail", "viewModel.pageCount"] {
            XCTAssertFalse(source.contains(forbidden), "FocusHUDView must not contain \(forbidden)")
        }
        XCTAssertTrue(source.contains("let isHighlighted = FocusHUDNameDisplay.isHighlighted("))
        XCTAssertTrue(source.contains(
            ".frame(width: metrics.cellSize, height: metrics.cellSize, alignment: .leading)"
        ))
        XCTAssertTrue(source.contains(".padding(.top, FocusHUDDesign.workspaceContentTopInset)"))
        XCTAssertTrue(source.contains("viewModel.activateApp(windowID: app.id)"))
        XCTAssertTrue(source.contains("screen-switcher.hud.layout_unavailable"))
        XCTAssertTrue(source.contains("width: CGFloat(layout.contentWidth)"))
        XCTAssertTrue(source.contains("height: CGFloat(layout.contentHeight)"))
        XCTAssertTrue(source.contains(".padding(CGFloat(layout.contentInset))"))
        XCTAssertFalse(source.contains(".padding(FocusHUDDesign.contentInset)"))
        XCTAssertFalse(source.contains("maxHeight: CGFloat = 400"))
        XCTAssertFalse(source.contains("height: min(maxHeight"))
        XCTAssertTrue(source.contains(
            ".accessibilityElement(children: .combine)\n"
                + "            .accessibilityRespondsToUserInteraction(false)\n"
                + "            .accessibilityIdentifier(\"screen-switcher.hud.workspace."
        ))
    }

    func testFullHUDRenderAcknowledgementUsesTopmostFullRootCompositorOverlay() throws {
        let source = try String(contentsOf: focusHUDViewSourceURL())

        XCTAssertTrue(source.contains(
            ".overlay {\n"
                + "            FocusHUDRenderSentinel("
        ))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertFalse(source.contains(
            ".background {\n"
                + "            FocusHUDRenderSentinel("
        ))
        XCTAssertFalse(source.contains("CATransaction.begin()\n            CATransaction.setCompletionBlock"))
    }

    func testFullHUDRenderAcknowledgementWaitsForDelayedForegroundInCurrentCommit() async {
        let acknowledged = expectation(description: "full HUD compositor acknowledgement")
        var events: [String] = []
        let sentinel = FocusHUDRenderSentinel.RenderView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        sentinel.configure(
            presentationRevision: 7,
            interactionRevision: 3,
            state: .empty
        ) { presentationRevision, interactionRevision, _ in
            XCTAssertEqual(presentationRevision, 7)
            XCTAssertEqual(interactionRevision, 3)
            events.append("acknowledged")
            acknowledged.fulfill()
        }
        let foreground = ForegroundDrawProbe(frame: sentinel.frame) {
            events.append("foreground-drawn")
        }

        CATransaction.begin()
        sentinel.draw(sentinel.bounds)
        XCTAssertTrue(events.isEmpty)
        foreground.draw(foreground.bounds)
        XCTAssertEqual(events, ["foreground-drawn"])
        CATransaction.commit()

        await fulfillment(of: [acknowledged], timeout: 1)
        XCTAssertEqual(events, ["foreground-drawn", "acknowledged"])
    }

    private final class ForegroundDrawProbe: NSView {
        private let onDraw: () -> Void

        init(frame: NSRect, onDraw: @escaping () -> Void) {
            self.onDraw = onDraw
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            onDraw()
        }
    }

    private func snapshot(
        layout: FocusHUDOverviewLayoutResult? = nil
    ) -> FocusHUDPresentationSnapshot {
        let sections = [
            section("one", name: "Deep Work", current: true, apps: [
                app("w1", screenID: "one", name: "Mail", shortcut: shortcut("a")),
                app("w2", screenID: "one", name: "Editor", shortcut: nil),
            ]),
            section("two", name: "Comms", apps: [
                app("w3", screenID: "two", name: "Chat", shortcut: shortcut("b")),
            ]),
            section("three", name: "Research", apps: [
                app("w4", screenID: "three", name: "Browser", shortcut: shortcut("c")),
            ]),
        ]
        return FocusHUDPresentationSnapshot(
            sections: sections,
            layout: layout ?? .available(FocusHUDOverviewLayout(
                panelWidth: 84,
                panelHeight: 184,
                cellSize: 40,
                workspaceLayouts: [
                    .init(appCount: 2, columnCount: 2, rowCount: 1, cellSize: 40),
                    .init(appCount: 1, columnCount: 1, rowCount: 1, cellSize: 40),
                    .init(appCount: 1, columnCount: 1, rowCount: 1, cellSize: 40),
                ]
            )),
            inventoryRevision: 1,
            keyAssignmentRevision: 1,
            presentationRevision: 1
        )
    }

    private func section(
        _ id: FocusScreenID,
        name: String,
        current: Bool = false,
        apps: [FocusHUDAppEntry]
    ) -> FocusHUDWorkspaceSection {
        FocusHUDWorkspaceSection(
            id: id,
            screenID: id,
            ordinal: 1,
            name: name,
            isCurrent: current,
            apps: apps
        )
    }

    private func app(
        _ id: ManagedWindowID,
        screenID: FocusScreenID,
        name: String,
        shortcut: FocusHUDShortcut?
    ) -> FocusHUDAppEntry {
        FocusHUDAppEntry(
            id: id,
            screenID: screenID,
            appIdentityHash: "opaque-\(id)",
            appName: name,
            appIcon: nil,
            iconLeadingInsetFraction: 0,
            windowTitle: "Window \(id)",
            shortcut: shortcut,
            isCurrent: false
        )
    }

    private func shortcut(_ label: Character) -> FocusHUDShortcut {
        FocusHUDShortcut(
            chord: .init(physicalKey: .letter(label), requiresShift: false),
            label: label
        )
    }

    private func focusHUDViewSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ScreenSwitcherApp/FocusHUDView.swift")
    }
}

@MainActor
private final class LogoAlignmentMetadataProvider: FocusHUDWindowMetadataProviding {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
    }

    func metadata(for window: ManagedWindow) -> FocusHUDWindowMetadata {
        FocusHUDWindowMetadata(appName: "App", appIcon: image, windowTitle: "Window")
    }
}
