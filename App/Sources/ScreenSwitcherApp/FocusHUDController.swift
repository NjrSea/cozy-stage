import AppKit
import Carbon.HIToolbox
import ScreenDomainCore
import SwiftUI

/// The compact, non-full-screen focus HUD panel.
///
/// `styleMask` is `[.nonactivatingPanel, .fullSizeContentView]`,
/// `canBecomeKey` is `true` so it can receive keyboard input, the level is
/// strictly above `.floating`, and the collection behavior excludes native
/// full screen.
final class FocusHUDPanel: NSPanel {
    static let hudWindowLevel = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 1
    )

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let keyAndOrderFrontAction: (@MainActor (FocusHUDPanel) -> Void)?
    private let eventDispatchAction: (@MainActor (NSEvent) -> Void)?
    private var isPresentationEnabled = false

    init(
        keyAndOrderFrontAction: (@MainActor (FocusHUDPanel) -> Void)? = nil,
        eventDispatchAction: (@MainActor (NSEvent) -> Void)? = nil
    ) {
        self.keyAndOrderFrontAction = keyAndOrderFrontAction
        self.eventDispatchAction = eventDispatchAction
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: FocusHUDDesign.minWidth,
            height: FocusHUDDesign.minHeight
        )
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = Self.hudWindowLevel
        // Compact HUD: follows the user to the active Space but never
        // participates in native full screen, so it never creates a
        // full-screen Space or auxiliary surface.
        collectionBehavior = [.canJoinAllSpaces]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        titleVisibility = .hidden
        title = ""
        isReleasedWhenClosed = false
        setAccessibilityIdentifier("screen-switcher.focus-hud.window")
        setAccessibilityLabel("Cozy Stage Focus HUD")
    }

    func reassertKeyAndOrderFront() {
        if let keyAndOrderFrontAction {
            keyAndOrderFrontAction(self)
        } else {
            makeKeyAndOrderFront(nil)
        }
    }

    func setPresentationEnabled(_ enabled: Bool) {
        isPresentationEnabled = enabled
    }

    override func sendEvent(_ event: NSEvent) {
        let isMouseDown = event.type == .leftMouseDown
            || event.type == .rightMouseDown
            || event.type == .otherMouseDown
        if isPresentationEnabled && isMouseDown {
            reassertKeyAndOrderFront()
        }
        if let eventDispatchAction {
            eventDispatchAction(event)
        } else {
            super.sendEvent(event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape is handled by the controller's key monitor; nothing to do here.
    }
}

/// Abstraction over local keyboard and same-process mouse monitor installation
/// so tests can assert exactly one monitor is installed and removed.
@MainActor
protocol FocusHUDLocalMonitorRegistering: AnyObject {
    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    func removeMonitor(_ monitor: Any)
}

/// Abstraction over global (outside-click) event monitor installation so tests
/// can assert exactly one monitor is installed and removed. Global monitors
/// observe events but cannot consume them, so the handler returns Void.
@MainActor
protocol FocusHUDGlobalEventRegistering: AnyObject {
    func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
private final class SystemLocalMonitorRegistrar: FocusHUDLocalMonitorRegistering {
    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

@MainActor
private final class SystemGlobalEventRegistrar: FocusHUDGlobalEventRegistering {
    func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

struct FocusHUDWindowServerIdentity: Equatable {
    let windowNumber: Int
    let ownerProcessIdentifier: Int32
    let layer: Int
}

struct FocusHUDWindowServerRecord: Equatable {
    let windowNumber: Int
    let ownerProcessIdentifier: Int32
    let layer: Int
    let bounds: CGRect
    let isOnscreen: Bool
    let alpha: Double

    var identity: FocusHUDWindowServerIdentity {
        FocusHUDWindowServerIdentity(
            windowNumber: windowNumber,
            ownerProcessIdentifier: ownerProcessIdentifier,
            layer: layer
        )
    }
}

enum FocusHUDGlobalClickRoute: Equatable {
    case hudExact
    case hudTopmost
    case outsideExact
    case outsideTopmost
    case unresolved
}

enum FocusHUDGlobalClickGuard {
    static func route(
        eventWindowNumber: Int,
        eventHandlingWindowNumber: Int?,
        windowServerRecords: [FocusHUDWindowServerRecord]?,
        expectedHUD: FocusHUDWindowServerIdentity
    ) -> FocusHUDGlobalClickRoute {
        guard expectedHUD.windowNumber > 0,
              expectedHUD.windowNumber <= Int(UInt32.max)
        else { return .unresolved }
        guard let handlingWindowNumber = eventHandlingWindowNumber,
              handlingWindowNumber > 0,
              handlingWindowNumber <= Int(UInt32.max),
              let records = windowServerRecords,
              records.allSatisfy(isValid)
        else { return .unresolved }
        let handlingRecords = records.filter { $0.windowNumber == handlingWindowNumber }
        guard handlingRecords.count == 1, let handlingRecord = handlingRecords.first else {
            return .unresolved
        }
        if handlingWindowNumber == expectedHUD.windowNumber {
            guard handlingRecord.identity == expectedHUD else { return .unresolved }
            return eventWindowNumber == handlingWindowNumber ? .hudExact : .hudTopmost
        }
        return eventWindowNumber == handlingWindowNumber ? .outsideExact : .outsideTopmost
    }

    static func keepsHUD(
        eventWindowNumber: Int,
        eventHandlingWindowNumber: Int?,
        windowServerRecords: [FocusHUDWindowServerRecord]?,
        expectedHUD: FocusHUDWindowServerIdentity
    ) -> Bool {
        switch route(
            eventWindowNumber: eventWindowNumber,
            eventHandlingWindowNumber: eventHandlingWindowNumber,
            windowServerRecords: windowServerRecords,
            expectedHUD: expectedHUD
        ) {
        case .hudExact, .hudTopmost: true
        case .outsideExact, .outsideTopmost, .unresolved: false
        }
    }

    static func systemWindowServerRecords() -> [FocusHUDWindowServerRecord]? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return records(from: infos)
    }

    static func records(from infos: [[String: Any]]) -> [FocusHUDWindowServerRecord]? {
        let records = infos.map(record)
        guard records.allSatisfy({ $0 != nil }) else { return nil }
        return records.compactMap { $0 }
    }

    private static func record(from info: [String: Any]) -> FocusHUDWindowServerRecord? {
        guard let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue,
              let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
        else { return nil }
        let record = FocusHUDWindowServerRecord(
            windowNumber: windowNumber,
            ownerProcessIdentifier: ownerPID,
            layer: layer,
            bounds: bounds,
            isOnscreen: isOnscreen,
            alpha: alpha
        )
        return isValid(record) ? record : nil
    }

    private static func isValid(_ record: FocusHUDWindowServerRecord) -> Bool {
        record.windowNumber > 0
            && record.windowNumber <= Int(UInt32.max)
            && record.ownerProcessIdentifier > 0
            && record.bounds.origin.x.isFinite
            && record.bounds.origin.y.isFinite
            && record.bounds.width.isFinite
            && record.bounds.height.isFinite
            && record.bounds.width > 0
            && record.bounds.height > 0
            && record.alpha.isFinite
            && record.alpha >= 0
    }
}

/// Sendable holder for the local + global monitor tokens returned by AppKit.
/// The token values are opaque `Any?` (e.g. `NSEvent` monitor objects) that are
/// only ever handed back to `removeMonitor(_:)`; they hold no main-actor state
/// themselves, so carrying them across the `deinit` → `@MainActor` hop is safe.
private struct FocusHUDMonitorTokens: @unchecked Sendable {
    let local: Any?
    let global: Any?
    let activation: [NSObjectProtocol]
}

enum FocusHUDControllerPresentationError: Error, Equatable {
    case keyboardLayoutUnavailable
    case snapshot(FocusHUDPresentationError)
    case shortcutAssignment(FocusHUDShortcutAssignmentError)
    case unexpected
}

/// `@unchecked Sendable` box around a `FocusHUDLocalMonitorRegistering` so a
/// nonisolated `deinit` can capture it into a detached `Task`. Safe because the
/// registrar is a `@MainActor`-isolated type and is only ever accessed after the
/// `Task` hops to `@MainActor`; the box itself performs no concurrent access.
private struct SendableMonitorRegistrar: @unchecked Sendable {
    let box: any FocusHUDLocalMonitorRegistering
    init(box: any FocusHUDLocalMonitorRegistering) {
        self.box = box
    }
}

/// `@unchecked Sendable` box around a `FocusHUDGlobalEventRegistering`; see
/// `SendableMonitorRegistrar` for the isolation-safety rationale.
private struct SendableGlobalEventRegistrar: @unchecked Sendable {
    let box: any FocusHUDGlobalEventRegistering
    init(box: any FocusHUDGlobalEventRegistering) {
        self.box = box
    }
}

/// `ProductWorkspaceEvidenceCaptureToken` is MainActor-isolated; this box only
/// carries it across `deinit` so cancellation can hop back to MainActor.
private struct SendableEvidenceCaptureToken: @unchecked Sendable {
    let box: any ProductWorkspaceEvidenceCaptureToken
}

private struct SendableEvidenceCaptureOwner: @unchecked Sendable {
    let box: ProductWorkspaceEvidenceCapture
}

/// The HUD remains a nonactivating panel, but clicks inside its SwiftUI root
/// must still be allowed to make that exact panel key before keyboard input.
final class FocusHUDHostingView: NSHostingView<FocusHUDView> {
    override var needsPanelToBecomeKey: Bool { true }
}

/// Reasons the focus HUD may close.
public enum FocusHUDCloseReason: Equatable, Sendable {
    case escape
    case outsideClick
    case programmatic
    case applicationTermination
}

/// Owner of the `FocusHUDPanel` lifecycle. Holds the `FocusHUDViewModel`,
/// shows/hides the panel, wires exactly one local key monitor and one
/// outside-click monitor, and tears both down on close and App termination.
@MainActor
public final class FocusHUDController {
    @Published private(set) var isPresented: Bool = false

    public let viewModel: FocusHUDViewModel
    private let hudPanel: FocusHUDPanel
    private let localMonitorRegistrar: any FocusHUDLocalMonitorRegistering
    private let globalEventRegistrar: any FocusHUDGlobalEventRegistering
    private let notificationCenter: NotificationCenter
    private let shiftedDigitSymbolsProvider: @MainActor () -> [Character]?
    private let panelKeyWindowReader: @MainActor (NSPanel) -> Bool
    private let applicationActivator: @MainActor () -> Void
    private let windowServerRecordsProvider: @MainActor () -> [FocusHUDWindowServerRecord]?
    private let globalEventHandlingWindowNumberProvider: @MainActor (NSEvent) -> Int?
    private let evidenceCapture: ProductWorkspaceEvidenceCapture?
    private let visualQualificationEnvironment: [String: String]
    private var evidenceCaptureToken: (any ProductWorkspaceEvidenceCaptureToken)?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var presentationToken: UUID?
    private var activationObservers: [NSObjectProtocol] = []
    private var hostingView: FocusHUDHostingView?
    /// When true, the HUD dismisses when the command modifier is released.
    private(set) var dismissesOnModifierRelease = false
    private(set) var lastPresentationError: FocusHUDControllerPresentationError?
    private(set) var lastCloseReason: FocusSemanticHUDLastCloseReason = .none
    private(set) var lastMouseRoute: FocusSemanticHUDLastMouseRoute = .staleIgnored
    private(set) var matchedFocusAttempt = false

    /// Number of sibling scrim windows the controller has created. The compact
    /// HUD never creates a scrim, so this is always zero; exposed for contract
    /// tests and production assertions.
    public var scrimWindowCount: Int { createdSiblingScrimWindows.count }

    /// Number of real `NSWindow`s the controller has created and still owns
    /// while presented. The compact HUD owns exactly one window — the HUD panel
    /// itself — and must never create sibling scrim/dimming windows. Exposed so
    /// the no-sibling-scrim contract can be tested against actual windows rather
    /// than a hardcoded constant.
    var presentedWindowCount: Int {
        var count = 0
        if isPresented { count += 1 } // the HUD panel itself
        count += createdSiblingScrimWindows.count
        return count
    }

    /// Real sibling scrim/dimming windows the controller has created. The
    /// compact HUD never allocates any; this collection is kept empty so the
    /// contract is enforced by allocation tracking rather than a literal.
    private var createdSiblingScrimWindows: [NSWindow] = []

    /// The currently presented panel (when visible), for contract tests.
    var panel: NSPanel? { isPresented ? hudPanel : nil }
    var isPanelVisible: Bool { hudPanel.isVisible }
    var isPanelKeyWindow: Bool { isPresented && panelKeyWindowReader(hudPanel) }

    init(
        viewModel: FocusHUDViewModel,
        localMonitorRegistrar: (any FocusHUDLocalMonitorRegistering)? = nil,
        globalEventRegistrar: (any FocusHUDGlobalEventRegistering)? = nil,
        notificationCenter: NotificationCenter = .default,
        shiftedDigitSymbolsProvider: (@MainActor () -> [Character]?)? = nil,
        panelKeyWindowReader: @escaping @MainActor (NSPanel) -> Bool = { $0.isKeyWindow },
        evidenceCapture: ProductWorkspaceEvidenceCapture? = nil,
        hudPanel: FocusHUDPanel? = nil,
        windowServerRecordsProvider: @escaping @MainActor () -> [FocusHUDWindowServerRecord]? = {
            FocusHUDGlobalClickGuard.systemWindowServerRecords()
        },
        globalEventHandlingWindowNumberProvider: @escaping @MainActor (NSEvent) -> Int? = {
            FocusHUDController.eventHandlingWindowNumber(from: $0)
        },
        visualQualificationEnvironment: [String: String] = [:],
        applicationActivator: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.viewModel = viewModel
        self.localMonitorRegistrar = localMonitorRegistrar ?? SystemLocalMonitorRegistrar()
        self.globalEventRegistrar = globalEventRegistrar ?? SystemGlobalEventRegistrar()
        self.notificationCenter = notificationCenter
        self.shiftedDigitSymbolsProvider = shiftedDigitSymbolsProvider
            ?? PhysicalDigitKeyboardLayoutTranslator.activeShiftedDigitSymbols
        self.panelKeyWindowReader = panelKeyWindowReader
        self.applicationActivator = applicationActivator
        self.evidenceCapture = evidenceCapture
        self.visualQualificationEnvironment = visualQualificationEnvironment
        self.hudPanel = hudPanel ?? FocusHUDPanel()
        self.windowServerRecordsProvider = windowServerRecordsProvider
        self.globalEventHandlingWindowNumberProvider = globalEventHandlingWindowNumberProvider
    }

    deinit {
        // Swift 6 readiness: `deinit` is nonisolated, so it may not capture
        // non-Sendable, MainActor-isolated properties (`localKeyMonitor`,
        // `globalClickMonitor`, `localMonitorRegistrar`, `globalEventRegistrar`)
        // directly into the detached `Task` below — that would fail to build
        // under Swift 6 strict concurrency even though it compiles in Swift 5
        // mode today.
        //
        // The monitor tokens are plain `Any?` values returned by AppKit and are
        // safe to pass across actors: they're only ever handed back to
        // `removeMonitor(_:)` on the main thread. The registrars are
        // `@MainActor`-isolated classes, so they are wrapped behind a
        // documented `@unchecked Sendable` box. The detached `Task` hops to
        // `@MainActor` before touching either registrar, so the only access
        // remains on the main actor — preserving the existing isolation.
        // Runtime behavior is unchanged: each monitor is removed exactly once.
        let tokens = FocusHUDMonitorTokens(
            local: localKeyMonitor,
            global: globalClickMonitor,
            activation: activationObservers
        )
        let localRegistrarBox = SendableMonitorRegistrar(box: localMonitorRegistrar)
        let globalRegistrarBox = SendableGlobalEventRegistrar(box: globalEventRegistrar)
        let notificationCenter = notificationCenter
        let captureToken = evidenceCaptureToken.map(SendableEvidenceCaptureToken.init)
        let captureOwner = evidenceCapture.map(SendableEvidenceCaptureOwner.init)
        Task { @MainActor in
            withExtendedLifetime(captureOwner) {
                captureToken?.box.cancel()
            }
            if let local = tokens.local {
                localRegistrarBox.box.removeMonitor(local)
            }
            if let global = tokens.global {
                globalRegistrarBox.box.removeMonitor(global)
            }
            for activation in tokens.activation {
                notificationCenter.removeObserver(activation)
            }
        }
    }

    // MARK: - Presentation

    func rebuildSnapshot(inventoryRevision: UInt64, safeBounds: CanvasRect) {
        guard viewModel.windowDiscoveryStatus == .ready,
              viewModel.snapshot == nil
        else { return }
        guard let symbols = shiftedDigitSymbolsProvider() else { return }
        let constraints = Self.layoutConstraints(
            in: safeBounds,
            environment: visualQualificationEnvironment
        )
        viewModel.rebuildSnapshotIfPresented(
            constraints: constraints,
            shiftedDigitSymbols: symbols,
            inventoryRevision: inventoryRevision
        )
        // Re-center the panel now that it has real content
        let frame = Self.frame(for: viewModel.snapshot, in: safeBounds)
        hudPanel.setFrame(frame, display: true)
    }

    func present(
        inventoryRevision: UInt64,
        safeBounds: CanvasRect
    ) -> Result<Void, FocusHUDControllerPresentationError> {
        NSApp.windows.filter(SettingsWindowIdentity.matches).forEach { $0.close() }
        guard !isPresented else { return .success(()) }
        let shiftedDigitSymbols: [Character]
        if viewModel.windowDiscoveryStatus == .ready {
            guard let symbols = shiftedDigitSymbolsProvider() else {
                lastPresentationError = .keyboardLayoutUnavailable
                return .failure(.keyboardLayoutUnavailable)
            }
            shiftedDigitSymbols = symbols
        } else {
            shiftedDigitSymbols = []
        }
        do {
            try viewModel.present(
                constraints: Self.layoutConstraints(
                    in: safeBounds,
                    environment: visualQualificationEnvironment
                ),
                shiftedDigitSymbols: shiftedDigitSymbols,
                inventoryRevision: inventoryRevision
            )
        } catch let error as FocusHUDPresentationError {
            lastPresentationError = .snapshot(error)
            return .failure(.snapshot(error))
        } catch let error as FocusHUDShortcutAssignmentError {
            lastPresentationError = .shortcutAssignment(error)
            return .failure(.shortcutAssignment(error))
        } catch {
            lastPresentationError = .unexpected
            return .failure(.unexpected)
        }
        lastPresentationError = nil
        lastCloseReason = .none
        lastMouseRoute = .staleIgnored
        matchedFocusAttempt = false
        let frame = Self.frame(for: viewModel.snapshot, in: safeBounds)
        installRootView()
        hudPanel.setFrame(frame, display: true)
        hudPanel.level = FocusHUDPanel.hudWindowLevel
        hudPanel.setPresentationEnabled(true)
        let presentationToken = UUID()
        self.presentationToken = presentationToken
        isPresented = true
        installMonitors(for: presentationToken)
        installActivationObservers(for: presentationToken)
        applicationActivator()
        hudPanel.reassertKeyAndOrderFront()
        hudPanel.orderFrontRegardless()
        evidenceCaptureToken = evidenceCapture?.startCapture(
            for: hudPanel,
            waitsForHUDTrigger: true
        )
        return .success(())
    }

    func close(reason: FocusHUDCloseReason) {
        guard isPresented else { return }
        presentationToken = nil
        recordCloseReason(reason)
        hudPanel.setPresentationEnabled(false)
        evidenceCaptureToken?.cancel()
        evidenceCaptureToken = nil
        removePresentationObservers()
        hudPanel.orderOut(nil)
        isPresented = false
        viewModel.dismiss()
    }

    private func recordCloseReason(_ reason: FocusHUDCloseReason) {
        guard lastCloseReason == .none else { return }
        switch reason {
        case .escape: lastCloseReason = .escape
        case .outsideClick: lastCloseReason = .outsideClick
        case .programmatic: lastCloseReason = .programmatic
        case .applicationTermination: lastCloseReason = .applicationTermination
        }
    }

    /// Hook for App termination. Ensures monitors are removed before the
    /// application tears down observers.
    func handleApplicationTermination() {
        close(reason: .applicationTermination)
    }

    static func layoutConstraints(
        in safeBounds: CanvasRect,
        environment: [String: String] = [:]
    ) -> FocusHUDOverviewLayoutConstraints {
        let minimumMetricQualification = environment["CS_DIAG_DOGFOOD"] == "1"
            && environment["CS_DIAG_RUNTIME"] == "1"
            && environment["CS_DIAG_GUI_SMOKE"] == "1"
            && environment["CS_DIAG_CAPTURE_MODE"] == "full"
            && environment["CS_DIAG_CAPTURE_DIRECTORY"]?.isEmpty == false
            && environment["SCREEN_SWITCHER_HUD_VISUAL_STATE"] == "minimum-metric"
        return FocusHUDOverviewLayoutConstraints(
            safeWidth: safeBounds.width,
            safeHeight: safeBounds.height,
            outerMargin: 32,
            relaxedCellSize: minimumMetricQualification ? 40 : 100,
            minimumCellSize: 40,
            horizontalGap: Double(FocusHUDDesign.cellGap),
            verticalGap: Double(FocusHUDDesign.cellGap),
            groupHeaderHeight: Double(
                FocusHUDDesign.headerHeight + FocusHUDDesign.workspaceContentTopInset
            ),
            emptyWorkspaceHeight: Double(FocusHUDDesign.emptyWorkspaceHeight),
            groupGap: Double(FocusHUDDesign.sectionGap),
            minimumPanelWidth: Double(FocusHUDDesign.minWidth),
            contentInset: Double(FocusHUDDesign.contentInset)
        )
    }

    static func frame(
        for snapshot: FocusHUDPresentationSnapshot?,
        in safeBounds: CanvasRect
    ) -> CGRect {
        let proposed = snapshot?.layout.availableLayout.map {
            CGSize(width: $0.panelWidth, height: $0.panelHeight)
        } ?? CGSize(width: FocusHUDDesign.minWidth, height: FocusHUDDesign.minHeight)
        let width = min(proposed.width, max(CGFloat(safeBounds.width) - 64, 1))
        let height = min(proposed.height, max(CGFloat(safeBounds.height) - 64, 1))
        return CGRect(
            x: safeBounds.x + (safeBounds.width - width) / 2,
            y: safeBounds.y + (safeBounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Internals

    private func installRootView() {
        let view = FocusHUDView(viewModel: viewModel)
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = FocusHUDHostingView(rootView: view)
            hudPanel.contentView = hostingView
            self.hostingView = hostingView
        }
    }

    private func installMonitors(for presentationToken: UUID) {
        guard localKeyMonitor == nil, globalClickMonitor == nil else { return }

        localKeyMonitor = localMonitorRegistrar.addLocalMonitor(
            matching: [
                .keyDown, .keyUp, .flagsChanged,
                .leftMouseDown, .rightMouseDown, .otherMouseDown
            ]
        ) { [weak self] event in
            guard let self,
                  self.isPresented,
                  self.presentationToken == presentationToken
            else { return event }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return self.handleLocalMouseEvent(event)
            case .flagsChanged:
                return self.handleFlagsChanged(event)
            default:
                return self.handleKeyEvent(event)
            }
        }

        globalClickMonitor = globalEventRegistrar.addGlobalMonitor(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self,
                  self.isPresented,
                  self.presentationToken == presentationToken
            else { return }
            self.handleGlobalMouseEvent(event)
        }
    }

    private func removePresentationObservers() {
        if let localKeyMonitor {
            localMonitorRegistrar.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalClickMonitor {
            globalEventRegistrar.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        for activationObserver in activationObservers {
            notificationCenter.removeObserver(activationObserver)
        }
        activationObservers = []
    }

    private func installActivationObservers(for presentationToken: UUID) {
        guard activationObservers.isEmpty else { return }
        activationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reassertHUD(for: presentationToken)
            }
        })
        activationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isPresented,
                      self.presentationToken == presentationToken
                else { return }
                self.applicationActivator()
                self.reassertHUD(for: presentationToken)
            }
        })
    }

    private func reassertHUD(for presentationToken: UUID) {
        guard isPresented, self.presentationToken == presentationToken else { return }
        hudPanel.level = FocusHUDPanel.hudWindowLevel
        hudPanel.reassertKeyAndOrderFront()
        hudPanel.orderFrontRegardless()
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isPresented else { return event }
        guard let key = FocusHUDPhysicalKeyTranslator.translate(event) else {
            return event
        }
        if key == .escape {
            recordCloseReason(.escape)
        }
        // Modifier key-up (release) events arrive as key-up; they must never
        // commit or dismiss the HUD. The translator returns nil for pure
        // modifier presses, so we only reach here for actionable keys.
        let intent = viewModel.handle(key: key)
        if intent == .cancel {
            close(reason: .escape)
        }
        switch intent {
        case .none:
            return event
        default:
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard isPresented, dismissesOnModifierRelease else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty {
            let targetID = viewModel.hoveredWindowID ?? viewModel.focusedWindowID
            if let targetID {
                _ = viewModel.activateApp(windowID: targetID)
            } else {
                // Dispatch .cancel through the intent handler so
                // FocusScreenController is notified and clears isHUDPresented.
                _ = viewModel.handle(key: .escape)
            }
            close(reason: .escape)
        }
        return event
    }

    func setDismissesOnModifierRelease(_ value: Bool) {
        dismissesOnModifierRelease = value
    }

    private func handleLocalMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard isPresented else {
            lastMouseRoute = .staleIgnored
            return event
        }
        if let eventWindow = event.window {
            if eventWindow !== hudPanel {
                lastMouseRoute = .localOutside
                handleOutsideClick()
            } else {
                lastMouseRoute = .localHUD
            }
        } else if hudPanel.frame.contains(event.locationInWindow) {
            lastMouseRoute = .localHUD
            hudPanel.reassertKeyAndOrderFront()
        } else {
            lastMouseRoute = .localOutside
            handleOutsideClick()
        }
        return event
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        guard isPresented else {
            lastMouseRoute = .staleIgnored
            return
        }
        if Self.isMarkedFocusAttempt(event) {
            matchedFocusAttempt = true
        }
        let handlingWindowNumber = globalEventHandlingWindowNumberProvider(event)
        let route = FocusHUDGlobalClickGuard.route(
            eventWindowNumber: event.windowNumber,
            eventHandlingWindowNumber: handlingWindowNumber,
            windowServerRecords: handlingWindowNumber != nil
                ? windowServerRecordsProvider()
                : nil,
            expectedHUD: FocusHUDWindowServerIdentity(
                windowNumber: hudPanel.windowNumber,
                ownerProcessIdentifier: NSRunningApplication.current.processIdentifier,
                layer: FocusHUDPanel.hudWindowLevel.rawValue
            )
        )
        switch route {
        case .hudExact:
            lastMouseRoute = .globalHUDExact
            hudPanel.reassertKeyAndOrderFront()
        case .hudTopmost:
            lastMouseRoute = .globalHUDTopmost
            hudPanel.reassertKeyAndOrderFront()
        case .outsideExact:
            lastMouseRoute = .globalOutsideExact
            handleOutsideClick()
        case .outsideTopmost:
            lastMouseRoute = .globalOutsideTopmost
            handleOutsideClick()
        case .unresolved:
            lastMouseRoute = .globalUnresolved
            handleOutsideClick()
        }
    }

    static func eventHandlingWindowNumber(from event: NSEvent) -> Int? {
        guard let cgEvent = event.cgEvent else { return nil }
        let value = cgEvent.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        guard value > 0, value <= Int64(UInt32.max) else { return nil }
        return Int(value)
    }

    private static func isMarkedFocusAttempt(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            == FocusSemanticHUDFocusAttemptMarker.eventSourceUserData
    }

    /// Test-only seam that routes a synthetic `NSEvent` through the exact
    /// `handleKeyEvent` path the installed local key monitor uses. Exposed so
    /// release/non-keyDown events (e.g. `.flagsChanged`, `.keyUp`) can be driven
    /// deterministically without a real AppKit key dispatch.
    func handleTestKeyEvent(_ event: NSEvent) -> NSEvent? {
        handleKeyEvent(event)
    }

    private func handleOutsideClick() {
        guard isPresented else { return }
        recordCloseReason(.outsideClick)
        _ = viewModel.cancelPresentation()
        if isPresented {
            close(reason: .outsideClick)
        }
    }
}

/// Translates an `NSEvent` into a physical overview key. Returns nil
/// for modifier-only presses (so releasing a modifier does nothing) and for
/// keys the HUD does not handle.
enum FocusHUDPhysicalKeyTranslator {
    static func translate(_ event: NSEvent) -> FocusHUDOverviewKey? {
        // Only act on key-down; key-up is a modifier release and must never
        // commit or dismiss.
        guard event.type == .keyDown else { return nil }

        switch event.keyCode {
        case 53: // escape
            return .escape
        case 36, 76: // return / enter
            return .returnKey
        case 48: // tab
            return .tab
        case 123: // left arrow
            return .left
        case 124: // right arrow
            return .right
        case 125: // down arrow
            return .down
        case 126: // up arrow
            return .up
        default:
            break
        }

        let shifted = event.modifierFlags.contains(.shift)
        if let digit = physicalDigit(for: event.keyCode) {
            return .shortcut(.digit(digit), shifted: shifted)
        }

        if let letter = physicalLetter(for: event.keyCode) {
            return .shortcut(.letter(letter), shifted: shifted)
        }

        return nil
    }

    private static func physicalDigit(for keyCode: UInt16) -> Int? {
        [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][keyCode]
    }

    private static func physicalLetter(for keyCode: UInt16) -> Character? {
        [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
            6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q",
            13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            31: "o", 32: "u", 34: "i", 35: "p", 37: "l",
            38: "j", 40: "k", 45: "n", 46: "m",
        ][keyCode]
    }
}

enum PhysicalDigitKeyboardLayoutTranslator {
    static let physicalDigitKeyCodes: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
    static let shiftModifierState = UInt32(shiftKey >> 8)

    static func shiftedDigitSymbols(
        using translate: (UInt16, UInt32) -> Character?
    ) -> [Character]? {
        var symbols: [Character] = []
        symbols.reserveCapacity(physicalDigitKeyCodes.count)
        for keyCode in physicalDigitKeyCodes {
            guard let symbol = translate(keyCode, shiftModifierState) else { return nil }
            symbols.append(symbol)
        }
        return symbols
    }

    @MainActor
    static func activeShiftedDigitSymbols() -> [Character]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(
                  source,
                  kTISPropertyUnicodeKeyLayoutData
              )
        else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        let keyLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<CoreServices.UCKeyboardLayout>.self
        )
        return withExtendedLifetime(source) {
            withExtendedLifetime(layoutData) {
                shiftedDigitSymbols { keyCode, modifierState in
                    translatedCharacter(
                        keyCode: keyCode,
                        modifierState: modifierState,
                        keyLayout: keyLayout
                    )
                }
            }
        }
    }

    private static func translatedCharacter(
        keyCode: UInt16,
        modifierState: UInt32,
        keyLayout: UnsafePointer<CoreServices.UCKeyboardLayout>
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = CoreServices.UCKeyTranslate(
            keyLayout,
            keyCode,
            UInt16(CoreServices.kUCKeyActionDisplay),
            modifierState,
            UInt32(LMGetKbdType()),
            OptionBits(CoreServices.kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr else { return nil }
        let value = String(utf16CodeUnits: characters, count: length)
        return value.count == 1 ? value.first : nil
    }
}
