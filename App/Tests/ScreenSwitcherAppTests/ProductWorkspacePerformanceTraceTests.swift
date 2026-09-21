import AppKit
import SwiftUI
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class ProductWorkspacePerformanceTraceTests: XCTestCase {
    func testTraceArtifactDeclaresWindowUpdateAsItsFirstFrameEndpoint() throws {
        let data = try JSONEncoder().encode(ProductWorkspacePerformanceTraceArtifact(samples: []))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["endpoint"] as? String, "ns_window_did_update")
    }

    func testConfiguredRequiresEveryPackagedDogfoodFullCaptureGateAndExistingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let complete = [
            RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1",
            RuntimeAdapterStartupPolicy.dogfoodEnvironmentKey: "1",
            "CS_DIAG_GUI_SMOKE": "1",
            "CS_DIAG_CAPTURE_MODE": "full",
            "CS_DIAG_CAPTURE_DIRECTORY": directory.path
        ]

        XCTAssertNotNil(ProductWorkspacePerformanceTrace.configured(
            environment: complete,
            bundleURL: URL(fileURLWithPath: "/tmp/ScreenSwitcher.app")
        ))
        for key in complete.keys {
            XCTAssertNil(ProductWorkspacePerformanceTrace.configured(
                environment: complete.filter { $0.key != key },
                bundleURL: URL(fileURLWithPath: "/tmp/ScreenSwitcher.app")
            ), "missing gate must disable trace: \(key)")
        }
        XCTAssertNil(ProductWorkspacePerformanceTrace.configured(
            environment: complete,
            bundleURL: URL(fileURLWithPath: "/tmp/ScreenSwitcher")
        ))
    }

    func testConfiguredStartsOwnedGUIRunCleanAndRejectsSymlinkTrace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let environment = [
            RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1",
            RuntimeAdapterStartupPolicy.dogfoodEnvironmentKey: "1",
            "CS_DIAG_GUI_SMOKE": "1",
            "CS_DIAG_CAPTURE_MODE": "full",
            "CS_DIAG_CAPTURE_DIRECTORY": directory.path
        ]
        let traceURL = directory.appendingPathComponent(ProductWorkspacePerformanceTrace.artifactName)
        try Data("stale".utf8).write(to: traceURL)

        XCTAssertNotNil(ProductWorkspacePerformanceTrace.configured(
            environment: environment,
            bundleURL: URL(fileURLWithPath: "/tmp/ScreenSwitcher.app")
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: traceURL.path))

        let outsideTrace = outside.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outsideTrace)
        try FileManager.default.createSymbolicLink(at: traceURL, withDestinationURL: outsideTrace)

        XCTAssertNil(ProductWorkspacePerformanceTrace.configured(
            environment: environment,
            bundleURL: URL(fileURLWithPath: "/tmp/ScreenSwitcher.app")
        ))
        XCTAssertEqual(try Data(contentsOf: outsideTrace), Data("outside".utf8))
    }

    func testInteractiveFirstExposureWritesOrderedColdAndHotSamplesOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now: UInt64 = 210_000_010
        let trace = ProductWorkspacePerformanceTrace(
            artifactDirectory: directory,
            monotonicNow: { now }
        )
        let first = TraceFixtureWindow(role: .interactive)
        let stale = try XCTUnwrap(trace.beginGlobalShortcutFirstExposure(
            startNanoseconds: 10,
            for: first
        ))
        stale.cancel()
        first.expose()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(ProductWorkspacePerformanceTrace.artifactName).path
        ))

        let coldWindow = TraceFixtureWindow(role: .interactive)
        let coldToken = try XCTUnwrap(trace.beginGlobalShortcutFirstExposure(
            startNanoseconds: 10,
            for: coldWindow
        ))
        coldWindow.expose()
        coldWindow.expose()
        withExtendedLifetime(coldToken) {}

        now = 380_000_000
        let hotWindow = TraceFixtureWindow(role: .interactive)
        let hotToken = try XCTUnwrap(trace.beginGlobalShortcutFirstExposure(
            startNanoseconds: 300_000_000,
            for: hotWindow
        ))
        hotWindow.expose()
        withExtendedLifetime(hotToken) {}

        let artifact = try JSONDecoder().decode(
            ProductWorkspacePerformanceTraceArtifact.self,
            from: Data(contentsOf: directory.appendingPathComponent(ProductWorkspacePerformanceTrace.artifactName))
        )
        XCTAssertEqual(artifact.trigger, .globalShortcut)
        XCTAssertEqual(artifact.endpoint, .nsWindowDidUpdate)
        XCTAssertEqual(artifact.samples.map(\.thermalState), [.cold, .hot])
        XCTAssertEqual(artifact.samples.map(\.sequence), [0, 1])
        XCTAssertEqual(artifact.samples[0].startNanoseconds, 10)
        XCTAssertEqual(artifact.samples[0].endNanoseconds, 210_000_010)
        XCTAssertEqual(artifact.samples[1].startNanoseconds, 300_000_000)
        XCTAssertEqual(artifact.samples[1].endNanoseconds, 380_000_000)
    }

    func testDimmingWindowAndSanitizedPayloadNeverRecordSensitiveContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = ProductWorkspacePerformanceTrace(
            artifactDirectory: directory,
            monotonicNow: { 20 }
        )
        XCTAssertNil(trace.beginGlobalShortcutFirstExposure(
            startNanoseconds: 10,
            for: TraceFixtureWindow(role: .dimming)
        ))
        let interactive = TraceFixtureWindow(role: .interactive)
        let token = trace.beginGlobalShortcutFirstExposure(startNanoseconds: 10, for: interactive)
        interactive.expose()
        withExtendedLifetime(token) {}

        let data = try Data(contentsOf: directory.appendingPathComponent(ProductWorkspacePerformanceTrace.artifactName))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["private-token", "Screen Switcher Workspace", "carbonKeyCode", "carbonModifiers", directory.path] {
            XCTAssertFalse(text.contains(forbidden), "trace leaked \(forbidden)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != ProductWorkspacePerformanceTrace.artifactName }
        XCTAssertTrue(leftovers.isEmpty, "atomic write left unexpected files: \(leftovers)")
    }
}

@MainActor
private final class TraceFixtureWindow: WorkspaceWindowControlling {
    let displayID = "display-private"
    let role: WorkspaceWindowRole
    var escapeHandler: (@MainActor () -> Void)?
    private var exposureHandlers: [@MainActor () -> Void] = []

    init(role: WorkspaceWindowRole) {
        self.role = role
    }

    func observeFirstExposure(_ handler: @escaping @MainActor () -> Void) -> WorkspaceWindowExposureObservation? {
        exposureHandlers.append(handler)
        return WorkspaceWindowExposureObservation { [weak self] in self?.exposureHandlers.removeAll() }
    }

    func expose() {
        exposureHandlers.forEach { $0() }
    }

    func setFrame(_ frame: CGRect) {}
    func setRootView(_ rootView: AnyView) {}
    func show(makeKey: Bool) {}
    func close() {}
}
