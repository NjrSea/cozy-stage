import AppKit
import SwiftUI
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class ProductWorkspaceDimmingPresentationEvidenceTests: XCTestCase {
    func testConfiguredRequiresPackagedDogfoodRuntimeAndExplicitFullGUICaptureGates() throws {
        let directory = temporaryDirectory(prefix: "dimming-evidence-gate")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let completeEnvironment = enabledEnvironment(captureDirectory: directory)
        let bundleURL = URL(fileURLWithPath: "/Applications/ScreenSwitcher.app")

        XCTAssertNotNil(ProductWorkspaceDimmingPresentationEvidence.configured(
            environment: completeEnvironment,
            bundleURL: bundleURL
        ))

        for key in [
            RuntimeAdapterStartupPolicy.runtimeEnvironmentKey,
            RuntimeAdapterStartupPolicy.dogfoodEnvironmentKey,
            "CS_DIAG_GUI_SMOKE",
            "CS_DIAG_CAPTURE_MODE",
            "CS_DIAG_CAPTURE_DIRECTORY"
        ] {
            var incomplete = completeEnvironment
            incomplete.removeValue(forKey: key)
            XCTAssertNil(
                ProductWorkspaceDimmingPresentationEvidence.configured(
                    environment: incomplete,
                    bundleURL: bundleURL
                ),
                "Missing \(key) must keep the product evidence producer inert"
            )
        }

        XCTAssertNil(ProductWorkspaceDimmingPresentationEvidence.configured(
            environment: completeEnvironment,
            bundleURL: URL(fileURLWithPath: "/tmp/ScreenSwitcher")
        ))
    }

    func testRecordInspectsActualDimmingPanelsWithoutExposingDisplayIdentityOrContent() throws {
        _ = NSApplication.shared
        let directory = temporaryDirectory(prefix: "dimming-evidence-success")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let leftFrame = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let rightFrame = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let left = AppKitWorkspaceWindow(configuration: WorkspaceWindowConfiguration(
            displayID: "private-display-left",
            frame: leftFrame,
            role: .dimming,
            rootView: nil
        ))
        let right = AppKitWorkspaceWindow(configuration: WorkspaceWindowConfiguration(
            displayID: "private-display-right",
            frame: rightFrame,
            role: .dimming,
            rootView: nil
        ))
        defer {
            left.close()
            right.close()
        }
        left.show(makeKey: false)
        right.show(makeKey: false)
        let recorder = ProductWorkspaceDimmingPresentationEvidence(artifactDirectory: directory)

        recorder.record([
            ProductWorkspaceDimmingWindow(
                displayID: left.displayID,
                expectedFrame: leftFrame,
                window: left
            ),
            ProductWorkspaceDimmingWindow(
                displayID: right.displayID,
                expectedFrame: rightFrame,
                window: right
            )
        ])

        let artifactURL = directory.appendingPathComponent(
            ProductWorkspaceDimmingPresentationEvidence.artifactName
        )
        let data = try Data(contentsOf: artifactURL)
        let artifact = try JSONDecoder().decode(
            ProductWorkspaceDimmingPresentationArtifact.self,
            from: data
        )
        XCTAssertEqual(artifact.schemaVersion, 1)
        XCTAssertEqual(artifact.kind, "workspace_dimming_presentation")
        XCTAssertEqual(artifact.panels.map(\.presentationIndex), [0, 1])
        XCTAssertEqual(artifact.panels.map(\.expectedFrame), [
            ProductWorkspaceEvidenceFrame(leftFrame),
            ProductWorkspaceEvidenceFrame(rightFrame)
        ])
        XCTAssertEqual(artifact.panels.map(\.actualFrame), [
            ProductWorkspaceEvidenceFrame(leftFrame),
            ProductWorkspaceEvidenceFrame(rightFrame)
        ])
        XCTAssertTrue(artifact.panels.allSatisfy(\.isVisible))
        XCTAssertTrue(artifact.panels.allSatisfy(\.isOrdered))
        XCTAssertTrue(artifact.panels.allSatisfy(\.coversExpectedDisplayFrame))
        XCTAssertTrue(artifact.panels.allSatisfy {
            abs($0.treatment.red) < 0.0001
                && abs($0.treatment.green) < 0.0001
                && abs($0.treatment.blue) < 0.0001
                && abs($0.treatment.alpha - 0.72) < 0.0001
        })
        XCTAssertTrue(artifact.panels.allSatisfy {
            $0.displayIdentity.hasPrefix("display:") && $0.displayIdentity.count == 24
        })

        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-display-left"))
        XCTAssertFalse(encoded.contains("private-display-right"))
        XCTAssertFalse(encoded.contains(directory.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [ProductWorkspaceDimmingPresentationEvidence.artifactName],
            "Atomic publication must not leave temporary evidence files"
        )
    }

    func testUnresolvableOrNonDimmingWindowRemovesStaleArtifactAndFailsClosed() throws {
        let directory = temporaryDirectory(prefix: "dimming-evidence-fail-closed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactURL = directory.appendingPathComponent(
            ProductWorkspaceDimmingPresentationEvidence.artifactName
        )
        try Data("stale".utf8).write(to: artifactURL)
        let recorder = ProductWorkspaceDimmingPresentationEvidence(
            artifactDirectory: directory,
            sourceResolver: { _ in nil }
        )

        recorder.record([
            ProductWorkspaceDimmingWindow(
                displayID: "private-display",
                expectedFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                window: DimmingEvidenceFixtureWindow(role: .dimming)
            )
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    private func enabledEnvironment(captureDirectory: URL) -> [String: String] {
        [
            RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1",
            RuntimeAdapterStartupPolicy.dogfoodEnvironmentKey: "1",
            "CS_DIAG_GUI_SMOKE": "1",
            "CS_DIAG_CAPTURE_MODE": "full",
            "CS_DIAG_CAPTURE_DIRECTORY": captureDirectory.path
        ]
    }

    private func temporaryDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private final class DimmingEvidenceFixtureWindow: WorkspaceWindowControlling {
    let displayID = "fixture-display"
    let role: WorkspaceWindowRole
    var escapeHandler: (@MainActor () -> Void)?

    init(role: WorkspaceWindowRole) {
        self.role = role
    }

    func setFrame(_ frame: CGRect) {}
    func setRootView(_ rootView: AnyView) {}
    func show(makeKey: Bool) {}
    func close() {}
}
