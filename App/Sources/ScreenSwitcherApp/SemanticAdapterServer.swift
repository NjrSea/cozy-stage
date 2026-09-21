@preconcurrency import Network
import CryptoKit
import Foundation
import ScreenDomainCore

public enum SemanticAdapterMode: Equatable {
    case devTest
    case productionDisabled
}

public enum SemanticAdapterPermissionState: String, Codable, Equatable {
    case granted
    case accessibilityMissing = "accessibility_missing"
}

public struct SemanticPanelGeometry: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let scale: Double
    public let ringCount: Int
    public let itemCount: Int
    public let availableIconCount: Int
    public let shortcutCount: Int

    public init(
        width: Double,
        height: Double,
        scale: Double,
        ringCount: Int,
        itemCount: Int,
        availableIconCount: Int,
        shortcutCount: Int
    ) {
        self.width = width
        self.height = height
        self.scale = scale
        self.ringCount = ringCount
        self.itemCount = itemCount
        self.availableIconCount = availableIconCount
        self.shortcutCount = shortcutCount
    }
}

public struct SemanticAdapterRuntimeState: Codable, Equatable {
    public let isPanelOpen: Bool
    public let selectedItemID: String?
    public let permissionState: SemanticAdapterPermissionState
    public let panelGeometry: SemanticPanelGeometry?
    public let currentTab: WorkspaceTab
    public let appPage: Int
    public let gesturePhase: String
    public let reducedMotion: Bool
    public let overlayDisplayID: String?
    public let pointerDisplayID: String?
    public let overlayFrame: SemanticWorkspaceFrame?
    public let selectedTargetKind: String?
    public let selectedTargetIdentity: String?
    public let dryRunSelectionConfirmed: Bool
    public let tabTransitionRevision: UInt64
    public let tabSettledRevision: UInt64
    public let displayCardTransitionRevision: UInt64
    public let displayCardSettledRevision: UInt64

    public init(
        isPanelOpen: Bool,
        selectedItemID: String?,
        permissionState: SemanticAdapterPermissionState,
        panelGeometry: SemanticPanelGeometry? = nil,
        currentTab: WorkspaceTab = .switch,
        appPage: Int = 0,
        gesturePhase: String = "idle",
        reducedMotion: Bool = false,
        overlayDisplayID: String? = nil,
        pointerDisplayID: String? = nil,
        overlayFrame: SemanticWorkspaceFrame? = nil,
        selectedTargetKind: String? = nil,
        selectedTargetIdentity: String? = nil,
        dryRunSelectionConfirmed: Bool = false,
        tabTransitionRevision: UInt64 = 0,
        tabSettledRevision: UInt64 = 0,
        displayCardTransitionRevision: UInt64 = 0,
        displayCardSettledRevision: UInt64 = 0
    ) {
        self.isPanelOpen = isPanelOpen
        self.selectedItemID = selectedItemID
        self.permissionState = permissionState
        self.panelGeometry = panelGeometry
        self.currentTab = currentTab
        self.appPage = max(appPage, 0)
        self.gesturePhase = gesturePhase
        self.reducedMotion = reducedMotion
        self.overlayDisplayID = overlayDisplayID
        self.pointerDisplayID = pointerDisplayID
        self.overlayFrame = overlayFrame
        self.selectedTargetKind = selectedTargetKind
        self.selectedTargetIdentity = selectedTargetIdentity
        self.dryRunSelectionConfirmed = dryRunSelectionConfirmed
        self.tabTransitionRevision = tabTransitionRevision
        self.tabSettledRevision = tabSettledRevision
        self.displayCardTransitionRevision = displayCardTransitionRevision
        self.displayCardSettledRevision = displayCardSettledRevision
    }
}

@MainActor
public protocol SemanticAdapterRuntime: AnyObject {
    func state() -> SemanticAdapterRuntimeState
    func snapshot() -> SwitcherSnapshot
    func openPanel()
    func select(itemID: String) -> Bool
    func executeSelected() async -> Result<Void, SwitcherActionFailure>
    func permissionState() -> SemanticAdapterPermissionState
    func closePanel()
    func openWorkspace(tab: WorkspaceTab)
    func sendWorkspaceKey(_ key: WorkspaceKeyCommand) -> Bool
    func selectWorkspaceDryRunTarget(_ key: WorkspaceKeyCommand) -> Bool
    func sendWorkspaceGesture(_ gesture: SemanticWorkspaceGesture) -> Bool
    func executeWorkspaceDryRun() -> Bool
}

public extension SemanticAdapterRuntime {
    func openWorkspace(tab: WorkspaceTab) {
        guard tab == .switch else { return }
        openPanel()
    }

    func sendWorkspaceKey(_ key: WorkspaceKeyCommand) -> Bool { false }
    func selectWorkspaceDryRunTarget(_ key: WorkspaceKeyCommand) -> Bool { false }
    func sendWorkspaceGesture(_ gesture: SemanticWorkspaceGesture) -> Bool { false }
    func executeWorkspaceDryRun() -> Bool { state().isPanelOpen }
}

@MainActor
protocol SemanticAdapterRuntimeTearingDown: AnyObject {
    func teardown()
}

public enum SemanticAdapterErrorCode: String, Codable, Equatable {
    case invalidRequest = "invalid_request"
    case missingToken = "missing_token"
    case invalidToken = "invalid_token"
    case unknownCommand = "unknown_command"
    case invalidItemID = "invalid_item_id"
    case requestTooLarge = "request_too_large"
    case executeNotAllowed = "execute_not_allowed"
    case panelNotOpen = "panel_not_open"
    case panelAlreadyOpen = "panel_already_open"
    case panelAlreadyClosed = "panel_already_closed"
    case panelOwnershipLost = "panel_ownership_lost"
    case screenNotFound = "screen_not_found"
    case screenOwnershipLost = "screen_ownership_lost"
    case actionInProgress = "action_in_progress"
    case actionOverloaded = "action_overloaded"
    case productionDisabled = "production_disabled"
    case runtimeFailure = "runtime_failure"
}

public struct SemanticAdapterError: Codable, Equatable {
    public let code: SemanticAdapterErrorCode
    public let message: String

    public init(code: SemanticAdapterErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct SemanticAdapterState: Codable, Equatable {
    public let isPanelOpen: Bool
    public let selectedItemID: String?
    public let snapshot: SwitcherSnapshot?
    public let permissionState: SemanticAdapterPermissionState?
    public let adapterMode: String?
    public let dryRun: Bool?
    public let panelGeometry: SemanticPanelGeometry?
    public let workspace: SemanticWorkspaceSnapshot?

    public init(
        isPanelOpen: Bool,
        selectedItemID: String?,
        snapshot: SwitcherSnapshot? = nil,
        permissionState: SemanticAdapterPermissionState? = nil,
        adapterMode: String? = nil,
        dryRun: Bool? = nil,
        panelGeometry: SemanticPanelGeometry? = nil,
        workspace: SemanticWorkspaceSnapshot? = nil
    ) {
        self.isPanelOpen = isPanelOpen
        self.selectedItemID = selectedItemID
        self.snapshot = snapshot
        self.permissionState = permissionState
        self.adapterMode = adapterMode
        self.dryRun = dryRun
        self.panelGeometry = panelGeometry
        self.workspace = workspace
    }
}

public struct SemanticWorkspaceFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct SemanticWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let isOverlayOpen: Bool
    public let currentTab: String
    public let overlayDisplayID: String?
    public let pointerDisplayID: String?
    public let targetDisplayID: String?
    public let focusedAppBundleIdentity: String?
    public let dimmedDisplayIDs: [String]
    public let overlayFrame: SemanticWorkspaceFrame
    public let gesturePhase: String
    public let reducedMotion: Bool
    public let previewAvailability: String
    public let appPage: Int
    public let appBundleIdentities: [String]
    public let selectedTargetKind: String?
    public let selectedTargetIdentity: String?
    public let dryRunSelectionConfirmed: Bool
    public let tabTransitionRevision: UInt64
    public let tabSettledRevision: UInt64
    public let displayCardTransitionRevision: UInt64
    public let displayCardSettledRevision: UInt64

    public init(
        isOverlayOpen: Bool,
        currentTab: String,
        overlayDisplayID: String?,
        pointerDisplayID: String?,
        targetDisplayID: String?,
        focusedAppBundleIdentity: String?,
        dimmedDisplayIDs: [String],
        overlayFrame: SemanticWorkspaceFrame,
        gesturePhase: String,
        reducedMotion: Bool,
        previewAvailability: String,
        appPage: Int,
        appBundleIdentities: [String],
        selectedTargetKind: String? = nil,
        selectedTargetIdentity: String? = nil,
        dryRunSelectionConfirmed: Bool = false,
        tabTransitionRevision: UInt64 = 0,
        tabSettledRevision: UInt64 = 0,
        displayCardTransitionRevision: UInt64 = 0,
        displayCardSettledRevision: UInt64 = 0
    ) {
        self.isOverlayOpen = isOverlayOpen
        self.currentTab = currentTab
        self.overlayDisplayID = overlayDisplayID
        self.pointerDisplayID = pointerDisplayID
        self.targetDisplayID = targetDisplayID
        self.focusedAppBundleIdentity = focusedAppBundleIdentity
        self.dimmedDisplayIDs = dimmedDisplayIDs
        self.overlayFrame = overlayFrame
        self.gesturePhase = gesturePhase
        self.reducedMotion = reducedMotion
        self.previewAvailability = previewAvailability
        self.appPage = appPage
        self.appBundleIdentities = appBundleIdentities
        self.selectedTargetKind = selectedTargetKind
        self.selectedTargetIdentity = selectedTargetIdentity
        self.dryRunSelectionConfirmed = dryRunSelectionConfirmed
        self.tabTransitionRevision = tabTransitionRevision
        self.tabSettledRevision = tabSettledRevision
        self.displayCardTransitionRevision = displayCardTransitionRevision
        self.displayCardSettledRevision = displayCardSettledRevision
    }
}

public enum SemanticWorkspaceGesturePhase: String, Codable, Equatable, Sendable {
    case began
    case changed
    case ended
    case cancelled
}

public struct SemanticWorkspaceGesture: Codable, Equatable, Sendable {
    public let id: UInt64
    public let phase: SemanticWorkspaceGesturePhase
    public let deltaX: Double
    public let deltaY: Double
    public let velocityX: Double
    public let velocityY: Double

    public init(
        id: UInt64,
        phase: SemanticWorkspaceGesturePhase,
        deltaX: Double,
        deltaY: Double,
        velocityX: Double,
        velocityY: Double
    ) {
        self.id = id
        self.phase = phase
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.velocityX = velocityX
        self.velocityY = velocityY
    }
}

public struct SemanticAdapterResponse: Codable, Equatable {
    public let schemaVersion: Int
    public let ok: Bool
    public let command: String?
    public let state: SemanticAdapterState?
    public let error: SemanticAdapterError?

    public init(
        schemaVersion: Int = 2,
        ok: Bool,
        command: String?,
        state: SemanticAdapterState?,
        error: SemanticAdapterError?
    ) {
        self.schemaVersion = schemaVersion
        self.ok = ok
        self.command = command
        self.state = state
        self.error = error
    }
}

public struct SemanticAdapterRuntimeMetadata: Codable, Equatable {
    public let pid: Int32
    public let port: UInt16
    public let tokenReference: String
    public let bundle: String
    public let version: String
    public let logPath: String

    public init(
        pid: Int32,
        port: UInt16,
        tokenReference: String,
        bundle: String,
        version: String,
        logPath: String
    ) {
        self.pid = pid
        self.port = port
        self.tokenReference = tokenReference
        self.bundle = bundle
        self.version = version
        self.logPath = logPath
    }
}

public enum SemanticAdapterServerError: Error, Equatable {
    case productionDisabled
    case alreadyStarted
    case listenerFailed
    case metadataWriteFailed
    case startCancelled
}

private enum SemanticAdapterCommand: String {
    case snapshot = "workspace.snapshot"
    case open = "workspace.open"
    case close = "workspace.close"
    case key = "workspace.key"
    case gesture = "workspace.gesture"
    case executeDryRun = "workspace.executeDryRun"
}

private struct SemanticAdapterRequest: Decodable {
    let command: String
    let token: String?
    let tab: String?
    let key: String?
    let gesture: SemanticWorkspaceGesture?

    private enum CodingKeys: String, CodingKey {
        case command
        case token
        case tab
        case key
        case gesture
    }
}

@MainActor
final class SemanticAdapterConnectionStateStore {
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var activeIDs: Set<ObjectIdentifier> = []

    var activeConnectionCount: Int {
        activeIDs.count
    }

    func register(_ id: ObjectIdentifier) {
        activeIDs.insert(id)
        buffers[id] = Data()
    }

    func append(_ data: Data, for id: ObjectIdentifier) {
        guard activeIDs.contains(id) else { return }
        buffers[id, default: Data()].append(data)
    }

    func bufferedByteCount(for id: ObjectIdentifier) -> Int {
        buffers[id]?.count ?? 0
    }

    var totalBufferedByteCount: Int {
        buffers.values.reduce(into: 0) { total, buffer in
            total += buffer.count
        }
    }

    func popLine(for id: ObjectIdentifier) -> Data? {
        guard let buffer = buffers[id],
              let range = buffer.range(of: Data([0x0A]))
        else {
            return nil
        }
        let line = Data(buffer[..<range.lowerBound])
        buffers[id] = Data(buffer[range.upperBound...])
        return line
    }

    func cleanup(_ id: ObjectIdentifier) {
        activeIDs.remove(id)
        buffers.removeValue(forKey: id)
    }

    func cleanupAll() {
        activeIDs.removeAll()
        buffers.removeAll()
    }
}

/// A dev/test-only semantic bridge. Product startup constructs and starts it
/// only after the explicit `RuntimeAdapterStartupPolicy` gate; packaged
/// production remains inert. Execute remains governed by
/// `SwitcherActionService`'s existing policy gates.
@MainActor
public final class SemanticAdapterServer {
    public static let maxFrameBytes = 64 * 1024

    public let mode: SemanticAdapterMode
    public let token: String

    private let runtime: SemanticAdapterRuntime
    private let executionPolicy: ExecutionPolicy
    private let metadataURL: URL
    private let logURL: URL
    private let bundleName: String
    private let version: String
    private let metadataWriter: (Data, URL) throws -> Void
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let connectionState = SemanticAdapterConnectionStateStore()
    private var startContinuation: CheckedContinuation<SemanticAdapterRuntimeMetadata, Error>?
    private var generation: UInt = 0
    private var activeGeneration: UInt?
    private var metadataOwnedByInstance = false
    private var totalAcceptedConnectionsForTesting = 0
    private var cleanupInProgress = false

    var staleConnectionCancellationObserverForTesting: ((ObjectIdentifier) -> Void)?
    var holdStartCompletionForTesting = false

    public private(set) var metadata: SemanticAdapterRuntimeMetadata?

    public init(
        runtime: SemanticAdapterRuntime,
        mode: SemanticAdapterMode = .productionDisabled,
        token: String? = nil,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(),
        metadataURL: URL? = nil,
        logURL: URL? = nil,
        bundleName: String? = nil,
        version: String? = nil,
        metadataWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.runtime = runtime
        self.mode = mode
        self.token = token ?? Self.makeToken()
        self.executionPolicy = executionPolicy
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-switcher", isDirectory: true)
        self.metadataURL = metadataURL
            ?? temporaryDirectory.appendingPathComponent(
                "runtime-\(ProcessInfo.processInfo.processIdentifier).json"
            )
        self.logURL = logURL
            ?? temporaryDirectory.appendingPathComponent(
                "runtime-\(ProcessInfo.processInfo.processIdentifier).log"
            )
        self.bundleName = bundleName
            ?? Bundle.main.bundleIdentifier
            ?? "ScreenSwitcherApp"
        self.version = version
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "dev"
        self.metadataWriter = metadataWriter ?? { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    var generationForTesting: UInt {
        generation
    }

    func isCurrentGenerationForTesting(_ expected: UInt) -> Bool {
        generation == expected && activeGeneration == expected && listener != nil
    }

    var acceptedConnectionCountForTesting: Int {
        totalAcceptedConnectionsForTesting
    }

    var activeConnectionCountForTesting: Int {
        connectionState.activeConnectionCount
    }

    var totalBufferedByteCountForTesting: Int {
        connectionState.totalBufferedByteCount
    }

    func triggerNewConnectionForTesting(_ connection: NWConnection) {
        listener?.newConnectionHandler?(connection)
    }

    func triggerListenerStateForTesting(_ state: NWListener.State) {
        handle(listenerState: state)
    }

    /// Handles one JSON line without opening a socket, keeping the command
    /// contract directly testable and reusable by the Network transport.
    public func handle(jsonLine: String) async -> SemanticAdapterResponse {
        guard let data = jsonLine.data(using: .utf8),
              let request = try? JSONDecoder().decode(SemanticAdapterRequest.self, from: data)
        else {
            let response = failure(
                command: nil,
                code: .invalidRequest,
                message: "Request must be one JSON object per line"
            )
            appendLog(command: nil, response: response)
            return response
        }

        if mode == .productionDisabled {
            let response = failure(
                command: nil,
                code: .productionDisabled,
                message: "Semantic adapter is disabled for production"
            )
            appendLog(command: nil, response: response)
            return response
        }

        guard let suppliedToken = request.token else {
            let response = failure(
                command: nil,
                code: .missingToken,
                message: "A runtime token is required"
            )
            appendLog(command: nil, response: response)
            return response
        }
        guard suppliedToken == token else {
            let response = failure(
                command: nil,
                code: .invalidToken,
                message: "The runtime token is invalid"
            )
            appendLog(command: nil, response: response)
            return response
        }
        guard let command = SemanticAdapterCommand(rawValue: request.command) else {
            let response = failure(
                command: nil,
                code: .unknownCommand,
                message: "Command is not in the semantic adapter allowlist"
            )
            appendLog(command: nil, response: response)
            return response
        }

        let response: SemanticAdapterResponse
        switch command {
        case .snapshot:
            response = success(command: command.rawValue)
        case .open:
            guard let tab = workspaceTab(rawValue: request.tab) else {
                response = failure(
                    command: command.rawValue,
                    code: .invalidRequest,
                    message: "workspace.open requires a supported tab"
                )
                appendLog(command: command.rawValue, response: response)
                return response
            }
            runtime.openWorkspace(tab: tab)
            response = success(command: command.rawValue)
        case .close:
            runtime.closePanel()
            response = success(command: command.rawValue)
        case .key:
            guard let key = workspaceKey(rawValue: request.key) else {
                response = failure(
                    command: command.rawValue,
                    code: .invalidRequest,
                    message: "workspace.key requires a supported key and an open overlay"
                )
                appendLog(command: command.rawValue, response: response)
                return response
            }
            guard key != .returnKey else {
                response = failure(
                    command: command.rawValue,
                    code: .invalidRequest,
                    message: "workspace.key cannot execute actions; use workspace.executeDryRun"
                )
                appendLog(command: command.rawValue, response: response)
                return response
            }
            let handled = switch key {
            case .appLetter, .displayIndex:
                runtime.selectWorkspaceDryRunTarget(key)
            default:
                runtime.sendWorkspaceKey(key)
            }
            guard handled else {
                response = failure(
                    command: command.rawValue,
                    code: .invalidRequest,
                    message: "workspace.key requires an open overlay"
                )
                appendLog(command: command.rawValue, response: response)
                return response
            }
            response = success(command: command.rawValue)
        case .gesture:
            guard let gesture = request.gesture,
                  gesture.id > 0,
                  gesture.deltaX.isFinite,
                  gesture.deltaY.isFinite,
                  gesture.velocityX.isFinite,
                  gesture.velocityY.isFinite,
                  runtime.sendWorkspaceGesture(gesture) else {
                response = failure(
                    command: command.rawValue,
                    code: .invalidRequest,
                    message: "workspace.gesture requires a valid gesture and an open overlay"
                )
                appendLog(command: command.rawValue, response: response)
                return response
            }
            response = success(command: command.rawValue)
        case .executeDryRun:
            guard runtime.executeWorkspaceDryRun() else {
                response = failure(
                    command: command.rawValue,
                    code: .panelNotOpen,
                    message: "workspace.executeDryRun requires an open overlay"
                )
                appendLog(command: command.rawValue, response: response)
                return response
            }
            response = success(command: command.rawValue)
        }
        appendLog(command: command.rawValue, response: response)
        return response
    }

    public func jsonLine(for response: SemanticAdapterResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(response)
        data.append(0x0A)
        return data
    }

    /// Starts an IPv4 loopback listener on an ephemeral port and writes the
    /// short-lived metadata file only after the listener is ready.
    public func start() async throws -> SemanticAdapterRuntimeMetadata {
        guard mode == .devTest else { throw SemanticAdapterServerError.productionDisabled }
        guard listener == nil else { throw SemanticAdapterServerError.alreadyStarted }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 0)!
        )
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)
        self.listener = listener
        generation &+= 1
        let currentGeneration = generation
        activeGeneration = currentGeneration
        let listenerID = ObjectIdentifier(listener)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self, weak listener] in
                guard let self, listener != nil,
                      self.isCurrentListener(
                          generation: currentGeneration,
                          listenerID: listenerID
                      )
                else { return }
                self.handle(listenerState: state)
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor [weak self, weak listener] in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard listener != nil,
                      self.isCurrentListener(
                          generation: currentGeneration,
                          listenerID: listenerID
                      )
                else {
                    connection.cancel()
                    self.staleConnectionCancellationObserverForTesting?(
                        ObjectIdentifier(connection)
                    )
                    return
                }
                self.accept(connection)
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                if Task.isCancelled {
                    cleanupAfterListenerTermination(resumeError: .startCancelled)
                    return
                }
                listener.start(queue: .main)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelPendingStart()
            }
        })
    }

    public func stop() {
        cleanupAfterListenerTermination(resumeError: .listenerFailed)
        (runtime as? SemanticAdapterRuntimeTearingDown)?.teardown()
    }

    private func success(command: String) -> SemanticAdapterResponse {
        let state = runtime.state()
        return SemanticAdapterResponse(
            ok: true,
            command: command,
            state: SemanticAdapterState(
                isPanelOpen: state.isPanelOpen,
                selectedItemID: nil,
                snapshot: nil,
                permissionState: nil,
                adapterMode: "product_runtime",
                dryRun: true,
                panelGeometry: state.panelGeometry,
                workspace: workspaceSnapshot(runtimeState: state, snapshot: runtime.snapshot())
            ),
            error: nil
        )
    }

    private func workspaceTab(rawValue: String?) -> WorkspaceTab? {
        switch rawValue {
        case "switch": return .switch
        case "agents": return .agents
        case "focus": return .focus
        default: return nil
        }
    }

    private func workspaceKey(rawValue: String?) -> WorkspaceKeyCommand? {
        switch rawValue {
        case "previous_app_page": return .previousAppPage
        case "next_app_page": return .nextAppPage
        case "escape": return .escape
        case "return", "enter": return .returnKey
        case "app_a": return .appLetter(0)
        case "display_1": return .displayIndex(1)
        case "display_2": return .displayIndex(2)
        case "display_3": return .displayIndex(3)
        default: return nil
        }
    }

    private func workspaceSnapshot(
        runtimeState: SemanticAdapterRuntimeState,
        snapshot: SwitcherSnapshot
    ) -> SemanticWorkspaceSnapshot {
        let pointerDisplay = runtimeState.pointerDisplayID.flatMap { pointerID in
            snapshot.displays.first { $0.id == pointerID }
        } ?? snapshot.displays.first(where: \.isCurrent) ?? snapshot.displays.first
        let targetDisplay = snapshot.displays.first { $0.id == runtimeState.selectedItemID }
            ?? pointerDisplay
        let overlayDisplay = runtimeState.isPanelOpen
            ? runtimeState.overlayDisplayID.flatMap { overlayID in
                snapshot.displays.first { $0.id == overlayID }
            } ?? pointerDisplay
            : nil
        let fallbackOverlayFrame = overlayDisplay?.frame ?? targetDisplay?.frame
        let targetWorkspace = snapshot.workspaces.first { $0.display.id == targetDisplay?.id }
        let identities = stableUnique(snapshot.runningApps.map(\.id)).map(Self.sanitizedBundleIdentity)
        return SemanticWorkspaceSnapshot(
            isOverlayOpen: runtimeState.isPanelOpen,
            currentTab: Self.workspaceTabName(runtimeState.currentTab),
            overlayDisplayID: runtimeState.isPanelOpen
                ? runtimeState.overlayDisplayID ?? overlayDisplay?.id
                : nil,
            pointerDisplayID: pointerDisplay?.id,
            targetDisplayID: targetDisplay?.id,
            focusedAppBundleIdentity: snapshot.frontmostAppID.map(Self.sanitizedBundleIdentity),
            dimmedDisplayIDs: runtimeState.isPanelOpen
                ? snapshot.displays.map(\.id).filter { $0 != overlayDisplay?.id }
                : [],
            overlayFrame: SemanticWorkspaceFrame(
                x: runtimeState.overlayFrame?.x ?? fallbackOverlayFrame?.x ?? 0,
                y: runtimeState.overlayFrame?.y ?? fallbackOverlayFrame?.y ?? 0,
                width: runtimeState.overlayFrame?.width ?? fallbackOverlayFrame?.width ?? 0,
                height: runtimeState.overlayFrame?.height ?? fallbackOverlayFrame?.height ?? 0
            ),
            gesturePhase: runtimeState.gesturePhase,
            reducedMotion: runtimeState.reducedMotion,
            previewAvailability: Self.workspacePreviewAvailabilityName(
                targetWorkspace?.previewAvailability ?? .schematicFallback
            ),
            appPage: runtimeState.appPage,
            appBundleIdentities: identities,
            selectedTargetKind: runtimeState.selectedTargetKind,
            selectedTargetIdentity: runtimeState.selectedTargetIdentity.map { rawValue in
                runtimeState.selectedTargetKind == "app"
                    ? Self.sanitizedBundleIdentity(rawValue)
                    : rawValue
            },
            dryRunSelectionConfirmed: runtimeState.dryRunSelectionConfirmed,
            tabTransitionRevision: runtimeState.tabTransitionRevision,
            tabSettledRevision: runtimeState.tabSettledRevision,
            displayCardTransitionRevision: runtimeState.displayCardTransitionRevision,
            displayCardSettledRevision: runtimeState.displayCardSettledRevision
        )
    }

    private static func workspaceTabName(_ tab: WorkspaceTab) -> String {
        switch tab {
        case .switch: return "switch"
        case .agents: return "agents"
        case .focus: return "focus"
        }
    }

    private static func workspacePreviewAvailabilityName(_ availability: PreviewAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .schematicFallback: return "schematic_fallback"
        }
    }

    private static func sanitizedBundleIdentity(_ rawValue: String) -> String {
        ProductAppAXIdentity.opaqueToken(forBundleIdentifier: rawValue)
    }

    private func stableUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func failure(
        command: String?,
        code: SemanticAdapterErrorCode,
        message: String
    ) -> SemanticAdapterResponse {
        SemanticAdapterResponse(
            ok: false,
            command: command,
            state: nil,
            error: SemanticAdapterError(code: code, message: message)
        )
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            guard startContinuation != nil, metadata == nil else { return }
            guard let port = listener?.port?.rawValue, port != 0 else {
                cleanupAfterListenerTermination(resumeError: .listenerFailed)
                return
            }
            let metadata = SemanticAdapterRuntimeMetadata(
                pid: ProcessInfo.processInfo.processIdentifier,
                port: port,
                tokenReference: Self.tokenReference(for: token),
                bundle: bundleName,
                version: version,
                logPath: logURL.path
            )
            guard !FileManager.default.fileExists(atPath: metadataURL.path) else {
                metadataOwnedByInstance = false
                cleanupAfterListenerTermination(resumeError: .metadataWriteFailed)
                return
            }
            metadataOwnedByInstance = true
            do {
                try writeMetadata(metadata)
            } catch {
                cleanupAfterListenerTermination(resumeError: .metadataWriteFailed)
                return
            }
            self.metadata = metadata
            appendLog(command: "server_started", response: nil)
            if holdStartCompletionForTesting {
                return
            }
            if let startContinuation {
                self.startContinuation = nil
                startContinuation.resume(returning: metadata)
            }
        case .failed:
            cleanupAfterListenerTermination(resumeError: .listenerFailed)
        case .cancelled:
            cleanupAfterListenerTermination(resumeError: .listenerFailed)
        default:
            break
        }
    }

    private func cleanupAfterListenerTermination(
        resumeError: SemanticAdapterServerError?
    ) {
        guard !cleanupInProgress else { return }
        cleanupInProgress = true
        defer { cleanupInProgress = false }

        generation &+= 1
        activeGeneration = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        while let connection = connections.first {
            finish(connection)
        }
        connectionState.cleanupAll()
        metadata = nil
        cleanupOwnedMetadata()

        guard let resumeError, let startContinuation else { return }
        self.startContinuation = nil
        startContinuation.resume(throwing: resumeError)
    }

    private func cancelPendingStart() {
        guard startContinuation != nil else { return }
        cleanupAfterListenerTermination(resumeError: .startCancelled)
    }

    private func isCurrentListener(generation: UInt, listenerID: ObjectIdentifier) -> Bool {
        self.generation == generation
            && activeGeneration == generation
            && self.listener.map { ObjectIdentifier($0) == listenerID } == true
    }

    private func accept(_ connection: NWConnection) {
        totalAcceptedConnectionsForTesting += 1
        connections.append(connection)
        connectionState.register(ObjectIdentifier(connection))
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receive(on: connection)
                case .failed, .cancelled:
                    self.finish(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let key = ObjectIdentifier(connection)
                if let data {
                    connectionState.append(data, for: key)
                    if await processLines(on: connection, key: key) {
                        return
                    }
                    if connectionState.bufferedByteCount(for: key) > Self.maxFrameBytes {
                        send(
                            requestTooLargeResponse(),
                            on: connection,
                            closeAfterSend: true
                        )
                        return
                    }
                }
                if isComplete || error != nil {
                    finish(connection)
                } else {
                    receive(on: connection)
                }
            }
        }
    }

    /// Processes newline-delimited payloads. The limit applies to each JSON
    /// payload, including fragments accumulated across multiple receives, but
    /// excludes the delimiter itself.
    @discardableResult
    private func processLines(on connection: NWConnection, key: ObjectIdentifier) async -> Bool {
        while let line = connectionState.popLine(for: key) {
            guard line.count <= Self.maxFrameBytes else {
                send(
                    requestTooLargeResponse(),
                    on: connection,
                    closeAfterSend: true
                )
                return true
            }
            let response = await handle(jsonLine: String(decoding: line, as: UTF8.self))
            send(response, on: connection)
        }
        return false
    }

    private func requestTooLargeResponse() -> SemanticAdapterResponse {
        failure(
            command: nil,
            code: .requestTooLarge,
            message: "The JSON line exceeds the maximum frame size"
        )
    }

    private func send(
        _ response: SemanticAdapterResponse,
        on connection: NWConnection,
        closeAfterSend: Bool = false
    ) {
        guard let output = try? jsonLine(for: response) else {
            finish(connection)
            return
        }
        connection.send(
            content: output,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                guard closeAfterSend || error != nil else { return }
                Task { @MainActor in
                    self.finish(connection)
                }
            }
        )
    }

    private func finish(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connection.stateUpdateHandler = nil
        connection.cancel()
        connections.removeAll { $0 === connection }
        connectionState.cleanup(key)
    }

    private func writeMetadata(_ metadata: SemanticAdapterRuntimeMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        try metadataWriter(data, metadataURL)
    }

    private func cleanupOwnedMetadata() {
        guard metadataOwnedByInstance else { return }
        try? FileManager.default.removeItem(at: metadataURL)
        metadataOwnedByInstance = false
    }

    private func appendLog(command: String?, response: SemanticAdapterResponse?) {
        let outcome = response?.ok == true ? "ok" : (response == nil ? "ready" : "error")
        let errorCode = response?.error?.code.rawValue ?? ""
        let loggedCommand = command.flatMap {
            SemanticAdapterCommand(rawValue: $0)?.rawValue
        } ?? "unknown"
        let line = "command=\(loggedCommand) outcome=\(outcome) error=\(errorCode)\n"
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = (try? Data(contentsOf: logURL)) ?? Data()
        var output = existing
        output.append(contentsOf: line.data(using: .utf8) ?? Data())
        try? output.write(to: logURL, options: .atomic)
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...UInt8.max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    private static func tokenReference(for token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SemanticAdapterServer: SemanticAdapterServerControlling {}

@MainActor
public final class SwitcherRuntimeSemanticAdapter: SemanticAdapterRuntime {
    private let runtimeState: SwitcherRuntimeState
    private let sessionProvider: @MainActor () -> SwitcherHeadlessSession?
    private let openPanelAction: @MainActor () -> Void
    private let closePanelAction: @MainActor () -> Void

    public init(
        runtimeState: SwitcherRuntimeState,
        sessionProvider: @escaping @MainActor () -> SwitcherHeadlessSession?,
        openPanel: @escaping @MainActor () -> Void,
        closePanel: @escaping @MainActor () -> Void
    ) {
        self.runtimeState = runtimeState
        self.sessionProvider = sessionProvider
        self.openPanelAction = openPanel
        self.closePanelAction = closePanel
    }

    public func state() -> SemanticAdapterRuntimeState {
        let session = sessionProvider()
        return SemanticAdapterRuntimeState(
            isPanelOpen: session?.isOpen == true,
            selectedItemID: session?.selectedItemID,
            permissionState: permissionState(),
            panelGeometry: nil
        )
    }

    public func snapshot() -> SwitcherSnapshot {
        runtimeState.semanticSnapshot()
    }

    public func openPanel() {
        openPanelAction()
    }

    public func select(itemID: String) -> Bool {
        sessionProvider()?.select(itemID: itemID) ?? false
    }

    public func executeSelected() async -> Result<Void, SwitcherActionFailure> {
        guard let session = sessionProvider() else { return .failure(.panelNotOpen) }
        return await session.executeSelected()
    }

    public func permissionState() -> SemanticAdapterPermissionState {
        switch runtimeState.runningAppCatalog.permissionState() {
        case .granted:
            return .granted
        case .accessibilityMissing:
            return .accessibilityMissing
        }
    }

    public func closePanel() {
        closePanelAction()
    }
}

extension SwitcherSemanticModel {
    func makeSemanticAdapterRuntime() -> SwitcherRuntimeSemanticAdapter {
        var session: SwitcherHeadlessSession?
        return SwitcherRuntimeSemanticAdapter(
            runtimeState: runtimeState,
            sessionProvider: { session },
            openPanel: { [weak self] in
                guard let self else { return }
                let opened = self.makeHeadlessSession()
                opened.open(snapshot: self.runtimeState.liveSnapshot())
                session = opened
            },
            closePanel: {
                session?.close(reason: .programmatic)
                session = nil
            }
        )
    }
}

// MARK: - Semantic v3 server (FocusScreen)

/// The v3 semantic focus-screen request. Unknown keys are rejected so the
/// wire contract stays closed.
struct FocusScreenSemanticRequest: Decodable {
    let command: String
    let token: String?
    let key: String?
    let screenID: String?
    let windowID: String?
    let spaceID: String?
    let tabID: String?
    let paneID: String?
    let ratioPrimary: Double?
    let expectedPresentationRevision: UInt64?
    let expectedScreen: FocusSemanticScreen?
    private let receivedKeys: Set<String>

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case command
        case token
        case key
        case screenID
        case windowID
        case spaceID
        case tabID
        case paneID
        case ratioPrimary
        case expectedPresentationRevision
        case expectedScreen
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let allowedKeys = Set(CodingKeys.allCases.map(\.stringValue))
        if container.allKeys.contains(where: { !allowedKeys.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown FocusScreen semantic request key"
            ))
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        receivedKeys = Set(container.allKeys.map(\.stringValue))
        command = try keyed.decode(String.self, forKey: .command)
        token = try keyed.decodeIfPresent(String.self, forKey: .token)
        key = try keyed.decodeIfPresent(String.self, forKey: .key)
        screenID = try keyed.decodeIfPresent(String.self, forKey: .screenID)
        windowID = try keyed.decodeIfPresent(String.self, forKey: .windowID)
        spaceID = try keyed.decodeIfPresent(String.self, forKey: .spaceID)
        tabID = try keyed.decodeIfPresent(String.self, forKey: .tabID)
        paneID = try keyed.decodeIfPresent(String.self, forKey: .paneID)
        ratioPrimary = try keyed.decodeIfPresent(Double.self, forKey: .ratioPrimary)
        expectedPresentationRevision = try keyed.decodeIfPresent(UInt64.self, forKey: .expectedPresentationRevision)
        expectedScreen = try keyed.decodeIfPresent(FocusSemanticScreen.self, forKey: .expectedScreen)
    }

    func hasExactKeys(_ keys: Set<String>) -> Bool {
        receivedKeys == keys
    }
}

/// `JSONDecoder` accepts duplicate object keys, so validate the request before
/// decoding or dispatching any command with side effects.
private struct FocusScreenStrictJSONScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func validate() throws {
        try value(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw ValidationError.invalid }
    }

    private mutating func value(depth: Int) throws {
        guard depth < 64 else { throw ValidationError.invalid }
        skipWhitespace()
        guard index < bytes.count else { throw ValidationError.invalid }
        switch bytes[index] {
        case 123: try object(depth: depth + 1)
        case 91: try array(depth: depth + 1)
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try number()
        default: throw ValidationError.invalid
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1
        skipWhitespace()
        var keys = Set<String>()
        if consume(125) { return }
        while true {
            skipWhitespace()
            guard keys.insert(try string()).inserted else { throw ValidationError.invalid }
            skipWhitespace()
            guard consume(58) else { throw ValidationError.invalid }
            try value(depth: depth)
            skipWhitespace()
            if consume(125) { return }
            guard consume(44) else { throw ValidationError.invalid }
        }
    }

    private mutating func array(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(93) { return }
        while true {
            try value(depth: depth)
            skipWhitespace()
            if consume(93) { return }
            guard consume(44) else { throw ValidationError.invalid }
        }
    }

    private mutating func string() throws -> String {
        guard consume(34) else { throw ValidationError.invalid }
        let start = index - 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                let data = Data(bytes[start..<index])
                guard let value = try? JSONSerialization.jsonObject(
                    with: data,
                    options: .fragmentsAllowed
                ) as? String else { throw ValidationError.invalid }
                return value
            }
            if byte == 92 {
                guard index < bytes.count else { throw ValidationError.invalid }
                index += 1
            } else if byte < 32 {
                throw ValidationError.invalid
            }
        }
        throw ValidationError.invalid
    }

    private mutating func literal(_ value: String) throws {
        let target = Array(value.utf8)
        guard bytes[index...].starts(with: target) else { throw ValidationError.invalid }
        index += target.count
    }

    private mutating func number() throws {
        let start = index
        while index < bytes.count,
              bytes[index] == 45 || bytes[index] == 43 || bytes[index] == 46
                || bytes[index] == 69 || bytes[index] == 101
                || (48...57).contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw ValidationError.invalid }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private enum ValidationError: Error { case invalid }
}

/// The v3 semantic focus-screen response. Contains ONLY `schemaVersion`, `ok`,
/// `command`, `snapshot`, and `error`. `screen.snapshot` is always read-only;
/// mutation commands gate on the runtime execution policy.
public struct FocusScreenSemanticResponse: Codable, Equatable {
    public let schemaVersion: Int
    public let ok: Bool
    public let command: String?
    public let snapshot: FocusScreenSemanticSnapshotV3?
    public let error: SemanticAdapterError?

    public init(
        schemaVersion: Int = 3,
        ok: Bool,
        command: String?,
        snapshot: FocusScreenSemanticSnapshotV3?,
        error: SemanticAdapterError?
    ) {
        self.schemaVersion = schemaVersion
        self.ok = ok
        self.command = command
        self.snapshot = snapshot
        self.error = error
    }
}

/// A dev/test-only semantic v3 bridge over `FocusScreenSemanticRuntime`. Product
/// startup constructs and starts it only after the explicit
/// `RuntimeAdapterStartupPolicy` gate; packaged production remains inert.
/// Execute remains governed by the runtime execution policy.
///
/// The v3 server mirrors the v2 `SemanticAdapterServer`'s NWListener
/// implementation: a localhost-only listener, token gating, the closed
/// content-free contract in `handle(jsonLine:)`, and the same
/// connection-state / metadata cleanup. It reuses the v2 connection-state
/// store so the localhost / token / frame-size guarantees are identical.
@MainActor
public final class SemanticFocusScreenServer {
    public static let maxFrameBytes = 64 * 1024

    public let mode: SemanticAdapterMode
    public let token: String

    private let runtime: FocusScreenSemanticRuntime
    private let executionPolicy: ExecutionPolicy
    private let metadataURL: URL
    private let logURL: URL
    private let bundleName: String
    private let version: String
    private let metadataWriter: (Data, URL) throws -> Void
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let connectionState = SemanticAdapterConnectionStateStore()
    private var startContinuation: CheckedContinuation<SemanticAdapterRuntimeMetadata, Error>?
    private var generation: UInt = 0
    private var activeGeneration: UInt?
    private var metadataOwnedByInstance = false
    private var totalAcceptedConnectionsForTesting = 0
    private var cleanupInProgress = false

    var staleConnectionCancellationObserverForTesting: ((ObjectIdentifier) -> Void)?
    var holdStartCompletionForTesting = false

    public private(set) var metadata: SemanticAdapterRuntimeMetadata?

    public init(
        runtime: FocusScreenSemanticRuntime,
        mode: SemanticAdapterMode = .productionDisabled,
        token: String? = nil,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(),
        metadataURL: URL? = nil,
        logURL: URL? = nil,
        bundleName: String? = nil,
        version: String? = nil,
        metadataWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.runtime = runtime
        self.mode = mode
        self.token = token ?? Self.makeToken()
        self.executionPolicy = executionPolicy
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-switcher", isDirectory: true)
        self.metadataURL = metadataURL
            ?? temporaryDirectory.appendingPathComponent(
                "focus-runtime-\(ProcessInfo.processInfo.processIdentifier).json"
            )
        self.logURL = logURL
            ?? temporaryDirectory.appendingPathComponent(
                "focus-runtime-\(ProcessInfo.processInfo.processIdentifier).log"
            )
        self.bundleName = bundleName
            ?? Bundle.main.bundleIdentifier
            ?? "ScreenSwitcherApp"
        self.version = version
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "dev"
        self.metadataWriter = metadataWriter ?? { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    /// Generates a fresh per-run token shared with the v2 server's scheme.
    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...UInt8.max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    var generationForTesting: UInt {
        generation
    }

    func isCurrentGenerationForTesting(_ expected: UInt) -> Bool {
        generation == expected && activeGeneration == expected && listener != nil
    }

    var acceptedConnectionCountForTesting: Int {
        totalAcceptedConnectionsForTesting
    }

    var activeConnectionCountForTesting: Int {
        connectionState.activeConnectionCount
    }

    var totalBufferedByteCountForTesting: Int {
        connectionState.totalBufferedByteCount
    }

    func triggerNewConnectionForTesting(_ connection: NWConnection) {
        listener?.newConnectionHandler?(connection)
    }

    func triggerListenerStateForTesting(_ state: NWListener.State) {
        handle(listenerState: state)
    }

    /// Handles one JSON line without opening a socket, keeping the v3 command
    /// contract directly testable and reusable by the Network transport.
    public func handle(jsonLine: String) async -> FocusScreenSemanticResponse {
        guard let data = jsonLine.data(using: .utf8) else {
            return failure(command: nil, code: .invalidRequest, message: "Request must be one JSON object per line")
        }
        var scanner = FocusScreenStrictJSONScanner(data)
        guard (try? scanner.validate()) != nil else {
            return failure(command: nil, code: .invalidRequest, message: "Request fields are invalid")
        }
        guard let request = try? JSONDecoder().decode(FocusScreenSemanticRequest.self, from: data) else {
            return failure(command: nil, code: .invalidRequest, message: "Request must be one JSON object per line")
        }

        if mode == .productionDisabled {
            return failure(command: nil, code: .productionDisabled, message: "Semantic adapter is disabled for production")
        }
        guard let suppliedToken = request.token else {
            return failure(command: nil, code: .missingToken, message: "A runtime token is required")
        }
        guard suppliedToken == token else {
            return failure(command: nil, code: .invalidToken, message: "The runtime token is invalid")
        }
        guard let command = FocusSemanticCommand(rawValue: request.command) else {
            return failure(command: nil, code: .unknownCommand, message: "Command is not in the semantic adapter allowlist")
        }

        switch command {
        case .screenSnapshot:
            // Always read-only; bypasses the execution gate.
            return success(command: command)

        case .hudOpen:
            guard request.hasExactKeys(["command", "token"]) else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "hud.open request fields are invalid")
            }
            guard !runtime.isHUDVisible else {
                return failure(command: command.rawValue, code: .panelAlreadyOpen, message: "hud.open requires a closed overlay")
            }
            let baselinePresentationRevision = runtime.snapshot().hud.presentationRevision
            runtime.openHUD()
            let opened = runtime.snapshot()
            guard opened.hud.visible,
                  opened.hud.presentationRevision > baselinePresentationRevision else {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "hud.open did not create a new presentation")
            }
            return FocusScreenSemanticResponse(
                ok: true,
                command: command.rawValue,
                snapshot: opened,
                error: nil
            )

        case .hudClose:
            runtime.closeHUD()
            return success(command: command)

        case .hudCloseOwned:
            guard request.hasExactKeys(["command", "token", "expectedPresentationRevision"]) else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "hud.close-owned request fields are invalid")
            }
            guard let expectedRevision = request.expectedPresentationRevision else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "hud.close-owned requires expectedPresentationRevision")
            }
            guard runtime.isHUDVisible else {
                return failure(command: command.rawValue, code: .panelAlreadyClosed, message: "Owned HUD presentation is already closed")
            }
            let current = runtime.snapshot()
            guard current.hud.presentationRevision == expectedRevision else {
                return failure(command: command.rawValue, code: .panelOwnershipLost, message: "Owned HUD presentation was replaced")
            }
            runtime.closeHUD()
            let closed = runtime.snapshot()
            guard !closed.hud.visible else {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "Owned HUD presentation did not close")
            }
            return FocusScreenSemanticResponse(
                ok: true, command: command.rawValue, snapshot: closed, error: nil
            )

        case .hudKey:
            guard runtime.isHUDVisible else {
                return failure(command: command.rawValue, code: .panelNotOpen, message: "hud.key requires an open overlay")
            }
            guard let keyValue = request.key,
                  let key = Self.translateHUDKey(keyValue) else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "hud.key requires a supported key")
            }
            _ = runtime.sendHUDKey(key)
            return success(command: command)

        case .screenCreate:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "screen.create requires execution authorization")
            }
            guard let screenID = request.screenID, !screenID.isEmpty else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "screen.create requires a screenID")
            }
            do {
                try runtime.createScreen(id: screenID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "screen.create failed: \(error)")
            }
            return success(command: command)

        case .screenSwitch:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "screen.switch requires execution authorization")
            }
            guard let screenID = request.screenID,
                  let windowID = request.windowID,
                  !screenID.isEmpty,
                  !windowID.isEmpty else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "screen.switch requires a screenID and a windowID")
            }
            let result = await runtime.switchScreen(id: screenID, windowID: windowID)
            guard case .committed = result else {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "screen.switch transaction did not commit")
            }
            return success(command: command)

        case .screenClose:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "screen.close requires execution authorization")
            }
            guard let screenID = request.screenID, !screenID.isEmpty else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "screen.close requires a screenID")
            }
            do {
                try runtime.closeScreen(id: screenID)
            } catch FocusScreenDomainError.soleScreenCannotClose {
                return failure(command: command.rawValue, code: .invalidRequest, message: "screen.close cannot close the sole live screen")
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "screen.close failed: \(error)")
            }
            return success(command: command)

        case .screenCloseOwned:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "screen.close-owned requires execution authorization")
            }
            guard request.hasExactKeys(["command", "token", "expectedScreen"]),
                  let expected = request.expectedScreen else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "screen.close-owned requires an exact expectedScreen")
            }
            guard expected.windowIDs.isEmpty, expected.activeWindowID == nil else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "screen.close-owned accepts only an empty Screen fingerprint")
            }
            switch runtime.closeOwnedScreen(expected: expected) {
            case .closed:
                return success(command: command)
            case .ownershipLost:
                return failure(command: command.rawValue, code: .screenOwnershipLost, message: "Owned Screen was replaced")
            case .notFound:
                return failure(command: command.rawValue, code: .screenNotFound, message: "Owned Screen was already removed")
            case .failed:
                return failure(command: command.rawValue, code: .runtimeFailure, message: "Owned Screen did not close")
            }

        case .recoveryRevealAll:
            // Reveal All is a recovery primitive; it runs whenever the server is
            // authenticated and dev-test-enabled. It does not require the execute
            // gate because it restores visibility rather than mutating focus.
            _ = await runtime.revealAll()
            return success(command: command)

        case .spaceSave:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "Execution is not allowed in the current policy")
            }
            guard let spaceID = request.spaceID else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "space.save requires a spaceID")
            }
            do {
                try runtime.saveSpace(id: spaceID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "space.save failed: \(error)")
            }
            return success(command: command)

        case .spaceRestore:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "Execution is not allowed in the current policy")
            }
            guard let spaceID = request.spaceID, let screenID = request.screenID else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "space.restore requires spaceID and screenID")
            }
            do {
                try runtime.restoreSpace(spaceID, into: screenID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "space.restore failed: \(error)")
            }
            return success(command: command)

        case .layoutSet:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "Execution is not allowed in the current policy")
            }
            guard let screenID = request.screenID, let kindRaw = request.key, let kind = LayoutKind(rawValue: kindRaw) else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "layout.set requires screenID and a valid key (layout kind)")
            }
            do {
                try runtime.setLayout(kind, for: screenID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "layout.set failed: \(error)")
            }
            return success(command: command)

        case .tabActivate:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "Execution is not allowed in the current policy")
            }
            guard let tabID = request.tabID, let paneID = request.paneID, let screenID = request.screenID else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "tab.activate requires tabID, paneID, and screenID")
            }
            do {
                try runtime.activateTab(tabID, in: paneID, screenID: screenID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "tab.activate failed: \(error)")
            }
            return success(command: command)

        case .tabMove:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "Execution is not allowed in the current policy")
            }
            guard let tabID = request.tabID, let paneID = request.paneID, let screenID = request.screenID else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "tab.move requires tabID, paneID, and screenID")
            }
            do {
                try runtime.moveTab(tabID, to: paneID, screenID: screenID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "tab.move failed: \(error)")
            }
            return success(command: command)

        case .tabClose:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "Execution is not allowed in the current policy")
            }
            guard let tabID = request.tabID, let paneID = request.paneID, let screenID = request.screenID else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "tab.close requires tabID, paneID, and screenID")
            }
            do {
                try runtime.closeTab(tabID, in: paneID, screenID: screenID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "tab.close failed: \(error)")
            }
            return success(command: command)

        case .paneResize:
            guard executionPolicy.isExecuteAllowed else {
                return failure(command: command.rawValue, code: .executeNotAllowed, message: "Execution is not allowed in the current policy")
            }
            guard let paneID = request.paneID, let screenID = request.screenID, let ratioPrimary = request.ratioPrimary else {
                return failure(command: command.rawValue, code: .invalidRequest, message: "pane.resize requires paneID, screenID, and ratioPrimary")
            }
            do {
                try runtime.setPaneRatio(paneID, ratio: PaneRatio(primary: ratioPrimary), screenID: screenID)
            } catch {
                return failure(command: command.rawValue, code: .runtimeFailure, message: "pane.resize failed: \(error)")
            }
            return success(command: command)
        }
    }

    public func jsonLine(for response: FocusScreenSemanticResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(response)
        data.append(0x0A)
        return data
    }

    // MARK: - NWListener lifecycle (mirrors the v2 SemanticAdapterServer)

    /// Starts an IPv4 loopback listener on an ephemeral port and writes the
    /// short-lived metadata file only after the listener is ready. Mirrors the
    /// v2 `SemanticAdapterServer.start()` so the v3 server is reachable over the
    /// same localhost Network.framework transport the scenario client uses.
    ///
    /// Packaged production remains inert: only `.devTest` binds. This gate is
    /// identical to the v2 server's production-disabled guard.
    public func start() async throws -> SemanticAdapterRuntimeMetadata {
        guard mode == .devTest else { throw SemanticAdapterServerError.productionDisabled }
        guard listener == nil else { throw SemanticAdapterServerError.alreadyStarted }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 0)!
        )
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)
        self.listener = listener
        generation &+= 1
        let currentGeneration = generation
        activeGeneration = currentGeneration
        let listenerID = ObjectIdentifier(listener)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self, weak listener] in
                guard let self, listener != nil,
                      self.isCurrentListener(
                          generation: currentGeneration,
                          listenerID: listenerID
                      )
                else { return }
                self.handle(listenerState: state)
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor [weak self, weak listener] in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard listener != nil,
                      self.isCurrentListener(
                          generation: currentGeneration,
                          listenerID: listenerID
                      )
                else {
                    connection.cancel()
                    self.staleConnectionCancellationObserverForTesting?(
                        ObjectIdentifier(connection)
                    )
                    return
                }
                self.accept(connection)
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                if Task.isCancelled {
                    cleanupAfterListenerTermination(resumeError: .startCancelled)
                    return
                }
                listener.start(queue: .main)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelPendingStart()
            }
        })
    }

    public func stop() {
        cleanupAfterListenerTermination(resumeError: .listenerFailed)
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            guard startContinuation != nil, metadata == nil else { return }
            guard let port = listener?.port?.rawValue, port != 0 else {
                cleanupAfterListenerTermination(resumeError: .listenerFailed)
                return
            }
            let metadata = SemanticAdapterRuntimeMetadata(
                pid: ProcessInfo.processInfo.processIdentifier,
                port: port,
                tokenReference: Self.tokenReference(for: token),
                bundle: bundleName,
                version: version,
                logPath: logURL.path
            )
            guard !FileManager.default.fileExists(atPath: metadataURL.path) else {
                metadataOwnedByInstance = false
                cleanupAfterListenerTermination(resumeError: .metadataWriteFailed)
                return
            }
            metadataOwnedByInstance = true
            do {
                try writeMetadata(metadata)
            } catch {
                cleanupAfterListenerTermination(resumeError: .metadataWriteFailed)
                return
            }
            self.metadata = metadata
            appendLog(command: "server_started", response: nil)
            if holdStartCompletionForTesting {
                return
            }
            if let startContinuation {
                self.startContinuation = nil
                startContinuation.resume(returning: metadata)
            }
        case .failed:
            cleanupAfterListenerTermination(resumeError: .listenerFailed)
        case .cancelled:
            cleanupAfterListenerTermination(resumeError: .listenerFailed)
        default:
            break
        }
    }

    private func cleanupAfterListenerTermination(
        resumeError: SemanticAdapterServerError?
    ) {
        guard !cleanupInProgress else { return }
        cleanupInProgress = true
        defer { cleanupInProgress = false }

        generation &+= 1
        activeGeneration = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        while let connection = connections.first {
            finish(connection)
        }
        connectionState.cleanupAll()
        metadata = nil
        cleanupOwnedMetadata()

        guard let resumeError, let startContinuation else { return }
        self.startContinuation = nil
        startContinuation.resume(throwing: resumeError)
    }

    private func cancelPendingStart() {
        guard startContinuation != nil else { return }
        cleanupAfterListenerTermination(resumeError: .startCancelled)
    }

    private func isCurrentListener(generation: UInt, listenerID: ObjectIdentifier) -> Bool {
        self.generation == generation
            && activeGeneration == generation
            && self.listener.map { ObjectIdentifier($0) == listenerID } == true
    }

    private func accept(_ connection: NWConnection) {
        totalAcceptedConnectionsForTesting += 1
        connections.append(connection)
        connectionState.register(ObjectIdentifier(connection))
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receive(on: connection)
                case .failed, .cancelled:
                    self.finish(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let key = ObjectIdentifier(connection)
                if let data {
                    connectionState.append(data, for: key)
                    if await processLines(on: connection, key: key) {
                        return
                    }
                    if connectionState.bufferedByteCount(for: key) > Self.maxFrameBytes {
                        send(
                            requestTooLargeResponse(),
                            on: connection,
                            closeAfterSend: true
                        )
                        return
                    }
                }
                if isComplete || error != nil {
                    finish(connection)
                } else {
                    receive(on: connection)
                }
            }
        }
    }

    /// Processes newline-delimited payloads. The limit applies to each JSON
    /// payload, including fragments accumulated across multiple receives, but
    /// excludes the delimiter itself.
    @discardableResult
    private func processLines(on connection: NWConnection, key: ObjectIdentifier) async -> Bool {
        while let line = connectionState.popLine(for: key) {
            guard line.count <= Self.maxFrameBytes else {
                send(
                    requestTooLargeResponse(),
                    on: connection,
                    closeAfterSend: true
                )
                return true
            }
            let response = await handle(jsonLine: String(decoding: line, as: UTF8.self))
            send(response, on: connection)
        }
        return false
    }

    private func requestTooLargeResponse() -> FocusScreenSemanticResponse {
        failure(
            command: nil,
            code: .requestTooLarge,
            message: "The JSON line exceeds the maximum frame size"
        )
    }

    private func send(
        _ response: FocusScreenSemanticResponse,
        on connection: NWConnection,
        closeAfterSend: Bool = false
    ) {
        guard let output = try? jsonLine(for: response) else {
            finish(connection)
            return
        }
        connection.send(
            content: output,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                guard closeAfterSend || error != nil else { return }
                Task { @MainActor in
                    self.finish(connection)
                }
            }
        )
    }

    private func finish(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connection.stateUpdateHandler = nil
        connection.cancel()
        connections.removeAll { $0 === connection }
        connectionState.cleanup(key)
    }

    private func writeMetadata(_ metadata: SemanticAdapterRuntimeMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        try metadataWriter(data, metadataURL)
    }

    private func cleanupOwnedMetadata() {
        guard metadataOwnedByInstance else { return }
        try? FileManager.default.removeItem(at: metadataURL)
        metadataOwnedByInstance = false
    }

    private func appendLog(command: String?, response: FocusScreenSemanticResponse?) {
        let outcome = response?.ok == true ? "ok" : (response == nil ? "ready" : "error")
        let errorCode = response?.error?.code.rawValue ?? ""
        let loggedCommand = command ?? "unknown"
        let line = "command=\(loggedCommand) outcome=\(outcome) error=\(errorCode)\n"
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = (try? Data(contentsOf: logURL)) ?? Data()
        var output = existing
        output.append(contentsOf: line.data(using: .utf8) ?? Data())
        try? output.write(to: logURL, options: .atomic)
    }

    private static func tokenReference(for token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private func success(command: FocusSemanticCommand) -> FocusScreenSemanticResponse {
        FocusScreenSemanticResponse(
            ok: true,
            command: command.rawValue,
            snapshot: runtime.snapshot(),
            error: nil
        )
    }

    private func failure(
        command: String?,
        code: SemanticAdapterErrorCode,
        message: String
    ) -> FocusScreenSemanticResponse {
        FocusScreenSemanticResponse(
            ok: false,
            command: command,
            snapshot: nil,
            error: SemanticAdapterError(code: code, message: message)
        )
    }

    /// Translates semantic physical-key grammar to the overview reducer input.
    static func translateHUDKey(_ rawValue: String) -> FocusHUDOverviewKey? {
        switch rawValue {
        case "escape": return .escape
        case "return": return .returnKey
        case "tab": return .tab
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        default:
            let shifted = rawValue.hasPrefix("shift+")
            let token = shifted ? String(rawValue.dropFirst("shift+".count)) : rawValue
            guard token.count == 1, let scalar = token.unicodeScalars.first else { return nil }
            if (UnicodeScalar("a").value...UnicodeScalar("z").value).contains(scalar.value) {
                return .shortcut(.letter(Character(token)), shifted: shifted)
            }
            if (UnicodeScalar("0").value...UnicodeScalar("9").value).contains(scalar.value),
               let digit = Int(token) {
                return .shortcut(.digit(digit), shifted: shifted)
            }
            return nil
        }
    }
}

extension SemanticFocusScreenServer: SemanticAdapterServerControlling {
    // The v3 server conforms to the lifecycle protocol so the AppDelegate
    // bootstrap can swap it in for the v2 server without changing the wiring.
    // `start()`/`stop()` are implemented above on the class itself; this
    // extension only declares protocol conformance (the methods satisfy
    // `start() async throws -> SemanticAdapterRuntimeMetadata` and `stop()`).
}
