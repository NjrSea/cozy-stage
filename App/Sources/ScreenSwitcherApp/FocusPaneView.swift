import SwiftUI
import ScreenDomainCore

// MARK: - Phase 1C: Tab Rail and Pane UI model

/// Design tokens for the persistent Tab Rail.
enum FocusTabRailDesign {
    /// Target height ~30 points.
    static let railHeight: CGFloat = 30
    /// 14–16pt app icon.
    static let appIconSize: CGFloat = 15
    /// Compact equal-width tab minimum.
    static let minTabWidth: CGFloat = 80
    static let maxTabWidth: CGFloat = 200
    /// Close button appears on hover or active Tab.
    static let closeButtonSize: CGFloat = 12
    /// Divider between Panes: ~4–6pt visible with wider hit target.
    static let dividerWidth: CGFloat = 5
    static let dividerHitTarget: CGFloat = 12
    static let dividerCornerRadius: CGFloat = 2.5
}

/// A UI-presentable projection of a Tab in the persistent Rail.
struct FocusTabRailEntry: Equatable, Identifiable {
    let id: TabID
    let windowID: ManagedWindowID
    let state: TabVisualState
    let order: Int
    let appName: String
    let appIcon: NSImage?
    let windowTitle: String

    enum TabVisualState: String, Equatable {
        case active, inactive, loading, unavailable
    }
}

/// A UI-presentable projection of a Pane with its Tab Rail.
struct FocusPaneRailEntry: Equatable, Identifiable {
    let id: PaneID
    let role: String?
    let tabEntries: [FocusTabRailEntry]
    let activeTabID: TabID?
}

/// The persistent Tab Rail view.
///
/// Every Pane in a Tabs Layout keeps this Rail, including empty and
/// single-window Panes. Compact equal-width tabs with horizontal overflow.
/// Active Tab uses stronger contrast. Close appears on hover or active Tab.
/// `+` and `…` are fixed at the trailing edge.
struct FocusTabRailView: View {
    let entry: FocusPaneRailEntry

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(entry.tabEntries) { tab in
                        FocusTabCell(tab: tab, isActive: tab.id == entry.activeTabID)
                    }
                }
            }
            FocusTabRailTrailing()
        }
        .frame(height: FocusTabRailDesign.railHeight)
        .background(Color.primary.opacity(0.04))
    }
}

/// A single Tab cell in the Rail.
struct FocusTabCell: View {
    let tab: FocusTabRailEntry
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let icon = tab.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: FocusTabRailDesign.appIconSize, height: FocusTabRailDesign.appIconSize)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: FocusTabRailDesign.appIconSize, height: FocusTabRailDesign.appIconSize)
            }
            Text(truncatedTitle)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .foregroundColor(stateColor)
                .lineLimit(1)
            if isActive {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: FocusTabRailDesign.closeButtonSize, height: FocusTabRailDesign.closeButtonSize)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: FocusTabRailDesign.minTabWidth, maxWidth: FocusTabRailDesign.maxTabWidth)
        .background(isActive ? Color.primary.opacity(0.08) : Color.clear)
    }

    private var truncatedTitle: String {
        tab.windowTitle.count > 20 ? String(tab.windowTitle.prefix(18)) + "…" : tab.windowTitle
    }

    private var stateColor: Color {
        switch tab.state {
        case .active: return .primary
        case .inactive: return .secondary
        case .loading: return .secondary
        case .unavailable: return .secondary.opacity(0.5)
        }
    }
}

/// The trailing `+` and `…` controls fixed at the Rail edge.
struct FocusTabRailTrailing: View {
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Button(action: {}) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }
}

/// The draggable divider between Panes.
/// ~4–6pt visible with a wider transparent hit target.
struct FocusPaneDivider: View {
    let isHorizontal: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: FocusTabRailDesign.dividerCornerRadius)
            .fill(Color.primary.opacity(0.1))
            .frame(
                width: isHorizontal ? FocusTabRailDesign.dividerWidth : FocusTabRailDesign.dividerHitTarget,
                height: isHorizontal ? FocusTabRailDesign.dividerHitTarget : FocusTabRailDesign.dividerWidth
            )
    }
}

// MARK: - Preview support (mock data)

#if DEBUG
extension FocusPaneRailEntry {
    static func mock(paneID: PaneID = "pane-1", tabs: Int = 2) -> FocusPaneRailEntry {
        let entries = (0..<tabs).map { i in
            FocusTabRailEntry(
                id: "tab-\(i + 1)",
                windowID: "w\(i + 1)",
                state: i == 0 ? .active : .inactive,
                order: i,
                appName: ["Editor", "Browser", "Terminal"][min(i, 2)],
                appIcon: nil,
                windowTitle: ["main.rs", "docs.md", "zsh"][min(i, 2)]
            )
        }
        return FocusPaneRailEntry(id: paneID, role: "primary", tabEntries: entries, activeTabID: entries.first?.id)
    }
}
#endif
