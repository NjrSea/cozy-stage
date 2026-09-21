import Foundation

// MARK: - Phase 1C: Geometry normalization coordinator

/// In a Tabs Layout, the Pane owns final geometry:
/// - An App-initiated resize does NOT alter the Pane ratio.
/// - Screen Switcher observes the completed change and restores the canonical frame.
/// - If an App repeatedly resists, it is marked incompatible and offered As Is.
public enum GeometryNormalizationCoordinator {

    /// The number of times an App may resist frame normalization before being
    /// declared incompatible ("If an App repeatedly resists...").
    public static let defaultResistanceThreshold = 3

    /// Normalizes an observed App-initiated resize by restoring the canonical
    /// Pane frame. If the App has resisted `resistanceCount` times, declares it
    /// incompatible.
    public static func normalize(
        observedFrame: CanvasRect,
        paneFrame: CanvasRect,
        resistanceCount: Int,
        threshold: Int = defaultResistanceThreshold
    ) -> NormalizationResult {
        // If the observed frame matches the pane frame, no normalization needed.
        if framesMatch(observedFrame, paneFrame) {
            return NormalizationResult(restoredFrame: nil, declaredIncompatible: false)
        }

        // If the app has resisted too many times, declare incompatible.
        if resistanceCount >= threshold {
            return NormalizationResult(restoredFrame: nil, declaredIncompatible: true)
        }

        // Restore the canonical pane frame.
        return NormalizationResult(restoredFrame: paneFrame, declaredIncompatible: false)
    }

    /// Normalizes a minimized Tab: restores it to its Pane frame (
    /// "A Tabs window that becomes minimized is restored to its Pane; there is
    /// no minimized Tab UI").
    public static func normalizeMinimized(
        observedMinimized: Bool,
        paneFrame: CanvasRect
    ) -> CanvasRect? {
        guard observedMinimized else { return nil }
        // Return the target frame to restore the minimized window to.
        return paneFrame
    }

    /// Determines whether a window is a "special window" that should float and
    /// NOT become a Tab (file panels, save panels, color pickers,
    /// transient utility panels, browser recovery prompts, child/non-resizable
    /// windows float with their owning top-level window).
    ///
    /// This is a heuristic check — the runtime layer provides the concrete signals.
    public static func isSpecialWindow(
        isResizable: Bool,
        isPanel: Bool,
        isTransient: Bool,
        level: SpecialWindowLevel
    ) -> Bool {
        if isPanel || isTransient { return true }
        if !isResizable { return true }
        switch level {
        case .normal:
            return false
        case .floating, .modalPanel, .mainMenu, .statusBar, .popUpMenu, .screenSaver:
            return true
        }
    }

    // MARK: - Private helpers

    private static func framesMatch(_ a: CanvasRect, _ b: CanvasRect, tolerance: Double = 1.0) -> Bool {
        abs(a.x - b.x) <= tolerance
            && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}

/// Result of a normalization attempt.
public struct NormalizationResult: Equatable, Sendable {
    /// The frame to restore, or `nil` if no restoration is needed (frame already
    /// matches) or the App was declared incompatible.
    public let restoredFrame: CanvasRect?
    /// `true` if the App resisted normalization too many times and should be
    /// declared incompatible (offered As Is).
    public let declaredIncompatible: Bool

    public init(restoredFrame: CanvasRect?, declaredIncompatible: Bool) {
        self.restoredFrame = restoredFrame
        self.declaredIncompatible = declaredIncompatible
    }
}

/// Window level categories for special-window detection.
/// Maps to NSWindow.Level values conceptually.
public enum SpecialWindowLevel: String, Codable, Equatable, Sendable {
    case normal
    case floating
    case modalPanel
    case mainMenu
    case statusBar
    case popUpMenu
    case screenSaver
}
