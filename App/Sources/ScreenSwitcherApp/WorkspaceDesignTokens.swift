import AppKit
import Combine
import PagedNavigationCore
import SwiftUI

public enum WorkspaceAppearance: String, Equatable, Sendable {
    case dark
    case light
}

public enum WorkspaceMotionStyle: String, Equatable, Sendable {
    case standard
    case reduced
}

public enum WorkspaceCardPagingDirection: Equatable, Sendable {
    case previous
    case next
}

public struct WorkspaceCardTransitionPlan: Equatable, Sendable {
    public let insertionOffsetY: Double
    public let removalOffsetY: Double
    public let inactiveScale: Double
    public let motion: WorkspaceMotionTransition

    public init(
        insertionOffsetY: Double,
        removalOffsetY: Double,
        inactiveScale: Double,
        motion: WorkspaceMotionTransition
    ) {
        self.insertionOffsetY = insertionOffsetY
        self.removalOffsetY = removalOffsetY
        self.inactiveScale = inactiveScale
        self.motion = motion
    }
}

public struct WorkspaceCardInteractiveTransform: Equatable, Sendable {
    public static let identity = Self(offsetY: 0, scale: 1, opacity: 1)

    public let offsetY: Double
    public let scale: Double
    public let opacity: Double

    public init(offsetY: Double, scale: Double, opacity: Double) {
        self.offsetY = offsetY
        self.scale = scale
        self.opacity = opacity
    }
}

public struct WorkspaceVisualEnvironment: Equatable, Sendable {
    public let appearance: WorkspaceAppearance
    public let reduceMotion: Bool
    public let reduceTransparency: Bool
    public let increaseContrast: Bool

    public init(
        appearance: WorkspaceAppearance,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) {
        self.appearance = appearance
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }

    @MainActor
    static func system(appearance: WorkspaceAppearance) -> Self {
        Self(
            appearance: appearance,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

public struct WorkspaceResolvedTokens: Equatable, Sendable {
    public let appearance: WorkspaceAppearance
    public let usesTranslucentMaterials: Bool
    public let borderWidth: CGFloat
    public let secondaryTextOpacity: Double
    public let inactiveControlOpacity: Double
    public let motionStyle: WorkspaceMotionStyle

    init(environment: WorkspaceVisualEnvironment) {
        appearance = environment.appearance
        usesTranslucentMaterials = !environment.reduceTransparency
        borderWidth = environment.increaseContrast ? 2 : 1
        secondaryTextOpacity = environment.increaseContrast ? 0.92 : 0.68
        inactiveControlOpacity = environment.increaseContrast ? 0.72 : 0.48
        motionStyle = environment.reduceMotion ? .reduced : .standard
    }
}

public enum WorkspaceGlassBackground: Equatable, Sendable {
    case material
    case solid
}

public struct WorkspaceRenderPolicy: Equatable, Sendable {
    public let glassBackground: WorkspaceGlassBackground
    public let borderWidth: CGFloat
    public let secondaryTextOpacity: Double
    public let inactiveControlOpacity: Double
    public let appPageTransition: WorkspaceMotionTransition
    public let cardTransition: WorkspaceMotionTransition

    public init(environment: WorkspaceVisualEnvironment) {
        let tokens = WorkspaceDesignTokens.resolve(environment: environment)
        glassBackground = tokens.usesTranslucentMaterials ? .material : .solid
        borderWidth = tokens.borderWidth
        secondaryTextOpacity = tokens.secondaryTextOpacity
        inactiveControlOpacity = tokens.inactiveControlOpacity
        appPageTransition = environment.reduceMotion
            ? ReducedWorkspaceMotion().appPage
            : StandardWorkspaceMotion().appPage
        cardTransition = environment.reduceMotion
            ? ReducedWorkspaceMotion().card
            : StandardWorkspaceMotion().card
    }

    public func cardTransitionPlan(
        direction: WorkspaceCardPagingDirection
    ) -> WorkspaceCardTransitionPlan {
        guard cardTransition.hasSpatialTravel else {
            return WorkspaceCardTransitionPlan(
                insertionOffsetY: 0,
                removalOffsetY: 0,
                inactiveScale: 1,
                motion: cardTransition
            )
        }
        let insertionOffset = direction == .next ? 56.0 : -56.0
        return WorkspaceCardTransitionPlan(
            insertionOffsetY: insertionOffset,
            removalOffsetY: -insertionOffset,
            inactiveScale: 0.97,
            motion: cardTransition
        )
    }

    public func cardInteractiveTransform(
        offset: Double,
        axis: NavigationAxis?
    ) -> WorkspaceCardInteractiveTransform {
        guard axis == .vertical, offset.isFinite else { return .identity }
        let opacity = 1 - min(abs(offset) / 480, 0.16)
        guard cardTransition.hasSpatialTravel else {
            return WorkspaceCardInteractiveTransform(
                offsetY: 0,
                scale: 1,
                opacity: opacity
            )
        }
        return WorkspaceCardInteractiveTransform(
            offsetY: min(max(offset * 0.55, -72), 72),
            scale: 1 - min(abs(offset) / 1_400, 0.035),
            opacity: opacity
        )
    }

    var animation: Animation {
        animation(for: appPageTransition)
    }

    var cardAnimation: Animation {
        animation(for: cardTransition)
    }

    func cardViewTransition(direction: WorkspaceCardPagingDirection) -> AnyTransition {
        let plan = cardTransitionPlan(direction: direction)
        guard plan.motion.hasSpatialTravel else { return .opacity }
        let insertion = AnyTransition.offset(y: plan.insertionOffsetY)
            .combined(with: .scale(scale: plan.inactiveScale))
            .combined(with: .opacity)
        let removal = AnyTransition.offset(y: plan.removalOffsetY)
            .combined(with: .scale(scale: plan.inactiveScale))
            .combined(with: .opacity)
        return .asymmetric(insertion: insertion, removal: removal)
    }

    private func animation(for transition: WorkspaceMotionTransition) -> Animation {
        switch transition.kind {
        case .opacity:
            return .easeOut(duration: transition.duration)
        case .spring:
            return .spring(
                response: transition.springResponse ?? transition.duration,
                dampingFraction: transition.dampingFraction ?? 0.86
            )
        }
    }

    var transition: AnyTransition {
        appPageTransition.hasSpatialTravel
            ? .move(edge: .trailing).combined(with: .opacity)
            : .opacity
    }
}

@MainActor
public final class WorkspaceAccessibilityEnvironment: ObservableObject {
    @Published public private(set) var visualEnvironment: WorkspaceVisualEnvironment

    private let appearance: () -> WorkspaceAppearance
    private let environmentReader: (WorkspaceAppearance) -> WorkspaceVisualEnvironment
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    public init(
        initial: WorkspaceVisualEnvironment,
        notificationCenter: NotificationCenter = .default,
        appearance: @escaping () -> WorkspaceAppearance,
        environmentReader: @escaping (WorkspaceAppearance) -> WorkspaceVisualEnvironment
    ) {
        visualEnvironment = initial
        self.notificationCenter = notificationCenter
        self.appearance = appearance
        self.environmentReader = environmentReader
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public convenience init(initial: WorkspaceVisualEnvironment) {
        self.init(
            initial: initial,
            appearance: { initial.appearance },
            environmentReader: { appearance in .system(appearance: appearance) }
        )
    }

    public func refresh() {
        visualEnvironment = environmentReader(appearance())
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}

enum WorkspaceColorRole {
    case environmentTop
    case environmentBottom
    case environmentScrim
    case contentShadow
    case navigationSolid
    case actionSolid
    case contentSurface
    case contentInset
    case border
    case primaryText
    case secondaryText
    case focus
    case focusFill
    case keycap
    case keycapText
    case schematicWindow
    case schematicWindowHeader
}

public enum WorkspaceDesignTokens {
    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 24
    public static let space6: CGFloat = 32
    public static let space7: CGFloat = 40

    public static let topTabHeight: CGFloat = 44
    public static let topTabItemWidth: CGFloat = 138
    public static let topInset: CGFloat = 34
    public static let contentRadius: CGFloat = 26
    public static let glassRadius: CGFloat = 24
    public static let leftRailRadius: CGFloat = 28
    public static let leftRailWidth: CGFloat = 96
    public static let leftRailPadding: CGFloat = 9
    public static let leftRailItem: CGFloat = 76
    public static let leftRailItemRadius: CGFloat = 18
    public static let displayArtworkMaximum = CGSize(width: 68, height: 48)
    public static let switchCardHeightRatio: CGFloat = 0.76
    public static let switchContentVerticalPosition: CGFloat = 0.47
    public static let switchCardMinimumHeight: CGFloat = 700
    public static let displayCardHorizontalPadding: CGFloat = 22
    public static let previewAppLayerInset: CGFloat = 16
    public static let appIcon: CGFloat = 48
    public static let appCell: CGFloat = 64
    public static let appColumnGap: CGFloat = 12
    public static let keycapHeight: CGFloat = 21

    public static func resolve(environment: WorkspaceVisualEnvironment) -> WorkspaceResolvedTokens {
        WorkspaceResolvedTokens(environment: environment)
    }

    static func glassTintOpacity(
        role: WorkspaceGlassRole,
        environment: WorkspaceVisualEnvironment
    ) -> Double {
        switch (environment.appearance, role) {
        case (.dark, .navigation): return 0.18
        case (.dark, .action): return 0.52
        case (.light, .navigation): return 0.20
        case (.light, .action): return 0.68
        }
    }

    static func contentShadowOpacity(environment: WorkspaceVisualEnvironment) -> Double {
        environment.appearance == .dark ? 0.46 : 0.18
    }

    static func color(_ role: WorkspaceColorRole, environment: WorkspaceVisualEnvironment) -> Color {
        switch (environment.appearance, role) {
        case (.dark, .environmentTop): return Color(red: 0.035, green: 0.075, blue: 0.13)
        case (.dark, .environmentBottom): return Color(red: 0.018, green: 0.03, blue: 0.055)
        case (.light, .environmentTop): return Color(red: 0.91, green: 0.94, blue: 0.98)
        case (.light, .environmentBottom): return Color(red: 0.82, green: 0.87, blue: 0.93)
        case (.dark, .environmentScrim): return Color.black.opacity(0.46)
        case (.light, .environmentScrim): return Color(red: 0.16, green: 0.22, blue: 0.31).opacity(0.08)
        case (_, .contentShadow): return Color.black.opacity(contentShadowOpacity(environment: environment))
        case (.dark, .navigationSolid): return Color(red: 0.12, green: 0.16, blue: 0.23)
        case (.light, .navigationSolid): return Color(red: 0.94, green: 0.96, blue: 0.99)
        case (.dark, .actionSolid): return Color(red: 0.045, green: 0.075, blue: 0.12)
        case (.light, .actionSolid): return Color(red: 0.88, green: 0.91, blue: 0.95)
        case (.dark, .contentSurface): return Color(red: 0.07, green: 0.10, blue: 0.16)
        case (.light, .contentSurface): return Color(red: 0.97, green: 0.98, blue: 0.995)
        case (.dark, .contentInset): return Color(red: 0.045, green: 0.075, blue: 0.13)
        case (.light, .contentInset): return Color(red: 0.87, green: 0.91, blue: 0.96)
        case (.dark, .border): return Color.white.opacity(environment.increaseContrast ? 0.38 : 0.16)
        case (.light, .border): return Color.black.opacity(environment.increaseContrast ? 0.34 : 0.14)
        case (.dark, .primaryText): return Color(red: 0.95, green: 0.97, blue: 1)
        case (.light, .primaryText): return Color(red: 0.09, green: 0.13, blue: 0.20)
        case (.dark, .secondaryText): return Color(red: 0.65, green: 0.71, blue: 0.82)
        case (.light, .secondaryText): return Color(red: 0.32, green: 0.38, blue: 0.48)
        case (_, .focus): return Color(nsColor: .controlAccentColor)
        case (.dark, .focusFill): return Color(nsColor: .controlAccentColor).opacity(0.23)
        case (.light, .focusFill): return Color(nsColor: .controlAccentColor).opacity(0.16)
        case (.dark, .keycap): return Color.black.opacity(0.72)
        case (.light, .keycap): return Color.white.opacity(0.86)
        case (.dark, .keycapText): return Color.white
        case (.light, .keycapText): return Color.black.opacity(0.84)
        case (.dark, .schematicWindow): return Color.white.opacity(0.09)
        case (.light, .schematicWindow): return Color.black.opacity(0.08)
        case (.dark, .schematicWindowHeader): return Color.white.opacity(0.13)
        case (.light, .schematicWindowHeader): return Color.black.opacity(0.12)
        }
    }
}

enum WorkspaceGlassRole {
    case navigation
    case action
}

struct WorkspaceGlassSurface: View {
    let role: WorkspaceGlassRole
    let environment: WorkspaceVisualEnvironment
    let cornerRadius: CGFloat

    var body: some View {
        let tokens = WorkspaceDesignTokens.resolve(environment: environment)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(background(tokens: tokens))
            .overlay {
                if tokens.usesTranslucentMaterials {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(WorkspaceDesignTokens.color(
                            role == .navigation ? .navigationSolid : .actionSolid,
                            environment: environment
                        ).opacity(WorkspaceDesignTokens.glassTintOpacity(
                            role: role,
                            environment: environment
                        )))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        WorkspaceDesignTokens.color(.border, environment: environment),
                        lineWidth: tokens.borderWidth
                    )
            }
    }

    private func background(tokens: WorkspaceResolvedTokens) -> AnyShapeStyle {
        if tokens.usesTranslucentMaterials {
            return AnyShapeStyle(role == .navigation ? .thinMaterial : .regularMaterial)
        }
        return AnyShapeStyle(WorkspaceDesignTokens.color(
            role == .navigation ? .navigationSolid : .actionSolid,
            environment: environment
        ))
    }
}
