import SwiftUI

public struct ShortcutKeycapGeometry: Equatable, Sendable {
    public static let keycapSize = CGSize(width: 14, height: 21)
    public static let defaultSafeGap: CGFloat = 2

    public let containerSize: CGSize
    public let artworkFrame: CGRect
    public let keycapFrame: CGRect
    public let safeGap: CGFloat

    public init(
        containerSize: CGSize,
        requestedArtworkSize: CGSize,
        safeGap: CGFloat = Self.defaultSafeGap
    ) {
        let container = CGSize(
            width: max(containerSize.width, 0),
            height: max(containerSize.height, 0)
        )
        let gap = max(safeGap, 0)
        let keycap = CGSize(
            width: min(Self.keycapSize.width, container.width),
            height: min(Self.keycapSize.height, container.height)
        )
        let artwork = CGSize(
            width: min(max(requestedArtworkSize.width, 0), max(container.width - keycap.width - gap, 0)),
            height: min(max(requestedArtworkSize.height, 0), container.height)
        )

        self.containerSize = container
        self.safeGap = gap
        artworkFrame = CGRect(
            x: 0,
            y: max((container.height - artwork.height) / 2, 0),
            width: artwork.width,
            height: artwork.height
        )
        keycapFrame = CGRect(
            x: max(container.width - keycap.width, 0),
            y: max(container.height - keycap.height, 0),
            width: keycap.width,
            height: keycap.height
        )
    }
}

struct ShortcutKeycapAnchor<Artwork: View>: View {
    let geometry: ShortcutKeycapGeometry
    let value: String
    let selected: Bool
    let environment: WorkspaceVisualEnvironment
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        ZStack(alignment: .topLeading) {
            artwork()
                .frame(
                    width: geometry.artworkFrame.width,
                    height: geometry.artworkFrame.height
                )
                .offset(x: geometry.artworkFrame.minX, y: geometry.artworkFrame.minY)
            ShortcutKeycap(value: value, selected: selected, environment: environment)
                .frame(width: geometry.keycapFrame.width, height: geometry.keycapFrame.height)
                .offset(x: geometry.keycapFrame.minX, y: geometry.keycapFrame.minY)
        }
        .frame(
            width: geometry.containerSize.width,
            height: geometry.containerSize.height,
            alignment: .topLeading
        )
    }
}

public struct LeftContextRail: View {
    @ObservedObject private var interactionModel: WorkspaceInteractionModel
    let environment: WorkspaceVisualEnvironment

    public init(
        interactionModel: WorkspaceInteractionModel,
        environment: WorkspaceVisualEnvironment
    ) {
        self.interactionModel = interactionModel
        self.environment = environment
    }

    private var workspaces: [DisplayWorkspaceSnapshot] {
        let visible = Set(interactionModel.presentation.visibleDisplayIDs)
        return interactionModel.content.workspaces.filter { visible.contains($0.display.id) }
    }

    public var body: some View {
        if interactionModel.content.workspaces.count > 1 {
            VStack(spacing: WorkspaceDesignTokens.space2) {
                if interactionModel.presentation.displayPageCount > 1 {
                    displayPageButton(delta: -1)
                }
                ForEach(workspaces, id: \.display.id) { workspace in
                    displayButton(workspace)
                }
                if interactionModel.presentation.displayPageCount > 1 {
                    displayPageButton(delta: 1)
                }
            }
            .padding(WorkspaceDesignTokens.leftRailPadding)
            .frame(width: WorkspaceDesignTokens.leftRailWidth)
            .background {
                WorkspaceGlassSurface(
                    role: .navigation,
                    environment: environment,
                    cornerRadius: WorkspaceDesignTokens.leftRailRadius
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Displays")
            .accessibilityIdentifier("screen-switcher.workspace.display-rail")
        }
    }

    private func displayButton(_ workspace: DisplayWorkspaceSnapshot) -> some View {
        let selected = interactionModel.presentation.selectedDisplayID == workspace.display.id
        let number = (interactionModel.content.workspaces.firstIndex {
            $0.display.id == workspace.display.id
        } ?? 0) + 1
        return Button {
            _ = interactionModel.send(.selectDisplay(workspace.display.id))
        } label: {
            let geometry = ShortcutKeycapGeometry(
                containerSize: CGSize(
                    width: WorkspaceDesignTokens.leftRailItem,
                    height: WorkspaceDesignTokens.leftRailItem
                ),
                requestedArtworkSize: WorkspaceDesignTokens.displayArtworkMaximum
            )
            ShortcutKeycapAnchor(
                geometry: geometry,
                value: String(number),
                selected: selected,
                environment: environment
            ) {
                DisplayDeviceArtwork(
                    kind: DisplayDeviceKind.resolve(from: workspace.display),
                    environment: environment,
                    size: geometry.artworkFrame.size
                )
            }
            .frame(
                width: WorkspaceDesignTokens.leftRailItem,
                height: WorkspaceDesignTokens.leftRailItem
            )
            .background {
                RoundedRectangle(cornerRadius: WorkspaceDesignTokens.leftRailItemRadius, style: .continuous)
                    .fill(selected
                        ? WorkspaceDesignTokens.color(.focusFill, environment: environment)
                        : WorkspaceDesignTokens.color(.contentInset, environment: environment).opacity(0.28))
            }
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceDesignTokens.leftRailItemRadius, style: .continuous)
                    .stroke(
                        selected
                            ? WorkspaceDesignTokens.color(.focus, environment: environment)
                            : WorkspaceDesignTokens.color(.border, environment: environment),
                        lineWidth: WorkspaceDesignTokens.resolve(environment: environment).borderWidth
                    )
            }
            .opacity(selected ? 1 : WorkspaceDesignTokens.resolve(environment: environment).inactiveControlOpacity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Display \(number)"
                + (workspace.display.isCurrent ? ", current display" : "")
                + (selected ? ", selected display" : "")
        )
        .accessibilityIdentifier("screen-switcher.workspace.display.\(workspace.display.id)")
    }

    private func displayPageButton(delta: Int) -> some View {
        let page = interactionModel.presentation.selectedDisplayPage
        let destination = page + delta
        let enabled = destination >= 0
            && destination < interactionModel.presentation.displayPageCount
        let direction = delta < 0 ? "previous" : "next"
        return Button {
            _ = interactionModel.send(.selectDisplayPage(destination))
        } label: {
            Image(systemName: delta < 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WorkspaceDesignTokens.color(.secondaryText, environment: environment))
                .frame(width: WorkspaceDesignTokens.leftRailItem, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? WorkspaceDesignTokens.resolve(environment: environment).inactiveControlOpacity : 0.25)
        .accessibilityLabel("\(delta < 0 ? "Previous" : "Next") display page, page \(page + 1) of \(interactionModel.presentation.displayPageCount)")
        .accessibilityIdentifier("screen-switcher.workspace.display-page.\(direction)")
    }

}

struct ShortcutKeycap: View {
    let value: String
    let selected: Bool
    let environment: WorkspaceVisualEnvironment

    var body: some View {
        Text(value)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(WorkspaceDesignTokens.color(
                selected ? .keycapText : .secondaryText,
                environment: environment
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected
                        ? WorkspaceDesignTokens.color(.focus, environment: environment)
                        : WorkspaceDesignTokens.color(.keycap, environment: environment))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(WorkspaceDesignTokens.color(.border, environment: environment), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
