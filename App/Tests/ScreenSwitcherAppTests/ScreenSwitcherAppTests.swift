import Foundation
@preconcurrency import Network
import AppKit
import KeyboardShortcuts
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class ScreenSwitcherAppTests: XCTestCase {
    func testAppTargetExistsAndProvidesMenuBarDelegate() {
        let app = ScreenSwitcherApp()

        XCTAssertNotNil(app)
        XCTAssertNotNil(app.delegate)
    }

    func testMenuBarStatusItemProvidesVisibleControlContent() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ScreenSwitcherApp/AppDelegate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("button?.image") || source.contains("button?.title"),
            "The menu-bar status button must have visible image or title content"
        )
    }

    func testStatusItemConfigurationPreservesNativeAppKitAccessibilityRole() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let nativeRole = try XCTUnwrap(item.button?.accessibilityRole())
        let delegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator()
        )

        delegate.configureStatusItem(item)

        XCTAssertEqual(item.button?.accessibilityRole(), nativeRole)
        XCTAssertEqual(item.button?.accessibilityIdentifier(), "screen-switcher.status-item")
        XCTAssertEqual(item.button?.accessibilityLabel(), "Cozy Stage")
        XCTAssertEqual(item.button?.image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(item.button?.image?.isTemplate, true)
        XCTAssertEqual(item.button?.image?.accessibilityDescription, "Cozy Stage")
    }

    func testSettingsPresenterCanOpenSettingsWindow() {
        let presenter = DefaultSettingsPresenter(
            shortcutStore: ShortcutConfigurationStore(storage: FixtureShortcutStorage())
        )
        let delegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: presenter,
            applicationTerminator: FixtureApplicationTerminator()
        )

        delegate.dispatchMenuAction(identifier: AppDelegate.MenuAction.settings.rawValue)
        NSApp.windows.first(where: { SettingsWindowIdentity.matches($0) })?.close()
        delegate.dispatchMenuAction(identifier: AppDelegate.MenuAction.settings.rawValue)

        XCTAssertNotNil(NSApp.windows.first(where: { SettingsWindowIdentity.matches($0) }))
        NSApp.windows.first(where: { SettingsWindowIdentity.matches($0) })?.close()
    }

    func testRuntimeAdapterStartupPolicyDisablesPackagedProductionAndEnablesExplicitDevRuntime() {
        XCTAssertFalse(RuntimeAdapterStartupPolicy(environment: [:], isPackagedProduction: false).isEnabled)
        XCTAssertFalse(RuntimeAdapterStartupPolicy(environment: [RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1"], isPackagedProduction: true).isEnabled)
        XCTAssertTrue(RuntimeAdapterStartupPolicy(environment: [
            RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1",
            RuntimeAdapterStartupPolicy.dogfoodEnvironmentKey: "1"
        ], isPackagedProduction: true).isEnabled)
        XCTAssertTrue(RuntimeAdapterStartupPolicy(environment: [RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1"], isPackagedProduction: false).isEnabled)
        XCTAssertTrue(RuntimeAdapterStartupPolicy(environment: [
            "SCREEN_SWITCHER_RUNTIME_METADATA_FILE": "/tmp/runtime.json",
            "SCREEN_SWITCHER_RUNTIME_TOKEN": "token-kept-out-of-results"
        ], isPackagedProduction: false).isEnabled)
    }

    func testPackagedProductionClassificationCannotBeBypassedByTestEnvironmentMarker() {
        XCTAssertTrue(RuntimeAdapterStartupPolicy.isPackagedProduction(
            bundleURL: URL(fileURLWithPath: "/tmp/ScreenSwitcher.app"),
            environment: ["XCTestConfigurationFilePath": "attempted-bypass"]
        ))
    }

    func testAppDelegateDoesNotCreateRuntimeAdapterWhenStartupPolicyIsDisabled() {
        var factoryCount = 0
        let delegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            runtimeAdapterStartupPolicy: RuntimeAdapterStartupPolicy(environment: [:], isPackagedProduction: false),
            semanticAdapterServerFactory: {
                factoryCount += 1
                return FixtureSemanticAdapterServer()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(factoryCount, 0)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    func testFirstLaunchDoesNotOpenSettings() {
        let settings = FixtureSettingsPresenter()
        let delegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: settings,
            applicationTerminator: FixtureApplicationTerminator(),
            shortcutStore: ShortcutConfigurationStore(storage: FixtureShortcutStorage())
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(settings.openCount, 0)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    func testAppDelegateStartsAndStopsRuntimeAdapterOnlyWhenExplicitlyEnabled() async {
        let started = expectation(description: "runtime adapter starts")
        let server = FixtureSemanticAdapterServer(onStart: { started.fulfill() })
        let delegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            runtimeAdapterStartupPolicy: RuntimeAdapterStartupPolicy(environment: [RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1"], isPackagedProduction: false),
            semanticAdapterServerFactory: { server }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(server.startCount, 1)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(server.stopCount, 1)
    }

    func testAppDelegateWiresKeyboardShortcutCallbackToPanel() {
        let defaultsName = "screen-switcher-keyboard-shortcut-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let panel = FixturePanelPresenter()
        let shortcutStore = ShortcutConfigurationStore(
            storage: FixtureShortcutStorage(
                shortcut: KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
            ),
            userDefaults: defaults,
            onTrigger: { panel.openSwitcher() }
        )
        let triggerRegistrar = FixtureShortcutTriggerRegistrar()
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            shortcutStore: shortcutStore,
            shortcutTriggerRegistrar: triggerRegistrar
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        triggerRegistrar.invoke()

        XCTAssertEqual(panel.openCount, 1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        triggerRegistrar.invoke()
        XCTAssertEqual(panel.openCount, 1)
    }

    func testDiagnosticsRuntimeDoesNotRegisterConfiguredGlobalOpeners() {
        let shortcutDefaultsName = "screen-switcher-diagnostics-shortcut-\(UUID().uuidString)"
        let commandTabDefaultsName = "screen-switcher-diagnostics-command-tab-\(UUID().uuidString)"
        let shortcutDefaults = UserDefaults(suiteName: shortcutDefaultsName)!
        let commandTabDefaults = UserDefaults(suiteName: commandTabDefaultsName)!
        defer {
            shortcutDefaults.removePersistentDomain(forName: shortcutDefaultsName)
            commandTabDefaults.removePersistentDomain(forName: commandTabDefaultsName)
        }
        let policy = RuntimeAdapterStartupPolicy(
            environment: [RuntimeAdapterStartupPolicy.runtimeEnvironmentKey: "1"],
            isPackagedProduction: false
        )
        let shortcutRegistrar = FixtureShortcutTriggerRegistrar()
        let shortcutDelegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            shortcutStore: ShortcutConfigurationStore(
                storage: FixtureShortcutStorage(),
                userDefaults: shortcutDefaults
            ),
            runtimeAdapterStartupPolicy: policy,
            shortcutTriggerRegistrar: shortcutRegistrar
        )
        let commandTabInterceptor = FixtureCommandTabInterceptor()
        let commandTabStore = ShortcutConfigurationStore(
            storage: FixtureShortcutStorage(),
            userDefaults: commandTabDefaults,
            commandTabInterceptor: commandTabInterceptor
        )
        _ = commandTabStore.setCommandTabTakeoverEnabled(true)
        let commandTabDelegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            shortcutStore: commandTabStore,
            runtimeAdapterStartupPolicy: policy,
            shortcutTriggerRegistrar: FixtureShortcutTriggerRegistrar()
        )

        shortcutDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        commandTabDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertEqual(shortcutRegistrar.registerCount, 0)
        XCTAssertEqual(commandTabInterceptor.startCount, 0)

        shortcutDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        commandTabDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        XCTAssertEqual(shortcutRegistrar.cancelCount, 0)
        XCTAssertEqual(commandTabInterceptor.cancelCount, 0)
    }

    func testDefaultAppDelegateRegistersConfiguredCommandTabTakeover() {
        let defaultsName = "screen-switcher-command-tab-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let interceptor = FixtureCommandTabInterceptor()
        let store = ShortcutConfigurationStore(
            storage: FixtureShortcutStorage(),
            userDefaults: defaults,
            commandTabInterceptor: interceptor
        )
        _ = store.setCommandTabTakeoverEnabled(true)
        let delegate = AppDelegate(
            panelPresenter: FixturePanelPresenter(),
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            shortcutStore: store,
            shortcutTriggerRegistrar: FixtureShortcutTriggerRegistrar()
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertEqual(interceptor.startCount, 1)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        XCTAssertEqual(interceptor.cancelCount, 1)
    }

    func testSemanticModelWiresActionReaderWithoutPresentationDependencies() {
        let model = SwitcherSemanticModel()
        let session = model.makeHeadlessSession()

        XCTAssertTrue(session.runtimeState === model.runtimeState)
        XCTAssertTrue(session.actionService === model.actionService)
        let liveProvider = model.actionService.liveSnapshotProvider as AnyObject?
        XCTAssertTrue(liveProvider === model.runtimeState)
        XCTAssertTrue(
            model.runtimeState.runningAppCatalog.windowReader
                is AppKitWindowMetadataReader
        )
    }

    func testInteractiveProductPolicyExecutesWhileDiagnosticsExecuteRemainsGated() async {
        let presenter = SwitcherSemanticModel()

        XCTAssertEqual(presenter.actionService.executionPolicy.mode, .interactive)
        XCTAssertTrue(presenter.actionService.executionPolicy.isExecuteAllowed)

        let recorder = FixtureActionRecorder()
        let interactive = makeActionService(
            policy: ExecutionPolicy(mode: .interactive, environment: [:]),
            recorder: recorder
        )
        guard case .success(.executed) = await interactive.perform(
            target: displayTarget(hasWindow: false),
            snapshot: actionSnapshot()
        ) else {
            return XCTFail("interactive product action should execute without diagnostics env")
        }
        XCTAssertEqual(recorder.events, ["move"])

        let diagnosticsWithoutFlag = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: [:]),
            recorder: FixtureActionRecorder()
        )
        let denied = await diagnosticsWithoutFlag.perform(
            target: displayTarget(hasWindow: false),
            snapshot: actionSnapshot()
        )
        XCTAssertEqual(denied, .failure(.executeNotAllowed))
    }

    func testDisplayActionDiscoversWindowWhenTargetOmitsWindow() async {
        let recorder = FixtureActionRecorder()
        let discovery = FixtureDisplayWindowDiscovery(window: displayTargetWindow())
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .interactive, environment: [:]),
            recorder: recorder,
            displayWindowDiscovery: discovery
        )

        guard case let .success(.executed(execution)) = await service.perform(
            target: displayTarget(hasWindow: false),
            snapshot: actionSnapshot()
        ) else {
            return XCTFail("expected discovered display window execution")
        }
        XCTAssertTrue(execution.windowActivated)
        XCTAssertEqual(discovery.displayIDs, ["display-1"])
        XCTAssertEqual(recorder.events, ["move", "display-window"])
        XCTAssertEqual(recorder.displayWindowIDs, ["window-1"])
    }

    func testSemanticAdapterAllowsOnlyAuthenticatedAllowlistedCommands() async throws {
        let runtime = FixtureSemanticAdapterRuntime(snapshot: actionSnapshot())
        let server = SemanticAdapterServer(
            runtime: runtime,
            mode: .devTest,
            token: "test-token"
        )

        let snapshot = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"test-token"}"#
        )
        XCTAssertTrue(snapshot.ok)
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.command, "workspace.snapshot")
        XCTAssertNil(snapshot.state?.snapshot)
        XCTAssertNotNil(snapshot.state?.workspace)
        let bogus = await server.handle(
            jsonLine: #"{"command":"bogus","token":"test-token"}"#
        )
        XCTAssertEqual(bogus.error?.code, .unknownCommand)
        let legacy = await server.handle(
            jsonLine: #"{"command":"status","token":"test-token"}"#
        )
        XCTAssertEqual(legacy.error?.code, .unknownCommand)
        let missing = await server.handle(jsonLine: #"{"command":"workspace.snapshot"}"#)
        XCTAssertEqual(missing.error?.code, .missingToken)
        let invalid = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"wrong"}"#
        )
        XCTAssertEqual(invalid.error?.code, .invalidToken)
        let malformed = await server.handle(jsonLine: "not-json")
        XCTAssertEqual(malformed.error?.code, .invalidRequest)
    }

    func testSemanticAdapterCommandsDriveOnlySanitizedRuntimeOperations() async {
        let runtime = FixtureSemanticAdapterRuntime(snapshot: actionSnapshot())
        let server = SemanticAdapterServer(
            runtime: runtime,
            mode: .devTest,
            token: "test-token",
            executionPolicy: ExecutionPolicy(
                mode: .execute,
                environment: ["CS_DIAG_ALLOW_INPUT": "1"]
            )
        )

        let opened = await server.handle(
            jsonLine: #"{"command":"workspace.open","token":"test-token","tab":"switch"}"#
        )
        XCTAssertTrue(opened.ok)
        let keyed = await server.handle(
            jsonLine: #"{"command":"workspace.key","token":"test-token","key":"next_app_page"}"#
        )
        XCTAssertTrue(keyed.ok)
        for gesture in [
            #"{"command":"workspace.gesture","token":"test-token","gesture":{"id":41,"phase":"began","deltaX":0,"deltaY":0,"velocityX":0,"velocityY":0}}"#,
            #"{"command":"workspace.gesture","token":"test-token","gesture":{"id":41,"phase":"changed","deltaX":-640,"deltaY":0,"velocityX":-900,"velocityY":0}}"#,
            #"{"command":"workspace.gesture","token":"test-token","gesture":{"id":41,"phase":"ended","deltaX":-640,"deltaY":0,"velocityX":-900,"velocityY":0}}"#
        ] {
            let response = await server.handle(jsonLine: gesture)
            XCTAssertTrue(response.ok)
        }
        let executed = await server.handle(
            jsonLine: #"{"command":"workspace.executeDryRun","token":"test-token"}"#
        )
        XCTAssertTrue(executed.ok)
        XCTAssertEqual(runtime.executeCount, 0)
        XCTAssertEqual(runtime.dryRunCount, 1)
        let closed = await server.handle(
            jsonLine: #"{"command":"workspace.close","token":"test-token"}"#
        )
        XCTAssertTrue(closed.ok)
        XCTAssertEqual(runtime.closeCount, 1)

        let legacySelection = await server.handle(
            jsonLine: #"{"command":"select","token":"test-token","itemID":"pid-123"}"#
        )
        XCTAssertEqual(legacySelection.error?.code, .unknownCommand)
    }

    func testSemanticAdapterDryRunNeverInvokesRealExecutionOrRequiresInputGate() async {
        let runtime = FixtureSemanticAdapterRuntime(snapshot: actionSnapshot())
        let server = SemanticAdapterServer(
            runtime: runtime,
            mode: .devTest,
            token: "test-token",
            executionPolicy: ExecutionPolicy(mode: .execute, environment: [:])
        )

        _ = await server.handle(
            jsonLine: #"{"command":"workspace.open","token":"test-token","tab":"switch"}"#
        )
        let response = await server.handle(
            jsonLine: #"{"command":"workspace.executeDryRun","token":"test-token"}"#
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(runtime.dryRunCount, 1)
        XCTAssertEqual(runtime.executeCount, 0)

        let legacy = await server.handle(
            jsonLine: #"{"command":"executeSelected","token":"test-token"}"#
        )
        XCTAssertEqual(legacy.error?.code, .unknownCommand)
        XCTAssertEqual(runtime.executeCount, 0)
    }

    func testSemanticAdapterProductionDisabledReturnsStableTypedError() async {
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .productionDisabled,
            token: "test-token"
        )

        let response = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"test-token"}"#
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .productionDisabled)
    }

    func testSemanticAdapterMetadataHasPortAndTokenReferenceWithoutRawToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-switcher-adapter-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("runtime.json")
        let logURL = directory.appendingPathComponent("runtime.log")
        let token = "test-token"
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: token,
            metadataURL: metadataURL,
            logURL: logURL,
            bundleName: "com.example.ScreenSwitcher",
            version: "1.2.3"
        )

        let metadata = try await server.start()
        XCTAssertGreaterThan(metadata.port, 0)
        XCTAssertEqual(metadata.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(metadata.tokenReference.hasPrefix("sha256:"))
        XCTAssertEqual(metadata.tokenReference.count, 71)
        XCTAssertFalse(metadata.tokenReference.contains(token))
        XCTAssertEqual(metadata.bundle, "com.example.ScreenSwitcher")
        XCTAssertEqual(metadata.version, "1.2.3")
        XCTAssertEqual(metadata.logPath, logURL.path)
        let writtenMetadata = try JSONDecoder().decode(
            SemanticAdapterRuntimeMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        XCTAssertEqual(writtenMetadata, metadata)
        XCTAssertFalse(try String(contentsOf: metadataURL, encoding: .utf8).contains(token))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testSemanticAdapterDefaultMetadataPathsContainCurrentPID() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-switcher", isDirectory: true)
        let metadataURL = directory.appendingPathComponent("runtime-\(pid).json")
        let logURL = directory.appendingPathComponent("runtime-\(pid).log")
        try? FileManager.default.removeItem(at: metadataURL)
        try? FileManager.default.removeItem(at: logURL)

        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "default-path-token"
        )
        let metadata = try await server.start()

        XCTAssertEqual(metadata.logPath, logURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testSemanticAdapterLogsOnlyAllowlistCommandsAndNeverRawRequestToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-switcher-log-safety-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("runtime.json")
        let logURL = directory.appendingPathComponent("runtime.log")
        let authToken = "auth-token"
        let rawToken = "raw-command-token"
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: authToken,
            metadataURL: metadataURL,
            logURL: logURL,
            bundleName: "com.example.ScreenSwitcher",
            version: "1.2.3"
        )

        let metadata = try await server.start()
        _ = await server.handle(jsonLine: #"{"command":"raw-command-token","token":"auth-token"}"#)
        _ = await server.handle(jsonLine: #"{"command":"raw-command-token"}"#)
        _ = await server.handle(jsonLine: #"{"command":"workspace.snapshot"}"#)
        _ = await server.handle(
            jsonLine: #"{"command":"workspace.snapshot","token":"auth-token"}"#
        )

        let log = try String(contentsOf: logURL, encoding: .utf8)
        let writtenMetadata = try String(contentsOf: metadataURL, encoding: .utf8)
        XCTAssertFalse(log.contains(rawToken))
        XCTAssertFalse(log.contains(authToken))
        XCTAssertFalse(writtenMetadata.contains(rawToken))
        XCTAssertFalse(writtenMetadata.contains(authToken))
        XCTAssertTrue(log.contains("command=unknown"))
        XCTAssertTrue(log.contains("command=workspace.snapshot"))
        XCTAssertEqual(metadata.tokenReference.count, 71)

        server.stop()
    }

    func testSemanticAdapterServesAuthenticatedJSONLineOverLoopback() async throws {
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "network-token"
        )
        let metadata = try await server.start()
        defer { server.stop() }

        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: metadata.port)!
            ),
            using: .tcp
        )
        let responseData = try await sendAndReceiveJSONLine(
            connection: connection,
            request: Data(
                "{\"command\":\"workspace.snapshot\",\"token\":\"network-token\"}\n".utf8
            )
        )
        let response = try JSONDecoder().decode(SemanticAdapterResponse.self, from: responseData)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.command, "workspace.snapshot")
        XCTAssertFalse(String(decoding: responseData, as: UTF8.self).contains("network-token"))
        connection.cancel()
    }

    func testSemanticAdapterRepeatedReadyPreservesMetadataAndConnections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "screen-switcher-repeated-ready-\(UUID().uuidString)",
                isDirectory: true
            )
        let metadataURL = directory.appendingPathComponent("runtime.json")
        let logURL = directory.appendingPathComponent("runtime.log")
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "repeated-ready-token",
            metadataURL: metadataURL,
            logURL: logURL
        )
        let metadata = try await server.start()
        let originalMetadata = try Data(contentsOf: metadataURL)
        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: metadata.port)!
            ),
            using: .tcp
        )
        try await sendPartial(
            Data("repeated-ready-buffer".utf8),
            on: connection
        )
        for _ in 0..<50 {
            if server.activeConnectionCountForTesting == 1,
               server.totalBufferedByteCountForTesting > 0 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        XCTAssertGreaterThan(server.totalBufferedByteCountForTesting, 0)

        server.triggerListenerStateForTesting(.ready)
        server.triggerListenerStateForTesting(.ready)

        XCTAssertEqual(server.metadata, metadata)
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata)
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        XCTAssertGreaterThan(server.totalBufferedByteCountForTesting, 0)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        connection.cancel()
    }

    func testSemanticAdapterRejectsFragmentedOversizedFrameAndClosesConnection() async throws {
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "oversized-token"
        )
        let metadata = try await server.start()
        defer { server.stop() }

        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: metadata.port)!
            ),
            using: .tcp
        )
        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: SemanticAdapterServer.maxFrameBytes + 1
        )
        let splitIndex = oversized.count / 2
        let result = try await sendFragmentsAndAwaitServerClose(
            connection: connection,
            fragments: [
                Data(oversized[..<splitIndex]),
                Data(oversized[splitIndex...])
            ]
        )

        XCTAssertTrue(result.isComplete)
        let response = try JSONDecoder().decode(SemanticAdapterResponse.self, from: result.data)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .requestTooLarge)
        XCTAssertEqual(server.acceptedConnectionCountForTesting, 1)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
        XCTAssertEqual(server.totalBufferedByteCountForTesting, 0)
        connection.cancel()
    }

    func testSemanticAdapterConnectionStateCleanupRemovesBufferedData() {
        let store = SemanticAdapterConnectionStateStore()
        final class ConnectionMarker {}
        let marker = ConnectionMarker()
        let connectionID = ObjectIdentifier(marker)

        store.register(connectionID)
        store.append(Data("partial".utf8), for: connectionID)
        XCTAssertEqual(store.activeConnectionCount, 1)
        XCTAssertNil(store.popLine(for: connectionID))

        store.cleanup(connectionID)
        XCTAssertEqual(store.activeConnectionCount, 0)
        XCTAssertNil(store.popLine(for: connectionID))

        store.register(connectionID)
        store.append(Data("another\n".utf8), for: connectionID)
        store.cleanupAll()
        XCTAssertEqual(store.activeConnectionCount, 0)
        XCTAssertNil(store.popLine(for: connectionID))
    }

    func testSemanticAdapterStopCancelsStaleQueuedNewConnectionWithoutAcceptingIt() async throws {
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "generation-token"
        )
        _ = try await server.start()
        let generation = server.generationForTesting
        XCTAssertTrue(server.isCurrentGenerationForTesting(generation))
        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: server.metadata!.port)!
            ),
            using: .tcp
        )
        var cancelledConnectionID: ObjectIdentifier?
        server.staleConnectionCancellationObserverForTesting = { cancelledConnectionID = $0 }

        server.triggerNewConnectionForTesting(connection)

        server.stop()
        _ = try await server.start()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(server.isCurrentGenerationForTesting(generation))
        XCTAssertEqual(cancelledConnectionID, ObjectIdentifier(connection))
        XCTAssertEqual(server.acceptedConnectionCountForTesting, 0)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
        XCTAssertEqual(server.totalBufferedByteCountForTesting, 0)
        server.stop()
    }

    func testSemanticAdapterListenerFailureCleansMetadataConnectionsAndBuffers() async throws {
        try await assertListenerTerminationCleansState(
            .failed(.posix(.ECONNABORTED))
        )
    }

    func testSemanticAdapterListenerCancellationCleansMetadataConnectionsAndBuffers() async throws {
        try await assertListenerTerminationCleansState(.cancelled)
    }

    func testSemanticAdapterStartCancellationCleansPendingResourcesAndResumesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "screen-switcher-start-cancellation-\(UUID().uuidString)",
                isDirectory: true
            )
        let metadataURL = directory.appendingPathComponent("runtime.json")
        let logURL = directory.appendingPathComponent("runtime.log")
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "start-cancellation-token",
            metadataURL: metadataURL,
            logURL: logURL
        )
        server.holdStartCompletionForTesting = true
        let startTask = Task { @MainActor () -> Result<SemanticAdapterRuntimeMetadata, Error> in
            do {
                return .success(try await server.start())
            } catch {
                return .failure(error)
            }
        }

        for _ in 0..<50 {
            if server.metadata != nil {
                break
            }
            await Task.yield()
        }
        XCTAssertNotNil(server.metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: server.metadata!.port)!
            ),
            using: .tcp
        )
        try await sendPartial(
            Data("pending-start-with-buffer".utf8),
            on: connection
        )
        for _ in 0..<50 {
            if server.activeConnectionCountForTesting == 1,
               server.totalBufferedByteCountForTesting > 0 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        XCTAssertGreaterThan(server.totalBufferedByteCountForTesting, 0)

        startTask.cancel()
        let result = await startTask.value
        guard case let .failure(error) = result else {
            return XCTFail("cancelled start should not report ready")
        }
        XCTAssertEqual(error as? SemanticAdapterServerError, .startCancelled)
        XCTAssertNil(server.metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
        XCTAssertEqual(server.totalBufferedByteCountForTesting, 0)

        server.triggerListenerStateForTesting(.failed(.posix(.ECONNABORTED)))
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
        XCTAssertEqual(server.totalBufferedByteCountForTesting, 0)
        server.stop()
        connection.cancel()
    }

    func testSemanticAdapterMetadataWriteFailureIsTypedAndCleansOwnedPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-switcher-metadata-failure-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("runtime.json")
        let writeError = NSError(domain: "MetadataWriteFailure", code: 1)
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "metadata-failure-token",
            metadataURL: metadataURL,
            metadataWriter: { _, url in
                try Data("partial".utf8).write(to: url)
                throw writeError
            }
        )

        do {
            _ = try await server.start()
            XCTFail("metadata write failure should prevent readiness")
        } catch let error as SemanticAdapterServerError {
            XCTAssertEqual(error, .metadataWriteFailed)
        }
        XCTAssertNil(server.metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        server.stop()
    }

    func testSemanticAdapterMetadataWriteFailurePreservesPreExistingSentinel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-switcher-metadata-sentinel-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("runtime.json")
        let sentinel = Data("owned-by-previous-run".utf8)
        try sentinel.write(to: metadataURL)
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "metadata-sentinel-token",
            metadataURL: metadataURL
        )

        do {
            _ = try await server.start()
            XCTFail("metadata write failure should prevent readiness")
        } catch let error as SemanticAdapterServerError {
            XCTAssertEqual(error, .metadataWriteFailed)
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), sentinel)
        server.stop()
    }

    private func sendAndReceiveJSONLine(
        connection: NWConnection,
        request: Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: request,
                        completion: .contentProcessed { error in
                            if let error {
                                finish(.failure(error))
                                return
                            }
                            connection.receive(
                                minimumIncompleteLength: 1,
                                maximumLength: 64 * 1024
                            ) { data, _, _, error in
                                if let error {
                                    finish(.failure(error))
                                } else if let data {
                                    finish(.success(data))
                                } else {
                                    finish(.failure(SemanticAdapterServerError.listenerFailed))
                                }
                            }
                        }
                    )
                case let .failed(error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(SemanticAdapterServerError.listenerFailed))
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func assertListenerTerminationCleansState(
        _ state: NWListener.State
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "screen-switcher-listener-termination-\(UUID().uuidString)",
                isDirectory: true
            )
        let metadataURL = directory.appendingPathComponent("runtime.json")
        let logURL = directory.appendingPathComponent("runtime.log")
        let server = SemanticAdapterServer(
            runtime: FixtureSemanticAdapterRuntime(snapshot: actionSnapshot()),
            mode: .devTest,
            token: "listener-termination-token",
            metadataURL: metadataURL,
            logURL: logURL
        )
        let metadata = try await server.start()
        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: metadata.port)!
            ),
            using: .tcp
        )
        try await sendPartial(
            Data("partial-without-newline".utf8),
            on: connection
        )
        for _ in 0..<50 {
            if server.activeConnectionCountForTesting == 1,
               server.totalBufferedByteCountForTesting > 0 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        XCTAssertGreaterThan(server.totalBufferedByteCountForTesting, 0)
        XCTAssertNotNil(server.metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        server.triggerListenerStateForTesting(state)

        XCTAssertNil(server.metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
        XCTAssertEqual(server.totalBufferedByteCountForTesting, 0)
        server.stop()
        connection.cancel()
    }

    private func sendPartial(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: data,
                        completion: .contentProcessed { error in
                            if let error {
                                finish(.failure(error))
                            } else {
                                finish(.success(()))
                            }
                        }
                    )
                case let .failed(error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(SemanticAdapterServerError.listenerFailed))
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func sendFragmentsAndAwaitServerClose(
        connection: NWConnection,
        fragments: [Data]
    ) async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<(data: Data, isComplete: Bool), Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            var responseData = Data()

            func receiveUntilClose() {
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 64 * 1024
                ) { data, _, isComplete, error in
                    if let data {
                        responseData.append(data)
                    }
                    if isComplete {
                        finish(.success((data: responseData, isComplete: true)))
                    } else if let error {
                        finish(.failure(error))
                    } else {
                        receiveUntilClose()
                    }
                }
            }

            func sendNext(_ index: Int) {
                guard index < fragments.count else {
                    receiveUntilClose()
                    return
                }
                connection.send(
                    content: fragments[index],
                    completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                        } else {
                            sendNext(index + 1)
                        }
                    }
                )
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sendNext(0)
                case let .failed(error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(SemanticAdapterServerError.listenerFailed))
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    func testAppKitWindowMetadataReaderReturnsNilWhenPermissionIsUnavailable() {
        let reader = AppKitWindowMetadataReader(
            permissionService: PermissionService(
                accessibilityChecker: FixtureAccessibilityChecker(trusted: false),
                settingsOpener: FixturePermissionSettingsOpener()
            )
        )

        XCTAssertNil(reader.mostRecentWindow(for: "com.example.editor"))
    }

    func testFirstRunShortcutRequiresConfigurationAndRejectsUnmodifiedKey() {
        let storage = FixtureShortcutStorage()
        let store = ShortcutConfigurationStore(storage: storage)

        XCTAssertTrue(store.requiresFirstRun)
        XCTAssertEqual(
            store.capture(ShortcutChord(modifiers: [], key: "K")),
            .invalid(.requiresModifier)
        )
        XCTAssertNil(store.configuration.chord)
        XCTAssertNil(storage.shortcut)
    }

    func testValidShortcutRegistrationMakesFirstRunReady() {
        let storage = FixtureShortcutStorage()
        let store = ShortcutConfigurationStore(storage: storage)
        let chord = ShortcutChord(modifiers: [.command, .shift], key: "K")

        XCTAssertEqual(store.capture(chord), .registered(chord))
        XCTAssertFalse(store.requiresFirstRun)
        XCTAssertEqual(store.configuration.chord, chord)
        XCTAssertEqual(storage.shortcut, KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift]))
    }

    func testShortcutReplacementUpdatesCanonicalKeyboardShortcutsState() {
        let storage = FixtureShortcutStorage()
        let first = ShortcutChord(modifiers: [.command], key: "K")
        let store = ShortcutConfigurationStore(storage: storage)
        XCTAssertEqual(store.capture(first), .registered(first))

        let replacement = ShortcutChord(modifiers: [.command], key: "L")
        XCTAssertEqual(store.capture(replacement), .registered(replacement))
        XCTAssertEqual(store.configuration.chord, replacement)
        XCTAssertEqual(storage.shortcut, KeyboardShortcuts.Shortcut(.l, modifiers: [.command]))

        let restarted = ShortcutConfigurationStore(storage: storage)
        XCTAssertFalse(restarted.requiresFirstRun)
        XCTAssertEqual(restarted.configuration.shortcut, storage.shortcut)
    }

    func testKeyboardShortcutsStoragePersistsAndRestoresAcrossStoreInstances() {
        let name = KeyboardShortcuts.Name("screen-switcher-storage-test-\(UUID().uuidString)")
        let storage = KeyboardShortcutsStorage(name: name)
        let original = storage.shortcut
        defer { storage.setShortcut(original) }

        let suiteName = "screen-switcher-storage-test-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
        storage.setShortcut(expected)

        let firstStore = ShortcutConfigurationStore(storage: storage, userDefaults: defaults)
        let restartedStorage = KeyboardShortcutsStorage(name: name)
        let restartedStore = ShortcutConfigurationStore(storage: restartedStorage, userDefaults: defaults)

        XCTAssertEqual(firstStore.configuration.shortcut, expected)
        XCTAssertEqual(restartedStore.configuration.shortcut, expected)
        XCTAssertFalse(restartedStore.requiresFirstRun)
    }

    func testCanonicalConfigurationRetainsSpecialKeyboardShortcuts() {
        let specialShortcut = KeyboardShortcuts.Shortcut(.f1, modifiers: [.command, .option])
        let storage = FixtureShortcutStorage(shortcut: specialShortcut)
        let store = ShortcutConfigurationStore(storage: storage)

        XCTAssertEqual(store.configuration.shortcut, specialShortcut)
        XCTAssertFalse(store.requiresFirstRun)
    }

    func testReservedShortcutIsRejected() {
        let store = ShortcutConfigurationStore(storage: FixtureShortcutStorage())

        XCTAssertEqual(
            store.capture(ShortcutChord(modifiers: [.command], key: "escape")),
            .invalid(.reserved)
        )
    }

    func testMenuContainsOnlySemanticActionsAndOpenSwitcherDispatchesExactlyOnceWhenDeferredActionRuns() {
        let panel = FixturePanelPresenter()
        let settings = FixtureSettingsPresenter()
        var deferredActions: [@MainActor () -> Void] = []
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: settings,
            applicationTerminator: FixtureApplicationTerminator(),
            deferredMainActionScheduler: { action in
                deferredActions.append(action)
            }
        )

        XCTAssertEqual(
            Set(delegate.menuItems.compactMap { $0.identifier?.rawValue }),
            Set(["menu.open-switcher", "menu.settings", "menu.quit"])
        )
        delegate.dispatchMenuAction(identifier: "menu.open-switcher")

        XCTAssertEqual(panel.openCount, 0)
        XCTAssertEqual(deferredActions.count, 1)
        deferredActions.removeFirst()()
        XCTAssertEqual(panel.openCount, 1)
        XCTAssertTrue(deferredActions.isEmpty)
        XCTAssertEqual(settings.openCount, 0)
    }

    func testTrackedOpenSchedulesOnceWithoutWaitingForMenuDidCloseAndDoesNotReplayIntoSettings() {
        let panel = FixturePanelPresenter()
        let settings = FixtureSettingsPresenter()
        var cancelledMenus: [NSMenu] = []
        var deferredActions: [@MainActor () -> Void] = []
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: settings,
            applicationTerminator: FixtureApplicationTerminator(),
            deferredMainActionScheduler: { deferredActions.append($0) },
            menuTrackingCanceller: { cancelledMenus.append($0) }
        )

        delegate.menuWillOpen(delegate.menu)
        delegate.dispatchMenuAction(identifier: AppDelegate.MenuAction.openSwitcher.rawValue)

        XCTAssertEqual(cancelledMenus.count, 1)
        XCTAssertTrue(cancelledMenus.first === delegate.menu)
        XCTAssertEqual(deferredActions.count, 1, "Open must not depend on a future menuDidClose callback")
        XCTAssertEqual(panel.openCount, 0, "Opening must remain asynchronous while menu tracking unwinds")

        delegate.menuWillOpen(delegate.menu)
        delegate.menuDidClose(delegate.menu)
        delegate.dispatchMenuAction(identifier: AppDelegate.MenuAction.settings.rawValue)

        XCTAssertEqual(deferredActions.count, 1, "A later menu lifecycle must not replay the prior Open")
        XCTAssertEqual(settings.openCount, 1)
        deferredActions.removeFirst()()
        XCTAssertEqual(panel.openCount, 1)
    }

    func testTrackedOpenThenMenuDidCloseSchedulesExactlyOnce() {
        let panel = FixturePanelPresenter()
        var deferredActions: [@MainActor () -> Void] = []
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            deferredMainActionScheduler: { deferredActions.append($0) },
            menuTrackingCanceller: { _ in }
        )

        delegate.menuWillOpen(delegate.menu)
        delegate.dispatchMenuAction(identifier: AppDelegate.MenuAction.openSwitcher.rawValue)
        delegate.menuDidClose(delegate.menu)

        XCTAssertEqual(deferredActions.count, 1)
        deferredActions.removeFirst()()
        XCTAssertEqual(panel.openCount, 1)
    }

    func testMenuDidCloseThenOpenActionSchedulesExactlyOnce() {
        let panel = FixturePanelPresenter()
        var cancelledMenuCount = 0
        var deferredActions: [@MainActor () -> Void] = []
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            deferredMainActionScheduler: { deferredActions.append($0) },
            menuTrackingCanceller: { _ in cancelledMenuCount += 1 }
        )

        delegate.menuWillOpen(delegate.menu)
        delegate.menuDidClose(delegate.menu)
        delegate.dispatchMenuAction(identifier: AppDelegate.MenuAction.openSwitcher.rawValue)

        XCTAssertEqual(cancelledMenuCount, 0)
        XCTAssertEqual(deferredActions.count, 1)
        deferredActions.removeFirst()()
        XCTAssertEqual(panel.openCount, 1)
    }

    func testDeferredMenuOpenDoesNotRunAfterApplicationWillTerminate() {
        let panel = FixturePanelPresenter()
        var deferredActions: [@MainActor () -> Void] = []
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            deferredMainActionScheduler: { deferredActions.append($0) }
        )

        delegate.dispatchMenuAction(identifier: "menu.open-switcher")
        XCTAssertEqual(deferredActions.count, 1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        deferredActions.removeFirst()()

        XCTAssertEqual(panel.openCount, 0)
        XCTAssertEqual(panel.closeCount, 1)
    }

    func testPendingTrackedMenuOpenIsDiscardedWhenApplicationTerminatesBeforeMenuCloses() {
        let panel = FixturePanelPresenter()
        var deferredActions: [@MainActor () -> Void] = []
        let delegate = AppDelegate(
            panelPresenter: panel,
            settingsPresenter: FixtureSettingsPresenter(),
            applicationTerminator: FixtureApplicationTerminator(),
            deferredMainActionScheduler: { deferredActions.append($0) }
        )

        delegate.menuWillOpen(delegate.menu)
        delegate.dispatchMenuAction(identifier: AppDelegate.MenuAction.openSwitcher.rawValue)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate.menuDidClose(delegate.menu)

        XCTAssertEqual(deferredActions.count, 1, "The action is scheduled before termination")
        deferredActions.removeFirst()()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.openCount, 0)
        XCTAssertEqual(panel.closeCount, 1, "Only termination cleanup should reach the presenter")
    }

    func testSettingsLaunchAtLoginIsExplicitAndPermissionFallbackIsVisible() throws {
        let launch = FixtureLaunchAtLoginManager(enabled: false)
        let permissions = PermissionService(
            accessibilityChecker: FixtureAccessibilityChecker(trusted: true),
            settingsOpener: FixturePermissionSettingsOpener()
        )
        let settings = SettingsModel(
            permissionService: permissions,
            launchAtLogin: launch,
            shortcutStore: ShortcutConfigurationStore(storage: FixtureShortcutStorage()),
            version: "1.0"
        )

        XCTAssertFalse(settings.launchAtLoginEnabled)
        XCTAssertTrue(launch.events.isEmpty)
        XCTAssertTrue(settings.setLaunchAtLogin(true))
        XCTAssertTrue(settings.launchAtLoginEnabled)
        XCTAssertEqual(launch.events, [.register])
        XCTAssertTrue(settings.setLaunchAtLogin(false))
        XCTAssertFalse(settings.launchAtLoginEnabled)
        XCTAssertEqual(launch.events, [.register, .unregister])
    }

    func testShortcutStartupRequiresValidConfigurationAndDispatchesRegisteredChord() {
        let storage = FixtureShortcutStorage()
        var openCount = 0
        let firstRun = ShortcutConfigurationStore(
            storage: storage,
            onTrigger: { openCount += 1 }
        )
        XCTAssertTrue(firstRun.requiresFirstRun)

        let chord = ShortcutChord(modifiers: [.command, .shift], key: "K")
        XCTAssertEqual(firstRun.capture(chord), .registered(chord))
        XCTAssertFalse(firstRun.requiresFirstRun)
        let triggerRegistrar = FixtureShortcutTriggerRegistrar()
        firstRun.registerGlobalTrigger(using: triggerRegistrar)
        triggerRegistrar.invoke()
        XCTAssertEqual(openCount, 1)

        let startupStorage = FixtureShortcutStorage(
            shortcut: KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
        )
        let startup = ShortcutConfigurationStore(
            storage: startupStorage,
            onTrigger: { openCount += 1 }
        )
        XCTAssertFalse(startup.requiresFirstRun)
        let startupTriggerRegistrar = FixtureShortcutTriggerRegistrar()
        startup.registerGlobalTrigger(using: startupTriggerRegistrar)
        startupTriggerRegistrar.invoke()
        XCTAssertEqual(openCount, 2)
    }

    func testRepeatedGlobalShortcutRegistrationReplacesPreviousCallbackAndCanBeCancelled() {
        let registrar = FixtureShortcutTriggerRegistrar()
        var callbackCount = 0
        let store = ShortcutConfigurationStore(
            storage: FixtureShortcutStorage(shortcut: KeyboardShortcuts.Shortcut(.k, modifiers: [.command])),
            onTrigger: { callbackCount += 1 }
        )

        store.registerGlobalTrigger(using: registrar)
        store.registerGlobalTrigger(using: registrar)
        registrar.invoke()
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(registrar.cancelCount, 1)

        store.unregisterGlobalTrigger()
        registrar.invoke()
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(registrar.cancelCount, 2)
    }

    func testSettingsModelPublishesShortcutWithoutWritingCanonicalStorageAgain() {
        let initial = KeyboardShortcuts.Shortcut(.k, modifiers: [.command])
        let next = KeyboardShortcuts.Shortcut(.l, modifiers: [.command, .shift])
        let storage = FixtureShortcutStorage(shortcut: initial)
        let model = SettingsModel(
            permissionService: PermissionService(
                accessibilityChecker: FixtureAccessibilityChecker(trusted: true),
                settingsOpener: FixturePermissionSettingsOpener()
            ),
            launchAtLogin: FixtureLaunchAtLoginManager(enabled: false),
            shortcutStore: ShortcutConfigurationStore(storage: storage)
        )
        storage.setCount = 0

        model.updateShortcut(next)

        XCTAssertEqual(model.shortcut, next)
        XCTAssertEqual(storage.shortcut, initial)
        XCTAssertEqual(storage.setCount, 0)
    }

    func testShortcutMigrationCopiesLegacyValuesOnceWithoutOverwritingCanonicalValue() {
        let suiteName = "screen-switcher-shortcut-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ShortcutChord(modifiers: [.command], key: "K")
        defaults.set(first.key, forKey: "screen-switcher.shortcut.key")
        defaults.set(Int(first.modifiers.rawValue), forKey: "screen-switcher.shortcut.modifiers")

        let migratedStorage = FixtureShortcutStorage()
        let migrated = ShortcutConfigurationStore(storage: migratedStorage, userDefaults: defaults)
        XCTAssertEqual(migrated.configuration.chord, first)
        XCTAssertTrue(defaults.bool(forKey: "screen-switcher.shortcut.keyboard-shortcuts-migrated"))

        let existingSuiteName = "screen-switcher-shortcut-existing-\(UUID().uuidString)"
        let existingDefaults = UserDefaults(suiteName: existingSuiteName)!
        defer { existingDefaults.removePersistentDomain(forName: existingSuiteName) }
        existingDefaults.set(first.key, forKey: "screen-switcher.shortcut.key")
        existingDefaults.set(Int(first.modifiers.rawValue), forKey: "screen-switcher.shortcut.modifiers")
        let existing = KeyboardShortcuts.Shortcut(.l, modifiers: [.command, .shift])
        let existingStorage = FixtureShortcutStorage(shortcut: existing)
        let existingStore = ShortcutConfigurationStore(storage: existingStorage, userDefaults: existingDefaults)
        XCTAssertEqual(existingStore.configuration.shortcut, existing)
    }

    func testShortcutMigrationMarkerPreventsLaterLegacyChangesFromBeingApplied() {
        let suiteName = "screen-switcher-shortcut-migration-marker-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "screen-switcher.shortcut.keyboard-shortcuts-migrated")
        defaults.set("K", forKey: "screen-switcher.shortcut.key")
        defaults.set(Int(ShortcutModifiers.command.rawValue), forKey: "screen-switcher.shortcut.modifiers")

        let storage = FixtureShortcutStorage()
        let firstStore = ShortcutConfigurationStore(storage: storage, userDefaults: defaults)
        XCTAssertTrue(firstStore.requiresFirstRun)
        XCTAssertNil(storage.shortcut)

        defaults.set("L", forKey: "screen-switcher.shortcut.key")
        let secondStore = ShortcutConfigurationStore(storage: storage, userDefaults: defaults)
        XCTAssertTrue(secondStore.requiresFirstRun)
        XCTAssertNil(storage.shortcut)
        XCTAssertTrue(defaults.bool(forKey: "screen-switcher.shortcut.keyboard-shortcuts-migrated"))
    }

    func testSettingsShortcutSourceUsesKeyboardShortcutsRecorderContract() throws {
        let settingsSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ScreenSwitcherApp/SettingsView.swift")
        let source = try String(contentsOf: settingsSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("KeyboardShortcuts.Recorder("))
        XCTAssertTrue(source.contains("for: shortcut.name"))
        // Phase 1A: settings renders exactly ONE shortcut row (openHUD) and
        // must no longer reference the collapsed switch/agents/focus rows.
        XCTAssertTrue(source.contains("shortcutRecorder(.openHUD)"))
        XCTAssertFalse(source.contains("shortcutRecorder(.switch"))
        XCTAssertFalse(source.contains("shortcutRecorder(.agents"))
        XCTAssertFalse(source.contains("shortcutRecorder(.focus"))
        XCTAssertTrue(source.contains("shortcutValidationMessage(for: .openHUD)"))
        XCTAssertFalse(source.contains("ShortcutCaptureNSView"))
        XCTAssertFalse(source.contains("NSEvent.addGlobalMonitorForEvents"))
        XCTAssertTrue(source.contains("model.requestAndOpenAccessibilitySettings()"))
        XCTAssertFalse(source.contains("model.requestAndOpenScreenRecordingSettings()"))
        XCTAssertTrue(source.contains("NSApplication.didBecomeActiveNotification"))
        XCTAssertTrue(source.contains("NSWindow.didBecomeKeyNotification"))
        XCTAssertTrue(source.contains("SettingsWindowIdentity.matches(window)"))
        XCTAssertTrue(source.contains("settingsWindow.identifier = SettingsWindowIdentity.identifier"))
        XCTAssertTrue(source.contains(".alert("))
        XCTAssertFalse(source.contains("try? model.requestAndOpen"))
    }

    func testSystemSettingsOpenerUsesStablePrivacyAnchors() {
        XCTAssertEqual(
            SystemSettingsOpener.url(for: .accessibility)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testSettingsModelRefreshesPermissionStateAfterReturningFromSettings() {
        let accessibility = FixtureAccessibilityChecker(trusted: false)
        let model = SettingsModel(
            permissionService: PermissionService(
                accessibilityChecker: accessibility,
                settingsOpener: FixturePermissionSettingsOpener()
            ),
            launchAtLogin: FixtureLaunchAtLoginManager(enabled: false),
            shortcutStore: ShortcutConfigurationStore(storage: FixtureShortcutStorage())
        )

        accessibility.trusted = true
        model.refreshPermissionStatus()

        XCTAssertEqual(model.accessibilityStatus, .granted)
    }

    func testSettingsWindowIdentityFiltersKeyWindowRefreshesToSettingsWindow() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        settingsWindow.identifier = SettingsWindowIdentity.identifier
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(SettingsWindowIdentity.matches(settingsWindow))
        XCTAssertFalse(SettingsWindowIdentity.matches(otherWindow))
    }

    func testSettingsOpensAccessibilitySettings() throws {
        let opener = FixturePermissionSettingsOpener()
        let model = SettingsModel(
            permissionService: PermissionService(
                accessibilityChecker: FixtureAccessibilityChecker(trusted: false),
                settingsOpener: opener
            ),
            launchAtLogin: FixtureLaunchAtLoginManager(enabled: false),
            shortcutStore: ShortcutConfigurationStore(storage: FixtureShortcutStorage())
        )

        XCTAssertEqual(model.accessibilityStatus, .missing)
        try model.openAccessibilitySettings()
        XCTAssertEqual(opener.opened, [.accessibility])
    }

    func testDisplayCatalogSortsSpatiallyUsesIDTieBreakAndMarksCurrentDisplay() {
        let discovery = FixtureDisplayDiscovery(displays: [
            display("display-right", x: 300, y: 0),
            display("display-tie-b", x: 100, y: 200),
            display("display-tie-a", x: 100, y: 0),
            display("display-left", x: -100, y: 0)
        ])
        let catalog = DisplayCatalog(
            discovery: discovery,
            pointerLocation: FixturePointerLocationProvider(
                location: PointSnapshot(x: 150, y: 250)
            )
        )

        let snapshot = catalog.snapshot()

        XCTAssertEqual(snapshot.map(\.id), [
            "display-left",
            "display-tie-a",
            "display-tie-b",
            "display-right"
        ])
        XCTAssertEqual(snapshot.filter { $0.isCurrent }.map(\.id), ["display-tie-b"])
    }

    func testCoreGraphicsHardwareKindProviderUsesRealDisplayIDShape() {
        let provider = CGDisplayHardwareKindProvider(isBuiltin: { displayID in
            displayID == 42
        })

        XCTAssertEqual(provider.hardwareKind(forDisplayID: "display-42"), .builtIn)
        XCTAssertEqual(provider.hardwareKind(forDisplayID: "display-99"), .external)
        XCTAssertEqual(provider.hardwareKind(forDisplayID: "display-built-in"), .unknown)
        XCTAssertEqual(provider.hardwareKind(forDisplayID: "display-42-extra"), .unknown)
    }

    func testDisplayCatalogPropagatesInjectedHardwareKindWithoutIDGuessing() {
        let discovery = FixtureDisplayDiscovery(displays: [
            DisplaySource(
                id: "display-73",
                frame: try! RectDescriptor(x: 0, y: 0, width: 100, height: 100),
                hardwareKind: .builtIn
            ),
            DisplaySource(
                id: "display-84",
                frame: try! RectDescriptor(x: 100, y: 0, width: 100, height: 100),
                hardwareKind: .external
            )
        ])

        let snapshot = DisplayCatalog(
            discovery: discovery,
            pointerLocation: FixturePointerLocationProvider(location: nil)
        ).snapshot()

        XCTAssertEqual(snapshot.map(\.hardwareKind), [.builtIn, .external])
    }

    func testDisplayDescriptorCodableDefaultsOldJSONAndEmitsStableHardwareKind() throws {
        let legacy = #"{"id":"display-42","frame":{"x":0,"y":0,"width":100,"height":100},"isCurrent":true}"#
            .data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(DisplayDescriptor.self, from: legacy)
        XCTAssertEqual(decodedLegacy.hardwareKind, .unknown)

        let current = DisplayDescriptor(
            id: "display-42",
            frame: try RectDescriptor(x: 0, y: 0, width: 100, height: 100),
            isCurrent: true,
            hardwareKind: .builtIn
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        XCTAssertEqual(object["hardwareKind"] as? String, "built-in")
        XCTAssertEqual(try JSONDecoder().decode(DisplayDescriptor.self, from: JSONEncoder().encode(current)), current)
    }

    func testDisplayFramesUseHalfOpenBoundariesAndMissingPointerHasNoCurrentDisplay() {
        let discovery = FixtureDisplayDiscovery(displays: [
            display("display-left", x: 0, y: 0),
            display("display-right", x: 100, y: 0)
        ])

        let boundarySnapshot = DisplayCatalog(
            discovery: discovery,
            pointerLocation: FixturePointerLocationProvider(
                location: PointSnapshot(x: 100, y: 50)
            )
        ).snapshot()
        let ordinaryPointSnapshot = DisplayCatalog(
            discovery: discovery,
            pointerLocation: FixturePointerLocationProvider(
                location: PointSnapshot(x: 50, y: 50)
            )
        ).snapshot()
        let missingPointerSnapshot = DisplayCatalog(
            discovery: discovery,
            pointerLocation: FixturePointerLocationProvider(location: nil)
        ).snapshot()

        XCTAssertEqual(
            boundarySnapshot.filter { $0.isCurrent }.map(\.id),
            ["display-right"]
        )
        XCTAssertEqual(
            ordinaryPointSnapshot.filter { $0.isCurrent }.map(\.id),
            ["display-left"]
        )
        XCTAssertTrue(missingPointerSnapshot.allSatisfy { !$0.isCurrent })
    }

    func testDisplayCatalogFiltersInvalidGeometry() throws {
        let validFrame = try XCTUnwrap(
            try? RectDescriptor(x: 0, y: 0, width: 100, height: 100)
        )
        let discovery = FixtureDisplayDiscovery(displays: [
            DisplaySource(
                id: "display-nan",
                frame: RectDescriptor(uncheckedX: .nan, y: 0, width: 100, height: 100)
            ),
            DisplaySource(
                id: "display-negative",
                frame: RectDescriptor(uncheckedX: 100, y: 0, width: -1, height: 100)
            ),
            DisplaySource(id: "display-valid", frame: validFrame)
        ])

        let snapshot = DisplayCatalog(
            discovery: discovery,
            pointerLocation: FixturePointerLocationProvider(location: nil)
        ).snapshot()

        XCTAssertEqual(snapshot.map(\.id), ["display-valid"])
    }

    func testRectDescriptorRejectsNonFiniteNonPositiveAndOverflowingFrames() {
        XCTAssertThrowsError(try RectDescriptor(x: .nan, y: 0, width: 100, height: 100)) { error in
            XCTAssertEqual(error as? RectDescriptorError, .nonFiniteCoordinateOrSize)
        }
        XCTAssertThrowsError(try RectDescriptor(x: 0, y: .infinity, width: 100, height: 100)) { error in
            XCTAssertEqual(error as? RectDescriptorError, .nonFiniteCoordinateOrSize)
        }
        XCTAssertThrowsError(try RectDescriptor(x: 0, y: 0, width: 0, height: 100)) { error in
            XCTAssertEqual(error as? RectDescriptorError, .nonPositiveSize)
        }
        XCTAssertThrowsError(try RectDescriptor(x: 0, y: 0, width: -1, height: 100)) { error in
            XCTAssertEqual(error as? RectDescriptorError, .nonPositiveSize)
        }
        XCTAssertThrowsError(
            try RectDescriptor(
                x: Double.greatestFiniteMagnitude,
                y: 0,
                width: Double.greatestFiniteMagnitude,
                height: 100
            )
        ) { error in
            XCTAssertEqual(error as? RectDescriptorError, .overflowingMaxX)
        }
        XCTAssertThrowsError(
            try RectDescriptor(
                x: 0,
                y: Double.greatestFiniteMagnitude,
                width: 100,
                height: Double.greatestFiniteMagnitude
            )
        ) { error in
            XCTAssertEqual(error as? RectDescriptorError, .overflowingMaxY)
        }
    }

    func testSnapshotEncodingRejectsUncheckedInvalidDisplayAndWindowGeometry() throws {
        let invalidFrame = RectDescriptor(
            uncheckedX: 0,
            y: 0,
            width: .infinity,
            height: 100
        )
        let invalidWindow = WindowDescriptor(
            id: "window-invalid",
            frame: invalidFrame,
            isOnScreen: true,
            isMain: true
        )
        let snapshot = SwitcherSnapshot(
            displays: [
                DisplayDescriptor(id: "display-invalid", frame: invalidFrame, isCurrent: false)
            ],
            runningApps: [
                RunningAppDescriptor(
                    id: "com.example.editor",
                    displayName: "Editor",
                    mostRecentWindow: invalidWindow
                )
            ],
            pointerLocation: nil,
            frontmostAppID: nil
        )

        XCTAssertThrowsError(try snapshot.encodedJSON()) { error in
            XCTAssertEqual(error as? RectDescriptorError, .nonFiniteCoordinateOrSize)
        }
    }

    func testSnapshotJSONHasAnExplicitSanitizedFieldAllowlist() throws {
        let frame = try XCTUnwrap(try? RectDescriptor(x: 1, y: 2, width: 300, height: 200))
        let window = WindowDescriptor(id: "window-1", frame: frame, isOnScreen: true, isMain: true)
        let snapshot = SwitcherSnapshot(
            displays: [DisplayDescriptor(id: "display-1", frame: frame, isCurrent: true)],
            runningApps: [
                RunningAppDescriptor(
                    id: "com.example.editor",
                    displayName: "Editor",
                    mostRecentWindow: window
                )
            ],
            pointerLocation: PointSnapshot(x: 10, y: 20),
            frontmostAppID: "com.example.editor"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshot.encodedJSON()) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["displays", "runningApps", "pointerLocation", "frontmostAppID"])

        let display = try XCTUnwrap((object["displays"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(display.keys), ["id", "frame", "isCurrent", "hardwareKind"])
        XCTAssertEqual(display["hardwareKind"] as? String, "unknown")
        let displayFrame = try XCTUnwrap(display["frame"] as? [String: Any])
        XCTAssertEqual(Set(displayFrame.keys), ["x", "y", "width", "height"])

        let app = try XCTUnwrap((object["runningApps"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(app.keys), ["id", "displayName", "mostRecentWindow", "iconAvailability"])
        XCTAssertEqual(app["iconAvailability"] as? String, "fallback")
        let encodedWindow = try XCTUnwrap(app["mostRecentWindow"] as? [String: Any])
        XCTAssertEqual(Set(encodedWindow.keys), ["id", "frame", "isOnScreen", "isMain"])
        let windowFrame = try XCTUnwrap(encodedWindow["frame"] as? [String: Any])
        XCTAssertEqual(Set(windowFrame.keys), ["x", "y", "width", "height"])

        let pointer = try XCTUnwrap(object["pointerLocation"] as? [String: Any])
        XCTAssertEqual(Set(pointer.keys), ["x", "y"])
    }

    func testRunningAppCatalogFiltersToRegularAndIgnoresProviderOrderForInitialMRU() {
        let discovery = FixtureRunningAppDiscovery(apps: [
            app("com.example.beta", policy: .regular),
            app("com.example.helper", policy: .accessory),
            app("com.example.alpha", policy: .regular)
        ])
        let activationObserver = FixtureActivationObserver()
        let catalog = RunningAppCatalog(
            discovery: discovery,
            windowReader: FixtureWindowReader(),
            activationObserver: activationObserver
        )

        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.alpha",
            "com.example.beta"
        ])

        discovery.apps = Array(discovery.apps.reversed())
        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.alpha",
            "com.example.beta"
        ])

        activationObserver.emit(appID: "com.example.beta")
        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.beta",
            "com.example.alpha"
        ])
    }

    func testSystemRunningAppIconProviderMapsBundleIdentifierToRunningApplication() {
        var requestedBundleIdentifier: String?
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let provider = SystemRunningAppIconProvider(iconLookup: { bundleIdentifier in
            requestedBundleIdentifier = bundleIdentifier
            return bundleIdentifier == "com.example.editor" ? icon : nil
        })

        XCTAssertTrue(provider.icon(for: "com.example.editor") === icon)
        XCTAssertEqual(requestedBundleIdentifier, "com.example.editor")
    }

    func testRunningAppIconSessionCachesFakeProviderAndUsesSystemFallback() {
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let provider = FixtureRunningAppIconProvider(icons: ["com.example.editor": icon])
        let session = RunningAppIconSession(provider: provider)

        let first = session.resolve(bundleIdentifier: "com.example.editor")
        provider.icons["com.example.editor"] = NSImage(size: NSSize(width: 64, height: 64))
        let second = session.resolve(bundleIdentifier: "com.example.editor")

        XCTAssertEqual(first.availability, .available)
        XCTAssertTrue(first.image === icon)
        XCTAssertTrue(second.image === icon, "one panel session must keep one icon instance per bundle ID")
        XCTAssertEqual(provider.requestedBundleIdentifiers, ["com.example.editor"])

        let fallback = RunningAppIconSession(
            provider: FixtureRunningAppIconProvider(icons: [:]),
            fallbackIcon: icon
        ).resolve(bundleIdentifier: "com.example.missing")
        XCTAssertEqual(fallback.availability, .fallback)
        XCTAssertTrue(fallback.image === icon)
    }

    func testRunningAppCatalogPublishesSanitizedIconAvailability() {
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let provider = FixtureRunningAppIconProvider(icons: ["com.example.editor": icon])
        let discovery = FixtureRunningAppDiscovery(apps: [app("com.example.editor")])
        let catalog = RunningAppCatalog(
            discovery: discovery,
            windowReader: FixtureWindowReader(),
            activationObserver: FixtureActivationObserver(),
            iconProvider: provider
        )

        XCTAssertEqual(catalog.snapshot().first?.iconAvailability, .available)
        provider.icons.removeValue(forKey: "com.example.editor")
        XCTAssertEqual(catalog.snapshot().first?.iconAvailability, .fallback)
    }

    func testRunningAppCatalogDeduplicatesAndResetsMissingAppsDeterministically() {
        let discovery = FixtureRunningAppDiscovery(apps: [
            RunningAppSource(
                id: "com.example.alpha",
                displayName: "Zeta duplicate",
                activationPolicy: .regular
            ),
            RunningAppSource(
                id: "com.example.alpha",
                displayName: "Alpha duplicate",
                activationPolicy: .regular
            ),
            app("com.example.beta")
        ])
        let catalog = RunningAppCatalog(
            discovery: discovery,
            windowReader: FixtureWindowReader(),
            activationObserver: FixtureActivationObserver()
        )

        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.alpha",
            "com.example.beta"
        ])
        XCTAssertEqual(catalog.snapshot().first?.displayName, "Alpha duplicate")

        catalog.recordActivation(appID: "com.example.beta")
        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.beta",
            "com.example.alpha"
        ])

        discovery.apps = [
            RunningAppSource(
                id: "com.example.alpha",
                displayName: "Alpha duplicate",
                activationPolicy: .regular
            )
        ]
        XCTAssertEqual(catalog.snapshot().map(\.id), ["com.example.alpha"])

        discovery.apps.append(app("com.example.beta"))
        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.alpha",
            "com.example.beta"
        ])
    }

    func testRunningAppCatalogRemovesActivationObserverWhenReleased() {
        let activationObserver = FixtureActivationObserver()

        do {
            _ = RunningAppCatalog(
                discovery: FixtureRunningAppDiscovery(apps: []),
                windowReader: FixtureWindowReader(),
                activationObserver: activationObserver
            )
        }

        XCTAssertTrue(activationObserver.didCancel)
    }

    func testQueuedActivationDoesNotUpdateMRUAfterObserverCancellation() async {
        let observer = NSWorkspaceRunningAppActivationObserver(
            notificationCenter: NotificationCenter()
        )
        let catalog = RunningAppCatalog(
            discovery: FixtureRunningAppDiscovery(
                apps: [app("com.example.alpha"), app("com.example.beta")]
            ),
            windowReader: FixtureWindowReader(),
            activationObserver: observer
        )
        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.alpha",
            "com.example.beta"
        ])

        observer.enqueueActivationForTesting(appID: "com.example.beta")
        catalog.cancelActivationObservation()
        await Task.yield()

        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.alpha",
            "com.example.beta"
        ])
    }

    func testRunningAppCatalogExposesInjectedMostRecentWindowMetadata() {
        let window = WindowDescriptor(
            id: "window-1",
            frame: try! RectDescriptor(x: 10, y: 20, width: 300, height: 200),
            isOnScreen: true,
            isMain: true
        )
        let catalog = RunningAppCatalog(
            discovery: FixtureRunningAppDiscovery(apps: [app("com.example.editor")]),
            windowReader: FixtureWindowReader(windows: ["com.example.editor": window])
        )

        XCTAssertEqual(catalog.snapshot().first?.mostRecentWindow, window)
    }

    func testRuntimeSnapshotIsStableAndHasDeterministicSafeJSON() throws {
        let displayDiscovery = FixtureDisplayDiscovery(displays: [
            display("display-main", x: 0, y: 0)
        ])
        let appDiscovery = FixtureRunningAppDiscovery(apps: [
            app("com.example.editor")
        ])
        let state = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: displayDiscovery,
                pointerLocation: FixturePointerLocationProvider(
                    location: PointSnapshot(x: 10, y: 10)
                )
            ),
            runningAppCatalog: RunningAppCatalog(
                discovery: appDiscovery,
                windowReader: FixtureWindowReader()
            ),
            pointerLocation: FixturePointerLocationProvider(
                location: PointSnapshot(x: 10, y: 10)
            ),
            frontmostState: FixtureFrontmostStateProvider(
                appID: "com.example.editor"
            )
        )

        let first = state.beginPanelSession()
        displayDiscovery.displays = [display("display-changed", x: 100, y: 0)]
        appDiscovery.apps = [app("com.example.changed")]
        let second = state.snapshot()
        let firstJSON = try first.encodedJSON()
        let decoded = try SwitcherSnapshot.decodeJSON(firstJSON)
        let json = String(decoding: firstJSON, as: UTF8.self)
        let live = state.liveSnapshot()

        XCTAssertEqual(first, second)
        XCTAssertEqual(live.displays.map(\.id), ["display-changed"])
        XCTAssertEqual(live.runningApps.map(\.id), ["com.example.changed"])
        XCTAssertEqual(first.frontmostAppID, "com.example.editor")
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(firstJSON, try second.encodedJSON())
        XCTAssertFalse(json.contains("pid"))
        XCTAssertFalse(json.contains("path"))
        XCTAssertFalse(json.contains("bundleURL"))
        XCTAssertFalse(json.contains("title"))
    }

    func testCatalogAndRuntimeHaveExplicitReferenceSemantics() {
        let discovery = FixtureRunningAppDiscovery(apps: [
            app("com.example.alpha"),
            app("com.example.beta")
        ])
        let catalog = RunningAppCatalog(
            discovery: discovery,
            windowReader: FixtureWindowReader(),
            activationObserver: FixtureActivationObserver()
        )
        let catalogAlias = catalog

        catalogAlias.recordActivation(appID: "com.example.beta")

        XCTAssertEqual(catalog.snapshot().map(\.id), [
            "com.example.beta",
            "com.example.alpha"
        ])

        let state = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: FixtureDisplayDiscovery(displays: []),
                pointerLocation: FixturePointerLocationProvider(location: nil)
            ),
            runningAppCatalog: catalog,
            pointerLocation: FixturePointerLocationProvider(location: nil),
            frontmostState: FixtureFrontmostStateProvider(appID: nil)
        )
        let stateAlias = state

        XCTAssertEqual(state.beginPanelSession(), stateAlias.snapshot())
    }

    func testMissingPointerAndWindowRemainSafeInSnapshot() {
        let state = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: FixtureDisplayDiscovery(displays: [display("display-1", x: 0, y: 0)]),
                pointerLocation: FixturePointerLocationProvider(location: nil)
            ),
            runningAppCatalog: RunningAppCatalog(
                discovery: FixtureRunningAppDiscovery(apps: [app("com.example.editor")]),
                windowReader: FixtureWindowReader()
            ),
            pointerLocation: FixturePointerLocationProvider(location: nil),
            frontmostState: FixtureFrontmostStateProvider(appID: nil)
        )

        let snapshot = state.beginPanelSession()

        XCTAssertNil(snapshot.pointerLocation)
        XCTAssertNil(snapshot.frontmostAppID)
        XCTAssertFalse(snapshot.displays[0].isCurrent)
        XCTAssertNil(snapshot.runningApps[0].mostRecentWindow)
    }

    func testEmptyProvidersProduceEmptySafeSnapshot() {
        let state = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: FixtureDisplayDiscovery(displays: []),
                pointerLocation: FixturePointerLocationProvider(location: nil)
            ),
            runningAppCatalog: RunningAppCatalog(
                discovery: FixtureRunningAppDiscovery(apps: []),
                windowReader: FixtureWindowReader()
            ),
            pointerLocation: FixturePointerLocationProvider(location: nil),
            frontmostState: FixtureFrontmostStateProvider(appID: nil)
        )

        let snapshot = state.beginPanelSession()

        XCTAssertTrue(snapshot.displays.isEmpty)
        XCTAssertTrue(snapshot.runningApps.isEmpty)
        XCTAssertNil(snapshot.pointerLocation)
        XCTAssertNil(snapshot.frontmostAppID)
    }

    func testPermissionServiceReportsAccessibilityMissingWithoutOpeningSettings() {
        let settings = FixturePermissionSettingsOpener()
        let service = PermissionService(
            accessibilityChecker: FixtureAccessibilityChecker(trusted: false),
            settingsOpener: settings
        )

        XCTAssertEqual(service.state(), .accessibilityMissing)
        XCTAssertThrowsError(try service.requireAll()) { error in
            XCTAssertEqual(error as? PermissionFailure, .accessibilityMissing)
        }
        XCTAssertTrue(settings.opened.isEmpty)
    }

    func testPermissionServiceDoesNotRequireScreenRecording() throws {
        let settings = FixturePermissionSettingsOpener()
        let service = PermissionService(
            accessibilityChecker: FixtureAccessibilityChecker(trusted: true),
            settingsOpener: settings
        )

        XCTAssertEqual(service.state(), .granted)
        XCTAssertNoThrow(try service.requireAll())
        XCTAssertTrue(settings.opened.isEmpty)
    }

    func testPermissionServiceReportsSettingsOpenFailure() {
        let service = PermissionService(
            accessibilityChecker: FixtureAccessibilityChecker(trusted: true),
            settingsOpener: FixturePermissionSettingsOpener(openResult: false)
        )

        XCTAssertThrowsError(try service.openSettings(for: .accessibility)) { error in
            XCTAssertEqual(error as? PermissionFailure, .settingsOpenFailed(.accessibility))
        }
    }

    func testPermissionServiceRequestsBeforeOpeningAccessibilitySettings() throws {
        let settings = FixturePermissionSettingsOpener()
        let checker = FixtureAccessibilityChecker(trusted: false)
        let service = PermissionService(
            accessibilityChecker: checker,
            settingsOpener: settings
        )

        try service.requestAndOpenSettings(for: .accessibility)

        XCTAssertEqual(checker.requests, 1)
        XCTAssertEqual(settings.opened, [.accessibility])
    }

    func testSettingsModelPublishesPermissionErrorWhenOpeningSettingsFails() {
        let settings = FixturePermissionSettingsOpener(openResult: false)
        let model = SettingsModel(
            permissionService: PermissionService(
                accessibilityChecker: FixtureAccessibilityChecker(trusted: true),
                settingsOpener: settings
            ),
            launchAtLogin: FixtureLaunchAtLoginManager(enabled: false),
            shortcutStore: ShortcutConfigurationStore(storage: FixtureShortcutStorage())
        )

        XCTAssertFalse(model.requestAndOpenAccessibilitySettings())
        XCTAssertEqual(model.permissionError, .settingsOpenFailed(.accessibility))
        XCTAssertEqual(model.permissionErrorMessage?.contains("Accessibility"), true)
        XCTAssertEqual(settings.opened, [.accessibility])

        model.clearPermissionError()
        XCTAssertNil(model.permissionError)
    }

    func testDryRunReturnsPreviewAndCallsNoInputProviders() async {
        let recorder = FixtureActionRecorder()
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .dryRun, environment: [:]),
            recorder: recorder
        )

        let result = await service.perform(
            target: displayTarget(hasWindow: true),
            snapshot: actionSnapshot()
        )

        guard case let .success(.preview(preview)) = result else {
            return XCTFail("expected dry-run preview, got \(result)")
        }
        XCTAssertEqual(preview.target, displayTarget(hasWindow: true))
        XCTAssertEqual(preview.pointerDestination, PointSnapshot(x: 50, y: 50))
        XCTAssertTrue(preview.hasWindow)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testExecuteRequiresBothExecuteFlagAndDiagnosticsEnvironment() async {
        let recorder = FixtureActionRecorder()
        let deniedByEnvironment = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: [:]),
            recorder: recorder
        )
        let deniedByValue = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "0"]),
            recorder: recorder
        )

        for service in [deniedByEnvironment, deniedByValue] {
            let result = await service.perform(
                target: displayTarget(hasWindow: true),
                snapshot: actionSnapshot()
            )
            XCTAssertEqual(result, .failure(.executeNotAllowed))
        }

        let dryRunWithDiagnosticsPermission = makeActionService(
            policy: ExecutionPolicy(mode: .dryRun, environment: ["CS_DIAG_ALLOW_INPUT": "1"]),
            recorder: recorder
        )
        guard case .success(.preview) = await dryRunWithDiagnosticsPermission.perform(
            target: displayTarget(hasWindow: true),
            snapshot: actionSnapshot()
        ) else {
            return XCTFail("dry-run must remain a preview even when the diagnostics gate is present")
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testExecuteDisplayMovesPointerThenActivatesWindowWhenPresent() async {
        let recorder = FixtureActionRecorder()
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]),
            recorder: recorder
        )

        let result = await service.perform(
            target: displayTarget(hasWindow: true),
            snapshot: actionSnapshot()
        )

        guard case let .success(.executed(execution)) = result else {
            return XCTFail("expected display execution, got \(result)")
        }
        XCTAssertTrue(execution.pointerMoved)
        XCTAssertTrue(execution.windowActivated)
        XCTAssertEqual(recorder.events, ["move", "display-window"])
        XCTAssertEqual(recorder.moved, [PointSnapshot(x: 50, y: 50)])
        XCTAssertEqual(recorder.displayWindowIDs, ["window-1"])
    }

    func testExecuteDisplayWithoutWindowStillSucceedsAfterPointerMove() async {
        let recorder = FixtureActionRecorder()
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]),
            recorder: recorder
        )

        let result = await service.perform(
            target: displayTarget(hasWindow: false),
            snapshot: actionSnapshot()
        )

        guard case let .success(.executed(execution)) = result else {
            return XCTFail("expected display execution, got \(result)")
        }
        XCTAssertTrue(execution.pointerMoved)
        XCTAssertFalse(execution.windowActivated)
        XCTAssertEqual(recorder.events, ["move"])
    }

    func testExecuteDisplayMovesPointerIntoTargetAndCatalogMarksItCurrent() async {
        let recorder = FixtureActionRecorder()
        let targetFrame = try! RectDescriptor(x: 100, y: 0, width: 100, height: 100)
        let sourceFrame = try! RectDescriptor(x: 0, y: 0, width: 100, height: 100)
        let snapshot = SwitcherSnapshot(
            displays: [
                DisplayDescriptor(id: "display-1", frame: targetFrame, isCurrent: false),
                DisplayDescriptor(id: "display-0", frame: sourceFrame, isCurrent: true)
            ],
            runningApps: [],
            pointerLocation: PointSnapshot(x: 50, y: 50),
            frontmostAppID: nil
        )
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .interactive, environment: [:]),
            recorder: recorder,
            liveSnapshot: snapshot
        )

        guard case .success(.executed) = await service.perform(
            target: .display(id: "display-1", window: nil),
            snapshot: snapshot
        ) else {
            return XCTFail("expected target display execution")
        }

        let catalog = DisplayCatalog(
            discovery: FixtureDisplayDiscovery(displays: [
                DisplaySource(id: "display-0", frame: sourceFrame),
                DisplaySource(id: "display-1", frame: targetFrame)
            ]),
            pointerLocation: FixturePointerLocationProvider(location: recorder.moved.last)
        )

        XCTAssertEqual(recorder.moved, [PointSnapshot(x: 150, y: 50)])
        XCTAssertEqual(catalog.snapshot().filter(\.isCurrent).map(\.id), ["display-1"])
    }

    func testDisplayRemovedDoesNotMovePointer() async {
        let recorder = FixtureActionRecorder()
        let missingSnapshot = actionSnapshot(includeDisplay: false)
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]),
            recorder: recorder,
            liveSnapshot: missingSnapshot
        )

        let result = await service.perform(
            target: .display(id: "display-removed", window: nil),
            snapshot: actionSnapshot()
        )

        XCTAssertEqual(result, .failure(.targetDisplayRemoved))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testExecuteAppTerminationAndMostRecentWindowActivation() async {
        let recorder = FixtureActionRecorder()
        let liveProvider = FixtureLiveSnapshotProvider(snapshot: actionSnapshot(includeApp: false))
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]),
            recorder: recorder,
            liveProvider: liveProvider
        )

        let missingResult = await service.perform(
            target: .app(id: "com.example.terminated"),
            snapshot: actionSnapshot()
        )
        XCTAssertEqual(missingResult, .failure(.targetAppTerminated))
        XCTAssertTrue(recorder.events.isEmpty)

        liveProvider.snapshot = actionSnapshot(includeDisplay: false, includeApp: true)
        let activeResult = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: actionSnapshot(includeDisplay: false, includeApp: true)
        )
        guard case let .success(.executed(execution)) = activeResult else {
            return XCTFail("expected app execution, got \(activeResult)")
        }
        XCTAssertTrue(execution.appActivated)
        XCTAssertTrue(execution.windowActivated)
        XCTAssertEqual(recorder.events, ["app"])
        XCTAssertEqual(recorder.appIDs, ["com.example.editor"])
        XCTAssertEqual(recorder.appWindows.first??.id, "window-1")
    }

    func testExecuteUsesLiveSnapshotAndDoesNotMoveWhenDisplayDisappearsBeforeExecution() async {
        let recorder = FixtureActionRecorder()
        let initialSnapshot = actionSnapshot()
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]),
            recorder: recorder,
            liveSnapshot: actionSnapshot(includeDisplay: false)
        )

        let result = await service.perform(
            target: displayTarget(hasWindow: true),
            snapshot: initialSnapshot
        )

        XCTAssertEqual(result, .failure(.targetDisplayRemoved))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testExecuteUsesLiveSnapshotAndDoesNotActivateWhenAppDisappearsBeforeExecution() async {
        let recorder = FixtureActionRecorder()
        let initialSnapshot = actionSnapshot()
        let service = makeActionService(
            policy: ExecutionPolicy(mode: .execute, environment: ["CS_DIAG_ALLOW_INPUT": "1"]),
            recorder: recorder,
            liveSnapshot: actionSnapshot(includeApp: false)
        )

        let result = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: initialSnapshot
        )

        XCTAssertEqual(result, .failure(.targetAppTerminated))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testDisplayWindowUnavailableDoesNotFailAfterPointerMoveButFailureIsTyped() async {
        let recorder = FixtureActionRecorder()
        recorder.displayWindowResult = .unavailable
        let service = makeActionService(recorder: recorder)

        let unavailableResult = await service.perform(
            target: displayTarget(hasWindow: true),
            snapshot: actionSnapshot()
        )
        guard case let .success(.executed(unavailableExecution)) = unavailableResult else {
            return XCTFail("unavailable window should not fail after pointer movement")
        }
        XCTAssertTrue(unavailableExecution.pointerMoved)
        XCTAssertFalse(unavailableExecution.windowActivated)

        recorder.displayWindowResult = .failed
        let failedResult = await service.perform(
            target: displayTarget(hasWindow: true),
            snapshot: actionSnapshot()
        )
        XCTAssertEqual(failedResult, .failure(.displayWindowActivationFailed))
    }

    func testDisplayWindowResolverRejectsStaleWindowBeforeActivation() async {
        let recorder = FixtureActionRecorder()
        let resolver = FixtureDisplayWindowResolver(
            resolution: .unavailable,
            requestedWindowIDs: []
        )
        let service = makeActionService(
            recorder: recorder,
            displayResolver: resolver
        )

        let result = await service.perform(
            target: displayTarget(hasWindow: true),
            snapshot: actionSnapshot()
        )

        guard case let .success(.executed(execution)) = result else {
            return XCTFail("stale display window should degrade to unavailable")
        }
        XCTAssertTrue(execution.pointerMoved)
        XCTAssertFalse(execution.windowActivated)
        XCTAssertEqual(resolver.requestedWindowIDs, ["window-1", "window-1"])
        XCTAssertEqual(recorder.events, ["move"])
        XCTAssertTrue(recorder.displayWindowIDs.isEmpty)
    }

    func testDisplayWindowFinalRevalidationRunsAfterPointerAndSkipsStaleActivator() async {
        let eventLog = FixtureEventLog()
        let recorder = FixtureActionRecorder(eventLog: eventLog)
        let currentWindow = WindowDescriptor(
            id: "window-current",
            frame: try! RectDescriptor(x: 0, y: 0, width: 100, height: 100),
            isOnScreen: true,
            isMain: true
        )
        let resolver = FixtureDisplayWindowResolver(
            resolutions: [
                .resolved(currentWindow),
                .unavailable
            ],
            eventLog: eventLog
        )
        let service = makeActionService(
            recorder: recorder,
            displayResolver: resolver
        )

        let result = await service.perform(
            target: displayTarget(hasWindow: true),
            snapshot: actionSnapshot()
        )

        guard case let .success(.executed(execution)) = result else {
            return XCTFail("final stale window should preserve pointer success")
        }
        XCTAssertTrue(execution.pointerMoved)
        XCTAssertFalse(execution.windowActivated)
        XCTAssertEqual(eventLog.events, ["resolve", "move", "resolve"])
        XCTAssertTrue(recorder.displayWindowIDs.isEmpty)
    }

    func testAppActivationOutcomeUsesExactMostRecentWindowAndRaisesTypedFailures() async {
        let resolver = FixtureWindowActivationResolver(outcome: .activated)
        let appActivator = FixtureResolvedAppActivator(resolver: resolver)
        let service = makeActionService(
            recorder: FixtureActionRecorder(),
            appActivator: appActivator
        )

        let activatedResult = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: actionSnapshot()
        )
        guard case let .success(.executed(execution)) = activatedResult else {
            return XCTFail("expected app activation, got \(activatedResult)")
        }
        XCTAssertTrue(execution.appActivated)
        XCTAssertTrue(execution.windowActivated)
        XCTAssertEqual(resolver.requestedWindowIDs, ["window-1"])
        XCTAssertEqual(appActivator.receivedWindowIDs, ["window-1"])

        resolver.outcome = .unavailable
        let unavailableResult = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: actionSnapshot()
        )
        guard case let .success(.executed(unavailableExecution)) = unavailableResult else {
            return XCTFail("unavailable window should preserve app activation")
        }
        XCTAssertTrue(unavailableExecution.appActivated)
        XCTAssertFalse(unavailableExecution.windowActivated)

        resolver.outcome = .failed
        let failedResult = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: actionSnapshot()
        )
        XCTAssertEqual(failedResult, .failure(.appWindowActivationFailed))

        appActivator.processActivationSucceeded = false
        let processFailedResult = await service.perform(
            target: .app(id: "com.example.editor"),
            snapshot: actionSnapshot()
        )
        XCTAssertEqual(processFailedResult, .failure(.appActivationFailed))
    }

    func testCandidateResolverAndSelectorRejectAmbiguousOrMalformedWindowMetadata() async {
        let permissionService = PermissionService(
            accessibilityChecker: FixtureAccessibilityChecker(trusted: true),
            settingsOpener: FixturePermissionSettingsOpener()
        )
        let target = displayTargetWindow()
        let targetCandidate = WindowCandidate(id: "window-1", frame: target.frame)
        let siblingCandidate = WindowCandidate(id: "window-2", frame: target.frame)
        let candidates = FixtureWindowCandidateResolver(candidates: [targetCandidate])
        let performer = FixtureAXActionPerformer(outcome: .activated)
        let resolver = AccessibilityWindowActivationResolver(
            permissionService: permissionService,
            actionPerformer: performer,
            actionExecutor: FixtureImmediateAXActionExecutor()
        )

        let activated = await resolver.resolveAndRaise(window: target, processIdentifier: 42)
        XCTAssertEqual(activated, .activated)
        XCTAssertEqual(performer.requestedWindowIDs, ["window-1"])

        performer.outcome = .unavailable
        let unavailable = await resolver.resolveAndRaise(window: target, processIdentifier: 42)
        XCTAssertEqual(unavailable, .unavailable)

        candidates.candidates = [targetCandidate, siblingCandidate]
        let ambiguousTarget = WindowDescriptor(
            id: "unknown-window",
            frame: target.frame,
            isOnScreen: true,
            isMain: true
        )
        XCTAssertNil(WindowCandidateSelector().select(
            requestedWindow: ambiguousTarget,
            from: candidates.candidates
        ))

        XCTAssertEqual(performer.requestedWindowIDs, ["window-1", "window-1"])
    }

    func testExecuteMapsAccessibilityMissingButNotScreenRecordingMissing() async {
        let recorder = FixtureActionRecorder()
        let accessibilityMissing = makeActionService(
            accessibilityTrusted: false,
            recorder: recorder
        )
        let recordingMissing = makeActionService(
            screenRecordingGranted: false,
            recorder: recorder
        )
        let snapshot = actionSnapshot()

        let missing = await accessibilityMissing.perform(
            target: displayTarget(hasWindow: true),
            snapshot: snapshot
        )
        XCTAssertEqual(missing, .failure(.accessibilityMissing))
        guard case .success(.executed) = await recordingMissing.perform(
            target: displayTarget(hasWindow: false),
            snapshot: snapshot
        ) else {
            return XCTFail("screen recording permission must not block execute")
        }
        XCTAssertEqual(recorder.events, ["move"])
    }

    private func actionSnapshot(
        includeDisplay: Bool = true,
        includeApp: Bool = true
    ) -> SwitcherSnapshot {
        let frame = try! RectDescriptor(x: 0, y: 0, width: 100, height: 100)
        let window = WindowDescriptor(
            id: "window-1",
            frame: frame,
            isOnScreen: true,
            isMain: true
        )
        return SwitcherSnapshot(
            displays: includeDisplay
                ? [DisplayDescriptor(id: "display-1", frame: frame, isCurrent: true)]
                : [],
            runningApps: includeApp
                ? [RunningAppDescriptor(
                    id: "com.example.editor",
                    displayName: "Editor",
                    mostRecentWindow: window
                )]
                : [],
            pointerLocation: nil,
            frontmostAppID: nil
        )
    }

    private func displayTarget(hasWindow: Bool) -> SwitcherActionTarget {
        return .display(id: "display-1", window: hasWindow ? displayTargetWindow() : nil)
    }

    private func displayTargetWindow() -> WindowDescriptor {
        WindowDescriptor(
            id: "window-1",
            frame: try! RectDescriptor(x: 0, y: 0, width: 100, height: 100),
            isOnScreen: true,
            isMain: true
        )
    }

    private func makeActionService(
        policy: ExecutionPolicy = ExecutionPolicy(
            mode: .execute,
            environment: ["CS_DIAG_ALLOW_INPUT": "1"]
        ),
        accessibilityTrusted: Bool = true,
        screenRecordingGranted: Bool = true,
        recorder: FixtureActionRecorder,
        liveSnapshot: SwitcherSnapshot? = nil,
        liveProvider: FixtureLiveSnapshotProvider? = nil,
        displayResolver: FixtureDisplayWindowResolver? = nil,
        displayWindowDiscovery: DisplayWindowDiscovering? = nil,
        appActivator: RunningAppActivating? = nil
    ) -> SwitcherActionService {
        SwitcherActionService(
            policy: policy,
            liveSnapshotProvider: liveProvider ?? FixtureLiveSnapshotProvider(
                snapshot: liveSnapshot ?? actionSnapshot()
            ),
            permissionService: PermissionService(
                accessibilityChecker: FixtureAccessibilityChecker(trusted: accessibilityTrusted),
                settingsOpener: FixturePermissionSettingsOpener()
            ),
            pointerMover: recorder,
            displayWindowDiscovery: displayWindowDiscovery
                ?? FixtureDisplayWindowDiscovery(window: nil),
            displayWindowResolver: displayResolver ?? FixtureDisplayWindowResolver(),
            displayWindowActivator: recorder,
            appActivator: appActivator ?? recorder
        )
    }

    private func display(_ id: String, x: Double, y: Double) -> DisplaySource {
        DisplaySource(
            id: id,
            frame: try! RectDescriptor(x: x, y: y, width: 100, height: 100)
        )
    }

    private func app(
        _ id: String,
        policy: AppActivationPolicy = .regular
    ) -> RunningAppSource {
        RunningAppSource(id: id, displayName: id, activationPolicy: policy)
    }
}

@MainActor
private final class FixtureDisplayDiscovery: DisplayDiscovering {
    var displays: [DisplaySource]

    init(displays: [DisplaySource]) {
        self.displays = displays
    }

    func discoverDisplays() -> [DisplaySource] {
        displays
    }
}

@MainActor
private final class FixturePointerLocationProvider: PointerLocationProviding {
    let location: PointSnapshot?

    init(location: PointSnapshot?) {
        self.location = location
    }

    func currentPointerLocation() -> PointSnapshot? {
        location
    }
}

@MainActor
private final class FixtureRunningAppDiscovery: RunningAppDiscovering {
    var apps: [RunningAppSource]

    init(apps: [RunningAppSource]) {
        self.apps = apps
    }

    func discoverRunningApps() -> [RunningAppSource] {
        apps
    }
}

@MainActor
private final class FixtureRunningAppIconProvider: RunningAppIconProviding {
    var icons: [String: NSImage]
    private(set) var requestedBundleIdentifiers: [String] = []

    init(icons: [String: NSImage]) {
        self.icons = icons
    }

    func icon(for bundleIdentifier: String) -> NSImage? {
        requestedBundleIdentifiers.append(bundleIdentifier)
        return icons[bundleIdentifier]
    }
}

@MainActor
private final class FixtureActivationObserver: RunningAppActivationObserving {
    private var handler: (@MainActor (String) -> Void)?
    private let lifecycle = FixtureActivationLifecycle()

    var didCancel: Bool { lifecycle.didCancel }

    func startObserving(
        _ handler: @escaping @MainActor (String) -> Void
    ) -> RunningAppActivationObservation {
        self.handler = handler
        let lifecycle = lifecycle
        return FixtureActivationObservation {
            lifecycle.cancel()
        }
    }

    func emit(appID: String) {
        handler?(appID)
    }
}

private final class FixtureActivationLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
private final class FixtureActivationObservation: RunningAppActivationObservation {
    private let onCancel: () -> Void
    private var isCancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel()
    }

    deinit {
        onCancel()
    }
}

@MainActor
private struct FixtureWindowReader: WindowMetadataReading {
    let windows: [String: WindowDescriptor]

    init(windows: [String: WindowDescriptor] = [:]) {
        self.windows = windows
    }

    func mostRecentWindow(for appID: String) -> WindowDescriptor? {
        windows[appID]
    }
}

@MainActor
private struct FixtureFrontmostStateProvider: FrontmostStateProviding {
    let appID: String?

    func frontmostApplicationID() -> String? {
        appID
    }
}

@MainActor
private final class FixtureAccessibilityChecker: AccessibilityChecking {
    var trusted: Bool
    let requestResult: Bool
    private(set) var requests = 0

    init(trusted: Bool, requestResult: Bool = false) {
        self.trusted = trusted
        self.requestResult = requestResult
    }

    func isAccessibilityTrusted() -> Bool {
        trusted
    }

    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        requests += 1
        return requestResult
    }
}

@MainActor
private final class FixtureScreenRecordingChecker {
    var granted: Bool
    let requestResult: Bool
    private(set) var requests = 0

    init(granted: Bool, requestResult: Bool = false) {
        self.granted = granted
        self.requestResult = requestResult
    }

    func hasScreenRecordingAccess() -> Bool {
        granted
    }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        requests += 1
        return requestResult
    }
}

@MainActor
private final class FixtureLiveSnapshotProvider: LiveSnapshotProviding {
    var snapshot: SwitcherSnapshot

    init(snapshot: SwitcherSnapshot) {
        self.snapshot = snapshot
    }

    func liveSnapshot() -> SwitcherSnapshot {
        snapshot
    }
}

@MainActor
private final class FixtureDisplayWindowResolver: DisplayWindowResolving {
    var resolution: DisplayWindowResolution
    var requestedWindowIDs: [String]
    private var resolutions: [DisplayWindowResolution]
    private let eventLog: FixtureEventLog?

    init(
        resolution: DisplayWindowResolution = .resolved(
            WindowDescriptor(
                id: "window-1",
                frame: try! RectDescriptor(x: 0, y: 0, width: 100, height: 100),
                isOnScreen: true,
                isMain: true
            )
        ),
        requestedWindowIDs: [String] = [],
        resolutions: [DisplayWindowResolution]? = nil,
        eventLog: FixtureEventLog? = nil
    ) {
        self.resolution = resolution
        self.requestedWindowIDs = requestedWindowIDs
        self.resolutions = resolutions ?? [resolution]
        self.eventLog = eventLog
    }

    func resolveDisplayWindow(
        display: DisplayDescriptor,
        requestedWindow: WindowDescriptor
    ) -> DisplayWindowResolution {
        requestedWindowIDs.append(requestedWindow.id)
        eventLog?.events.append("resolve")
        if !resolutions.isEmpty {
            return resolutions.removeFirst()
        }
        return resolution
    }
}

@MainActor
private final class FixtureEventLog {
    var events: [String] = []
}

@MainActor
private final class FixtureWindowCandidateResolver: WindowCandidateResolving {
    var candidates: [WindowCandidate]

    init(candidates: [WindowCandidate]) {
        self.candidates = candidates
    }

    func windowCandidates() -> [WindowCandidate] {
        candidates
    }
}

@MainActor
private final class FixtureWindowActivationResolver: WindowActivationResolving {
    var outcome: WindowActivationOutcome
    var requestedWindowIDs: [String] = []

    init(outcome: WindowActivationOutcome) {
        self.outcome = outcome
    }

    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t
    ) async -> WindowActivationOutcome {
        requestedWindowIDs.append(window.id)
        return outcome
    }
}

@MainActor
private final class FixtureResolvedAppActivator: RunningAppActivating {
    private let resolver: FixtureWindowActivationResolver
    var receivedWindowIDs: [String] = []
    var processActivationSucceeded = true

    init(resolver: FixtureWindowActivationResolver) {
        self.resolver = resolver
    }

    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?
    ) async -> AppActivationOutcome {
        guard processActivationSucceeded else {
            return .failed
        }
        guard let mostRecentWindow else {
            return .activated(windowActivated: false)
        }
        receivedWindowIDs.append(mostRecentWindow.id)
        switch await resolver.resolveAndRaise(window: mostRecentWindow, processIdentifier: 42) {
        case .activated:
            return .activated(windowActivated: true)
        case .unavailable:
            return .windowUnavailable
        case .timedOut:
            return .windowActivationTimedOut
        case .busy:
            return .windowActivationBusy
        case .failed:
            return .windowActivationFailed
        }
    }
}

@MainActor
private final class FixturePermissionSettingsOpener: PermissionSettingsOpening {
    private(set) var opened: [PermissionKind] = []
    let openResult: Bool

    init(openResult: Bool = true) {
        self.openResult = openResult
    }

    func openSettings(for kind: PermissionKind) -> Bool {
        opened.append(kind)
        return openResult
    }
}

@MainActor
private final class FixtureActionRecorder:
    PointerMoving,
    DisplayWindowActivating,
    RunningAppActivating
{
    var events: [String] = []
    var moved: [PointSnapshot] = []
    var displayWindowIDs: [String] = []
    var appIDs: [String] = []
    var appWindows: [WindowDescriptor?] = []

    var moveResult = true
    var displayWindowResult: DisplayWindowActivationResult = .activated
    var appOutcome: AppActivationOutcome = .activated(windowActivated: true)
    private let eventLog: FixtureEventLog?

    init(eventLog: FixtureEventLog? = nil) {
        self.eventLog = eventLog
    }

    func movePointer(to point: PointSnapshot) -> Bool {
        events.append("move")
        eventLog?.events.append("move")
        moved.append(point)
        return moveResult
    }

    func activateDisplayWindow(
        display: DisplayDescriptor,
        window: WindowDescriptor
    ) async -> DisplayWindowActivationResult {
        events.append("display-window")
        displayWindowIDs.append(window.id)
        return displayWindowResult
    }

    func activateApp(
        appID: String,
        mostRecentWindow: WindowDescriptor?
    ) async -> AppActivationOutcome {
        events.append("app")
        appIDs.append(appID)
        appWindows.append(mostRecentWindow)
        return appOutcome
    }
}

private final class FixtureAXActionPerformer: @unchecked Sendable,
    AXWindowActionPerforming {
    private let lock = NSLock()
    var outcome: WindowActivationOutcome
    private var windowIDs: [String] = []

    init(outcome: WindowActivationOutcome) { self.outcome = outcome }

    var requestedWindowIDs: [String] { lock.withLock { windowIDs } }

    func resolveAndRaise(
        window: WindowDescriptor,
        processIdentifier: pid_t,
        budget: TimeInterval,
        cancellation: any AXActionCancellationChecking
    ) -> WindowActivationOutcome {
        lock.withLock { windowIDs.append(window.id) }
        return outcome
    }
}

private struct FixtureImmediateAXActionExecutor: AXActionExecuting {
    func execute(
        _ operation: @escaping @Sendable (
            any AXActionCancellationChecking
        ) -> WindowActivationOutcome
    ) async -> WindowActivationOutcome {
        operation(AXActionOperationControl())
    }
}

@MainActor
private final class FixtureShortcutStorage: ShortcutStorage {
    var shortcut: KeyboardShortcuts.Shortcut?
    var setCount = 0

    init(shortcut: KeyboardShortcuts.Shortcut? = nil) {
        self.shortcut = shortcut
    }

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        setCount += 1
        self.shortcut = shortcut
    }
}

@MainActor
private final class FixtureShortcutTriggerRegistrar: ShortcutTriggerRegistering {
    private var actions: [KeyboardShortcuts.Name: @MainActor (UInt64) -> Void] = [:]
    private var registrations: [KeyboardShortcuts.Name: FixtureShortcutTriggerRegistration] = [:]
    private(set) var registerCount = 0
    private(set) var cancelCount = 0

    func register(
        name: KeyboardShortcuts.Name,
        action: @escaping @MainActor (UInt64) -> Void
    ) -> any ShortcutTriggerRegistration {
        registerCount += 1
        registrations[name]?.cancel()
        actions[name] = action
        let newRegistration = FixtureShortcutTriggerRegistration { [weak self] in
            self?.actions[name] = nil
            self?.registrations[name] = nil
            self?.cancelCount += 1
        }
        registrations[name] = newRegistration
        return newRegistration
    }

    func invoke(_ name: KeyboardShortcuts.Name = .screenSwitcher) {
        actions[name]?(0)
    }
}

@MainActor
private final class FixtureCommandTabInterceptor: CommandTabIntercepting {
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(
        action _: @escaping @MainActor (UInt64) -> Void
    ) -> (any ShortcutTriggerRegistration)? {
        startCount += 1
        return FixtureShortcutTriggerRegistration { [weak self] in
            self?.cancelCount += 1
        }
    }
}

@MainActor
private final class FixtureShortcutTriggerRegistration: ShortcutTriggerRegistration {
    private let onCancel: @MainActor () -> Void
    private var isCancelled = false

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel()
    }
}

@MainActor
private final class FixtureDisplayWindowDiscovery: DisplayWindowDiscovering {
    let window: WindowDescriptor?
    private(set) var displayIDs: [String] = []

    init(window: WindowDescriptor?) {
        self.window = window
    }

    func discoverWindow(for display: DisplayDescriptor) -> WindowDescriptor? {
        displayIDs.append(display.id)
        return window
    }
}

@MainActor
private final class FixtureSemanticAdapterRuntime: SemanticAdapterRuntime {
    let snapshotValue: SwitcherSnapshot
    private(set) var isPanelOpen = false
    private(set) var selectedItemID: String?
    private(set) var executeCount = 0
    private(set) var dryRunCount = 0
    private(set) var closeCount = 0

    init(snapshot: SwitcherSnapshot) {
        self.snapshotValue = snapshot
    }

    func state() -> SemanticAdapterRuntimeState {
        SemanticAdapterRuntimeState(
            isPanelOpen: isPanelOpen,
            selectedItemID: selectedItemID,
            permissionState: .granted
        )
    }

    func snapshot() -> SwitcherSnapshot {
        snapshotValue
    }

    func openPanel() {
        isPanelOpen = true
    }

    func select(itemID: String) -> Bool {
        let validIDs = snapshotValue.displays.map(\.id) + snapshotValue.runningApps.map(\.id)
        guard validIDs.contains(itemID) else { return false }
        selectedItemID = itemID
        return true
    }

    func executeSelected() async -> Result<Void, SwitcherActionFailure> {
        guard selectedItemID != nil else { return .failure(.executeNotAllowed) }
        executeCount += 1
        return .success(())
    }

    func permissionState() -> SemanticAdapterPermissionState {
        .granted
    }

    func sendWorkspaceKey(_ key: WorkspaceKeyCommand) -> Bool {
        isPanelOpen
    }

    func sendWorkspaceGesture(_ gesture: SemanticWorkspaceGesture) -> Bool {
        isPanelOpen
    }

    func executeWorkspaceDryRun() -> Bool {
        guard isPanelOpen else { return false }
        dryRunCount += 1
        return true
    }

    func closePanel() {
        closeCount += 1
        isPanelOpen = false
        selectedItemID = nil
    }
}

@MainActor
private final class FixturePanelPresenter: SwitcherPanelPresenting {
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var isVisible = false

    func openSwitcher() {
        openCount += 1
        isVisible = true
    }

    func closeSwitcher() {
        closeCount += 1
        isVisible = false
    }
}

@MainActor
private final class FixtureSettingsPresenter: SwitcherSettingsPresenting {
    private(set) var openCount = 0

    func openSettings() {
        openCount += 1
    }
}

@MainActor
private final class FixtureApplicationTerminator: ApplicationTerminating {
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
    }
}

@MainActor
private final class FixtureSemanticAdapterServer: SemanticAdapterServerControlling {
    private let onStart: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(onStart: (() -> Void)? = nil) {
        self.onStart = onStart
    }

    func start() async throws -> SemanticAdapterRuntimeMetadata {
        startCount += 1
        onStart?()
        return SemanticAdapterRuntimeMetadata(
            pid: 1,
            port: 43123,
            tokenReference: "sha256:test",
            bundle: "test.ScreenSwitcher",
            version: "test",
            logPath: "<artifact-root>/runtime.log"
        )
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FixtureLaunchAtLoginManager: LaunchAtLoginManaging {
    enum Event: Equatable {
        case register
        case unregister
    }

    private(set) var isEnabled: Bool
    private(set) var events: [Event] = []

    init(enabled: Bool) {
        isEnabled = enabled
    }

    func register() throws {
        events.append(.register)
        isEnabled = true
    }

    func unregister() throws {
        events.append(.unregister)
        isEnabled = false
    }
}
