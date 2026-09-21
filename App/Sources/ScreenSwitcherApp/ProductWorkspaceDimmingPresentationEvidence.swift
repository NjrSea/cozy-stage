import AppKit
import CryptoKit
import Foundation

public struct ProductWorkspaceEvidenceFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ frame: CGRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
    }
}

public struct ProductWorkspaceDimmingTreatment: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct ProductWorkspaceDimmingPanelPresentation: Codable, Equatable, Sendable {
    public let displayIdentity: String
    public let presentationIndex: Int
    public let expectedFrame: ProductWorkspaceEvidenceFrame
    public let actualFrame: ProductWorkspaceEvidenceFrame
    public let isVisible: Bool
    public let isOrdered: Bool
    public let coversExpectedDisplayFrame: Bool
    public let treatment: ProductWorkspaceDimmingTreatment
}

public struct ProductWorkspaceDimmingPresentationArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let panels: [ProductWorkspaceDimmingPanelPresentation]

    public init(panels: [ProductWorkspaceDimmingPanelPresentation]) {
        schemaVersion = 1
        kind = "workspace_dimming_presentation"
        self.panels = panels
    }
}

@MainActor
public struct ProductWorkspaceDimmingWindow {
    public let displayID: String
    public let expectedFrame: CGRect
    public let window: any WorkspaceWindowControlling

    public init(
        displayID: String,
        expectedFrame: CGRect,
        window: any WorkspaceWindowControlling
    ) {
        self.displayID = displayID
        self.expectedFrame = expectedFrame
        self.window = window
    }
}

@MainActor
public protocol ProductWorkspaceDimmingPresentationRecording: AnyObject {
    func record(_ windows: [ProductWorkspaceDimmingWindow])
}

@MainActor
struct ProductWorkspaceDimmingPresentationSource {
    let actualFrame: CGRect
    let isVisible: Bool
    let isOrdered: Bool
    let treatment: ProductWorkspaceDimmingTreatment
}

/// Emits a structural proof of the App-owned dimming panels without capturing
/// any desktop pixels, display names, window titles, paths, or content.
@MainActor
public final class ProductWorkspaceDimmingPresentationEvidence:
    ProductWorkspaceDimmingPresentationRecording {
    public static let artifactName = "workspace-dimming-presentation.json"

    typealias SourceResolver = @MainActor (
        _ window: ProductWorkspaceDimmingWindow
    ) -> ProductWorkspaceDimmingPresentationSource?

    private let artifactURL: URL
    private let sourceResolver: SourceResolver

    init(
        artifactDirectory: URL,
        sourceResolver: @escaping SourceResolver = ProductWorkspaceDimmingPresentationEvidence.resolveSource
    ) {
        artifactURL = artifactDirectory.appendingPathComponent(Self.artifactName)
        self.sourceResolver = sourceResolver
    }

    public static func configured(
        environment: [String: String],
        bundleURL: URL
    ) -> ProductWorkspaceDimmingPresentationEvidence? {
        guard RuntimeAdapterStartupPolicy.isPackagedProduction(
            bundleURL: bundleURL,
            environment: environment
        ),
        environment[RuntimeAdapterStartupPolicy.runtimeEnvironmentKey] == "1",
        environment[RuntimeAdapterStartupPolicy.dogfoodEnvironmentKey] == "1",
        environment["CS_DIAG_GUI_SMOKE"] == "1",
        environment["CS_DIAG_CAPTURE_MODE"] == "full",
        let path = environment["CS_DIAG_CAPTURE_DIRECTORY"],
        !path.isEmpty
        else { return nil }

        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let directoryValues = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
              ]),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else { return nil }

        let evidence = ProductWorkspaceDimmingPresentationEvidence(artifactDirectory: directory)
        guard evidence.removeExistingArtifactIfSafe() else { return nil }
        return evidence
    }

    public func record(_ windows: [ProductWorkspaceDimmingWindow]) {
        guard windows.allSatisfy({ $0.window.role == .dimming }) else {
            removeArtifact()
            return
        }

        var panels: [ProductWorkspaceDimmingPanelPresentation] = []
        panels.reserveCapacity(windows.count)
        for (index, window) in windows.enumerated() {
            guard let source = sourceResolver(window) else {
                removeArtifact()
                return
            }
            panels.append(ProductWorkspaceDimmingPanelPresentation(
                displayIdentity: Self.opaqueDisplayIdentity(window.displayID),
                presentationIndex: index,
                expectedFrame: ProductWorkspaceEvidenceFrame(window.expectedFrame),
                actualFrame: ProductWorkspaceEvidenceFrame(source.actualFrame),
                isVisible: source.isVisible,
                isOrdered: source.isOrdered,
                coversExpectedDisplayFrame: source.actualFrame.equalTo(window.expectedFrame),
                treatment: source.treatment
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            ProductWorkspaceDimmingPresentationArtifact(panels: panels)
        ) else {
            removeArtifact()
            return
        }
        do {
            try data.write(to: artifactURL, options: .atomic)
        } catch {
            removeArtifact()
        }
    }

    private func removeExistingArtifactIfSafe() -> Bool {
        guard FileManager.default.fileExists(atPath: artifactURL.path) else { return true }
        guard let values = try? artifactURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true else { return false }
        do {
            try FileManager.default.removeItem(at: artifactURL)
            return true
        } catch {
            return false
        }
    }

    private func removeArtifact() {
        guard FileManager.default.fileExists(atPath: artifactURL.path) else { return }
        try? FileManager.default.removeItem(at: artifactURL)
    }

    private static func resolveSource(
        _ context: ProductWorkspaceDimmingWindow
    ) -> ProductWorkspaceDimmingPresentationSource? {
        guard context.window.role == .dimming,
              let window = context.window as? AppKitWorkspaceWindow,
              let backgroundColor = window.panel.contentView?.layer?.backgroundColor,
              let color = NSColor(cgColor: backgroundColor)?.usingColorSpace(.sRGB)
        else { return nil }

        let panel = window.panel
        return ProductWorkspaceDimmingPresentationSource(
            actualFrame: panel.frame,
            isVisible: panel.isVisible,
            isOrdered: panel.isVisible && panel.windowNumber > 0,
            treatment: ProductWorkspaceDimmingTreatment(
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent,
                alpha: color.alphaComponent
            )
        )
    }

    private static func opaqueDisplayIdentity(_ displayID: String) -> String {
        let digest = SHA256.hash(data: Data(displayID.utf8))
        return "display:" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
