import AppKit
import Foundation
import ScreenDomainCore

/// UI-only metadata. It never enters domain or semantic state.
public struct FocusHUDWindowMetadata: Equatable, Sendable {
    public let appName: String
    public let appIcon: NSImage?
    public let windowTitle: String

    public init(appName: String, appIcon: NSImage?, windowTitle: String) {
        self.appName = appName
        self.appIcon = appIcon
        self.windowTitle = windowTitle
    }
}

@MainActor
public protocol FocusHUDWindowMetadataProviding: AnyObject {
    func metadata(for window: ManagedWindow) -> FocusHUDWindowMetadata
}

/// Transitional View compatibility projection. The presentation source of
/// truth is `FocusHUDPresentationSnapshot`.
public struct FocusHUDScreen: Equatable, Identifiable, Sendable {
    public let id: FocusScreenID
    public let number: Int
    public let name: String?
    public let isActive: Bool

    public init(id: FocusScreenID, number: Int, name: String?, isActive: Bool) {
        self.id = id
        self.number = number
        self.name = name
        self.isActive = isActive
    }
}

/// Transitional View compatibility projection for the current single-grid UI.
public struct FocusHUDWindowEntry: Equatable, Identifiable, Sendable {
    public let id: ManagedWindowID
    public let letter: Character
    public let appName: String
    public let appIcon: NSImage?
    public let windowTitle: String
    public let isCurrent: Bool

    public init(id: ManagedWindowID, letter: Character, appName: String, appIcon: NSImage?, windowTitle: String, isCurrent: Bool) {
        self.id = id
        self.letter = letter
        self.appName = appName
        self.appIcon = appIcon
        self.windowTitle = windowTitle
        self.isCurrent = isCurrent
    }
}

public enum FocusHUDWindowDiscoveryStatus: Equatable, Sendable {
    case loading
    case ready
    case accessibilityRequired
    case unavailable
}

/// Freezes a complete HUD overview for the lifetime of one presentation.
@MainActor
public final class FocusHUDViewModel: ObservableObject {
    @Published public private(set) var isPresented = false
    @Published private(set) var snapshot: FocusHUDPresentationSnapshot?
    @Published private(set) var focusedWindowID: ManagedWindowID?
    @Published private(set) var interactionRevision: UInt64 = 0
    private(set) var renderedPresentationRevision: UInt64 = 0
    private(set) var renderedInteractionRevision: UInt64 = 0
    private(set) var renderedState = FocusHUDRenderedState.empty
    @Published private(set) var hoveredWindowID: ManagedWindowID?
    @Published private(set) var hoverRevision: UInt64 = 0
    @Published private(set) var renderedHoverRevision: UInt64 = 0

    var visibleNameCount: Int {
        isPresented && (hoveredWindowID != nil || focusedWindowID != nil) ? 1 : 0
    }

    var nameFocusSource: FocusSemanticHUDNameFocusSource {
        if hoveredWindowID != nil { return .pointerHover }
        if focusedWindowID != nil { return .keyboardFocus }
        return .none
    }

    // Compatibility surface for FocusHUDView/FocusHUDController until their
    // overview migration. These are projections only; they cannot inspect a
    // workspace or alter a frozen snapshot.
    @Published public private(set) var screens: [FocusHUDScreen] = []
    @Published public private(set) var inspectedScreen: FocusHUDScreen?
    @Published public private(set) var windowEntries: [FocusHUDWindowEntry] = []
    @Published public private(set) var maximumAppCount = 0
    @Published public private(set) var page = 0
    @Published public private(set) var pageCount = 1
    @Published public private(set) var lastDispatchedIntent: FocusHUDOverviewIntent = .none
    @Published public private(set) var windowDiscoveryStatus: FocusHUDWindowDiscoveryStatus = .loading

    private var state: FocusScreenState
    private var pendingState: FocusScreenState?
    private var overviewInputState = FocusHUDOverviewInputState()
    private var presentationRevision: UInt64 = 0
    private var keyAssignmentRevision: UInt64 = 0
    private let metadataProvider: any FocusHUDWindowMetadataProviding
    private let appIdentityHasher: (String) -> String
    private var intentHandler: @MainActor (FocusHUDOverviewIntent) -> Void
    private let accessibilityRequestHandler: @MainActor () -> Void

    public init(
        state: FocusScreenState,
        metadataProvider: any FocusHUDWindowMetadataProviding,
        intentHandler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void,
        accessibilityRequestHandler: @escaping @MainActor () -> Void = {},
        appIdentityHasher: ((String) -> String)? = nil
    ) {
        self.state = state
        self.metadataProvider = metadataProvider
        self.intentHandler = intentHandler
        self.accessibilityRequestHandler = accessibilityRequestHandler
        self.appIdentityHasher = appIdentityHasher ?? ProductAppAXIdentity.opaqueToken(forBundleIdentifier:)
    }

    func setIntentHandler(_ handler: @escaping @MainActor (FocusHUDOverviewIntent) -> Void) {
        intentHandler = handler
    }

    func setWindowDiscoveryStatus(_ status: FocusHUDWindowDiscoveryStatus) {
        windowDiscoveryStatus = status
    }

    func setPresentationRevisionForTest(_ revision: UInt64) {
        keyAssignmentRevision = revision
        presentationRevision = revision
    }

    func setInteractionRevisionForTest(_ revision: UInt64) {
        interactionRevision = revision
    }

    func requestAccessibilityAccess() {
        accessibilityRequestHandler()
    }

    func setFocusedWindowID(_ windowID: ManagedWindowID?) {
        guard isPresented else { return }
        focusedWindowID = windowID
        overviewInputState = FocusHUDOverviewInputState(
            rows: overviewInputState.rows,
            assignments: overviewInputState.assignments,
            focusedWindowID: windowID
        )
    }

    /// Compatibility no-op: overview presentations do not inspect/switch a
    /// Workspace from the View layer.
    func preview(screenID: FocusScreenID) {}

    public func update(state: FocusScreenState) {
        if isPresented {
            pendingState = state
        } else {
            self.state = state
            rebuildHiddenCompatibilityProjection(from: state)
        }
    }

    /// Rebuilds the snapshot in-place when the HUD was presented in loading
    /// state and inventory has since become ready. This handles the case where
    /// `present()` was called before accessibility/AX data was available.
    public func rebuildSnapshotIfPresented(
        constraints: FocusHUDOverviewLayoutConstraints,
        shiftedDigitSymbols: [Character],
        inventoryRevision: UInt64
    ) {
        guard isPresented, snapshot == nil, windowDiscoveryStatus == .ready else { return }
        guard shiftedDigitSymbols.count == 10 else { return }

        let effectiveState = pendingState ?? state

        let (nextKeyAssignmentRevision, keyAssignmentOverflow) = keyAssignmentRevision.addingReportingOverflow(1)
        let (nextPresentationRevision, presentationOverflow) = presentationRevision.addingReportingOverflow(1)
        guard !keyAssignmentOverflow, !presentationOverflow else { return }
        guard let nextSnapshot = try? makeSnapshot(
            from: effectiveState,
            constraints: constraints,
            shiftedDigitSymbols: shiftedDigitSymbols,
            inventoryRevision: inventoryRevision,
            keyAssignmentRevision: nextKeyAssignmentRevision,
            presentationRevision: nextPresentationRevision
        ) else { return }

        let nextInputState = makeOverviewInputState(for: nextSnapshot)
        keyAssignmentRevision = nextKeyAssignmentRevision
        presentationRevision = nextPresentationRevision
        snapshot = nextSnapshot
        overviewInputState = nextInputState
        renderedPresentationRevision = 0
        renderedInteractionRevision = 0
        renderedState = .empty
        focusedWindowID = nextInputState.focusedWindowID
        hoveredWindowID = nil
        rebuildCompatibilityProjection(from: nextSnapshot)
        if pendingState != nil { pendingState = nil }
    }

    /// Builds and installs the complete immutable presentation before exposing
    /// it. Invalid shortcut symbols leave the prior hidden state untouched.
    public func present(
        constraints: FocusHUDOverviewLayoutConstraints,
        shiftedDigitSymbols: [Character],
        inventoryRevision: UInt64
    ) throws {
        guard !isPresented else { return }
        guard windowDiscoveryStatus == .ready else {
            snapshot = nil
            overviewInputState = FocusHUDOverviewInputState()
            focusedWindowID = nil
            clearCompatibilityProjection()
            isPresented = true
            return
        }
        guard shiftedDigitSymbols.count == 10 else {
            throw FocusHUDShortcutAssignmentError.invalidShiftedDigitSymbolCount(shiftedDigitSymbols.count)
        }

        let (nextKeyAssignmentRevision, keyAssignmentOverflow) = keyAssignmentRevision.addingReportingOverflow(1)
        let (nextPresentationRevision, presentationOverflow) = presentationRevision.addingReportingOverflow(1)
        guard !keyAssignmentOverflow, !presentationOverflow else {
            throw FocusHUDPresentationError.revisionExhausted
        }
        let nextSnapshot = try makeSnapshot(
            from: state,
            constraints: constraints,
            shiftedDigitSymbols: shiftedDigitSymbols,
            inventoryRevision: inventoryRevision,
            keyAssignmentRevision: nextKeyAssignmentRevision,
            presentationRevision: nextPresentationRevision
        )
        let nextInputState = makeOverviewInputState(for: nextSnapshot)

        keyAssignmentRevision = nextKeyAssignmentRevision
        presentationRevision = nextPresentationRevision
        snapshot = nextSnapshot
        overviewInputState = nextInputState
        renderedPresentationRevision = 0
        renderedInteractionRevision = 0
        renderedState = .empty
        focusedWindowID = nextInputState.focusedWindowID
        hoveredWindowID = nil
        rebuildCompatibilityProjection(from: nextSnapshot)
        isPresented = true
    }

    @discardableResult
    func handle(key: FocusHUDOverviewKey) -> FocusHUDOverviewIntent {
        guard isPresented else { return .none }
        if key == .escape { return cancelPresentation() }
        guard windowDiscoveryStatus == .ready,
              let snapshot,
              snapshot.layout.availableLayout != nil
        else { return .none }

        let intent = FocusHUDOverviewInputReducer.handle(key, state: overviewInputState)
        switch intent {
        case let .focusWindow(windowID):
            if focusedWindowID != windowID {
                let (nextRevision, overflow) = interactionRevision.addingReportingOverflow(1)
                guard !overflow else { return .none }
                interactionRevision = nextRevision
            }
            focusedWindowID = windowID
            overviewInputState = FocusHUDOverviewInputState(
                rows: overviewInputState.rows,
                assignments: overviewInputState.assignments,
                focusedWindowID: windowID
            )
            return intent
        case .activateWindow, .activatePreviousApplication, .cancel:
            return dispatch(intent)
        case .none:
            return .none
        }
    }

    /// Called only from SwiftUI's delivered `onHover` callback. The semantic
    /// projection exposes the resulting count/source/revision, never this raw
    /// window identity.
    func setHoveredWindowID(_ windowID: ManagedWindowID?) {
        guard isPresented, hoveredWindowID != windowID else { return }
        if let windowID {
            guard snapshot?.sections.contains(where: {
                $0.apps.contains(where: { $0.id == windowID })
            }) == true else { return }
        }
        let (nextRevision, overflow) = hoverRevision.addingReportingOverflow(1)
        guard !overflow else { return }
        hoveredWindowID = windowID
        hoverRevision = nextRevision
    }

    func acknowledgeRenderedHover(
        presentationRevision: UInt64,
        hoverRevision: UInt64
    ) {
        guard isPresented,
              hoveredWindowID != nil,
              snapshot?.presentationRevision == presentationRevision,
              self.hoverRevision == hoverRevision,
              renderedHoverRevision < hoverRevision else { return }
        renderedHoverRevision = hoverRevision
    }

    func acknowledgeRenderedHUD(
        presentationRevision: UInt64,
        interactionRevision: UInt64,
        state: FocusHUDRenderedState
    ) {
        guard isPresented,
              snapshot?.presentationRevision == presentationRevision,
              self.interactionRevision == interactionRevision else { return }
        renderedPresentationRevision = presentationRevision
        renderedInteractionRevision = interactionRevision
        renderedState = state
    }

    @discardableResult
    func cancelPresentation() -> FocusHUDOverviewIntent {
        guard isPresented else { return .none }
        return dispatch(.cancel)
    }

    @discardableResult
    func activateApp(windowID: ManagedWindowID) -> FocusHUDOverviewIntent {
        guard isPresented,
              windowDiscoveryStatus == .ready,
              let snapshot,
              snapshot.layout.availableLayout != nil,
              snapshot.sections.contains(where: { $0.apps.contains(where: { $0.id == windowID }) })
        else { return .none }
        return dispatch(.activateWindow(windowID))
    }

    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        snapshot = nil
        focusedWindowID = nil
        hoveredWindowID = nil
        renderedPresentationRevision = 0
        renderedInteractionRevision = 0
        renderedState = .empty
        overviewInputState = FocusHUDOverviewInputState()
        clearCompatibilityProjection()
        if let pendingState {
            state = pendingState
            self.pendingState = nil
        }
    }

    private func dispatch(_ intent: FocusHUDOverviewIntent) -> FocusHUDOverviewIntent {
        switch intent {
        case .activateWindow, .activatePreviousApplication, .cancel:
            lastDispatchedIntent = intent
            intentHandler(intent)
            dismiss()
            return intent
        case .focusWindow, .none:
            return .none
        }
    }

    private func makeSnapshot(
        from state: FocusScreenState,
        constraints: FocusHUDOverviewLayoutConstraints,
        shiftedDigitSymbols: [Character],
        inventoryRevision: UInt64,
        keyAssignmentRevision: UInt64,
        presentationRevision: UInt64
    ) throws -> FocusHUDPresentationSnapshot {
        let sectionDrafts = state.screens.map { screen in
            SectionDraft(screen: screen, apps: appDrafts(in: screen, state: state))
        }.filter { !$0.apps.isEmpty }
        let assignments = try FocusHUDShortcutAssignment.assign(
            windowIDs: sectionDrafts.flatMap { $0.apps.map(\.window.id) },
            shiftedDigitSymbols: shiftedDigitSymbols
        )
        var assignmentIndex = 0
        let sections = sectionDrafts.map { draft in
            let apps = draft.apps.map { app -> FocusHUDAppEntry in
                defer { assignmentIndex += 1 }
                return FocusHUDAppEntry(
                    id: app.window.id,
                    screenID: draft.screen.id,
                    appIdentityHash: appIdentityHasher(app.window.appID),
                    appName: app.metadata.appName,
                    appIcon: app.metadata.appIcon,
                    iconLeadingInsetFraction: FocusHUDIconArtwork.leadingInsetFraction(for: app.metadata.appIcon),
                    windowTitle: app.metadata.windowTitle,
                    shortcut: assignments[assignmentIndex].shortcut,
                    isCurrent: draft.screen.id == state.activeScreenID && app.window.id == draft.screen.lastActiveWindowID
                )
            }
            return FocusHUDWorkspaceSection(
                id: draft.screen.id,
                screenID: draft.screen.id,
                ordinal: draft.screen.number,
                name: draft.screen.name?.isEmpty == false ? draft.screen.name! : "Workspace",
                isCurrent: draft.screen.id == state.activeScreenID,
                apps: apps
            )
        }
        return FocusHUDPresentationSnapshot(
            sections: sections,
            layout: FocusHUDOverviewLayoutEngine.compute(appCounts: sections.map { $0.apps.count }, constraints: constraints),
            inventoryRevision: inventoryRevision,
            keyAssignmentRevision: keyAssignmentRevision,
            presentationRevision: presentationRevision
        )
    }

    private func appDrafts(in screen: FocusScreen, state: FocusScreenState) -> [AppDraft] {
        var order: [String] = []
        var representatives: [String: ManagedWindow] = [:]
        for windowID in screen.windowIDs {
            guard let window = state.windows[windowID] else { continue }
            if representatives[window.appID] == nil {
                order.append(window.appID)
                representatives[window.appID] = window
            }
        }
        if let activeID = screen.lastActiveWindowID,
           screen.windowIDs.contains(activeID),
           let activeWindow = state.windows[activeID],
           representatives[activeWindow.appID] != nil {
            representatives[activeWindow.appID] = activeWindow
        }
        return order.sorted().compactMap { appID in
            guard let window = representatives[appID] else { return nil }
            return AppDraft(window: window, metadata: metadataProvider.metadata(for: window))
        }
    }

    private func makeOverviewInputState(for snapshot: FocusHUDPresentationSnapshot) -> FocusHUDOverviewInputState {
        guard let layout = snapshot.layout.availableLayout,
              layout.workspaceLayouts.count == snapshot.sections.count
        else { return FocusHUDOverviewInputState() }

        let rows = zip(snapshot.sections, layout.workspaceLayouts).flatMap { section, workspaceLayout in
            guard workspaceLayout.columnCount > 0 else { return [[ManagedWindowID]]() }
            return stride(from: 0, to: section.apps.count, by: workspaceLayout.columnCount).map {
                Array(section.apps[$0..<min($0 + workspaceLayout.columnCount, section.apps.count)].map(\.id))
            }
        }
        let assignments = Dictionary(uniqueKeysWithValues: snapshot.sections.flatMap(\.apps).compactMap { app in
            app.shortcut.map { ($0.chord, app.id) }
        })
        return FocusHUDOverviewInputState(
            rows: rows,
            assignments: assignments,
            focusedWindowID: snapshot.sections.flatMap(\.apps).first(where: \.isCurrent)?.id
        )
    }

    private func rebuildCompatibilityProjection(from snapshot: FocusHUDPresentationSnapshot) {
        screens = snapshot.sections.map {
            FocusHUDScreen(id: $0.id, number: $0.ordinal, name: $0.name, isActive: $0.isCurrent)
        }
        inspectedScreen = screens.first(where: \.isActive)
        let currentSection = snapshot.sections.first(where: \.isCurrent)
        windowEntries = currentSection?.apps.compactMap { app in
            guard let label = app.shortcut?.label else { return nil }
            return FocusHUDWindowEntry(id: app.id, letter: label, appName: app.appName, appIcon: app.appIcon, windowTitle: app.windowTitle, isCurrent: app.isCurrent)
        } ?? []
        maximumAppCount = snapshot.sections.map { $0.apps.count }.max() ?? 0
        page = 0
        pageCount = 1
    }

    private func clearCompatibilityProjection() {
        screens = []
        inspectedScreen = nil
        windowEntries = []
        maximumAppCount = 0
        page = 0
        pageCount = 1
    }

    /// Maintains the hidden legacy projection until the semantic overview
    /// projection migrates in Task 6. This is never presentation truth.
    private func rebuildHiddenCompatibilityProjection(from state: FocusScreenState) {
        screens = state.screens.map {
            FocusHUDScreen(id: $0.id, number: $0.number, name: $0.name, isActive: $0.id == state.activeScreenID)
        }
        inspectedScreen = screens.first(where: \.isActive)
        windowEntries = []
        maximumAppCount = state.screens.map { appDrafts(in: $0, state: state).count }.max() ?? 0
        page = 0
        pageCount = 1
    }

}

private struct AppDraft {
    let window: ManagedWindow
    let metadata: FocusHUDWindowMetadata
}

private struct SectionDraft {
    let screen: FocusScreen
    let apps: [AppDraft]
}
