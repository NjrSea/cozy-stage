import AppKit
import QuartzCore
import ScreenDomainCore
import SwiftUI

enum FocusHUDDesign {
    static let minWidth: CGFloat = 390
    static let minHeight: CGFloat = 112
    static let contentInset: CGFloat = 16

    static let cornerRadius: CGFloat = 28
    static let backgroundTintOpacity: CGFloat = 0.06
    static let innerBorderLineWidth: CGFloat = 1
    static let sectionGap: CGFloat = 6
    static let headerHeight: CGFloat = 20
    static let workspaceLeadingInset: CGFloat = 6
    static let workspaceContentTopInset: CGFloat = 0
    static let cellGap: CGFloat = 4
    static let emptyWorkspaceHeight: CGFloat = 24

    struct OverviewAppMetrics {
        let cellSize: CGFloat
        let visibleIconSize: CGFloat
        let iconCornerRadius: CGFloat
        let selectionSize: CGFloat
        let selectionCornerRadius: CGFloat
        let nameRegionHeight: CGFloat
        let nameFontSize: CGFloat
        let badgeSize: CGFloat
        let badgeFontSize: CGFloat
    }

    static func appMetrics(cellSize: CGFloat) -> OverviewAppMetrics {
        let visibleIconSize = max(32, cellSize * 0.82)
        let nameRegionHeight: CGFloat = 0
        let selectionInset: CGFloat = 0
        return OverviewAppMetrics(
            cellSize: cellSize,
            visibleIconSize: visibleIconSize,
            iconCornerRadius: visibleIconSize * 0.224,
            selectionSize: min(cellSize, visibleIconSize + selectionInset * 2),
            selectionCornerRadius: visibleIconSize * 0.224 + selectionInset,
            nameRegionHeight: nameRegionHeight,
            nameFontSize: max(8, cellSize * 0.12),
            badgeSize: max(16, cellSize * 0.2),
            badgeFontSize: max(11, cellSize * 0.13)
        )
    }

    static func shortcutBadgeWeight(for shortcut: Character) -> Font.Weight {
        shortcut.isLowercase ? .regular : .bold
    }

}

enum FocusHUDRenderState: Equatable {
    case overview
    case layoutUnavailable
}

enum FocusHUDRenderActionKind: Equatable {
    case activateApp
    case dismiss
}

struct FocusHUDRenderAction: Equatable {
    let kind: FocusHUDRenderActionKind
    let windowID: ManagedWindowID?

    static let dismiss = Self(kind: .dismiss, windowID: nil)
}

struct FocusHUDRenderApp: Identifiable {
    let entry: FocusHUDAppEntry

    var id: ManagedWindowID { entry.id }
    var appName: String { entry.appName }
    var shortcutLabel: Character? { entry.shortcut?.label }
    var action: FocusHUDRenderAction { .init(kind: .activateApp, windowID: entry.id) }
}

struct FocusHUDRenderSection: Identifiable {
    let id: FocusScreenID
    let ordinal: Int
    let title: String
    let currentLabel: String?
    let rows: [[FocusHUDRenderApp]]

    var actions: [FocusHUDRenderAction] {
        rows.flatMap { $0 }.map(\.action)
    }
}

/// Pure projection from the frozen presentation snapshot into the View tree.
struct FocusHUDRenderModel {
    let state: FocusHUDRenderState
    let sections: [FocusHUDRenderSection]
    let actions: [FocusHUDRenderAction]
    let layout: FocusHUDOverviewLayout?

    init(snapshot: FocusHUDPresentationSnapshot) {
        guard let layout = snapshot.layout.availableLayout,
              layout.workspaceLayouts.count == snapshot.sections.count
        else {
            state = .layoutUnavailable
            sections = []
            actions = [.dismiss]
            self.layout = nil
            return
        }

        let projected = zip(snapshot.sections, layout.workspaceLayouts).compactMap(Self.section)
        guard projected.count == snapshot.sections.count else {
            state = .layoutUnavailable
            sections = []
            actions = [.dismiss]
            self.layout = nil
            return
        }

        state = .overview
        sections = projected
        actions = projected.flatMap(\.actions)
        self.layout = layout
    }

    private static func section(
        _ section: FocusHUDWorkspaceSection,
        _ workspaceLayout: FocusHUDWorkspaceLayout
    ) -> FocusHUDRenderSection? {
        guard workspaceLayout.appCount == section.apps.count else { return nil }
        if section.apps.isEmpty {
            guard workspaceLayout.columnCount == 0, workspaceLayout.rowCount == 0 else { return nil }
            return FocusHUDRenderSection(
                id: section.id,
                ordinal: section.ordinal,
                title: section.name,
                currentLabel: section.isCurrent ? "Current" : nil,
                rows: []
            )
        }

        guard workspaceLayout.columnCount > 0,
              (1...3).contains(workspaceLayout.rowCount),
              (section.apps.count - 1) / workspaceLayout.columnCount + 1 == workspaceLayout.rowCount
        else { return nil }
        let apps = section.apps.map(FocusHUDRenderApp.init)
        let rows = stride(from: 0, to: apps.count, by: workspaceLayout.columnCount).map {
            Array(apps[$0..<min($0 + workspaceLayout.columnCount, apps.count)])
        }
        return FocusHUDRenderSection(
            id: section.id,
            ordinal: section.ordinal,
            title: section.name,
            currentLabel: section.isCurrent ? "Current" : nil,
            rows: rows
        )
    }
}

struct FocusHUDRenderedState: Equatable {
    let layoutState: FocusSemanticHUDRenderedLayoutState
    let cellSize: Double?
    let visibleIconSize: Double?
    let nameFontSize: Double?
    let badgeSize: Double?
    let badgeFontSize: Double?
    let appTargetCount: Int
    let dismissTargetCount: Int
    let emptyWorkspaceCount: Int

    static let empty = Self(
        layoutState: .none,
        cellSize: nil,
        visibleIconSize: nil,
        nameFontSize: nil,
        badgeSize: nil,
        badgeFontSize: nil,
        appTargetCount: 0,
        dismissTargetCount: 0,
        emptyWorkspaceCount: 0
    )

    init(
        layoutState: FocusSemanticHUDRenderedLayoutState,
        cellSize: Double?,
        visibleIconSize: Double?,
        nameFontSize: Double?,
        badgeSize: Double?,
        badgeFontSize: Double?,
        appTargetCount: Int,
        dismissTargetCount: Int,
        emptyWorkspaceCount: Int
    ) {
        self.layoutState = layoutState
        self.cellSize = cellSize
        self.visibleIconSize = visibleIconSize
        self.nameFontSize = nameFontSize
        self.badgeSize = badgeSize
        self.badgeFontSize = badgeFontSize
        self.appTargetCount = appTargetCount
        self.dismissTargetCount = dismissTargetCount
        self.emptyWorkspaceCount = emptyWorkspaceCount
    }

    init(model: FocusHUDRenderModel) {
        let appTargetCount = model.actions.lazy.filter { $0.kind == .activateApp }.count
        let dismissTargetCount = model.actions.lazy.filter { $0.kind == .dismiss }.count
        guard let layout = model.layout else {
            self.init(
                layoutState: .layoutUnavailable,
                cellSize: nil,
                visibleIconSize: nil,
                nameFontSize: nil,
                badgeSize: nil,
                badgeFontSize: nil,
                appTargetCount: appTargetCount,
                dismissTargetCount: dismissTargetCount,
                emptyWorkspaceCount: 0
            )
            return
        }
        let metrics = FocusHUDDesign.appMetrics(cellSize: CGFloat(layout.cellSize))
        self.init(
            layoutState: .overview,
            cellSize: layout.cellSize,
            visibleIconSize: Double(metrics.visibleIconSize),
            nameFontSize: Double(metrics.nameFontSize),
            badgeSize: Double(metrics.badgeSize),
            badgeFontSize: Double(metrics.badgeFontSize),
            appTargetCount: appTargetCount,
            dismissTargetCount: dismissTargetCount,
            emptyWorkspaceCount: model.sections.lazy.filter(\.rows.isEmpty).count
        )
    }
}

enum FocusHUDNameDisplay {
    static func visibleWindowID(
        hovered: ManagedWindowID?,
        focused: ManagedWindowID?
    ) -> ManagedWindowID? {
        hovered ?? focused
    }

    static func isHighlighted(
        windowID: ManagedWindowID,
        hovered: ManagedWindowID?,
        focused: ManagedWindowID?
    ) -> Bool {
        visibleWindowID(hovered: hovered, focused: focused) == windowID
    }
}

private struct FocusHUDHoverRenderSentinel: NSViewRepresentable {
    let presentationRevision: UInt64
    let hoverRevision: UInt64
    let acknowledge: @MainActor (UInt64, UInt64) -> Void

    func makeNSView(context: Context) -> RenderView {
        RenderView()
    }

    func updateNSView(_ view: RenderView, context: Context) {
        view.configure(
            presentationRevision: presentationRevision,
            hoverRevision: hoverRevision,
            acknowledge: acknowledge
        )
    }

    final class RenderView: NSView {
        private var presentationRevision: UInt64 = 0
        private var hoverRevision: UInt64 = 0
        private var acknowledge: (@MainActor (UInt64, UInt64) -> Void)?

        override var isOpaque: Bool { false }

        func configure(
            presentationRevision: UInt64,
            hoverRevision: UInt64,
            acknowledge: @escaping @MainActor (UInt64, UInt64) -> Void
        ) {
            self.acknowledge = acknowledge
            guard self.presentationRevision != presentationRevision
                    || self.hoverRevision != hoverRevision else { return }
            self.presentationRevision = presentationRevision
            self.hoverRevision = hoverRevision
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard hoverRevision > 0, let acknowledge else { return }
            let presentationRevision = presentationRevision
            let hoverRevision = hoverRevision
            CATransaction.setCompletionBlock {
                Task { @MainActor in
                    acknowledge(presentationRevision, hoverRevision)
                }
            }
        }
    }
}

struct FocusHUDRenderSentinel: NSViewRepresentable {
    let presentationRevision: UInt64
    let interactionRevision: UInt64
    let state: FocusHUDRenderedState
    let acknowledge: @MainActor (UInt64, UInt64, FocusHUDRenderedState) -> Void

    func makeNSView(context: Context) -> RenderView { RenderView() }

    func updateNSView(_ view: RenderView, context: Context) {
        view.configure(
            presentationRevision: presentationRevision,
            interactionRevision: interactionRevision,
            state: state,
            acknowledge: acknowledge
        )
    }

    final class RenderView: NSView {
        private var presentationRevision: UInt64 = 0
        private var interactionRevision: UInt64 = 0
        private var state = FocusHUDRenderedState.empty
        private var acknowledge: (@MainActor (UInt64, UInt64, FocusHUDRenderedState) -> Void)?

        override var isOpaque: Bool { false }

        func configure(
            presentationRevision: UInt64,
            interactionRevision: UInt64,
            state: FocusHUDRenderedState,
            acknowledge: @escaping @MainActor (UInt64, UInt64, FocusHUDRenderedState) -> Void
        ) {
            self.acknowledge = acknowledge
            guard self.presentationRevision != presentationRevision
                    || self.interactionRevision != interactionRevision
                    || self.state != state else { return }
            self.presentationRevision = presentationRevision
            self.interactionRevision = interactionRevision
            self.state = state
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard presentationRevision > 0, let acknowledge else { return }
            let presentationRevision = presentationRevision
            let interactionRevision = interactionRevision
            let state = state
            CATransaction.setCompletionBlock {
                Task { @MainActor in
                    acknowledge(presentationRevision, interactionRevision, state)
                }
            }
        }
    }
}

/// The compact HUD renders only the immutable presentation snapshot. Workspace
/// headings are labels; App cells are the only activation targets.
struct FocusHUDView: View {
    @ObservedObject var viewModel: FocusHUDViewModel
    @FocusState private var keyboardFocusedWindowID: ManagedWindowID?

    var body: some View {
        Group {
            switch viewModel.windowDiscoveryStatus {
            case .accessibilityRequired:
                permissionAccessRegion
            case .loading, .unavailable:
                discoveryStatusRegion
            case .ready:
                if let snapshot = viewModel.snapshot {
                    snapshotRegion(snapshot)
                } else {
                    discoveryStatusRegion
                }
            }
        }
        .background(FocusHUDBackground())
        .clipShape(RoundedRectangle(cornerRadius: FocusHUDDesign.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-switcher.hud")
    }

    @ViewBuilder
    private func snapshotRegion(_ snapshot: FocusHUDPresentationSnapshot) -> some View {
        let model = FocusHUDRenderModel(snapshot: snapshot)
        Group {
            if let layout = model.layout {
                VStack(alignment: .leading, spacing: FocusHUDDesign.sectionGap) {
                    ForEach(model.sections) { section in
                        workspaceSection(section, cellSize: CGFloat(layout.cellSize))
                    }
                }
                .frame(
                    width: CGFloat(layout.contentWidth),
                    height: CGFloat(layout.contentHeight),
                    alignment: .topLeading
                )
                .padding(CGFloat(layout.contentInset))
                .frame(
                    width: CGFloat(layout.panelWidth),
                    height: CGFloat(layout.panelHeight),
                    alignment: .topLeading
                )
            } else {
                layoutUnavailableRegion
            }
        }
        .overlay {
            FocusHUDRenderSentinel(
                presentationRevision: snapshot.presentationRevision,
                interactionRevision: viewModel.interactionRevision,
                state: FocusHUDRenderedState(model: model),
                acknowledge: viewModel.acknowledgeRenderedHUD
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func workspaceSection(
        _ section: FocusHUDRenderSection,
        cellSize: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(section.title)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                if let currentLabel = section.currentLabel {
                    Text(currentLabel)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .regular))
            .padding(.leading, FocusHUDDesign.workspaceLeadingInset)
            .frame(height: FocusHUDDesign.headerHeight)
            .contentShape(Rectangle())
            .onTapGesture {}
            .accessibilityElement(children: .combine)
            .accessibilityRespondsToUserInteraction(false)
            .accessibilityIdentifier("screen-switcher.hud.workspace.\(section.ordinal)")

            if section.rows.isEmpty {
                Text("No Active Apps")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(height: FocusHUDDesign.emptyWorkspaceHeight)
                    .padding(.top, FocusHUDDesign.workspaceContentTopInset)
                    .accessibilityIdentifier("screen-switcher.hud.workspace.\(section.ordinal).empty")
            } else {
                VStack(alignment: .leading, spacing: FocusHUDDesign.cellGap) {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: FocusHUDDesign.cellGap) {
                            ForEach(row) { app in
                                appButton(app, cellSize: cellSize)
                            }
                        }
                    }
                }
                .padding(.top, FocusHUDDesign.workspaceContentTopInset)
            }
        }
    }

    private func appButton(
        _ app: FocusHUDRenderApp,
        cellSize: CGFloat
    ) -> some View {
        let metrics = FocusHUDDesign.appMetrics(cellSize: cellSize)
        let isHighlighted = FocusHUDNameDisplay.isHighlighted(
            windowID: app.id,
            hovered: viewModel.hoveredWindowID,
            focused: viewModel.focusedWindowID ?? keyboardFocusedWindowID
        )

        return Button {
            _ = viewModel.activateApp(windowID: app.id)
        } label: {
            HStack(spacing: 0) {
                icon(for: app.entry, metrics: metrics)
                    .background {
                        RoundedRectangle(cornerRadius: metrics.selectionCornerRadius, style: .continuous)
                            .fill(isHighlighted ? Color.primary.opacity(0.12) : .clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: metrics.selectionCornerRadius, style: .continuous)
                                    .strokeBorder(
                                        isHighlighted ? Color.white.opacity(0.22) : .clear,
                                        lineWidth: FocusHUDDesign.innerBorderLineWidth
                                    )
                            }
                            .frame(width: metrics.selectionSize, height: metrics.selectionSize)
                    }
                    .overlay {
                        if let shortcut = app.shortcutLabel {
                            shortcutBadge(shortcut, metrics: metrics)
                                .accessibilityHidden(true)
                                .offset(
                                    x: metrics.visibleIconSize / 2 - metrics.badgeSize / 3,
                                    y: metrics.visibleIconSize / 2 - metrics.badgeSize / 3
                                )
                        }
                    }
                    .offset(
                        x: FocusHUDDesign.workspaceLeadingInset
                            - app.entry.iconLeadingInsetFraction * metrics.visibleIconSize
                    )
            }
            .frame(width: metrics.cellSize, height: metrics.cellSize, alignment: .leading)
            .background {
                FocusHUDHoverRenderSentinel(
                    presentationRevision: viewModel.snapshot?.presentationRevision ?? 0,
                    hoverRevision: viewModel.hoveredWindowID == app.id
                        ? viewModel.hoverRevision
                        : 0,
                    acknowledge: viewModel.acknowledgeRenderedHover
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .focused($keyboardFocusedWindowID, equals: app.id)
        .onHover { isHovered in
            if isHovered {
                viewModel.setHoveredWindowID(app.id)
            }
        }
        .help(app.entry.windowTitle == app.appName
            ? app.appName
            : "\(app.appName) — \(app.entry.windowTitle)")
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("screen-switcher.hud.window.\(FocusHUDOpaqueWindowID.opaque(for: app.id))")
        .accessibilityLabel(accessibilityLabel(for: app))
    }

    @ViewBuilder
    private func icon(
        for entry: FocusHUDAppEntry,
        metrics: FocusHUDDesign.OverviewAppMetrics
    ) -> some View {
        if let image = entry.appIcon {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous))
                .frame(width: metrics.visibleIconSize, height: metrics.visibleIconSize)
        } else {
            RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .overlay {
                    Image(systemName: "app")
                        .font(.system(size: max(14, metrics.visibleIconSize * 0.45)))
                        .foregroundStyle(.secondary)
                }
                .frame(width: metrics.visibleIconSize, height: metrics.visibleIconSize)
        }
    }

    private func shortcutBadge(
        _ shortcut: Character,
        metrics: FocusHUDDesign.OverviewAppMetrics
    ) -> some View {
        // Characters with descenders need upward compensation so they
        // appear optically centered in the circle.
        let hasDescender = "gjpqy".contains(shortcut)
        let yOffset = hasDescender ? -metrics.badgeFontSize * 0.1 : 0.0
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Circle().path(in: rect), with: .color(.black))
            let text = Text(String(shortcut))
                .font(.system(
                    size: metrics.badgeFontSize,
                    weight: FocusHUDDesign.shortcutBadgeWeight(for: shortcut),
                    design: .monospaced
                ))
                .foregroundColor(.white)
            context.draw(
                context.resolve(text),
                at: CGPoint(x: size.width / 2, y: size.height / 2 + yOffset),
                anchor: .center
            )
        }
        .frame(width: metrics.badgeSize, height: metrics.badgeSize)
    }

    private func accessibilityLabel(for app: FocusHUDRenderApp) -> Text {
        let prefix = app.shortcutLabel.map { "\($0), " } ?? ""
        return Text(verbatim: "\(prefix)\(app.appName), \(app.entry.windowTitle)")
    }

    private var layoutUnavailableRegion: some View {
        VStack(spacing: 10) {
            Text("Unable to Fit Apps")
                .font(.system(size: 14, weight: .medium))
            Button("关闭") {
                _ = viewModel.handle(key: .escape)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("screen-switcher.hud.layout_unavailable.dismiss")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: FocusHUDDesign.minWidth, minHeight: FocusHUDDesign.minHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-switcher.hud.layout_unavailable")
    }

    private var discoveryStatusRegion: some View {
        VStack(spacing: 8) {
            switch viewModel.windowDiscoveryStatus {
            case .loading, .ready:
                ProgressView()
                Text("Reading Windows")
                    .font(.system(size: 13, weight: .medium))
            case .unavailable:
                Text("Unable to Read Windows")
                    .font(.system(size: 14, weight: .medium))
                Text("Close and reopen the HUD to retry.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .accessibilityRequired:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: FocusHUDDesign.minWidth, minHeight: FocusHUDDesign.minHeight)
        .accessibilityIdentifier("screen-switcher.hud.window-discovery-status")
    }

    private var permissionAccessRegion: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.and.cursorarrow")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text("Window Access Required")
                .font(.system(size: 17, weight: .semibold))
            Button(action: {
                viewModel.requestAccessibilityAccess()
                if !AXIsProcessTrusted() {
                    DragHelperWindow.show()
                }
            }) {
                HStack(spacing: 7) {
                    Text("Allow Access")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(Color.green.opacity(0.13), in: Capsule())
                .overlay(Capsule().stroke(Color.green.opacity(0.38), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("screen-switcher.hud.request-accessibility")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: FocusHUDDesign.minWidth, minHeight: FocusHUDDesign.minHeight)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-switcher.hud.permission-card")
    }
}

struct FocusHUDBackground: View {
    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(
                    .regular.tint(Color.black.opacity(FocusHUDDesign.backgroundTintOpacity)),
                    in: RoundedRectangle(cornerRadius: FocusHUDDesign.cornerRadius, style: .continuous)
                )
        } else {
            RoundedRectangle(cornerRadius: FocusHUDDesign.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: FocusHUDDesign.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(FocusHUDDesign.backgroundTintOpacity))
                }
        }
    }
}

enum FocusHUDOpaqueWindowID {
    static func opaque(for windowID: ManagedWindowID) -> String {
        let raw = windowID.lowercased()
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
