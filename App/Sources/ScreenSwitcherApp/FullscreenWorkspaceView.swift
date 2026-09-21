import SwiftUI

public enum WorkspaceKeycapPlacement: String, Equatable, Sendable {
    case external
}

public enum WorkspacePageIndicatorStyle: String, Equatable, Sendable {
    case none
    case dots
}

public enum WorkspaceNativeBaselineStatus: Equatable, Sendable {
    case unapproved
    case approvedBaselineMissing
    case ready
}

public enum WorkspaceNativeBaselineGate {
    public static func status(
        approvalEnvironmentValue: String?,
        approvedBaselineExists: Bool,
        candidateExists _: Bool
    ) -> WorkspaceNativeBaselineStatus {
        guard approvalEnvironmentValue == "1" else { return .unapproved }
        return approvedBaselineExists ? .ready : .approvedBaselineMissing
    }
}

public struct WorkspaceApprovedNativeBaselineContract: Equatable, Sendable {
    public static let approvalEnvironmentKey = "WORKSPACE_VISUAL_BASELINE_APPROVED"
    public static let recordEnvironmentKey = "RECORD_WORKSPACE_APPROVED_NATIVE_BASELINE"

    public let snapshotDirectory: URL
    public let testName: String
    public let snapshotName: String

    public var referenceURL: URL {
        snapshotDirectory.appendingPathComponent("\(testName).\(snapshotName).png")
    }

    public static func switchDark(testFilePath: String) -> Self {
        let directory = URL(fileURLWithPath: testFilePath)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "__Snapshots__/WorkspaceVisualContractTests/ApprovedNative",
                isDirectory: true
            )
        return Self(
            snapshotDirectory: directory,
            testName: "switch-dark",
            snapshotName: "approved"
        )
    }
}

public struct WorkspaceVisualSemanticSnapshot: CustomStringConvertible {
    public let hasOuterFrame: Bool
    public let hasSettingsControl: Bool
    public let topTabGroupCount: Int
    public let showsLeftContextRail: Bool
    public let appLayerParentIdentifier: String
    public let appGridCellBudget: Double
    public let appGridColumns: Int
    public let appGridRowCount: Int
    public let appGridPageCount: Int
    public let appGridRenderedWidth: Double
    public let keycapPlacement: WorkspaceKeycapPlacement
    public let pageIndicatorStyle: WorkspacePageIndicatorStyle
    public let hasVisiblePageCountText: Bool
    public let pageIndicatorAccessibilityLabel: String?
    public let visibleAppNames: [String]
    public let accessibleAppLabels: [String]
    public let accessibleAppIdentifiers: [String]
    public let description: String
}

@MainActor
public struct FullscreenWorkspaceView: View {
    private let backdrop: WorkspaceBackdrop
    private let visualEnvironment: WorkspaceVisualEnvironment?
    @ObservedObject private var interactionModel: WorkspaceInteractionModel
    @ObservedObject private var accessibilityEnvironment: WorkspaceAccessibilityEnvironment
    private let iconSession: RunningAppIconSession
    private let previewProvider: any DisplayPreviewProviding

    @Environment(\.colorScheme) private var colorScheme

    public init(
        interactionModel: WorkspaceInteractionModel,
        backdrop: WorkspaceBackdrop,
        visualEnvironment: WorkspaceVisualEnvironment? = nil,
        accessibilityEnvironment: WorkspaceAccessibilityEnvironment,
        iconSession: RunningAppIconSession,
        previewProvider: any DisplayPreviewProviding
    ) {
        self.interactionModel = interactionModel
        self.backdrop = backdrop
        self.visualEnvironment = visualEnvironment
        self.accessibilityEnvironment = accessibilityEnvironment
        self.iconSession = iconSession
        self.previewProvider = previewProvider
    }

    public init(
        selectedTab: WorkspaceTab,
        backdrop: WorkspaceBackdrop,
        switchContent: SwitchWorkspaceContent,
        visualEnvironment: WorkspaceVisualEnvironment? = nil,
        iconProvider: any RunningAppIconProviding,
        previewProvider: any DisplayPreviewProviding
    ) {
        self.backdrop = backdrop
        self.visualEnvironment = visualEnvironment
        let model = WorkspaceInteractionModel(content: switchContent, selectedTab: selectedTab)
        interactionModel = model
        accessibilityEnvironment = WorkspaceAccessibilityEnvironment(
            initial: visualEnvironment ?? WorkspaceVisualEnvironment(appearance: .dark)
        )
        let session = RunningAppIconSession(
            provider: iconProvider,
            fallbackIcon: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "App")
        )
        session.preload(bundleIdentifiers: switchContent.workspaces.flatMap { $0.apps.map(\.id) })
        iconSession = session
        self.previewProvider = previewProvider
    }

    public var body: some View {
        let environment = resolvedEnvironment
        ZStack(alignment: .top) {
            workspaceBackdrop(environment: environment)
            TopTabGlass(interactionModel: interactionModel, environment: environment)
                .padding(.top, WorkspaceDesignTokens.topInset)
                .zIndex(2)

            if let failure = interactionModel.presentation.executionFailure {
                Text(failure.recoveryMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WorkspaceDesignTokens.color(.primaryText, environment: environment))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 28)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .accessibilityIdentifier("screen-switcher.workspace.execution-error")
                    .zIndex(3)
            }

            Group {
                switch interactionModel.presentation.selectedTab {
                case .switch:
                    SwitchTabView(
                        interactionModel: interactionModel,
                        environment: environment,
                        iconSession: iconSession,
                        previewProvider: previewProvider
                    )
                case .agents:
                    deferredTab(title: "Agents", environment: environment)
                case .focus:
                    deferredTab(title: "Focus", environment: environment)
                }
            }
            .padding(.top, 104)
        }
        .ignoresSafeArea()
        .preferredColorScheme(visualEnvironment.map {
            $0.appearance == .dark ? ColorScheme.dark : ColorScheme.light
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen Switcher workspace")
        .accessibilityIdentifier("screen-switcher.workspace")
        .modifier(WorkspaceAnimationCompletionObserver(
            revision: interactionModel.presentation.tabTransitionRevision,
            completion: interactionModel.markTabTransitionSettled(revision:)
        ))
        .animation(
            WorkspaceRenderPolicy(environment: environment).animation,
            value: interactionModel.presentation.tabTransitionRevision
        )
    }

    public func semanticSnapshot(viewport: CGSize) -> WorkspaceVisualSemanticSnapshot {
        let environment = visualEnvironment ?? WorkspaceVisualEnvironment(appearance: .dark)
        let content = interactionModel.selectedContent()
        let layout = SwitchTabLayout(viewport: viewport, content: content)
        let presentation = SwitchTabPresentation(content: content, iconSession: iconSession)
        let selectedPage = min(
            interactionModel.presentation.selectedAppPage,
            max(layout.appGrid.pageCount - 1, 0)
        )
        let pageItems = layout.appGrid.items(onPage: selectedPage)
        let pageApps = pageItems.map { presentation.selectedApps[$0.absoluteIndex] }
        let preview = previewProvider.preview(for: presentation.selectedWorkspace.display)
        let resolved = WorkspaceDesignTokens.resolve(environment: environment)

        let accessibleLabels = pageApps.map(\.accessibilityLabel)
        let accessibleIdentifiers = pageApps.map(\.accessibilityIdentifier)
        let appLines = zip(pageItems, pageApps).map { item, app in
            "app[\(item.shortcut)] row=\(item.row) column=\(item.column) id=\(app.accessibilityIdentifier) label=\(app.accessibilityLabel) icon=\(app.iconAvailability.rawValue) name-visible=false keycap=external"
        }
        let pageIndicatorStyle: WorkspacePageIndicatorStyle = layout.appGrid.pageCount > 1 ? .dots : .none
        let pageIndicatorAccessibilityLabel = layout.appGrid.pageCount > 1
            ? "App page \(selectedPage + 1) of \(layout.appGrid.pageCount)"
            : nil
        let lines = [
            "workspace tab=\(tabName(interactionModel.presentation.selectedTab)) outer-frame=false settings=false top-tab-groups=1",
            "environment appearance=\(environment.appearance.rawValue) motion=\(resolved.motionStyle.rawValue) transparency=\(resolved.usesTranslucentMaterials ? "material" : "solid") contrast-border=\(format(resolved.borderWidth))",
            "left-rail visible=\(layout.showsDisplayRail) width=\(format(layout.displayRailWidth)) padding=\(format(WorkspaceDesignTokens.leftRailPadding)) item=\(format(WorkspaceDesignTokens.leftRailItem)) radius=\(format(WorkspaceDesignTokens.leftRailItemRadius))",
            "display-art max=68x48 source=public-vector",
            "display-card width=\(format(layout.displayCardWidth)) viewport-ratio=\(format(layout.displayCardWidth / max(viewport.width, 1))) role=content-surface",
            "preview semantic=\(preview.semanticSnapshot.description)",
            "app-layer parent=screen-switcher.workspace.switch.display-card role=action-glass inside=true",
            "app-grid budget=\(format(layout.appGridCellBudget)) columns=\(layout.appGrid.columns) rows=\(layout.appGrid.rowCount(onPage: selectedPage)) pages=\(layout.appGrid.pageCount) cell=64 icon=48 gap=12 required=\(format(layout.appGrid.requiredRenderedWidth)) rendered=\(format(layout.renderedAppGridWidth)) alignment=leading",
            "page-indicator style=\(pageIndicatorStyle.rawValue) visible-count=false accessibility-label=\(pageIndicatorAccessibilityLabel ?? "none")",
            "viewport horizontal-scroll=\(layout.requiresHorizontalAppScroll) vertical-scroll=\(layout.requiresVerticalAppScroll)"
        ] + appLines

        return WorkspaceVisualSemanticSnapshot(
            hasOuterFrame: false,
            hasSettingsControl: false,
            topTabGroupCount: 1,
            showsLeftContextRail: layout.showsDisplayRail,
            appLayerParentIdentifier: "screen-switcher.workspace.switch.display-card",
            appGridCellBudget: layout.appGridCellBudget,
            appGridColumns: layout.appGrid.columns,
            appGridRowCount: layout.appGrid.rowCount(onPage: selectedPage),
            appGridPageCount: layout.appGrid.pageCount,
            appGridRenderedWidth: layout.renderedAppGridWidth,
            keycapPlacement: .external,
            pageIndicatorStyle: pageIndicatorStyle,
            hasVisiblePageCountText: false,
            pageIndicatorAccessibilityLabel: pageIndicatorAccessibilityLabel,
            visibleAppNames: [],
            accessibleAppLabels: accessibleLabels,
            accessibleAppIdentifiers: accessibleIdentifiers,
            description: lines.joined(separator: "\n")
        )
    }

    private var resolvedEnvironment: WorkspaceVisualEnvironment {
        if let visualEnvironment { return visualEnvironment }
        let observed = accessibilityEnvironment.visualEnvironment
        return WorkspaceVisualEnvironment(
            appearance: colorScheme == .dark ? .dark : .light,
            reduceMotion: observed.reduceMotion,
            reduceTransparency: observed.reduceTransparency,
            increaseContrast: observed.increaseContrast
        )
    }

    @ViewBuilder
    private func workspaceBackdrop(environment: WorkspaceVisualEnvironment) -> some View {
        switch backdrop {
        case let .image(image) where !environment.reduceTransparency:
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .overlay(WorkspaceDesignTokens.color(.environmentScrim, environment: environment))
        case .image, .semanticGradient:
            LinearGradient(
                colors: [
                    WorkspaceDesignTokens.color(.environmentTop, environment: environment),
                    WorkspaceDesignTokens.color(.environmentBottom, environment: environment)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func deferredTab(
        title: String,
        environment: WorkspaceVisualEnvironment
    ) -> some View {
        Text(title)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(WorkspaceDesignTokens.color(.primaryText, environment: environment))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("screen-switcher.workspace.\(title.lowercased())")
    }

    private func tabName(_ tab: WorkspaceTab) -> String {
        switch tab {
        case .switch: return "switch"
        case .agents: return "agents"
        case .focus: return "focus"
        }
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
