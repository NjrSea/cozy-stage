import AppKit
import KeyboardShortcuts
import SwiftUI
#if canImport(ServiceManagement)
import ServiceManagement
#endif

@MainActor
public protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

public enum LaunchAtLoginError: String, Error, Equatable, Sendable {
    case registrationFailed = "launch_at_login_registration_failed"
    case unregistrationFailed = "launch_at_login_unregistration_failed"
}

@MainActor
public final class SettingsModel: ObservableObject {
    private let permissionService: PermissionService
    private let launchAtLogin: LaunchAtLoginManaging
    public let shortcutStore: ShortcutConfigurationStore
    public let version: String

    @Published public private(set) var launchAtLoginEnabled: Bool
    @Published public private(set) var accessibilityStatus: AccessibilityPermissionStatus
    @Published public private(set) var shortcut: KeyboardShortcuts.Shortcut?
    @Published public private(set) var shortcuts: [WorkspaceShortcut: KeyboardShortcuts.Shortcut?]
    @Published public private(set) var shortcutValidationMessages: [WorkspaceShortcut: String]
    @Published public private(set) var commandTabTakeoverEnabled: Bool
    @Published public private(set) var commandTabTakeoverActive: Bool
    @Published public private(set) var commandTabTakeoverError: String?
    @Published public private(set) var permissionError: PermissionFailure?
    @Published public private(set) var launchAtLoginError: LaunchAtLoginError?

    public init(
        permissionService: PermissionService,
        launchAtLogin: LaunchAtLoginManaging,
        shortcutStore: ShortcutConfigurationStore,
        version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    ) {
        self.permissionService = permissionService
        self.launchAtLogin = launchAtLogin
        self.shortcutStore = shortcutStore
        self.version = version
        self.launchAtLoginEnabled = launchAtLogin.isEnabled
        self.accessibilityStatus = permissionService.accessibilityStatus()
        self.shortcut = shortcutStore.configuration.shortcut
        self.shortcuts = Dictionary(uniqueKeysWithValues: WorkspaceShortcut.allCases.map {
            ($0, shortcutStore.configuration(for: $0).shortcut)
        })
        self.shortcutValidationMessages = [:]
        self.commandTabTakeoverEnabled = shortcutStore.isCommandTabTakeoverEnabled
        self.commandTabTakeoverActive = shortcutStore.isCommandTabTakeoverActive
        self.commandTabTakeoverError = nil
        self.permissionError = nil
        self.launchAtLoginError = nil
    }

    public func refreshPermissionStatus() {
        accessibilityStatus = permissionService.accessibilityStatus()
        shortcutStore.retryCommandTabTakeover()
        commandTabTakeoverActive = shortcutStore.isCommandTabTakeoverActive
        if commandTabTakeoverEnabled, commandTabTakeoverActive {
            commandTabTakeoverError = nil
        }
    }

    public func openAccessibilitySettings() throws {
        do {
            try permissionService.openSettings(for: .accessibility)
            permissionError = nil
        } catch let error as PermissionFailure {
            permissionError = error
            throw error
        } catch {
            permissionError = .settingsOpenFailed(.accessibility)
            throw error
        }
    }

    @discardableResult
    public func requestAndOpenAccessibilitySettings() -> Bool {
        requestAndOpenSettings(for: .accessibility)
    }

    public var permissionErrorMessage: String? {
        guard let permissionError else { return nil }
        switch permissionError {
        case let .settingsOpenFailed(kind):
            switch kind {
            case .accessibility:
                return "Unable to open Accessibility settings. Open System Settings manually and enable Cozy Stage."
            }
        case .accessibilityMissing:
            return "The requested permission is still unavailable."
        }
    }

    public func clearPermissionError() {
        permissionError = nil
    }

    @discardableResult
    private func requestAndOpenSettings(for kind: PermissionKind) -> Bool {
        do {
            try permissionService.requestAndOpenSettings(for: kind)
            permissionError = nil
            refreshPermissionStatus()
            if accessibilityStatus != .granted {
                DragHelperWindow.show()
            }
            return true
        } catch let error as PermissionFailure {
            permissionError = error
            return false
        } catch {
            permissionError = .settingsOpenFailed(kind)
            return false
        }
    }

    @discardableResult
    public func captureShortcut(_ chord: ShortcutChord) -> ShortcutRegistrationResult {
        shortcutStore.capture(chord)
    }

    public func updateShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        shortcutStore.synchronize(shortcut: shortcut)
        self.shortcut = shortcut
        shortcuts[.general] = shortcut
        shortcutValidationMessages[.general] = nil
    }

    public func shortcut(for kind: WorkspaceShortcut) -> KeyboardShortcuts.Shortcut? {
        shortcuts[kind] ?? nil
    }

    public func shortcutValidationMessage(for kind: WorkspaceShortcut) -> String? {
        shortcutValidationMessages[kind]
    }

    public func updateShortcut(
        _ value: KeyboardShortcuts.Shortcut?,
        for kind: WorkspaceShortcut
    ) {
        _ = shortcutStore.acceptRecorderChange(value, for: kind)
        let effective = shortcutStore.configuration(for: kind).shortcut
        shortcuts[kind] = effective
        shortcutValidationMessages[kind] = shortcutStore.validationMessage(for: kind)
        if kind == .general { shortcut = effective }
    }

    public func useCommandTab() {
        commandTabTakeoverEnabled = true
        commandTabTakeoverActive = shortcutStore.setCommandTabTakeoverEnabled(true)
        commandTabTakeoverError = commandTabTakeoverActive
            ? nil
            : "Allow Accessibility access, then try again. macOS Command-Tab remains unchanged until takeover succeeds."
    }

    public func restoreSystemCommandTab() {
        _ = shortcutStore.setCommandTabTakeoverEnabled(false)
        commandTabTakeoverEnabled = false
        commandTabTakeoverActive = false
        commandTabTakeoverError = nil
    }

    @discardableResult
    public func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        launchAtLoginEnabled = launchAtLogin.isEnabled
        guard enabled != launchAtLoginEnabled else {
            launchAtLoginError = nil
            return true
        }
        do {
            if enabled {
                try launchAtLogin.register()
            } else {
                try launchAtLogin.unregister()
            }
        } catch {
            launchAtLoginEnabled = launchAtLogin.isEnabled
            launchAtLoginError = enabled ? .registrationFailed : .unregistrationFailed
            return false
        }
        launchAtLoginEnabled = launchAtLogin.isEnabled
        guard launchAtLoginEnabled == enabled else {
            launchAtLoginError = enabled ? .registrationFailed : .unregistrationFailed
            return false
        }
        launchAtLoginError = nil
        return true
    }

    public var launchAtLoginErrorMessage: String? {
        switch launchAtLoginError {
        case .registrationFailed:
            "Cozy Stage could not be added to Login Items. Try again."
        case .unregistrationFailed:
            "Cozy Stage could not be removed from Login Items. Try again."
        case nil:
            nil
        }
    }

    public func clearLaunchAtLoginError() {
        launchAtLoginError = nil
    }
}

@MainActor
public struct SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    public init() {}

    public var isEnabled: Bool {
        #if canImport(ServiceManagement)
        SMAppService.mainApp.status == .enabled
        #else
        false
        #endif
    }

    public func register() throws {
        #if canImport(ServiceManagement)
        try SMAppService.mainApp.register()
        #endif
    }

    public func unregister() throws {
        #if canImport(ServiceManagement)
        try SMAppService.mainApp.unregister()
        #endif
    }
}

public struct SettingsView: View {
    @ObservedObject private var model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Keyboard Shortcut") {
                LabeledContent {
                    Group {
                        if model.commandTabTakeoverEnabled {
                            Text("⌘ Tab")
                                .font(.system(.body, design: .rounded).weight(.medium))
                        } else {
                            shortcutRecorder(.openHUD)
                        }
                    }
                } label: {
                    settingsLabel(
                        "Open Switcher",
                        detail: "Show workspaces and apps from anywhere."
                    )
                }
                if let message = model.shortcutValidationMessage(for: .openHUD) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "screen-switcher.settings.shortcut-\(WorkspaceShortcut.openHUD.rawValue)-error"
                        )
                }
                LabeledContent {
                    if model.commandTabTakeoverEnabled {
                        Button("Restore macOS ⌘Tab") {
                            model.restoreSystemCommandTab()
                        }
                    } else {
                        Button("Use ⌘Tab") {
                            model.useCommandTab()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } label: {
                    settingsLabel(
                        "Quick Setup",
                        detail: "While ScreenSwitcher runs, ⌘Tab opens this HUD instead of the macOS app switcher."
                    )
                }
                .accessibilityIdentifier("screen-switcher.settings.command-tab-takeover")
                if let message = model.commandTabTakeoverError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("screen-switcher.settings.command-tab-takeover-error")
                }
            }
            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Required to focus and switch windows.",
                    isGranted: model.accessibilityStatus == .granted,
                    identifier: "screen-switcher.settings.accessibility-status"
                ) {
                    _ = model.requestAndOpenAccessibilitySettings()
                }
            }
            Section("General") {
                LabeledContent {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { _ = model.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                } label: {
                    settingsLabel(
                        "Launch at Login",
                        detail: "Start Cozy Stage automatically after you sign in."
                    )
                }
                .accessibilityIdentifier("screen-switcher.settings.launch-at-login")
                if let message = model.launchAtLoginErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("screen-switcher.settings.launch-at-login-error")
                }
            }
            Text("Version \(model.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 430)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  SettingsWindowIdentity.matches(window)
            else { return }
            model.refreshPermissionStatus()
        }
        .alert(
            "Permission Settings",
            isPresented: Binding(
                get: { model.permissionError != nil },
                set: { isPresented in
                    if !isPresented { model.clearPermissionError() }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.clearPermissionError()
            }
        } message: {
            Text(model.permissionErrorMessage ?? "Unable to open permission settings.")
        }
    }

    private func shortcutRecorder(_ shortcut: WorkspaceShortcut) -> some View {
        KeyboardShortcuts.Recorder(
            for: shortcut.name,
            onChange: { value in model.updateShortcut(value, for: shortcut) }
        )
        .fixedSize()
        .accessibilityIdentifier("screen-switcher.settings.shortcut-\(shortcut.rawValue)")
    }

    private func settingsLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        identifier: String,
        openSettings: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            if !isGranted {
                Button("Open Settings…", action: openSettings)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                    Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(isGranted ? Color.green : Color.orange)
                        .accessibilityLabel(isGranted ? "Allowed" : "Not Allowed")
                        .accessibilityIdentifier(identifier)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A floating helper window that appears next to System Settings when the user
/// needs to drag the app into the Accessibility list.
@MainActor
enum DragHelperWindow {
    private static var panel: NSPanel?

    static func show() {
        if let existing = panel {
            existing.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let dragView = AppDragSourceView(frame: NSRect(x: 0, y: 0, width: 240, height: 72))
        panel.contentView = dragView

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 120
            let y = screenFrame.midY - 200
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func dismiss() {
        panel?.close()
        panel = nil
    }

    static func dismissIfAccessibilityGranted() {
        if AXIsProcessTrusted() {
            dismiss()
        }
    }
}

private final class AppDragSourceView: NSView, NSDraggingSource {
    private let iconSize: CGFloat = 36
    private let padding: CGFloat = 16
    private let cornerRadius: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // After drag ends, check if accessibility was granted and auto-close
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            DragHelperWindow.dismissIfAccessibilityGranted()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.windowBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        path.fill()

        // Draw close button (top-right)
        let closeSize: CGFloat = 16
        let closeMargin: CGFloat = 8
        let closeRect = NSRect(
            x: bounds.width - closeSize - closeMargin,
            y: bounds.height - closeSize - closeMargin,
            width: closeSize,
            height: closeSize
        )
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        let closePath = NSBezierPath(ovalIn: closeRect)
        closePath.fill()
        // Draw X
        let xInset: CGFloat = 4.5
        let xRect = closeRect.insetBy(dx: xInset, dy: xInset)
        NSColor.white.setStroke()
        let xPath = NSBezierPath()
        xPath.lineWidth = 1.5
        xPath.lineCapStyle = .round
        xPath.move(to: NSPoint(x: xRect.minX, y: xRect.minY))
        xPath.line(to: NSPoint(x: xRect.maxX, y: xRect.maxY))
        xPath.move(to: NSPoint(x: xRect.maxX, y: xRect.minY))
        xPath.line(to: NSPoint(x: xRect.minX, y: xRect.maxY))
        xPath.stroke()

        // Draw icon
        let icon = NSApp.applicationIconImage ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        let iconRect = NSRect(x: padding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        icon.draw(in: iconRect)

        // Draw text
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let textX = padding + iconSize + 12
        "Screen Switcher".draw(at: NSPoint(x: textX, y: bounds.height / 2 + 2), withAttributes: titleAttrs)
        "Drag into list, then toggle ON".draw(at: NSPoint(x: textX, y: bounds.height / 2 - 16), withAttributes: subtitleAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        // Check if close button was clicked
        let closeSize: CGFloat = 16
        let closeMargin: CGFloat = 8
        let closeRect = NSRect(
            x: bounds.width - closeSize - closeMargin,
            y: bounds.height - closeSize - closeMargin,
            width: closeSize,
            height: closeSize
        ).insetBy(dx: -4, dy: -4) // larger hit target
        if closeRect.contains(location) {
            DragHelperWindow.dismiss()
            return
        }

        let bundleURL = Bundle.main.bundleURL
        let icon = NSApp.applicationIconImage ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!

        let draggingItem = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        let iconRect = NSRect(x: padding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        draggingItem.setDraggingFrame(iconRect, contents: icon)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
}

enum SettingsWindowIdentity {
    static let identifier = NSUserInterfaceItemIdentifier("com.indie-mono.ScreenSwitcher.settings")

    static func matches(_ window: NSWindow) -> Bool {
        window.identifier == identifier
    }
}

@MainActor
private final class SettingsWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private let onWillClose: @MainActor () -> Void

    init(onWillClose: @escaping @MainActor () -> Void) {
        self.onWillClose = onWillClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose()
    }
}

@MainActor
final class DefaultSettingsPresenter: SwitcherSettingsPresenting {
    private let model: SettingsModel
    private var window: NSWindow?
    private var windowLifecycleDelegate: SettingsWindowLifecycleDelegate?

    init(shortcutStore: ShortcutConfigurationStore) {
        model = SettingsModel(
            permissionService: PermissionService(),
            launchAtLogin: SystemLaunchAtLoginManager(),
            shortcutStore: shortcutStore
        )
    }

    convenience init() {
        self.init(
            shortcutStore: ShortcutConfigurationStore(
                onTrigger: {}
            )
        )
    }

    func openSettings() {
        model.refreshPermissionStatus()
        if window == nil {
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = ""
            settingsWindow.titleVisibility = .hidden
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.minSize = NSSize(width: 520, height: 430)
            settingsWindow.identifier = SettingsWindowIdentity.identifier
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentView = NSHostingView(rootView: SettingsView(model: model))
            let lifecycleDelegate = SettingsWindowLifecycleDelegate { [weak self] in
                self?.window = nil
                self?.windowLifecycleDelegate = nil
            }
            settingsWindow.delegate = lifecycleDelegate
            windowLifecycleDelegate = lifecycleDelegate
            settingsWindow.center()
            window = settingsWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
