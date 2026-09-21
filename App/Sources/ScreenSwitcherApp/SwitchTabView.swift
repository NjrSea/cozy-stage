import AppKit
import SwiftUI

public struct SwitchWorkspaceContent: Equatable, Sendable {
    public let workspaces: [DisplayWorkspaceSnapshot]
    public let selectedDisplayID: String

    public init(workspaces: [DisplayWorkspaceSnapshot], selectedDisplayID: String?) {
        var seen = Set<String>()
        self.workspaces = workspaces.filter {
            !$0.display.id.isEmpty && seen.insert($0.display.id).inserted
        }
        if let selectedDisplayID,
           self.workspaces.contains(where: { $0.display.id == selectedDisplayID }) {
            self.selectedDisplayID = selectedDisplayID
        } else {
            self.selectedDisplayID = self.workspaces.first?.display.id ?? ""
        }
    }

    public var selectedWorkspace: DisplayWorkspaceSnapshot {
        workspace(id: selectedDisplayID) ?? Self.emptyWorkspace
    }

    public func workspace(id: String) -> DisplayWorkspaceSnapshot? {
        workspaces.first { $0.display.id == id }
    }

    func selecting(_ displayID: String) -> Self {
        Self(workspaces: workspaces, selectedDisplayID: displayID)
    }

    private static let emptyWorkspace = DisplayWorkspaceSnapshot(
        display: DisplayDescriptor(
            id: "display-unavailable",
            frame: RectDescriptor(uncheckedX: 0, y: 0, width: 1, height: 1),
            isCurrent: false
        ),
        apps: [],
        previewAvailability: .schematicFallback
    )
}

public struct SwitchTabLayout: Equatable, Sendable {
    public let viewport: CGSize
    public let safeViewport: CGSize
    public let showsDisplayRail: Bool
    public let displayRailWidth: CGFloat
    public let displayCardWidth: CGFloat
    public let displayCardHeight: CGFloat
    public let contentVerticalOffset: CGFloat
    public let appGridCellBudget: Double
    public let appGrid: AppGridLayout
    public let renderedAppGridWidth: Double
    public let appLayerWidth: CGFloat
    public let appLayerHeight: CGFloat
    public let appLayerIsInsideDisplayCard: Bool
    public let requiresHorizontalAppScroll: Bool
    public let requiresVerticalAppScroll: Bool

    public init(viewport: CGSize, content: SwitchWorkspaceContent) {
        self.viewport = viewport
        displayRailWidth = WorkspaceDesignTokens.leftRailWidth

        let safeWidth = viewport.width.isFinite ? max(viewport.width, 0) : 0
        let safeHeight = viewport.height.isFinite ? max(viewport.height, 0) : 0
        safeViewport = CGSize(width: safeWidth, height: safeHeight)
        contentVerticalOffset = safeHeight
            * (WorkspaceDesignTokens.switchContentVerticalPosition - 0.5)
        showsDisplayRail = content.workspaces.count > 1
            && safeWidth >= WorkspaceDesignTokens.leftRailWidth
            && safeHeight > 0
        let ratio: CGFloat
        if safeWidth >= 1_440 {
            ratio = 0.63
        } else if safeWidth >= 1_180 {
            ratio = 0.64
        } else {
            ratio = 0.66
        }
        let proposedCardWidth = safeWidth * ratio
        let proposedCellBudget = max(WorkspaceDesignTokens.appCell * 8, proposedCardWidth - 270)
        appGridCellBudget = Double(proposedCellBudget)
        appGrid = AppGridLayout(
            availableWidth: appGridCellBudget,
            itemCount: content.selectedWorkspace.apps.count
        )
        renderedAppGridWidth = appGrid.requiredRenderedWidth
        let embeddedLayerChrome: CGFloat = appGrid.pageCount > 1 ? 168 : 124
        let requiredCardWidth = CGFloat(renderedAppGridWidth) + embeddedLayerChrome
        let desiredCardWidth = max(
            proposedCardWidth,
            requiredCardWidth
        )
        let availableCardWidth = max(safeWidth - WorkspaceDesignTokens.space7, 0)
        displayCardWidth = min(desiredCardWidth, availableCardWidth)
        let desiredCardHeight = max(
            WorkspaceDesignTokens.switchCardMinimumHeight,
            safeHeight * WorkspaceDesignTokens.switchCardHeightRatio
        )
        let availableCardHeight = max(safeHeight - WorkspaceDesignTokens.space6, 0)
        displayCardHeight = min(desiredCardHeight, availableCardHeight)
        appLayerWidth = max(
            displayCardWidth
                - WorkspaceDesignTokens.displayCardHorizontalPadding * 2
                - WorkspaceDesignTokens.previewAppLayerInset * 2,
            0
        )
        requiresHorizontalAppScroll = requiredCardWidth > displayCardWidth
        let rowCount = max(appGrid.rowCount(onPage: 0), 1)
        let gridContentHeight = CGFloat(rowCount) * WorkspaceDesignTokens.appCell
            + CGFloat(max(rowCount - 1, 0)) * WorkspaceDesignTokens.space3
            + WorkspaceDesignTokens.space6
        appLayerHeight = gridContentHeight
        let previewHeight = max(displayCardHeight - 88, 0)
        requiresVerticalAppScroll = appLayerHeight
            + WorkspaceDesignTokens.previewAppLayerInset * 2 > previewHeight
        appLayerIsInsideDisplayCard = true
    }
}

public struct WorkspaceAppPresentation {
    public let descriptor: RunningAppDescriptor
    public let icon: NSImage?
    public let iconAvailability: RunningAppIconAvailability
    public let accessibilityLabel: String
    public let accessibilityIdentifier: String
}

@MainActor
public struct SwitchTabPresentation {
    public let selectedWorkspace: DisplayWorkspaceSnapshot
    public let selectedApps: [WorkspaceAppPresentation]

    public init(
        content: SwitchWorkspaceContent,
        iconProvider: any RunningAppIconProviding
    ) {
        let session = RunningAppIconSession(
            provider: iconProvider,
            fallbackIcon: NSImage(
                systemSymbolName: "app.dashed",
                accessibilityDescription: "App"
            )
        )
        session.preload(bundleIdentifiers: content.selectedWorkspace.apps.map(\.id))
        self.init(content: content, iconSession: session)
    }

    public init(
        content: SwitchWorkspaceContent,
        iconSession: RunningAppIconSession
    ) {
        selectedWorkspace = content.selectedWorkspace
        selectedApps = selectedWorkspace.apps.map { descriptor in
            let resolution = iconSession.presentation(bundleIdentifier: descriptor.id)
            return WorkspaceAppPresentation(
                descriptor: descriptor,
                icon: resolution.image,
                iconAvailability: resolution.availability,
                accessibilityLabel: descriptor.displayName,
                accessibilityIdentifier: ProductAppAXIdentity.accessibilityIdentifier(
                    forBundleIdentifier: descriptor.id
                )
            )
        }
    }
}

public struct SwitchTabView: View {
    @ObservedObject private var interactionModel: WorkspaceInteractionModel
    let environment: WorkspaceVisualEnvironment
    let iconSession: RunningAppIconSession
    let previewProvider: any DisplayPreviewProviding

    @State private var previewRevision = 0

    public init(
        interactionModel: WorkspaceInteractionModel,
        environment: WorkspaceVisualEnvironment,
        iconSession: RunningAppIconSession,
        previewProvider: any DisplayPreviewProviding
    ) {
        self.interactionModel = interactionModel
        self.environment = environment
        self.iconSession = iconSession
        self.previewProvider = previewProvider
    }

    public var body: some View {
        GeometryReader { proxy in
            let selectedContent = interactionModel.selectedContent()
            let layout = SwitchTabLayout(viewport: proxy.size, content: selectedContent)
            let presentation = SwitchTabPresentation(
                content: selectedContent,
                iconSession: iconSession
            )
            let renderPolicy = WorkspaceRenderPolicy(environment: environment)
            let motionOffset = interactionModel.presentation.motionOffset
            let interactiveTransform = renderPolicy.cardInteractiveTransform(
                offset: motionOffset,
                axis: interactionModel.presentation.gestureAxis
            )
            let cardPagingDirection = interactionModel.presentation.displayTransitionDirection
                ?? .next
            ZStack {
                ZStack {
                    displayCard(
                        presentation: presentation,
                        layout: layout,
                        preview: previewProvider.preview(for: presentation.selectedWorkspace.display)
                    )
                    .id(presentation.selectedWorkspace.display.id)
                    .frame(width: layout.displayCardWidth, height: layout.displayCardHeight)
                    .offset(y: CGFloat(interactiveTransform.offsetY))
                    .scaleEffect(CGFloat(interactiveTransform.scale))
                    .opacity(interactiveTransform.opacity)
                    .transition(renderPolicy.cardViewTransition(direction: cardPagingDirection))
                }
                .modifier(WorkspaceAnimationCompletionObserver(
                    revision: interactionModel.presentation.displayCardAnimationIdentity.terminalRevision,
                    completion: interactionModel.markDisplayCardTransitionSettled(revision:)
                ))
                .animation(
                    renderPolicy.cardAnimation,
                    value: interactionModel.presentation.displayCardAnimationIdentity
                )

                if layout.showsDisplayRail {
                    HStack {
                        LeftContextRail(
                            interactionModel: interactionModel,
                            environment: environment
                        )
                        .frame(height: layout.safeViewport.height)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, max(0, (layout.safeViewport.width - layout.displayCardWidth) / 2 - 136))
                }
            }
            .offset(y: layout.contentVerticalOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .task(id: layout.appGrid.pageCapacity) {
                interactionModel.updatePageCapacity(layout.appGrid.pageCapacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch workspace")
        .accessibilityIdentifier("screen-switcher.workspace.switch")
    }

    private func displayCard(
        presentation: SwitchTabPresentation,
        layout: SwitchTabLayout,
        preview: DisplayPreview
    ) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceDesignTokens.space3) {
            HStack(spacing: WorkspaceDesignTokens.space2) {
                Image(systemName: "display")
                    .foregroundStyle(WorkspaceDesignTokens.color(.focus, environment: environment))
                    .accessibilityHidden(true)
                Text(displayTitle(for: presentation.selectedWorkspace.display))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(WorkspaceDesignTokens.color(.secondaryText, environment: environment))
                    .opacity(WorkspaceRenderPolicy(environment: environment).secondaryTextOpacity)
                if presentation.selectedWorkspace.display.isCurrent {
                    Text("· Current")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WorkspaceDesignTokens.color(.focus, environment: environment))
                }
            }
            previewSurface(
                preview,
                presentation: presentation,
                layout: layout
            )
        }
        .padding(WorkspaceDesignTokens.displayCardHorizontalPadding)
        .background {
            RoundedRectangle(cornerRadius: WorkspaceDesignTokens.contentRadius, style: .continuous)
                .fill(WorkspaceDesignTokens.color(.contentSurface, environment: environment))
        }
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceDesignTokens.contentRadius, style: .continuous)
                .stroke(
                    WorkspaceDesignTokens.color(.border, environment: environment),
                    lineWidth: WorkspaceDesignTokens.resolve(environment: environment).borderWidth
                )
        }
        .shadow(color: WorkspaceDesignTokens.color(.contentShadow, environment: environment), radius: 34, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(displayTitle(for: presentation.selectedWorkspace.display))
        .accessibilityIdentifier("screen-switcher.workspace.switch.display-card")
    }

    private func previewSurface(
        _ preview: DisplayPreview,
        presentation: SwitchTabPresentation,
        layout: SwitchTabLayout
    ) -> some View {
        let renderPolicy = WorkspaceRenderPolicy(environment: environment)
        return ZStack(alignment: .bottom) {
            Group {
                if let image = preview.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    DisplaySchematic(environment: environment)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityLabel("Current display preview")
            .accessibilityIdentifier("screen-switcher.workspace.switch.preview")

            appLayer(presentation: presentation, layout: layout)
                .padding(WorkspaceDesignTokens.previewAppLayerInset)
                .transition(renderPolicy.transition)
        }
        .background(WorkspaceDesignTokens.color(.contentInset, environment: environment))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(WorkspaceDesignTokens.color(.border, environment: environment), lineWidth: 1)
        }
        .task(id: PreviewRequestID(
            displayID: presentation.selectedWorkspace.display.id,
            width: Int(max(layout.displayCardWidth - 44, 1).rounded()),
            height: Int(max(layout.displayCardHeight - 88, 1).rounded())
        )) {
            await previewProvider.requestPreview(
                for: presentation.selectedWorkspace.display,
                targetPixelSize: CGSize(
                    width: max(layout.displayCardWidth - 44, 1),
                    height: max(layout.displayCardHeight - 88, 1)
                )
            )
            previewRevision &+= 1
        }
        .animation(renderPolicy.animation, value: previewRevision)
    }

    private func appLayer(
        presentation: SwitchTabPresentation,
        layout: SwitchTabLayout
    ) -> some View {
        let safePage = min(
            max(interactionModel.presentation.selectedAppPage, 0),
            max(layout.appGrid.pageCount - 1, 0)
        )
        let items = layout.appGrid.items(onPage: safePage)
        let renderPolicy = WorkspaceRenderPolicy(environment: environment)
        return scrollableAppLayer(
            horizontal: layout.requiresHorizontalAppScroll,
            vertical: layout.requiresVerticalAppScroll
        ) {
            HStack(spacing: WorkspaceDesignTokens.space3) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .fixed(WorkspaceDesignTokens.appCell),
                        spacing: WorkspaceDesignTokens.appColumnGap,
                        alignment: .top
                    ),
                    count: layout.appGrid.columns
                ),
                alignment: .leading,
                spacing: WorkspaceDesignTokens.space3
            ) {
                ForEach(items, id: \.absoluteIndex) { item in
                    appCell(presentation.selectedApps[item.absoluteIndex], shortcut: item.shortcut)
                }
            }
            .frame(width: layout.renderedAppGridWidth, alignment: .leading)

            if layout.appGrid.pageCount > 1 {
                VStack(spacing: WorkspaceDesignTokens.space2) {
                    Button {
                        _ = interactionModel.send(.selectAppPage(max(0, safePage - 1)))
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(safePage == 0)
                    .accessibilityLabel("Previous App page")
                    .accessibilityIdentifier("screen-switcher.workspace.switch.app-page.previous")
                    Button {
                        _ = interactionModel.send(.selectAppPage(min(layout.appGrid.pageCount - 1, safePage + 1)))
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(safePage >= layout.appGrid.pageCount - 1)
                    .accessibilityLabel("Next App page")
                    .accessibilityIdentifier("screen-switcher.workspace.switch.app-page.next")
                    AppPageDots(
                        currentPage: safePage,
                        pageCount: layout.appGrid.pageCount,
                        environment: environment
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(WorkspaceDesignTokens.color(.secondaryText, environment: environment))
                .opacity(renderPolicy.secondaryTextOpacity)
            }
            }
        }
        .padding(.horizontal, WorkspaceDesignTokens.space5)
        .padding(.vertical, WorkspaceDesignTokens.space4)
        .frame(width: layout.appLayerWidth)
        .frame(minHeight: layout.appLayerHeight)
        .background {
            WorkspaceGlassSurface(
                role: .action,
                environment: environment,
                cornerRadius: WorkspaceDesignTokens.glassRadius
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Running Apps")
        .accessibilityIdentifier("screen-switcher.workspace.switch.app-layer")
        .animation(renderPolicy.animation, value: safePage)
    }

    private func appCell(_ app: WorkspaceAppPresentation, shortcut: String) -> some View {
        let geometry = ShortcutKeycapGeometry(
            containerSize: CGSize(
                width: WorkspaceDesignTokens.appCell,
                height: WorkspaceDesignTokens.appCell
            ),
            requestedArtworkSize: CGSize(
                width: WorkspaceDesignTokens.appIcon,
                height: WorkspaceDesignTokens.appIcon
            )
        )
        return Button {
            _ = interactionModel.send(.activateApp(app.descriptor.id))
        } label: {
            ShortcutKeycapAnchor(
                geometry: geometry,
                value: shortcut,
                selected: false,
                environment: environment
            ) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(WorkspaceDesignTokens.color(.secondaryText, environment: environment))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: WorkspaceDesignTokens.appCell, height: WorkspaceDesignTokens.appCell)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.accessibilityLabel)
        .accessibilityIdentifier(app.accessibilityIdentifier)
        .accessibilityAddTraits(.isButton)
    }

    private func displayTitle(for display: DisplayDescriptor) -> String {
        let index = interactionModel.content.workspaces.firstIndex { $0.display.id == display.id }.map { $0 + 1 } ?? 1
        return "Display \(index)"
    }

    @ViewBuilder
    private func scrollableAppLayer<Content: View>(
        horizontal: Bool,
        vertical: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if horizontal || vertical {
            ScrollView(
                horizontal && vertical ? [.horizontal, .vertical] : (horizontal ? .horizontal : .vertical),
                showsIndicators: false
            ) {
                content()
            }
        } else {
            content()
        }
    }
}

private struct PreviewRequestID: Hashable {
    let displayID: String
    let width: Int
    let height: Int
}

private struct AppPageDots: View {
    let currentPage: Int
    let pageCount: Int
    let environment: WorkspaceVisualEnvironment

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<pageCount, id: \.self) { page in
                Circle()
                    .fill(WorkspaceDesignTokens.color(
                        page == currentPage ? .primaryText : .secondaryText,
                        environment: environment
                    ))
                    .frame(width: 5, height: 5)
                    .opacity(page == currentPage ? 0.72 : 0.28)
            }
        }
        .frame(minHeight: WorkspaceDesignTokens.keycapHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App page \(currentPage + 1) of \(pageCount)")
        .accessibilityIdentifier("screen-switcher.workspace.switch.app-page.indicator")
    }
}

private struct DisplaySchematic: View {
    let environment: WorkspaceVisualEnvironment

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                WorkspaceDesignTokens.color(.contentInset, environment: environment)
                schematicWindow(width: proxy.size.width * 0.48, height: proxy.size.height * 0.43)
                    .offset(x: -proxy.size.width * 0.14, y: -proxy.size.height * 0.13)
                schematicWindow(width: proxy.size.width * 0.41, height: proxy.size.height * 0.37)
                    .offset(x: proxy.size.width * 0.15, y: -proxy.size.height * 0.05)
            }
        }
        .accessibilityHidden(true)
    }

    private func schematicWindow(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WorkspaceDesignTokens.color(.schematicWindow, environment: environment))
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(WorkspaceDesignTokens.color(.schematicWindowHeader, environment: environment))
                    .frame(height: 28)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(WorkspaceDesignTokens.color(.border, environment: environment), lineWidth: 1)
            }
    }
}
