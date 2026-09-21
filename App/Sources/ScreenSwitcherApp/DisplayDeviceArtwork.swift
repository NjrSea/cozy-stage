import SwiftUI

public enum DisplayDeviceKind: String, Equatable, Sendable {
    case laptop
    case monitor
    case wideMonitor

    static func resolve(from display: DisplayDescriptor) -> Self {
        if display.hardwareKind == .builtIn {
            return .laptop
        }
        return display.frame.width / display.frame.height >= 2 ? .wideMonitor : .monitor
    }
}

public struct DisplayDeviceArtwork: View {
    public let kind: DisplayDeviceKind
    let environment: WorkspaceVisualEnvironment
    let size: CGSize

    public init(
        kind: DisplayDeviceKind,
        environment: WorkspaceVisualEnvironment,
        size: CGSize = WorkspaceDesignTokens.displayArtworkMaximum
    ) {
        self.kind = kind
        self.environment = environment
        self.size = CGSize(
            width: min(max(size.width, 0), WorkspaceDesignTokens.displayArtworkMaximum.width),
            height: min(max(size.height, 0), WorkspaceDesignTokens.displayArtworkMaximum.height)
        )
    }

    public var body: some View {
        DeviceOutline(kind: kind)
            .stroke(
                WorkspaceDesignTokens.color(.primaryText, environment: environment),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
            )
            .frame(
                width: size.width,
                height: size.height
            )
            .accessibilityHidden(true)
    }
}

private struct DeviceOutline: Shape {
    let kind: DisplayDeviceKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .laptop:
            let screen = CGRect(x: 7, y: 4, width: rect.width - 14, height: rect.height - 14)
            path.addRoundedRect(in: screen, cornerSize: CGSize(width: 4, height: 4))
            path.move(to: CGPoint(x: 2, y: rect.height - 7))
            path.addLine(to: CGPoint(x: rect.width - 2, y: rect.height - 7))
            path.addLine(to: CGPoint(x: rect.width - 8, y: rect.height - 2))
            path.addLine(to: CGPoint(x: 8, y: rect.height - 2))
            path.closeSubpath()
        case .monitor, .wideMonitor:
            let insetX: CGFloat = kind == .wideMonitor ? 1 : 6
            let screen = CGRect(x: insetX, y: 2, width: rect.width - insetX * 2, height: rect.height - 14)
            path.addRoundedRect(in: screen, cornerSize: CGSize(width: 4, height: 4))
            path.move(to: CGPoint(x: rect.midX, y: screen.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.height - 4))
            path.move(to: CGPoint(x: rect.midX - 12, y: rect.height - 3))
            path.addLine(to: CGPoint(x: rect.midX + 12, y: rect.height - 3))
        }
        return path
    }
}
