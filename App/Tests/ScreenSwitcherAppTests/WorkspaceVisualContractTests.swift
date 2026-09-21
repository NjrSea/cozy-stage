import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WorkspaceVisualContractTests: XCTestCase {
    func testApprovedGeometryAndGridAllocationAreLiteral() {
        XCTAssertEqual(WorkspaceDesignTokens.leftRailWidth, 96)
        XCTAssertEqual(WorkspaceDesignTokens.leftRailPadding, 9)
        XCTAssertEqual(WorkspaceDesignTokens.leftRailItem, 76)
        XCTAssertEqual(WorkspaceDesignTokens.leftRailItemRadius, 18)
        XCTAssertEqual(WorkspaceDesignTokens.displayArtworkMaximum, CGSize(width: 68, height: 48))
        XCTAssertEqual(WorkspaceDesignTokens.appCell, 64)
        XCTAssertEqual(WorkspaceDesignTokens.appIcon, 48)
        XCTAssertGreaterThanOrEqual(WorkspaceDesignTokens.appColumnGap, 12)

        let content = makeContent(displayCount: 3, appCount: 27)
        let layout = SwitchTabLayout(viewport: CGSize(width: 1_920, height: 1_080), content: content)

        XCTAssertTrue(layout.showsDisplayRail)
        XCTAssertEqual(layout.displayRailWidth, 96)
        XCTAssertTrue((0.60...0.66).contains(layout.displayCardWidth / 1_920))
        XCTAssertGreaterThanOrEqual(layout.renderedAppGridWidth, layout.appGrid.requiredRenderedWidth)
        XCTAssertEqual(layout.appGrid.items(onPage: 0).map(\.row), Array(repeating: 0, count: layout.appGrid.columns) + Array(repeating: 1, count: layout.appGrid.columns) + Array(repeating: 2, count: min(layout.appGrid.pageCapacity - layout.appGrid.columns * 2, layout.appGrid.columns)))
        XCTAssertEqual(layout.appGrid.items(onPage: 1).first?.column, 0)
        XCTAssertTrue(layout.appLayerIsInsideDisplayCard)

        let narrowLayout = SwitchTabLayout(
            viewport: CGSize(width: 1_024, height: 768),
            content: content
        )
        XCTAssertGreaterThanOrEqual(
            narrowLayout.displayCardWidth,
            narrowLayout.renderedAppGridWidth + 168,
            "The paged action glass must stay completely inside the display card"
        )
    }

    func testSharedKeycapGeometryKeepsMaterialBoundsDisjointInsideFixedHitTargets() {
        let app = ShortcutKeycapGeometry(
            containerSize: CGSize(width: 64, height: 64),
            requestedArtworkSize: CGSize(width: 48, height: 48)
        )
        let display = ShortcutKeycapGeometry(
            containerSize: CGSize(width: 76, height: 76),
            requestedArtworkSize: CGSize(width: 68, height: 48)
        )

        XCTAssertEqual(app.artworkFrame.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(app.keycapFrame.height, 21)
        XCTAssertFalse(app.artworkFrame.intersects(app.keycapFrame))
        XCTAssertGreaterThanOrEqual(app.keycapFrame.minX - app.artworkFrame.maxX, app.safeGap)
        XCTAssertTrue(CGRect(origin: .zero, size: app.containerSize).contains(app.artworkFrame))
        XCTAssertTrue(CGRect(origin: .zero, size: app.containerSize).contains(app.keycapFrame))

        XCTAssertLessThanOrEqual(display.artworkFrame.width, 68)
        XCTAssertLessThanOrEqual(display.artworkFrame.height, 48)
        XCTAssertFalse(display.artworkFrame.intersects(display.keycapFrame))
        XCTAssertGreaterThanOrEqual(
            display.keycapFrame.minX - display.artworkFrame.maxX,
            display.safeGap
        )
        XCTAssertTrue(CGRect(origin: .zero, size: display.containerSize).contains(display.artworkFrame))
        XCTAssertTrue(CGRect(origin: .zero, size: display.containerSize).contains(display.keycapFrame))
    }

    func testOneDisplayRemovesRailAndWorkspaceHasNoOuterFrameOrSettings() {
        let snapshot = makeView(displayCount: 1, appCount: 12).semanticSnapshot(
            viewport: CGSize(width: 1_512, height: 982)
        )

        XCTAssertFalse(snapshot.hasOuterFrame)
        XCTAssertFalse(snapshot.hasSettingsControl)
        XCTAssertEqual(snapshot.topTabGroupCount, 1)
        XCTAssertFalse(snapshot.showsLeftContextRail)
        XCTAssertEqual(snapshot.appLayerParentIdentifier, "screen-switcher.workspace.switch.display-card")
        XCTAssertEqual(snapshot.visibleAppNames.count, 0)
        XCTAssertEqual(snapshot.accessibleAppLabels.count, 12)
    }

    func testAppCountsUseOneToThreeRowsThenPageWithExternalLocalKeycaps() {
        for count in [1, 10, 12, 24, 27] {
            let snapshot = makeView(displayCount: 3, appCount: count).semanticSnapshot(
                viewport: CGSize(width: 1_512, height: 982)
            )
            let expectedLayout = AppGridLayout(
                availableWidth: snapshot.appGridCellBudget,
                itemCount: count
            )

            XCTAssertEqual(snapshot.appGridColumns, expectedLayout.columns)
            XCTAssertEqual(snapshot.appGridPageCount, expectedLayout.pageCount)
            XCTAssertEqual(snapshot.appGridRowCount, expectedLayout.rowCount(onPage: 0))
            XCTAssertEqual(snapshot.appGridRenderedWidth, expectedLayout.requiredRenderedWidth)
            XCTAssertEqual(snapshot.keycapPlacement, .external)
            XCTAssertEqual(snapshot.accessibleAppIdentifiers.count, min(count, expectedLayout.pageCapacity))
            XCTAssertEqual(snapshot.visibleAppNames, [])
        }
    }

    func testOverflowUsesPageDotsWithoutVisibleFractionText() {
        let snapshot = makeView(displayCount: 3, appCount: 27).semanticSnapshot(
            viewport: CGSize(width: 1_512, height: 982)
        )

        XCTAssertEqual(snapshot.pageIndicatorStyle, .dots)
        XCTAssertFalse(snapshot.hasVisiblePageCountText)
        XCTAssertEqual(snapshot.pageIndicatorAccessibilityLabel, "App page 1 of 2")
    }

    func testExtremeViewportsClampCardAndUseInternalScrollingWithoutCompressingGrid() {
        let content = makeContent(displayCount: 5, appCount: 27)
        let sizes = [
            CGSize.zero,
            CGSize(width: 320, height: 180),
            CGSize(width: 900, height: 260),
            CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            CGSize(width: -CGFloat.infinity, height: -40)
        ]

        for size in sizes {
            let layout = SwitchTabLayout(viewport: size, content: content)
            XCTAssertTrue(layout.displayCardWidth.isFinite)
            XCTAssertTrue(layout.displayCardHeight.isFinite)
            XCTAssertGreaterThanOrEqual(layout.displayCardWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.displayCardHeight, 0)
            XCTAssertLessThanOrEqual(layout.displayCardWidth, layout.safeViewport.width)
            XCTAssertLessThanOrEqual(layout.displayCardHeight, layout.safeViewport.height)
            XCTAssertEqual(layout.appGrid.requiredRenderedWidth, layout.renderedAppGridWidth)
            XCTAssertEqual(AppGridLayout.cellSize, 64)
            XCTAssertEqual(AppGridLayout.iconSize, 48)
            XCTAssertEqual(AppGridLayout.minimumColumnGap, 12)
        }

        let zero = SwitchTabLayout(viewport: .zero, content: content)
        XCTAssertFalse(zero.showsDisplayRail, "A fixed 96pt rail must not escape an empty viewport")

        let narrow = SwitchTabLayout(viewport: CGSize(width: 320, height: 800), content: content)
        XCTAssertTrue(narrow.requiresHorizontalAppScroll)
        let short = SwitchTabLayout(viewport: CGSize(width: 1_512, height: 220), content: content)
        XCTAssertTrue(short.requiresVerticalAppScroll)
    }

    func testNormalWideViewportPreservesApprovedCardRatioAndZeroAppsAreSafe() {
        let normal = SwitchTabLayout(
            viewport: CGSize(width: 1_512, height: 982),
            content: makeContent(displayCount: 3, appCount: 27)
        )
        XCTAssertGreaterThanOrEqual(normal.displayCardWidth / 1_512, 0.60)
        XCTAssertLessThanOrEqual(normal.displayCardWidth / 1_512, 0.66)

        let empty = SwitchTabLayout(
            viewport: CGSize(width: 1_512, height: 982),
            content: makeContent(displayCount: 5, appCount: 0)
        )
        XCTAssertEqual(empty.appGrid.pageCount, 0)
        XCTAssertEqual(empty.appGrid.rowCount(onPage: 0), 0)
        XCTAssertTrue(empty.showsDisplayRail)
    }

    func testTallWorkspaceUsesLaunchpadScaleAndStableFullWidthAppLayer() {
        let tallViewport = CGSize(width: 3_008, height: 1_588)
        let oneApp = SwitchTabLayout(
            viewport: tallViewport,
            content: makeContent(displayCount: 2, appCount: 1)
        )
        let fullPage = SwitchTabLayout(
            viewport: tallViewport,
            content: makeContent(displayCount: 2, appCount: 26)
        )
        let twoRows = SwitchTabLayout(
            viewport: tallViewport,
            content: makeContent(displayCount: 2, appCount: 13)
        )

        XCTAssertEqual(WorkspaceDesignTokens.switchCardHeightRatio, 0.76)
        XCTAssertEqual(WorkspaceDesignTokens.switchContentVerticalPosition, 0.47)
        XCTAssertEqual(
            oneApp.displayCardHeight,
            tallViewport.height * WorkspaceDesignTokens.switchCardHeightRatio,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(oneApp.displayCardHeight / tallViewport.height, 0.60)
        XCTAssertEqual(
            oneApp.contentVerticalOffset,
            tallViewport.height * (WorkspaceDesignTokens.switchContentVerticalPosition - 0.5),
            accuracy: 0.01
        )
        XCTAssertEqual(oneApp.appLayerHeight, 96)
        XCTAssertEqual(twoRows.appLayerHeight, 172)
        XCTAssertEqual(fullPage.appLayerHeight, 248)
        XCTAssertEqual(
            oneApp.appLayerWidth,
            oneApp.displayCardWidth - WorkspaceDesignTokens.displayCardHorizontalPadding * 2
                - WorkspaceDesignTokens.previewAppLayerInset * 2
        )
        XCTAssertGreaterThan(oneApp.appLayerWidth, oneApp.renderedAppGridWidth)
    }

    func testAccessibilityRenderPolicyChangesActualSurfaceAndMotionConsumers() {
        let standard = WorkspaceRenderPolicy(environment: .init(appearance: .dark))
        let reducedTransparency = WorkspaceRenderPolicy(
            environment: .init(appearance: .dark, reduceTransparency: true)
        )
        let increasedContrast = WorkspaceRenderPolicy(
            environment: .init(appearance: .dark, increaseContrast: true)
        )
        let reducedMotion = WorkspaceRenderPolicy(
            environment: .init(appearance: .dark, reduceMotion: true)
        )

        XCTAssertEqual(standard.glassBackground, .material)
        XCTAssertEqual(reducedTransparency.glassBackground, .solid)
        XCTAssertGreaterThan(increasedContrast.borderWidth, standard.borderWidth)
        XCTAssertGreaterThan(increasedContrast.secondaryTextOpacity, standard.secondaryTextOpacity)
        XCTAssertTrue(standard.appPageTransition.hasSpatialTravel)
        XCTAssertFalse(reducedMotion.appPageTransition.hasSpatialTravel)
        XCTAssertEqual(reducedMotion.appPageTransition.kind, .opacity)
    }

    func testContentAndActionMaterialsKeepDistinctLightModeDepth() {
        let light = WorkspaceVisualEnvironment(appearance: .light)
        let dark = WorkspaceVisualEnvironment(appearance: .dark)

        XCTAssertGreaterThan(
            WorkspaceDesignTokens.glassTintOpacity(role: .action, environment: light),
            WorkspaceDesignTokens.glassTintOpacity(role: .navigation, environment: light)
        )
        XCTAssertGreaterThan(
            WorkspaceDesignTokens.contentShadowOpacity(environment: light),
            0.12
        )
        XCTAssertGreaterThan(
            WorkspaceDesignTokens.contentShadowOpacity(environment: dark),
            WorkspaceDesignTokens.contentShadowOpacity(environment: light)
        )
    }

    func testDisplayCardPagingUsesDirectionalSpringAndReducedMotionFade() {
        let standard = WorkspaceRenderPolicy(environment: .init(appearance: .dark))
        let reduced = WorkspaceRenderPolicy(
            environment: .init(appearance: .dark, reduceMotion: true)
        )

        let next = standard.cardTransitionPlan(direction: .next)
        let previous = standard.cardTransitionPlan(direction: .previous)
        XCTAssertEqual(next.insertionOffsetY, -previous.insertionOffsetY)
        XCTAssertEqual(next.removalOffsetY, -previous.removalOffsetY)
        XCTAssertGreaterThan(next.insertionOffsetY, 0)
        XCTAssertLessThan(next.removalOffsetY, 0)
        XCTAssertLessThan(next.inactiveScale, 1)
        XCTAssertTrue(next.motion.hasSpatialTravel)
        XCTAssertEqual(next.motion.duration, StandardWorkspaceMotion().card.duration)

        let reducedNext = reduced.cardTransitionPlan(direction: .next)
        XCTAssertEqual(reducedNext.insertionOffsetY, 0)
        XCTAssertEqual(reducedNext.removalOffsetY, 0)
        XCTAssertEqual(reducedNext.inactiveScale, 1)
        XCTAssertEqual(reducedNext.motion.kind, .opacity)
        XCTAssertFalse(reducedNext.motion.hasSpatialTravel)
    }

    func testDisplayCardInteractiveTransformIgnoresHorizontalTabMotion() {
        let standard = WorkspaceRenderPolicy(environment: .init(appearance: .dark))
        let reduced = WorkspaceRenderPolicy(
            environment: .init(appearance: .dark, reduceMotion: true)
        )

        XCTAssertEqual(
            standard.cardInteractiveTransform(offset: -48, axis: .horizontal),
            .identity
        )
        let vertical = standard.cardInteractiveTransform(offset: -48, axis: .vertical)
        XCTAssertLessThan(vertical.offsetY, 0)
        XCTAssertLessThan(vertical.scale, 1)
        XCTAssertLessThan(vertical.opacity, 1)
        XCTAssertEqual(
            reduced.cardInteractiveTransform(offset: -48, axis: .vertical).offsetY,
            0
        )
        XCTAssertEqual(
            reduced.cardInteractiveTransform(offset: -48, axis: .vertical).scale,
            1
        )
    }

    func testAccessibilityEnvironmentRefreshesWhenSystemDisplayOptionsChange() {
        let center = NotificationCenter()
        var current = WorkspaceVisualEnvironment(appearance: .dark)
        let observable = WorkspaceAccessibilityEnvironment(
            initial: current,
            notificationCenter: center,
            appearance: { .dark },
            environmentReader: { _ in current }
        )
        current = WorkspaceVisualEnvironment(
            appearance: .dark,
            reduceMotion: true,
            reduceTransparency: true,
            increaseContrast: true
        )

        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        XCTAssertEqual(observable.visualEnvironment, current)
        XCTAssertEqual(WorkspaceRenderPolicy(environment: observable.visualEnvironment).glassBackground, .solid)
        XCTAssertFalse(
            WorkspaceRenderPolicy(environment: observable.visualEnvironment)
                .appPageTransition.hasSpatialTravel
        )
    }

    func testNativeBaselineGateNeverTreatsCandidateAsHumanApproved() {
        XCTAssertEqual(
            WorkspaceNativeBaselineGate.status(
                approvalEnvironmentValue: nil,
                approvedBaselineExists: false,
                candidateExists: true
            ),
            .unapproved
        )
        XCTAssertEqual(
            WorkspaceNativeBaselineGate.status(
                approvalEnvironmentValue: "1",
                approvedBaselineExists: false,
                candidateExists: true
            ),
            .approvedBaselineMissing
        )
    }

    func testApprovedNativeBaselineGateAndSnapshotAssertionShareOneExactPath() {
        let contract = WorkspaceApprovedNativeBaselineContract.switchDark(
            testFilePath: #filePath
        )

        XCTAssertEqual(contract.snapshotDirectory.lastPathComponent, "ApprovedNative")
        XCTAssertEqual(contract.testName, "switch-dark")
        XCTAssertEqual(contract.snapshotName, "approved")
        XCTAssertEqual(contract.referenceURL.lastPathComponent, "switch-dark.approved.png")
        XCTAssertEqual(
            contract.referenceURL,
            contract.snapshotDirectory.appendingPathComponent(
                "\(contract.testName).\(contract.snapshotName).png"
            )
        )
    }

    func testHumanApprovedNativeRenderBaseline() throws {
        let contract = WorkspaceApprovedNativeBaselineContract.switchDark(testFilePath: #filePath)
        let environment = ProcessInfo.processInfo.environment
        let view = makeView(displayCount: 3, appCount: 12)
        if environment[WorkspaceApprovedNativeBaselineContract.recordEnvironmentKey] == "1" {
            let failure = verifySnapshot(
                of: NSHostingView(rootView: view.frame(width: 1_512, height: 982)),
                as: .image(size: CGSize(width: 1_512, height: 982)),
                named: contract.snapshotName,
                record: .all,
                snapshotDirectory: contract.snapshotDirectory.path,
                testName: contract.testName
            )
            if let failure { XCTFail(failure) }
            return
        }
        let status = WorkspaceNativeBaselineGate.status(
            approvalEnvironmentValue: environment[WorkspaceApprovedNativeBaselineContract.approvalEnvironmentKey],
            approvedBaselineExists: FileManager.default.fileExists(atPath: contract.referenceURL.path),
            candidateExists: false
        )
        switch status {
        case .unapproved:
            throw XCTSkip("native_visual_baseline_unapproved")
        case .approvedBaselineMissing:
            XCTFail("native_visual_baseline_approved_but_missing")
        case .ready:
            if let failure = verifySnapshot(
                of: NSHostingView(rootView: view.frame(width: 1_512, height: 982)),
                as: .image(size: CGSize(width: 1_512, height: 982)),
                named: contract.snapshotName,
                record: .never,
                snapshotDirectory: contract.snapshotDirectory.path,
                testName: contract.testName
            ) {
                XCTFail(failure)
            }
        }
    }

    func testIconFailureKeepsItemAndUsesGenericIcon() {
        let presentation = SwitchTabPresentation(
            content: makeContent(displayCount: 1, appCount: 1),
            iconProvider: MissingIconProvider()
        )

        XCTAssertEqual(presentation.selectedApps.count, 1)
        XCTAssertEqual(presentation.selectedApps.first?.iconAvailability, .fallback)
        XCTAssertNotNil(presentation.selectedApps.first?.icon)
        XCTAssertEqual(presentation.selectedApps.first?.accessibilityLabel, "Fixture App 1")
        XCTAssertEqual(
            presentation.selectedApps.first?.accessibilityIdentifier,
            "screen-switcher.workspace.switch.app.bundle:363919c82172b51b"
        )
    }

    func testPreviewNeverLeaksImageDataIntoSemanticSnapshot() async {
        let display = makeContent(displayCount: 1, appCount: 0).selectedWorkspace.display
        let image = NSImage(size: NSSize(width: 80, height: 50))
        let deniedCapture = FixtureDisplayPreviewCapturer(image: image)
        let denied = DisplayPreviewProvider(
            capturer: deniedCapture
        )
        let grantedCapture = FixtureDisplayPreviewCapturer(image: image)
        let granted = DisplayPreviewProvider(
            capturer: grantedCapture
        )

        let fallback = denied.preview(for: display)
        await denied.requestPreview(for: display, targetPixelSize: CGSize(width: 80, height: 50))
        await granted.requestPreview(for: display, targetPixelSize: CGSize(width: 80, height: 50))
        let preview = granted.preview(for: display)

        XCTAssertEqual(fallback.semanticSnapshot, .schematic(style: "display-window-grid-v1"))
        XCTAssertEqual(preview.semanticSnapshot, .currentDisplayImageInMemory)
        XCTAssertNil(fallback.image)
        let deniedCaptureCount = await deniedCapture.count()
        let grantedCaptureCount = await grantedCapture.count()
        XCTAssertEqual(deniedCaptureCount, 1)
        XCTAssertEqual(grantedCaptureCount, 1)
        XCTAssertFalse(preview.semanticSnapshot.description.contains("/"))
        XCTAssertFalse(preview.semanticSnapshot.description.contains("data"))
    }

    func testAppearanceAndAccessibilityResolveSemanticTokens() {
        let standardDark = WorkspaceDesignTokens.resolve(
            environment: .init(appearance: .dark)
        )
        let standardLight = WorkspaceDesignTokens.resolve(
            environment: .init(appearance: .light)
        )
        let reducedTransparency = WorkspaceDesignTokens.resolve(
            environment: .init(appearance: .dark, reduceTransparency: true)
        )
        let increasedContrast = WorkspaceDesignTokens.resolve(
            environment: .init(appearance: .light, increaseContrast: true)
        )
        let reducedMotion = WorkspaceDesignTokens.resolve(
            environment: .init(appearance: .dark, reduceMotion: true)
        )

        XCTAssertEqual(standardDark.appearance, .dark)
        XCTAssertEqual(standardLight.appearance, .light)
        XCTAssertTrue(standardDark.usesTranslucentMaterials)
        XCTAssertFalse(reducedTransparency.usesTranslucentMaterials)
        XCTAssertGreaterThan(increasedContrast.borderWidth, standardLight.borderWidth)
        XCTAssertGreaterThan(increasedContrast.secondaryTextOpacity, standardLight.secondaryTextOpacity)
        XCTAssertEqual(reducedMotion.motionStyle, .reduced)
        XCTAssertEqual(standardDark.motionStyle, .standard)
    }

    func testDeterministicSwitchSemanticSnapshots() throws {
        for scenario in Self.scenarios {
            let view = makeView(
                displayCount: scenario.displayCount,
                appCount: scenario.appCount,
                environment: scenario.environment
            )
            let semantic = view.semanticSnapshot(viewport: CGSize(width: 1_512, height: 982))

            assertSnapshot(of: semantic.description, as: .lines, named: scenario.name)
            if ProcessInfo.processInfo.environment["RECORD_WORKSPACE_VISUAL_CANDIDATES"] == "1" {
                try recordCandidate(view: view, scenario: scenario)
            }
        }
    }

    private static let scenarios: [VisualScenario] = [
        .init(name: "switch-dark", displayCount: 3, appCount: 12, environment: .init(appearance: .dark)),
        .init(name: "switch-light", displayCount: 3, appCount: 12, environment: .init(appearance: .light)),
        .init(name: "single-display", displayCount: 1, appCount: 12, environment: .init(appearance: .dark)),
        .init(name: "three-displays", displayCount: 3, appCount: 12, environment: .init(appearance: .dark)),
        .init(name: "one-app", displayCount: 3, appCount: 1, environment: .init(appearance: .dark)),
        .init(name: "ten-apps", displayCount: 3, appCount: 10, environment: .init(appearance: .dark)),
        .init(name: "twelve-apps", displayCount: 3, appCount: 12, environment: .init(appearance: .dark)),
        .init(name: "twenty-four-apps", displayCount: 3, appCount: 24, environment: .init(appearance: .dark)),
        .init(name: "twenty-seven-apps", displayCount: 3, appCount: 27, environment: .init(appearance: .dark)),
        .init(name: "reduce-motion", displayCount: 3, appCount: 12, environment: .init(appearance: .dark, reduceMotion: true)),
        .init(name: "reduce-transparency", displayCount: 3, appCount: 12, environment: .init(appearance: .dark, reduceTransparency: true)),
        .init(name: "increase-contrast", displayCount: 3, appCount: 12, environment: .init(appearance: .dark, increaseContrast: true))
    ]

    private func makeView(
        displayCount: Int,
        appCount: Int,
        environment: WorkspaceVisualEnvironment = .init(appearance: .dark)
    ) -> FullscreenWorkspaceView {
        FullscreenWorkspaceView(
            selectedTab: .switch,
            backdrop: .semanticGradient,
            switchContent: makeContent(displayCount: displayCount, appCount: appCount),
            visualEnvironment: environment,
            iconProvider: MissingIconProvider(),
            previewProvider: DeterministicDisplayPreviewProvider()
        )
    }

    private func makeContent(displayCount: Int, appCount: Int) -> SwitchWorkspaceContent {
        let displays = (0..<displayCount).map { index -> DisplayWorkspaceSnapshot in
            let width = index == 2 ? 2_560.0 : 1_512.0
            let apps = index == 0 ? (0..<appCount).map { appIndex in
                RunningAppDescriptor(
                    id: "com.example.fixture-\(appIndex + 1)",
                    displayName: "Fixture App \(appIndex + 1)",
                    mostRecentWindow: nil,
                    iconAvailability: .fallback
                )
            } : []
            return DisplayWorkspaceSnapshot(
                display: DisplayDescriptor(
                    id: "display-\(index + 1)",
                    frame: try! RectDescriptor(x: Double(index) * 1_512, y: 0, width: width, height: 982),
                    isCurrent: index == 0,
                    hardwareKind: index == 0 ? .builtIn : .external
                ),
                apps: apps,
                previewAvailability: .schematicFallback
            )
        }
        return SwitchWorkspaceContent(workspaces: displays, selectedDisplayID: displays.first?.display.id)
    }

    private func recordCandidate(view: FullscreenWorkspaceView, scenario: VisualScenario) throws {
        let size = NSSize(width: 1_512, height: 982)
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hostingView.appearance = NSAppearance(
            named: scenario.environment.appearance == .dark ? .darkAqua : .aqua
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to allocate candidate bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode candidate PNG")
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let artifactRoot = ProcessInfo.processInfo.environment["WORKSPACE_VISUAL_CANDIDATE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? packageRoot.appendingPathComponent(".build/workspace-visual-candidates", isDirectory: true)
        let fileURL = artifactRoot
            .appendingPathComponent("\(scenario.name).candidate.png")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: fileURL, options: .atomic)
    }
}

private struct VisualScenario {
    let name: String
    let displayCount: Int
    let appCount: Int
    let environment: WorkspaceVisualEnvironment
}

@MainActor
private struct MissingIconProvider: RunningAppIconProviding {
    func icon(for bundleIdentifier: String) -> NSImage? { nil }
}

@MainActor
private struct FixtureScreenRecordingChecker {
    let granted: Bool
    func hasScreenRecordingAccess() -> Bool { granted }
    func requestScreenRecordingAccess() -> Bool { granted }
}

private actor FixtureDisplayPreviewCapturer: DisplayPreviewCapturing {
    let imageSize: CGSize
    private var captureCount = 0

    init(image: NSImage) {
        imageSize = image.size
    }

    func capture(
        displayID: CGDirectDisplayID,
        targetPixelSize: CGSize
    ) async -> DisplayPreviewCapture? {
        captureCount += 1
        let width = max(Int(min(targetPixelSize.width, imageSize.width).rounded()), 1)
        let height = max(Int(min(targetPixelSize.height, imageSize.height).rounded()), 1)
        return DisplayPreviewCapture(
            pixelData: Data(repeating: 0, count: width * height * 4),
            pixelWidth: width,
            pixelHeight: height,
            bytesPerRow: width * 4
        )
    }

    func count() -> Int { captureCount }
}
