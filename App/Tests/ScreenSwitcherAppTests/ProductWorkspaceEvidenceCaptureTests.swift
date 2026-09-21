import AppKit
import SwiftUI
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class ProductWorkspaceEvidenceCaptureTests: XCTestCase {
    func testAsyncNativeScreenshotOperationCompletesOwnedGate() async throws {
        var timeoutAction: (@MainActor () async -> Void)?
        var operationContinuation: CheckedContinuation<CGImage, Error>?
        let image = try XCTUnwrap(
            NSImage(data: Self.onePixelPNG)?.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
        let request = ProductWorkspaceEvidenceCapture.asyncNativeScreenshotRequest {
            try await withCheckedThrowingContinuation { continuation in
                operationContinuation = continuation
            }
        }
        let task = Task { @MainActor in
            await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
                scheduler: { _, action in timeoutAction = action },
                request: request
            )
        }
        for _ in 0..<20 where operationContinuation == nil { await Task.yield() }

        guard let operationContinuation else {
            await timeoutAction?()
            _ = await task.value
            return XCTFail("The async ScreenCaptureKit operation must start")
        }
        operationContinuation.resume(returning: image)
        guard case .image = await task.value else {
            return XCTFail("The async ScreenCaptureKit result must resolve the owned gate")
        }
    }

    func testProductionNativeDeadlineAllowsCallbackAfterFormerOneSecondCutoff() async throws {
        var simulatedElapsed: TimeInterval = 0
        var scheduledDeadline: TimeInterval?
        var timeoutAction: (@MainActor () async -> Void)?
        var callback: (@MainActor (CGImage?) -> Void)?
        let image = try XCTUnwrap(
            NSImage(data: Self.onePixelPNG)?.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
        let task = Task { @MainActor in
            await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
                scheduler: { delay, action in
                    scheduledDeadline = simulatedElapsed + delay
                    timeoutAction = action
                },
                request: { callback = $0 }
            )
        }
        for _ in 0..<20 where callback == nil { await Task.yield() }

        simulatedElapsed = 1.5
        XCTAssertEqual(scheduledDeadline, 10)
        XCTAssertLessThan(simulatedElapsed, try XCTUnwrap(scheduledDeadline))
        guard let callback else {
            await timeoutAction?()
            _ = await task.value
            return XCTFail("The native screenshot request must be installed")
        }
        callback(image)
        guard case .image = await task.value else {
            return XCTFail("A callback inside the ten-second production deadline must succeed")
        }
    }

    func testReturnedNativeScreenshotFailureRetriesAndLaterAttemptSucceeds() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-native-timeout-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var screenshotTimeouts: [@MainActor () async -> Void] = []
        var screenshotCallbacks: [@MainActor (CGImage?) -> Void] = []
        let image = try XCTUnwrap(
            NSImage(data: Self.onePixelPNG)?.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in
                ProductWorkspaceEvidenceSource(windowID: 42, isVisible: { true })
            },
            nativeCaptureAttempt: { _, targetURL, reportStage in
                reportStage(.shareableContentReturned(targetFound: true))
                let screenshot = await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
                    scheduler: { _, action in screenshotTimeouts.append(action) },
                    request: { screenshotCallbacks.append($0) }
                )
                guard case .image = screenshot else {
                    reportStage(.screenshotReturned(success: false))
                    return false
                }
                reportStage(.screenshotReturned(success: true))
                try? Self.onePixelPNG.write(to: targetURL, options: .atomic)
                return true
            }
        )

        XCTAssertNotNil(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))
        let firstAttempt = scheduled.removeFirst()
        let firstTask = Task { @MainActor in await firstAttempt() }
        for _ in 0..<20 where screenshotCallbacks.isEmpty { await Task.yield() }
        XCTAssertEqual(screenshotCallbacks.count, 1)
        XCTAssertEqual(screenshotTimeouts.count, 1)

        screenshotCallbacks[0](nil)
        await firstTask.value
        var values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "screenshot_returned")
        XCTAssertEqual(values["success"] as? Bool, false)
        XCTAssertEqual(scheduled.count, 1, "a returned failure may continue the bounded retry policy")

        let secondAttempt = scheduled.removeFirst()
        let secondTask = Task { @MainActor in await secondAttempt() }
        for _ in 0..<20 where screenshotCallbacks.count < 2 { await Task.yield() }
        XCTAssertEqual(screenshotCallbacks.count, 2)
        screenshotCallbacks[1](image)
        await secondTask.value
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, true)

        XCTAssertEqual(screenshotTimeouts.count, 2)
    }

    func testHungNativeScreenshotTimesOutOnceWithClosedTerminalFailure() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-native-timeout-exhausted")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var screenshotDelays: [TimeInterval] = []
        var screenshotTimeouts: [@MainActor () async -> Void] = []
        var screenshotCallbacks: [@MainActor (CGImage?) -> Void] = []
        let screenshotLease = ProductWorkspaceEvidenceCapture.NativeScreenshotLease()
        let image = try XCTUnwrap(
            NSImage(data: Self.onePixelPNG)?.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in
                ProductWorkspaceEvidenceSource(windowID: 42, isVisible: { true })
            },
            nativeCaptureAttempt: { _, targetURL, reportStage in
                reportStage(.shareableContentReturned(targetFound: true))
                let screenshot = await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
                    lease: screenshotLease,
                    scheduler: { delay, action in
                        screenshotDelays.append(delay)
                        screenshotTimeouts.append(action)
                    },
                    request: { screenshotCallbacks.append($0) }
                )
                switch screenshot {
                case .image:
                    reportStage(.screenshotReturned(success: true))
                    try? Self.onePixelPNG.write(to: targetURL, options: .atomic)
                    return true
                case .returnedFailure:
                    reportStage(.screenshotReturned(success: false))
                case .timedOut:
                    reportStage(.screenshotTimedOut)
                case .busy:
                    reportStage(.screenshotBusy)
                }
                return false
            }
        )

        XCTAssertNotNil(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))
        XCTAssertEqual(scheduled.count, 1)
        let attempt = scheduled.removeFirst()
        let task = Task { @MainActor in await attempt() }
        for _ in 0..<20 where screenshotTimeouts.isEmpty { await Task.yield() }
        XCTAssertEqual(screenshotCallbacks.count, 1)
        XCTAssertEqual(screenshotTimeouts.count, 1)
        XCTAssertEqual(screenshotDelays, [10])
        await screenshotTimeouts.removeFirst()()
        await task.value

        var values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, false)
        XCTAssertEqual(values["failureCode"] as? String, "native_screenshot_timeout")
        XCTAssertTrue(scheduled.isEmpty, "a hung non-cancellable native request must not accumulate retries")

        XCTAssertNotNil(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))
        XCTAssertEqual(scheduled.count, 1)
        await scheduled.removeFirst()()
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["failureCode"] as? String, "native_screenshot_busy")
        XCTAssertEqual(screenshotCallbacks.count, 1, "B must not start another native request")

        screenshotCallbacks[0](nil)
        await Task.yield()
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["failureCode"] as? String, "native_screenshot_busy")

        XCTAssertNotNil(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))
        let thirdAttempt = scheduled.removeFirst()
        let thirdTask = Task { @MainActor in await thirdAttempt() }
        for _ in 0..<20 where screenshotCallbacks.count < 2 { await Task.yield() }
        XCTAssertEqual(screenshotCallbacks.count, 2, "C may start only after A's exact callback releases the lease")
        XCTAssertEqual(screenshotDelays, [10, 10])
        screenshotCallbacks[1](image)
        await thirdTask.value
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".hud-capture-trigger").path
        ))
    }

    func testNativeScreenshotTimeoutRetainsOneShotGateUntilResolution() async {
        var timeoutAction: (@MainActor () async -> Void)?
        var requestStarted = false
        let task = Task { @MainActor in
            await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
                scheduler: { _, action in timeoutAction = action },
                request: { _ in requestStarted = true }
            )
        }
        for _ in 0..<20 where !requestStarted { await Task.yield() }
        XCTAssertTrue(requestStarted)

        await timeoutAction?()
        let outcome = await task.value
        guard case .timedOut = outcome else {
            return XCTFail("Expected a typed timeout outcome")
        }
    }

    func testStaleNativeCallbackCannotReleaseNewLeaseIdentity() async {
        let lease = ProductWorkspaceEvidenceCapture.NativeScreenshotLease()
        var callbacks: [@MainActor (CGImage?) -> Void] = []
        let firstTask = Task { @MainActor in
            await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
                lease: lease,
                scheduler: { _, _ in },
                request: { callbacks.append($0) }
            )
        }
        for _ in 0..<20 where callbacks.isEmpty { await Task.yield() }
        callbacks[0](nil)
        guard case .returnedFailure = await firstTask.value else {
            return XCTFail("Expected the first callback to release its lease")
        }

        let secondTask = Task { @MainActor in
            await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
                lease: lease,
                scheduler: { _, _ in },
                request: { callbacks.append($0) }
            )
        }
        for _ in 0..<20 where callbacks.count < 2 { await Task.yield() }
        callbacks[0](nil)
        let staleReleaseProbe = await ProductWorkspaceEvidenceCapture.awaitNativeScreenshot(
            lease: lease,
            scheduler: { _, _ in },
            request: { _ in XCTFail("A stale callback must not release the second identity") }
        )
        guard case .busy = staleReleaseProbe else {
            return XCTFail("Expected the exact second lease identity to remain active")
        }

        callbacks[1](nil)
        guard case .returnedFailure = await secondTask.value else {
            return XCTFail("Expected the exact second callback to release the lease")
        }
    }

    func testSupersededNativeAttemptCannotOverwriteNewPresentationDiagnostics() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-superseded-native-stage")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var suspendedWindowID: CGWindowID?
        var suspendedContinuation: CheckedContinuation<Void, Never>?
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in nil },
            nativeCaptureAttempt: { windowID, targetURL, reportStage in
                if suspendedWindowID == nil {
                    suspendedWindowID = windowID
                    reportStage(.shareableContentReturned(targetFound: true))
                    await withCheckedContinuation { suspendedContinuation = $0 }
                    reportStage(.screenshotReturned(success: false))
                    return false
                }
                XCTAssertNotEqual(windowID, suspendedWindowID)
                reportStage(.shareableContentReturned(targetFound: true))
                reportStage(.screenshotReturned(success: true))
                try? Self.onePixelPNG.write(to: targetURL, options: .atomic)
                return true
            }
        )
        let firstPanel = NSPanel()
        let secondPanel = NSPanel()
        firstPanel.orderFrontRegardless()
        secondPanel.orderFrontRegardless()
        defer {
            firstPanel.orderOut(nil)
            secondPanel.orderOut(nil)
        }

        XCTAssertNotNil(capture.startCapture(for: firstPanel, waitsForHUDTrigger: false))
        let firstAttempt = scheduled.removeFirst()
        let firstTask = Task { @MainActor in await firstAttempt() }
        for _ in 0..<20 where suspendedContinuation == nil { await Task.yield() }
        XCTAssertNotNil(suspendedContinuation)

        XCTAssertNotNil(capture.startCapture(for: secondPanel, waitsForHUDTrigger: true))
        XCTAssertEqual(try diagnostic(at: directory)["stage"] as? String, "waiting_for_trigger")
        await scheduled.removeFirst()()
        XCTAssertEqual(try diagnostic(at: directory)["stage"] as? String, "trigger_poll_started")
        try Data().write(
            to: directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName),
            options: .atomic
        )
        await scheduled.removeFirst()()
        var values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, true)

        suspendedContinuation?.resume()
        await firstTask.value

        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, true)
    }

    func testStartupDiagnosticUsesOnlyClosedCaptureStages() throws {
        let directory = temporaryDirectory(prefix: "workspace-capture-startup-stage")
        defer { try? FileManager.default.removeItem(at: directory) }

        ProductWorkspaceEvidenceCapture.recordStartup(
            directory: directory,
            environment: enabledEnvironment
        )
        var values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "waiting_for_trigger")
        XCTAssertEqual(values.count, 1)

        ProductWorkspaceEvidenceCapture.recordStartup(
            directory: directory,
            environment: enabledEnvironment
        )
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "waiting_for_trigger")
        XCTAssertEqual(values.count, 1)
    }

    func testHUDCapturePublishesClosedDiagnosticStagesAtSchedulerBoundaries() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-diagnostic-stages")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var stageSeenInsideAttempt: [String: Any]?
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in nil },
            captureAttempt: { _, targetURL in
                stageSeenInsideAttempt = try? self.diagnostic(at: directory)
                try? Self.onePixelPNG.write(to: targetURL, options: .atomic)
                return true
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 20, y: 20, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNotNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        var values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "waiting_for_trigger")
        XCTAssertEqual(values.count, 1)

        await scheduled.removeFirst()()
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "trigger_poll_started")
        XCTAssertEqual(values.count, 1)

        try Data().write(
            to: directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName),
            options: .atomic
        )
        await scheduled.removeFirst()()
        XCTAssertEqual(stageSeenInsideAttempt?["stage"] as? String, "capture_attempt_started")
        XCTAssertEqual(stageSeenInsideAttempt?["ordinal"] as? Int, 1)
        XCTAssertEqual(stageSeenInsideAttempt?.count, 2)
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, true)
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testProductionMainSchedulerInvokesInjectedCaptureAttempt() async throws {
        let directory = temporaryDirectory(prefix: "workspace-capture-main-scheduler")
        defer { try? FileManager.default.removeItem(at: directory) }
        let attempted = expectation(description: "capture attempt ran on production main scheduler")
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: ProductWorkspaceEvidenceCapture.schedule,
            sourceResolver: { _ in
                ProductWorkspaceEvidenceSource(windowID: 42, isVisible: { true })
            },
            captureAttempt: { _, targetURL in
                XCTAssertTrue(Thread.isMainThread)
                try? Self.onePixelPNG.write(to: targetURL, options: .atomic)
                attempted.fulfill()
                return true
            }
        )

        XCTAssertNotNil(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))
        await fulfillment(of: [attempted], timeout: 2)
        let values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, true)
        XCTAssertEqual(values.count, 2)
    }

    func testShareableContentAndScreenshotDiagnosticsUseClosedContentFreePayloads() throws {
        let directory = temporaryDirectory(prefix: "workspace-capture-closed-native-stages")
        defer { try? FileManager.default.removeItem(at: directory) }

        ProductWorkspaceEvidenceCapture.writeStage(
            .shareableContentReturned,
            directory: directory,
            targetFound: true
        )
        var values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "shareable_content_returned")
        XCTAssertEqual(values["targetFound"] as? Bool, true)
        XCTAssertEqual(values.count, 2)

        ProductWorkspaceEvidenceCapture.writeStage(
            .screenshotReturned,
            directory: directory,
            success: false
        )
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "screenshot_returned")
        XCTAssertEqual(values["success"] as? Bool, false)
        XCTAssertEqual(values.count, 2)

        ProductWorkspaceEvidenceCapture.writeStage(
            .screenshotTimedOut,
            directory: directory
        )
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "screenshot_timed_out")
        XCTAssertEqual(values.count, 1)

        ProductWorkspaceEvidenceCapture.writeStage(
            .screenshotBusy,
            directory: directory
        )
        values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "screenshot_busy")
        XCTAssertEqual(values.count, 1)
    }

    func testCompactHUDPanelUsesTheSameProductOwnedCapturePipeline() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-success")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var capturedWindowID: CGWindowID?
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in nil },
            captureAttempt: { windowID, targetURL in
                capturedWindowID = windowID
                try? Self.onePixelPNG.write(to: targetURL, options: .atomic)
                return true
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 20, y: 20, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        let token = capture.startCapture(for: panel, waitsForHUDTrigger: true)
        XCTAssertNotNil(token)
        XCTAssertEqual(scheduled.count, 1)

        await scheduled.removeFirst()()

        XCTAssertNil(capturedWindowID, "HUD capture must not race ahead of the Diagnostics trigger")
        XCTAssertEqual(scheduled.count, 1)
        try Data().write(
            to: directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName),
            options: .atomic
        )
        await scheduled.removeFirst()()
        XCTAssertTrue(scheduled.isEmpty)

        XCTAssertEqual(capturedWindowID, CGWindowID(panel.windowNumber))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("capture.png").path
        ))
    }

    func testHUDCaptureRemovesStaleTriggerBeforeWaiting() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-stale-trigger")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        try Data().write(to: triggerURL)
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in XCTFail("stale trigger must not capture"); return false }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNotNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: triggerURL.path))
    }

    func testHUDCaptureFailsClosedWhenStaleTriggerCannotBeRemoved() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-stale-unlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        try Data().write(to: triggerURL)
        var scheduleCount = 0
        var attemptCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in scheduleCount += 1 },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in attemptCount += 1; return false },
            triggerRemover: { _ in false }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        XCTAssertEqual(scheduleCount, 0)
        XCTAssertEqual(attemptCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        let values = try diagnostic(at: directory)
        XCTAssertEqual(values["failureCode"] as? String, "hud_capture_trigger_cleanup_failed")
        XCTAssertNil(values["screenRecordingPreflight"], "cleanup failed before permission preflight")
    }

    func testHUDCaptureRejectsDanglingSymlinkTriggerWithoutDeletingIt() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-trigger-symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        try FileManager.default.createSymbolicLink(
            at: triggerURL,
            withDestinationURL: directory.appendingPathComponent("missing")
        )
        var scheduleCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in scheduleCount += 1 },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in XCTFail("unsafe marker must not capture"); return false }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        XCTAssertEqual(scheduleCount, 0)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: triggerURL.path))
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testHUDCaptureRejectsDirectoryTriggerWithoutDeletingIt() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-trigger-directory")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        try FileManager.default.createDirectory(at: triggerURL, withIntermediateDirectories: false)
        var scheduleCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in scheduleCount += 1 },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in XCTFail("unsafe marker must not capture"); return false }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        XCTAssertEqual(scheduleCount, 0)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testHUDCaptureDoesNotDeleteStaleTriggerReplacementAtCleanupBoundary() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-stale-trigger-swap")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        let heldOriginal = directory.appendingPathComponent("held-trigger")
        try Data().write(to: triggerURL, options: .atomic)
        var scheduleCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in scheduleCount += 1 },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in XCTFail("replacement marker must fail closed"); return false },
            beforeTriggerQuarantine: { original in
                try? FileManager.default.moveItem(at: original, to: heldOriginal)
                try? Data().write(to: original, options: .atomic)
            }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        XCTAssertEqual(scheduleCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginal.path))
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testHUDCaptureRestoresReplacementMovedDuringQuarantineRename() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-trigger-rename-swap")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        let heldOriginal = directory.appendingPathComponent("held-trigger")
        try Data().write(to: triggerURL, options: .atomic)
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in XCTFail("replacement must fail before scheduling") },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in XCTFail("replacement must not capture"); return false },
            triggerQuarantineRenamer: { original, quarantine in
                do {
                    try FileManager.default.moveItem(at: original, to: heldOriginal)
                    try Data().write(to: original, options: .atomic)
                    try FileManager.default.moveItem(at: original, to: quarantine)
                    return true
                } catch {
                    return false
                }
            }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginal.path))
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testHUDCaptureRetainsQuarantinedReplacementWhenOriginalIsReoccupied() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-trigger-rename-occupied")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        let heldOriginal = directory.appendingPathComponent("held-trigger")
        var capturedQuarantine: URL?
        try Data().write(to: triggerURL, options: .atomic)
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in XCTFail("replacement must fail before scheduling") },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in XCTFail("replacement must not capture"); return false },
            triggerQuarantineRenamer: { original, quarantine in
                do {
                    capturedQuarantine = quarantine
                    try FileManager.default.moveItem(at: original, to: heldOriginal)
                    try Data().write(to: original, options: .atomic)
                    try FileManager.default.moveItem(at: original, to: quarantine)
                    try Data().write(to: original, options: .atomic)
                    return true
                } catch {
                    return false
                }
            }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(capturedQuarantine).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginal.path))
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testHUDCaptureDoesNotConsumeTriggerReplacementAtCleanupBoundary() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-consume-trigger-swap")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var attemptCount = 0
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        let heldOriginal = directory.appendingPathComponent("held-trigger")
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in attemptCount += 1; return false },
            beforeTriggerQuarantine: { original in
                try? FileManager.default.moveItem(at: original, to: heldOriginal)
                try? Data().write(to: original, options: .atomic)
            }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertNotNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        try Data().write(to: triggerURL, options: .atomic)

        await scheduled.removeFirst()()

        XCTAssertEqual(attemptCount, 0)
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginal.path))
    }

    func testCancelledHUDCaptureDoesNotDeleteTriggerReplacementAtCleanupBoundary() throws {
        let directory = temporaryDirectory(prefix: "hud-capture-cancel-trigger-swap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        let heldOriginal = directory.appendingPathComponent("held-trigger")
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in XCTFail("cancelled capture must not attempt"); return false },
            beforeTriggerQuarantine: { original in
                try? FileManager.default.moveItem(at: original, to: heldOriginal)
                try? Data().write(to: original, options: .atomic)
            }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let token = try XCTUnwrap(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        try Data().write(to: triggerURL, options: .atomic)

        token.cancel()

        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginal.path))
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testCancelledHUDCaptureRemovesTriggerAndNeverAttempts() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-cancel-trigger")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var attemptCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in attemptCount += 1; return false }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let token = try XCTUnwrap(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        try Data().write(to: triggerURL, options: .atomic)

        token.cancel()
        await scheduled.removeFirst()()

        XCTAssertEqual(attemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: triggerURL.path))
    }

    func testHUDCaptureFailsClosedWhenConsumedTriggerCannotBeRemoved() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-consumed-unlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var attemptCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in attemptCount += 1; return false },
            triggerRemover: { _ in false }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        XCTAssertNotNil(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        try Data().write(to: triggerURL, options: .atomic)
        await scheduled.removeFirst()()

        XCTAssertEqual(attemptCount, 0)
        XCTAssertTrue(scheduled.isEmpty, "failed consumption must not poll or capture again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testCancelledHUDCaptureReportsTriggerCleanupFailure() async throws {
        let directory = temporaryDirectory(prefix: "hud-capture-cancel-unlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var attemptCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in nil },
            captureAttempt: { _, _ in attemptCount += 1; return false },
            triggerRemover: { _ in false }
        )
        let panel = NSPanel()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let token = try XCTUnwrap(capture.startCapture(for: panel, waitsForHUDTrigger: true))
        let triggerURL = directory.appendingPathComponent(ProductWorkspaceEvidenceCapture.hudTriggerFileName)
        try Data().write(to: triggerURL, options: .atomic)

        token.cancel()
        await scheduled.removeFirst()()

        XCTAssertEqual(attemptCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: triggerURL.path))
        XCTAssertEqual(
            try diagnostic(at: directory)["failureCode"] as? String,
            "hud_capture_trigger_cleanup_failed"
        )
    }

    func testExplicitFullGUICaptureSettlesThenProducesPNGWithoutPreseededArtifact() async throws {
        let directory = temporaryDirectory(prefix: "workspace-capture-success")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var scheduledDelays: [TimeInterval] = []
        var attemptCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { delay, action in
                scheduledDelays.append(delay)
                scheduled.append(action)
            },
            sourceResolver: { _ in
                ProductWorkspaceEvidenceSource(windowID: 42, isVisible: { true })
            },
            captureAttempt: { _, targetURL in
                attemptCount += 1
                try? Self.onePixelPNG.write(to: targetURL, options: .atomic)
                return true
            }
        )
        let window = EvidenceFixtureWorkspaceWindow(role: .interactive)
        let captureURL = directory.appendingPathComponent("capture.png")

        let token = capture.startCapture(for: window)

        XCTAssertNotNil(token)
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduledDelays, [ProductWorkspaceEvidenceCapture.initialSettleDelay])
        XCTAssertGreaterThan(
            ProductWorkspaceEvidenceCapture.initialSettleDelay,
            StandardWorkspaceMotion().card.duration
        )
        XCTAssertEqual(attemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))

        await scheduled.removeFirst()()

        XCTAssertEqual(attemptCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))
        let values = try diagnostic(at: directory)
        XCTAssertEqual(values["stage"] as? String, "terminal")
        XCTAssertEqual(values["success"] as? Bool, true)
    }

    func testEnabledCaptureSchedulesWithoutScreenRecordingPreflight() throws {
        let directory = temporaryDirectory(prefix: "workspace-capture-no-preflight")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduleCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, _ in scheduleCount += 1 },
            sourceResolver: { _ in
                ProductWorkspaceEvidenceSource(windowID: 42, isVisible: { true })
            },
            captureAttempt: { _, _ in true }
        )

        let token = capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive))

        XCTAssertNotNil(token)
        XCTAssertEqual(scheduleCount, 1)
    }

    func testCaptureRequiresBothExplicitEnvironmentGatesBeforeScheduling() {
        let environments: [[String: String]] = [
            ["CS_DIAG_CAPTURE_MODE": "full"],
            ["CS_DIAG_GUI_SMOKE": "1"],
            ["CS_DIAG_GUI_SMOKE": "1", "CS_DIAG_CAPTURE_MODE": "sanitized"]
        ]
        for environment in environments {
            let capture = ProductWorkspaceEvidenceCapture(
                artifactDirectory: temporaryDirectory(prefix: "workspace-capture-gate"),
                environment: environment,
                scheduler: { _, _ in XCTFail("disabled capture must not schedule") },
                sourceResolver: { _ in nil },
                captureAttempt: { _, _ in false }
            )

            XCTAssertNil(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))
        }
    }

    func testCancelledTokenPreventsSettledAttemptFromWritingCapture() async throws {
        let directory = temporaryDirectory(prefix: "workspace-capture-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var attemptCount = 0
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in
                ProductWorkspaceEvidenceSource(windowID: 42, isVisible: { true })
            },
            captureAttempt: { _, _ in attemptCount += 1; return true }
        )
        let token = try XCTUnwrap(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))

        token.cancel()
        await scheduled.removeFirst()()

        XCTAssertEqual(attemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture.png").path))
    }

    func testCancellationDuringAttemptCannotPublishStaleCapture() async throws {
        let directory = temporaryDirectory(prefix: "workspace-capture-inflight-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        var scheduled: [@MainActor () async -> Void] = []
        var attemptURL: URL?
        var continuation: CheckedContinuation<Bool, Never>?
        let capture = ProductWorkspaceEvidenceCapture(
            artifactDirectory: directory,
            environment: enabledEnvironment,
            scheduler: { _, action in scheduled.append(action) },
            sourceResolver: { _ in
                ProductWorkspaceEvidenceSource(windowID: 42, isVisible: { true })
            },
            captureAttempt: { _, targetURL in
                attemptURL = targetURL
                return await withCheckedContinuation { continuation = $0 }
            }
        )
        let token = try XCTUnwrap(capture.startCapture(for: EvidenceFixtureWorkspaceWindow(role: .interactive)))
        let action = scheduled.removeFirst()
        let task = Task { @MainActor in await action() }
        for _ in 0..<20 where continuation == nil { await Task.yield() }
        let staleURL = try XCTUnwrap(attemptURL)

        token.cancel()
        try Self.onePixelPNG.write(to: staleURL, options: .atomic)
        continuation?.resume(returning: true)
        await task.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    }

    private var enabledEnvironment: [String: String] {
        [
            "CS_DIAG_GUI_SMOKE": "1",
            "CS_DIAG_CAPTURE_MODE": "full"
        ]
    }

    private func temporaryDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func diagnostic(at directory: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("capture-diagnostics.json"))
        ) as? [String: Any])
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}

@MainActor
private final class EvidenceFixtureWorkspaceWindow: WorkspaceWindowControlling {
    let displayID = "display-evidence"
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
