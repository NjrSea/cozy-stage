import SwiftUI

public struct TopTabGlass: View {
    @ObservedObject private var interactionModel: WorkspaceInteractionModel
    let environment: WorkspaceVisualEnvironment

    public init(
        interactionModel: WorkspaceInteractionModel,
        environment: WorkspaceVisualEnvironment
    ) {
        self.interactionModel = interactionModel
        self.environment = environment
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                Button {
                    _ = interactionModel.send(.selectTab(tab))
                } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(WorkspaceDesignTokens.color(
                            interactionModel.presentation.selectedTab == tab ? .primaryText : .secondaryText,
                            environment: environment
                        ))
                        .opacity(
                            interactionModel.presentation.selectedTab == tab
                                ? 1
                                : WorkspaceRenderPolicy(environment: environment).secondaryTextOpacity
                        )
                        .frame(
                            width: WorkspaceDesignTokens.topTabItemWidth,
                            height: WorkspaceDesignTokens.topTabHeight - WorkspaceDesignTokens.space2
                        )
                        .background {
                            if interactionModel.presentation.selectedTab == tab {
                                Capsule()
                                    .fill(WorkspaceDesignTokens.color(.focusFill, environment: environment))
                                    .overlay {
                                        Capsule().stroke(
                                            WorkspaceDesignTokens.color(.focus, environment: environment),
                                            lineWidth: WorkspaceDesignTokens.resolve(environment: environment).borderWidth
                                        )
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("screen-switcher.workspace.tab.\(tab.identifier)")
            }
        }
        .padding(WorkspaceDesignTokens.space1)
        .frame(height: WorkspaceDesignTokens.topTabHeight)
        .background {
            WorkspaceGlassSurface(
                role: .navigation,
                environment: environment,
                cornerRadius: WorkspaceDesignTokens.topTabHeight / 2
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tabs")
        .accessibilityIdentifier("screen-switcher.workspace.tabs")
        .animation(
            WorkspaceRenderPolicy(environment: environment).animation,
            value: interactionModel.presentation.selectedTab
        )
    }
}

private extension WorkspaceTab {
    var title: String {
        switch self {
        case .switch: return "Switch"
        case .agents: return "Agents"
        case .focus: return "Focus"
        }
    }

    var identifier: String {
        switch self {
        case .switch: return "switch"
        case .agents: return "agents"
        case .focus: return "focus"
        }
    }
}
