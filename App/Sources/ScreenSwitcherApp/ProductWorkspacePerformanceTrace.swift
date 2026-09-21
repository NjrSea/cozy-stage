import Foundation

public enum ProductWorkspacePerformanceTraceTrigger: String, Codable, Equatable, Sendable {
    case globalShortcut = "global_shortcut"
}

public enum ProductWorkspacePerformanceTraceEndpoint: String, Codable, Equatable, Sendable {
    case nsWindowDidUpdate = "ns_window_did_update"
}

public enum ProductWorkspacePerformanceThermalState: String, Codable, Equatable, Sendable {
    case cold
    case hot
}

public struct ProductWorkspacePerformanceTraceSample: Codable, Equatable, Sendable {
    public let sequence: Int
    public let thermalState: ProductWorkspacePerformanceThermalState
    public let startNanoseconds: UInt64
    public let endNanoseconds: UInt64

    public init(
        sequence: Int,
        thermalState: ProductWorkspacePerformanceThermalState,
        startNanoseconds: UInt64,
        endNanoseconds: UInt64
    ) {
        self.sequence = sequence
        self.thermalState = thermalState
        self.startNanoseconds = startNanoseconds
        self.endNanoseconds = endNanoseconds
    }
}

public struct ProductWorkspacePerformanceTraceArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let trigger: ProductWorkspacePerformanceTraceTrigger
    public let endpoint: ProductWorkspacePerformanceTraceEndpoint
    public let samples: [ProductWorkspacePerformanceTraceSample]

    public init(samples: [ProductWorkspacePerformanceTraceSample]) {
        schemaVersion = 1
        trigger = .globalShortcut
        endpoint = .nsWindowDidUpdate
        self.samples = samples
    }
}

@MainActor
public protocol ProductWorkspacePerformanceTraceToken: AnyObject {
    func cancel()
}

@MainActor
public protocol ProductWorkspacePerformanceTracing: AnyObject {
    @discardableResult
    func beginGlobalShortcutFirstExposure(
        startNanoseconds: UInt64,
        for window: any WorkspaceWindowControlling
    ) -> (any ProductWorkspacePerformanceTraceToken)?
}

/// Product-owned shortcut-to-first-AppKit-window-update trace. The endpoint is
/// deliberately limited to what `NSWindow.didUpdateNotification` proves.
@MainActor
public final class ProductWorkspacePerformanceTrace: ProductWorkspacePerformanceTracing {
    public static let artifactName = "workspace-performance-trace.json"

    private final class TraceToken: ProductWorkspacePerformanceTraceToken {
        private var observation: WorkspaceWindowExposureObservation?
        private var isComplete = false
        private let completion: @MainActor () -> Void

        init(completion: @escaping @MainActor () -> Void) {
            self.completion = completion
        }

        func install(_ observation: WorkspaceWindowExposureObservation) {
            self.observation = observation
        }

        func complete() {
            guard !isComplete else { return }
            isComplete = true
            observation?.cancel()
            observation = nil
            completion()
        }

        func cancel() {
            guard !isComplete else { return }
            isComplete = true
            observation?.cancel()
            observation = nil
        }
    }

    private let artifactURL: URL
    private let monotonicNow: @MainActor () -> UInt64

    init(
        artifactDirectory: URL,
        monotonicNow: @escaping @MainActor () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        artifactURL = artifactDirectory.appendingPathComponent(Self.artifactName)
        self.monotonicNow = monotonicNow
    }

    public static func configured(
        environment: [String: String],
        bundleURL: URL
    ) -> ProductWorkspacePerformanceTrace? {
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
        let artifactURL = directory.appendingPathComponent(Self.artifactName)
        if let values = try? artifactURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]) {
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            do {
                try FileManager.default.removeItem(at: artifactURL)
            } catch {
                return nil
            }
        } else if FileManager.default.fileExists(atPath: artifactURL.path) {
            return nil
        }
        return ProductWorkspacePerformanceTrace(artifactDirectory: directory)
    }

    @discardableResult
    public func beginGlobalShortcutFirstExposure(
        startNanoseconds: UInt64,
        for window: any WorkspaceWindowControlling
    ) -> (any ProductWorkspacePerformanceTraceToken)? {
        guard window.role == .interactive else { return nil }
        let token = TraceToken { [weak self] in
            guard let self else { return }
            self.appendSample(
                startNanoseconds: startNanoseconds,
                endNanoseconds: self.monotonicNow()
            )
        }
        guard let observation = window.observeFirstExposure({ [weak token] in
            token?.complete()
        }) else { return nil }
        token.install(observation)
        return token
    }

    private func appendSample(startNanoseconds: UInt64, endNanoseconds: UInt64) {
        guard endNanoseconds >= startNanoseconds else { return }
        let existing: ProductWorkspacePerformanceTraceArtifact
        if FileManager.default.fileExists(atPath: artifactURL.path) {
            guard let data = try? Data(contentsOf: artifactURL),
                  let decoded = try? JSONDecoder().decode(
                    ProductWorkspacePerformanceTraceArtifact.self,
                    from: data
                  ),
                  decoded.schemaVersion == 1,
                  decoded.trigger == .globalShortcut,
                  decoded.endpoint == .nsWindowDidUpdate else { return }
            existing = decoded
        } else {
            existing = ProductWorkspacePerformanceTraceArtifact(samples: [])
        }
        let sequence = existing.samples.count
        let sample = ProductWorkspacePerformanceTraceSample(
            sequence: sequence,
            thermalState: sequence == 0 ? .cold : .hot,
            startNanoseconds: startNanoseconds,
            endNanoseconds: endNanoseconds
        )
        let artifact = ProductWorkspacePerformanceTraceArtifact(
            samples: existing.samples + [sample]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(artifact) else { return }
        try? data.write(to: artifactURL, options: .atomic)
    }
}
