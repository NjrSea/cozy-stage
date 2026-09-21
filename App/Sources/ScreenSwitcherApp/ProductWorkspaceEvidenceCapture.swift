import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO

private let productWorkspaceNativeScreenshotTimeout: TimeInterval = 10

@MainActor
public protocol ProductWorkspaceEvidenceCaptureToken: AnyObject {
    func cancel()
}

@MainActor
public protocol ProductWorkspaceEvidenceCapturing: AnyObject {
    @discardableResult
    func startCapture(
        for window: any WorkspaceWindowControlling
    ) -> (any ProductWorkspaceEvidenceCaptureToken)?
}

@MainActor
public struct ProductWorkspaceEvidenceSource {
    public let windowID: CGWindowID
    public let isVisible: @MainActor () -> Bool

    public init(windowID: CGWindowID, isVisible: @escaping @MainActor () -> Bool) {
        self.windowID = windowID
        self.isVisible = isVisible
    }
}

/// Product-owned producer for window capture consumed by the external GUI
/// Diagnostics. It is inert unless every explicit capture gate is present and
/// never substitutes an NSView snapshot or historical fixture.
@MainActor
public final class ProductWorkspaceEvidenceCapture: ProductWorkspaceEvidenceCapturing {
    /// Keeps GUI evidence out of the card spring's visual tail so captures represent a stable frame.
    public static let initialSettleDelay: TimeInterval = 0.45
    static let hudTriggerFileName = ".hud-capture-trigger"
    private static let hudTriggerPollInterval: TimeInterval = 0.05
    private static let hudTriggerPollLimit = 200
    private static let productionNativeScreenshotLease = NativeScreenshotLease()

    public typealias Scheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () async -> Void
    ) -> Void
    public typealias SourceResolver = @MainActor (
        _ window: any WorkspaceWindowControlling
    ) -> ProductWorkspaceEvidenceSource?
    public typealias CaptureAttempt = @MainActor (
        _ windowID: CGWindowID,
        _ targetURL: URL
    ) async -> Bool
    enum NativeCaptureStage: Equatable {
        case shareableContentReturned(targetFound: Bool)
        case screenshotReturned(success: Bool)
        case screenshotTimedOut
        case screenshotBusy
    }
    typealias NativeCaptureStageReporter = @MainActor (NativeCaptureStage) -> Void
    typealias NativeCaptureAttempt = @MainActor (
        _ windowID: CGWindowID,
        _ targetURL: URL,
        _ reportStage: @escaping NativeCaptureStageReporter
    ) async -> Bool
    typealias NativeScreenshotCompletion = @MainActor (_ image: CGImage?) -> Void
    typealias NativeScreenshotRequest = @MainActor (
        _ completion: @escaping NativeScreenshotCompletion
    ) -> Void
    typealias NativeScreenshotOperation = @MainActor () async throws -> CGImage
    enum NativeScreenshotOutcome {
        case image(CGImage)
        case returnedFailure
        case timedOut
        case busy
    }
    public typealias TriggerRemover = @MainActor (_ triggerURL: URL) -> Bool
    public typealias BeforeTriggerQuarantine = @MainActor (_ triggerURL: URL) -> Void
    public typealias TriggerQuarantineRenamer = @MainActor (_ source: URL, _ destination: URL) -> Bool

    enum CaptureDiagnosticStage: String {
        case waitingForTrigger = "waiting_for_trigger"
        case triggerPollStarted = "trigger_poll_started"
        case triggerConsumed = "trigger_consumed"
        case captureAttemptStarted = "capture_attempt_started"
        case shareableContentReturned = "shareable_content_returned"
        case screenshotReturned = "screenshot_returned"
        case screenshotTimedOut = "screenshot_timed_out"
        case screenshotBusy = "screenshot_busy"
        case terminal
    }

    private enum HUDTriggerPollResult {
        case absent
        case consumed
        case cleanupFailed
    }

    private struct HUDTriggerIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private enum HUDTriggerPathState: Equatable {
        case absent
        case ownedRegular(HUDTriggerIdentity)
        case unsafe
    }

    private struct CaptureAttemptOwnership: Equatable {
        let tokenID: UUID
        let ordinal: Int
    }

    private final class NativeScreenshotCompletionGate {
        private var continuation: CheckedContinuation<NativeScreenshotOutcome, Never>?
        private var isCompleted = false

        func install(_ continuation: CheckedContinuation<NativeScreenshotOutcome, Never>) {
            precondition(self.continuation == nil)
            self.continuation = continuation
        }

        func resolve(_ outcome: NativeScreenshotOutcome) {
            guard !isCompleted else { return }
            isCompleted = true
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    final class NativeScreenshotLease {
        private var activeIdentity: UUID?

        func acquire() -> UUID? {
            guard activeIdentity == nil else { return nil }
            let identity = UUID()
            activeIdentity = identity
            return identity
        }

        func release(identity: UUID) {
            guard activeIdentity == identity else { return }
            activeIdentity = nil
        }
    }

    private final class CaptureToken: ProductWorkspaceEvidenceCaptureToken {
        let id = UUID()
        private(set) var isCancelled = false
        private let onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel()
        }
    }

    private let artifactDirectory: URL
    private let environment: [String: String]
    private let scheduler: Scheduler
    private let sourceResolver: SourceResolver
    private let nativeCaptureAttempt: NativeCaptureAttempt
    private let beforeTriggerQuarantine: BeforeTriggerQuarantine
    private let triggerQuarantineRenamer: TriggerQuarantineRenamer
    private let triggerRemover: TriggerRemover
    private var activeToken: CaptureToken?
    private var activeAttemptOwnership: CaptureAttemptOwnership?

    public convenience init(
        artifactDirectory: URL,
        environment: [String: String]
    ) {
        self.init(
            artifactDirectory: artifactDirectory,
            environment: environment,
            scheduler: Self.schedule,
            sourceResolver: Self.resolveSource,
            nativeCaptureAttempt: { windowID, targetURL, reportStage in
                await Self.capture(
                    windowID: windowID,
                    targetURL: targetURL,
                    nativeScreenshotLease: Self.productionNativeScreenshotLease,
                    reportStage: reportStage
                )
            }
        )
    }

    convenience init(
        artifactDirectory: URL,
        environment: [String: String],
        scheduler: @escaping Scheduler,
        sourceResolver: @escaping SourceResolver,
        captureAttempt: @escaping CaptureAttempt,
        beforeTriggerQuarantine: @escaping BeforeTriggerQuarantine = { _ in },
        triggerQuarantineRenamer: @escaping TriggerQuarantineRenamer = ProductWorkspaceEvidenceCapture.atomicRenameExclusive,
        triggerRemover: @escaping TriggerRemover = ProductWorkspaceEvidenceCapture.removeTrigger
    ) {
        self.init(
            artifactDirectory: artifactDirectory,
            environment: environment,
            scheduler: scheduler,
            sourceResolver: sourceResolver,
            nativeCaptureAttempt: { windowID, targetURL, _ in
                await captureAttempt(windowID, targetURL)
            },
            beforeTriggerQuarantine: beforeTriggerQuarantine,
            triggerQuarantineRenamer: triggerQuarantineRenamer,
            triggerRemover: triggerRemover
        )
    }

    init(
        artifactDirectory: URL,
        environment: [String: String],
        scheduler: @escaping Scheduler,
        sourceResolver: @escaping SourceResolver,
        nativeCaptureAttempt: @escaping NativeCaptureAttempt,
        beforeTriggerQuarantine: @escaping BeforeTriggerQuarantine = { _ in },
        triggerQuarantineRenamer: @escaping TriggerQuarantineRenamer = ProductWorkspaceEvidenceCapture.atomicRenameExclusive,
        triggerRemover: @escaping TriggerRemover = ProductWorkspaceEvidenceCapture.removeTrigger
    ) {
        self.artifactDirectory = artifactDirectory
        self.environment = environment
        self.scheduler = scheduler
        self.sourceResolver = sourceResolver
        self.nativeCaptureAttempt = nativeCaptureAttempt
        self.beforeTriggerQuarantine = beforeTriggerQuarantine
        self.triggerQuarantineRenamer = triggerQuarantineRenamer
        self.triggerRemover = triggerRemover
    }

    public static func configured(environment: [String: String]) -> ProductWorkspaceEvidenceCapture? {
        guard let path = environment["CS_DIAG_CAPTURE_DIRECTORY"], !path.isEmpty else {
            return nil
        }
        return ProductWorkspaceEvidenceCapture(
            artifactDirectory: URL(fileURLWithPath: path, isDirectory: true),
            environment: environment
        )
    }

    public static func recordStartup(
        directory: URL,
        environment: [String: String]
    ) {
        _ = environment
        writeStage(.waitingForTrigger, directory: directory)
    }

    @discardableResult
    public func startCapture(
        for window: any WorkspaceWindowControlling
    ) -> (any ProductWorkspaceEvidenceCaptureToken)? {
        guard window.role == .interactive else { return nil }
        return startCapture(source: sourceResolver(window))
    }

    @discardableResult
    public func startCapture(for window: NSWindow) -> (any ProductWorkspaceEvidenceCaptureToken)? {
        startCapture(for: window, waitsForHUDTrigger: false)
    }

    @discardableResult
    func startCapture(
        for window: NSWindow,
        waitsForHUDTrigger: Bool
    ) -> (any ProductWorkspaceEvidenceCaptureToken)? {
        let windowNumber = window.windowNumber
        let windowID = windowNumber > 0 ? CGWindowID(windowNumber) : 0
        return startCapture(source: windowID > 0 ? ProductWorkspaceEvidenceSource(
            windowID: windowID,
            isVisible: { [weak window] in window?.isVisible == true }
        ) : nil, waitsForHUDTrigger: waitsForHUDTrigger)
    }

    private func startCapture(
        source: ProductWorkspaceEvidenceSource?,
        waitsForHUDTrigger: Bool = false
    ) -> (any ProductWorkspaceEvidenceCaptureToken)? {
        guard environment["CS_DIAG_GUI_SMOKE"] == "1",
              environment["CS_DIAG_CAPTURE_MODE"] == "full"
        else { return nil }

        activeToken?.cancel()
        activeToken = nil
        activeAttemptOwnership = nil
        removeCaptureArtifact()
        if waitsForHUDTrigger, !removeHUDTrigger() {
            writeHUDTriggerCleanupFailure()
            return nil
        }

        guard let source, source.windowID > 0 else {
            Self.writeTerminalDiagnostic(
                directory: artifactDirectory,
                success: false,
                failureCode: "workspace_capture_source_missing"
            )
            return nil
        }

        let token = CaptureToken { [weak self] in
            guard let self else { return }
            self.activeAttemptOwnership = nil
            guard !self.removeHUDTrigger() else { return }
            self.writeHUDTriggerCleanupFailure()
        }
        activeToken = token
        if waitsForHUDTrigger {
            Self.writeStage(.waitingForTrigger, directory: artifactDirectory)
            scheduleHUDTriggerPoll(token: token, source: source, poll: 0, delay: 0)
        } else {
            scheduleAttempt(
                token: token,
                source: source,
                attempt: 0,
                delay: Self.initialSettleDelay
            )
        }
        return token
    }

    private func scheduleHUDTriggerPoll(
        token: CaptureToken,
        source: ProductWorkspaceEvidenceSource,
        poll: Int,
        delay: TimeInterval
    ) {
        scheduler(delay) { [weak self, weak token] in
            guard let self, let token, !token.isCancelled, self.activeToken === token else { return }
            Self.writeStage(.triggerPollStarted, directory: self.artifactDirectory)
            guard poll < Self.hudTriggerPollLimit else {
                guard self.removeHUDTrigger() else {
                    self.writeHUDTriggerCleanupFailure()
                    return
                }
                Self.writeTerminalDiagnostic(
                    directory: self.artifactDirectory,
                    success: false,
                    failureCode: "hud_capture_trigger_timeout"
                )
                return
            }
            switch self.consumeHUDTrigger() {
            case .absent:
                self.scheduleHUDTriggerPoll(
                    token: token,
                    source: source,
                    poll: poll + 1,
                    delay: Self.hudTriggerPollInterval
                )
                return
            case .cleanupFailed:
                self.writeHUDTriggerCleanupFailure()
                return
            case .consumed:
                break
            }
            Self.writeStage(.triggerConsumed, directory: self.artifactDirectory)
            await self.performAttempt(token: token, source: source, attempt: 0)
        }
    }

    private func scheduleAttempt(
        token: CaptureToken,
        source: ProductWorkspaceEvidenceSource,
        attempt: Int,
        delay: TimeInterval
    ) {
        scheduler(delay) { [weak self, weak token] in
            guard let self, let token else { return }
            await self.performAttempt(token: token, source: source, attempt: attempt)
        }
    }

    private func performAttempt(
        token: CaptureToken,
        source: ProductWorkspaceEvidenceSource,
        attempt: Int
    ) async {
        guard !token.isCancelled, activeToken === token else { return }
        guard attempt < 20 else {
            Self.writeTerminalDiagnostic(
                directory: artifactDirectory,
                success: false,
                failureCode: "workspace_capture_attempts_exhausted"
            )
            return
        }
        guard source.isVisible() else {
            scheduleAttempt(token: token, source: source, attempt: attempt + 1, delay: 0.1)
            return
        }

        let attemptURL = artifactDirectory.appendingPathComponent(
            ".capture-\(token.id.uuidString)-\(attempt).png"
        )
        try? FileManager.default.removeItem(at: attemptURL)
        Self.writeStage(
            .captureAttemptStarted,
            directory: artifactDirectory,
            ordinal: attempt + 1
        )
        let ownership = CaptureAttemptOwnership(
            tokenID: token.id,
            ordinal: attempt + 1
        )
        activeAttemptOwnership = ownership
        var nativeScreenshotTimedOut = false
        var nativeScreenshotBusy = false
        let succeeded = await nativeCaptureAttempt(
            source.windowID,
            attemptURL,
            { [weak self, weak token] stage in
                guard let self, let token,
                      !token.isCancelled,
                      self.activeToken === token,
                      self.activeAttemptOwnership == ownership else { return }
                switch stage {
                case .shareableContentReturned(let targetFound):
                    Self.writeStage(
                        .shareableContentReturned,
                        directory: self.artifactDirectory,
                        targetFound: targetFound
                    )
                case .screenshotReturned(let success):
                    Self.writeStage(
                        .screenshotReturned,
                        directory: self.artifactDirectory,
                        success: success
                    )
                case .screenshotTimedOut:
                    nativeScreenshotTimedOut = true
                    Self.writeStage(
                        .screenshotTimedOut,
                        directory: self.artifactDirectory
                    )
                case .screenshotBusy:
                    nativeScreenshotBusy = true
                    Self.writeStage(
                        .screenshotBusy,
                        directory: self.artifactDirectory
                    )
                }
            }
        )
        guard !token.isCancelled,
              activeToken === token,
              activeAttemptOwnership == ownership else {
            try? FileManager.default.removeItem(at: attemptURL)
            return
        }
        activeAttemptOwnership = nil
        if nativeScreenshotTimedOut {
            try? FileManager.default.removeItem(at: attemptURL)
            Self.writeTerminalDiagnostic(
                directory: artifactDirectory,
                success: false,
                failureCode: "native_screenshot_timeout"
            )
            return
        }
        if nativeScreenshotBusy {
            try? FileManager.default.removeItem(at: attemptURL)
            Self.writeTerminalDiagnostic(
                directory: artifactDirectory,
                success: false,
                failureCode: "native_screenshot_busy"
            )
            return
        }
        if succeeded, promoteCapture(at: attemptURL) {
            Self.writeTerminalDiagnostic(
                directory: artifactDirectory,
                success: true
            )
        } else {
            try? FileManager.default.removeItem(at: attemptURL)
            scheduleAttempt(token: token, source: source, attempt: attempt + 1, delay: 0.1)
        }
    }

    private func promoteCapture(at attemptURL: URL) -> Bool {
        let captureURL = artifactDirectory.appendingPathComponent("capture.png")
        guard FileManager.default.fileExists(atPath: attemptURL.path) else { return false }
        do {
            if FileManager.default.fileExists(atPath: captureURL.path) {
                _ = try FileManager.default.replaceItemAt(captureURL, withItemAt: attemptURL)
            } else {
                try FileManager.default.moveItem(at: attemptURL, to: captureURL)
            }
            return true
        } catch {
            return false
        }
    }

    private func removeCaptureArtifact() {
        let captureURL = artifactDirectory.appendingPathComponent("capture.png")
        guard FileManager.default.fileExists(atPath: captureURL.path) else { return }
        try? FileManager.default.removeItem(at: captureURL)
    }

    private func consumeHUDTrigger() -> HUDTriggerPollResult {
        let triggerURL = artifactDirectory.appendingPathComponent(Self.hudTriggerFileName)
        switch Self.hudTriggerPathState(at: triggerURL) {
        case .absent:
            return .absent
        case .ownedRegular:
            return removeHUDTrigger() ? .consumed : .cleanupFailed
        case .unsafe:
            return .cleanupFailed
        }
    }

    private func removeHUDTrigger() -> Bool {
        let triggerURL = artifactDirectory.appendingPathComponent(Self.hudTriggerFileName)
        switch Self.hudTriggerPathState(at: triggerURL) {
        case .absent:
            return true
        case .unsafe:
            return false
        case .ownedRegular(let identity):
            return removeOwnedHUDTrigger(at: triggerURL, identity: identity)
        }
    }

    private func removeOwnedHUDTrigger(
        at triggerURL: URL,
        identity: HUDTriggerIdentity
    ) -> Bool {
        guard Self.hudTriggerPathState(at: triggerURL) == .ownedRegular(identity) else {
            return false
        }
        beforeTriggerQuarantine(triggerURL)
        guard Self.hudTriggerPathState(at: triggerURL) == .ownedRegular(identity) else {
            return false
        }

        let quarantine = artifactDirectory.appendingPathComponent(
            ".hud-capture-trigger-removal-\(UUID().uuidString)"
        )
        guard triggerQuarantineRenamer(triggerURL, quarantine) else {
            return false
        }
        guard Self.hudTriggerPathState(at: triggerURL) == .absent else {
            return false
        }
        guard case .ownedRegular(let quarantinedIdentity) = Self.hudTriggerPathState(at: quarantine) else {
            return false
        }
        guard quarantinedIdentity == identity else {
            _ = Self.restoreTrigger(
                from: quarantine,
                to: triggerURL,
                identity: quarantinedIdentity
            )
            return false
        }

        let descriptor = Darwin.open(quarantine.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            _ = Self.restoreTrigger(from: quarantine, to: triggerURL, identity: identity)
            return false
        }
        defer { Darwin.close(descriptor) }
        var before = Darwin.stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              HUDTriggerIdentity(device: before.st_dev, inode: before.st_ino) == identity,
              Self.hudTriggerPathState(at: quarantine) == .ownedRegular(identity),
              triggerRemover(quarantine) else {
            _ = Self.restoreTrigger(from: quarantine, to: triggerURL, identity: identity)
            return false
        }
        var after = Darwin.stat()
        return Darwin.fstat(descriptor, &after) == 0
            && after.st_nlink + 1 == before.st_nlink
            && Self.hudTriggerPathState(at: quarantine) == .absent
            && Self.hudTriggerPathState(at: triggerURL) == .absent
    }

    private func writeHUDTriggerCleanupFailure() {
        Self.writeTerminalDiagnostic(
            directory: artifactDirectory,
            success: false,
            failureCode: "hud_capture_trigger_cleanup_failed"
        )
    }

    private static func removeTrigger(at url: URL) -> Bool {
        Darwin.unlink(url.path) == 0
    }

    private static func hudTriggerPathState(at url: URL) -> HUDTriggerPathState {
        var metadata = Darwin.stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            return errno == ENOENT ? .absent : .unsafe
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == 0 else { return .unsafe }
        return .ownedRegular(HUDTriggerIdentity(device: metadata.st_dev, inode: metadata.st_ino))
    }

    private static func atomicRenameExclusive(from source: URL, to destination: URL) -> Bool {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0
            }
        }
    }

    private static func restoreTrigger(
        from quarantine: URL,
        to original: URL,
        identity: HUDTriggerIdentity
    ) -> Bool {
        guard hudTriggerPathState(at: quarantine) == .ownedRegular(identity),
              hudTriggerPathState(at: original) == .absent,
              atomicRenameExclusive(from: quarantine, to: original),
              hudTriggerPathState(at: quarantine) == .absent,
              hudTriggerPathState(at: original) == .ownedRegular(identity) else {
            return false
        }
        return true
    }

    static func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor () async -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in await action() }
        }
    }

    static func awaitNativeScreenshot(
        lease suppliedLease: NativeScreenshotLease? = nil,
        timeout: TimeInterval = productWorkspaceNativeScreenshotTimeout,
        scheduler: @escaping Scheduler = ProductWorkspaceEvidenceCapture.schedule,
        request: @escaping NativeScreenshotRequest
    ) async -> NativeScreenshotOutcome {
        guard timeout.isFinite, timeout > 0 else { return .timedOut }
        let lease = suppliedLease ?? NativeScreenshotLease()
        guard let leaseIdentity = lease.acquire() else { return .busy }
        let gate = NativeScreenshotCompletionGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            scheduler(timeout) { [gate] in
                gate.resolve(.timedOut)
            }
            request { [weak gate, lease] image in
                lease.release(identity: leaseIdentity)
                if let image {
                    gate?.resolve(.image(image))
                } else {
                    gate?.resolve(.returnedFailure)
                }
            }
        }
    }

    static func asyncNativeScreenshotRequest(
        operation: @escaping NativeScreenshotOperation
    ) -> NativeScreenshotRequest {
        { completion in
            Task { @MainActor in
                completion(try? await operation())
            }
        }
    }

    private static func resolveSource(
        window: any WorkspaceWindowControlling
    ) -> ProductWorkspaceEvidenceSource? {
        guard let appKitWindow = window as? AppKitWorkspaceWindow else { return nil }
        let windowID = CGWindowID(appKitWindow.panel.windowNumber)
        return ProductWorkspaceEvidenceSource(
            windowID: windowID,
            isVisible: { [weak appKitWindow] in
                appKitWindow?.panel.isVisible == true && appKitWindow?.panel.contentView != nil
            }
        )
    }

    private static func capture(
        windowID: CGWindowID,
        targetURL: URL,
        nativeScreenshotLease: NativeScreenshotLease,
        reportStage: @escaping NativeCaptureStageReporter
    ) async -> Bool {
        reportStage(.shareableContentReturned(targetFound: true))
        let screenshot = await awaitNativeScreenshot(
            lease: nativeScreenshotLease,
            request: asyncNativeScreenshotRequest {
                guard let image = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    windowID,
                    [.boundsIgnoreFraming]
                ) else {
                    throw NSError(domain: "ProductWorkspaceEvidenceCapture", code: 1)
                }
                return image
            }
        )
        switch screenshot {
        case .image(let image):
            reportStage(.screenshotReturned(success: true))
            return writePNG(image, to: targetURL)
        case .returnedFailure:
            reportStage(.screenshotReturned(success: false))
            return false
        case .timedOut:
            reportStage(.screenshotTimedOut)
            return false
        case .busy:
            reportStage(.screenshotBusy)
            return false
        }
    }

    private static func writePNG(_ image: CGImage, to targetURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let destination = CGImageDestinationCreateWithURL(
                targetURL as CFURL,
                "public.png" as CFString,
                1,
                nil
            ) else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination)
        } catch {
            return false
        }
    }

    private static func writeDiagnostic(directory: URL, values: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(values) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            try data.write(
                to: directory.appendingPathComponent("capture-diagnostics.json"),
                options: .atomic
            )
        } catch {
            // Evidence diagnostics are best-effort and never qualify a run.
        }
    }

    static func writeStage(
        _ stage: CaptureDiagnosticStage,
        directory: URL,
        ordinal: Int? = nil,
        targetFound: Bool? = nil,
        success: Bool? = nil
    ) {
        var values: [String: Any] = ["stage": stage.rawValue]
        switch stage {
        case .captureAttemptStarted:
            guard let ordinal else { return }
            values["ordinal"] = ordinal
        case .shareableContentReturned:
            guard let targetFound else { return }
            values["targetFound"] = targetFound
        case .screenshotReturned:
            guard let success else { return }
            values["success"] = success
        case .waitingForTrigger, .triggerPollStarted, .triggerConsumed,
             .screenshotTimedOut, .screenshotBusy:
            break
        case .terminal:
            return
        }
        writeDiagnostic(directory: directory, values: values)
    }

    private static func writeTerminalDiagnostic(
        directory: URL,
        success: Bool,
        failureCode: String? = nil
    ) {
        var values: [String: Any] = [
            "stage": CaptureDiagnosticStage.terminal.rawValue,
            "success": success,
        ]
        if let failureCode {
            values["failureCode"] = failureCode
        }
        writeDiagnostic(directory: directory, values: values)
    }
}
