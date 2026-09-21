public enum FocusSemanticCommand: String, Codable, CaseIterable, Sendable {
    case screenSnapshot = "screen.snapshot"
    case hudOpen = "hud.open"
    case hudClose = "hud.close"
    case hudCloseOwned = "hud.close-owned"
    case hudKey = "hud.key"
    case screenCreate = "screen.create"
    case screenSwitch = "screen.switch"
    case screenClose = "screen.close"
    case screenCloseOwned = "screen.close-owned"
    case recoveryRevealAll = "recovery.revealAll"
    // Phase 1B
    case spaceSave = "space.save"
    case spaceRestore = "space.restore"
    // Phase 1C
    case tabActivate = "tab.activate"
    case tabMove = "tab.move"
    case tabClose = "tab.close"
    case paneResize = "pane.resize"
    case layoutSet = "layout.set"
}

public enum FocusSemanticOwnedScreenCloseOutcome: Equatable, Sendable {
    case closed
    case ownershipLost
    case notFound
    case failed
}

struct ScreenDomainDynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

enum ScreenDomainClosedDecoding {
    static func validateExactKeys<Key>(
        _: Key.Type,
        from decoder: Decoder
    ) throws where Key: CodingKey & CaseIterable {
        let container = try decoder.container(keyedBy: ScreenDomainDynamicCodingKey.self)
        let allowedKeys = Set(Key.allCases.map(\.stringValue))
        guard container.allKeys.contains(where: {
            !allowedKeys.contains($0.stringValue)
        }) else {
            return
        }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown ScreenDomainCore key"
            )
        )
    }
}

public enum FocusSemanticHUDLayoutMode: String, Codable, Sendable {
    case segmented
    case workspaceOverview
}

public struct FocusSemanticHUDWorkspaceSection: Codable, Equatable, Sendable {
    public let screenID: FocusScreenID
    public let appIdentityHashes: [String]
    public let shortcutCount: Int
    public let rowCount: Int

    public init(
        screenID: FocusScreenID,
        appIdentityHashes: [String],
        shortcutCount: Int,
        rowCount: Int
    ) {
        self.screenID = screenID
        self.appIdentityHashes = appIdentityHashes
        self.shortcutCount = shortcutCount
        self.rowCount = rowCount
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case screenID
        case appIdentityHashes
        case shortcutCount
        case rowCount
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            screenID: try container.decode(FocusScreenID.self, forKey: .screenID),
            appIdentityHashes: try container.decode([String].self, forKey: .appIdentityHashes),
            shortcutCount: try container.decode(Int.self, forKey: .shortcutCount),
            rowCount: try container.decode(Int.self, forKey: .rowCount)
        )
    }
}

public enum FocusSemanticHUDNameFocusSource: String, Codable, Equatable, Sendable {
    case none
    case keyboardFocus = "keyboard_focus"
    case pointerHover = "pointer_hover"
}

public enum FocusSemanticHUDRenderedLayoutState: String, Codable, Equatable, Sendable {
    case none
    case overview
    case layoutUnavailable = "layout_unavailable"
}

public enum FocusSemanticHUDLastCloseReason: String, Codable, Equatable, Sendable {
    case none
    case escape
    case outsideClick = "outside_click"
    case programmatic
    case applicationTermination = "application_termination"
}

public enum FocusSemanticHUDLastMouseRoute: String, Codable, Equatable, Sendable {
    case localHUD = "local_hud"
    case localOutside = "local_outside"
    case globalHUDExact = "global_hud_exact"
    case globalHUDTopmost = "global_hud_topmost"
    case globalOutsideExact = "global_outside_exact"
    case globalOutsideTopmost = "global_outside_topmost"
    case globalUnresolved = "global_unresolved"
    case staleIgnored = "stale_ignored"
}

/// Reserved content-free marker carried only on Diagnostics-owned HUD focus mouse
/// events. The marker is never serialized; semantic state exposes only whether
/// it matched during the current owned presentation.
public enum FocusSemanticHUDFocusAttemptMarker {
    public static let eventSourceUserData: Int64 = 0x5353_4653_4844
}

public enum FocusSemanticHUDActivationStage: String, Codable, Equatable, Sendable {
    case idle
    case intent
    case queued
    case binding
    case activate
    case resolution
    case raise
    case focusWrite = "focus_write"
    case readback
    case applied
    case cancelled
    case fallback
    case commit
}

public enum FocusSemanticHUDActivationResult: String, Codable, Equatable, Sendable {
    case idle
    case pending
    case applied
    case unsupported
    case timedOut = "timed_out"
    case vanished
    case failed
    case cancelled
    case blocked
}

public enum FocusSemanticHUDActivationBindingKind: String, Codable, Equatable, Sendable {
    case none
    case system
    case windowServer = "window_server"
    case injected
}

public enum FocusSemanticHUDActivationBlockReason: String, Codable, Equatable, Sendable {
    case none
    case physicalMutation = "physical_mutation"
    case mappingUnavailable = "mapping_unavailable"
    case targetUnavailable = "target_unavailable"
    case bindingUnavailable = "binding_unavailable"
    case recoveryIncompatible = "recovery_incompatible"
    case selectionSuperseded = "selection_superseded"
    case bindingChanged = "binding_changed"
    case inventoryChanged = "inventory_changed"
    case activationRejected = "activation_rejected"
    case exactFocusSymbolUnavailable = "exact_focus_symbol_unavailable"
    case exactFocusProcessResolutionFailed = "exact_focus_process_resolution_failed"
    case exactFocusFrontProcessRejected = "exact_focus_front_process_rejected"
    case exactFocusKeyEventRejected = "exact_focus_key_event_rejected"
    case resolutionUnavailable = "resolution_unavailable"
    case resolutionRejected = "resolution_rejected"
    case raiseRejected = "raise_rejected"
    case focusWriteRejected = "focus_write_rejected"
    case readbackRejected = "readback_rejected"
    case settledReadbackUnavailable = "settled_readback_unavailable"
    case fallbackRejected = "fallback_rejected"
    case transactionRejected = "transaction_rejected"
}

public struct FocusSemanticHUDActivation: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let stage: FocusSemanticHUDActivationStage
    public let result: FocusSemanticHUDActivationResult
    public let bindingKind: FocusSemanticHUDActivationBindingKind
    public let selectionCurrent: Bool
    public let bindingCurrent: Bool
    public let blockReason: FocusSemanticHUDActivationBlockReason

    public static let idle = FocusSemanticHUDActivation(
        revision: 0,
        stage: .idle,
        result: .idle,
        bindingKind: .none,
        selectionCurrent: false,
        bindingCurrent: false,
        blockReason: .none
    )

    public init(
        revision: UInt64,
        stage: FocusSemanticHUDActivationStage,
        result: FocusSemanticHUDActivationResult,
        bindingKind: FocusSemanticHUDActivationBindingKind,
        selectionCurrent: Bool,
        bindingCurrent: Bool,
        blockReason: FocusSemanticHUDActivationBlockReason
    ) {
        self.revision = revision
        self.stage = stage
        self.result = result
        self.bindingKind = bindingKind
        self.selectionCurrent = selectionCurrent
        self.bindingCurrent = bindingCurrent
        self.blockReason = blockReason
    }

    public var isValidCombination: Bool {
        if stage != .idle, revision == 0 { return false }
        switch stage {
        case .idle:
            return revision == 0 && result == .idle && bindingKind == .none
                && !selectionCurrent && !bindingCurrent && blockReason == .none
        case .intent:
            return bindingKind == .none && !selectionCurrent && !bindingCurrent
                && ((result == .pending && blockReason == .none)
                    || (result == .blocked
                        && [.physicalMutation, .mappingUnavailable].contains(blockReason)))
        case .queued:
            return bindingKind == .none && !bindingCurrent
                && ((result == .pending && selectionCurrent && blockReason == .none)
                    || (result == .cancelled && !selectionCurrent
                        && blockReason == .selectionSuperseded))
        case .binding:
            return result == .pending && selectionCurrent && bindingCurrent
                && bindingKind != .none && blockReason == .none
        case .activate, .resolution, .raise, .focusWrite, .readback:
            let serviceReasons: [FocusSemanticHUDActivationBlockReason]
            switch stage {
            case .activate:
                serviceReasons = [
                    .activationRejected,
                    .exactFocusSymbolUnavailable,
                    .exactFocusProcessResolutionFailed,
                    .exactFocusFrontProcessRejected,
                    .exactFocusKeyEventRejected
                ]
            case .resolution:
                serviceReasons = [.resolutionUnavailable, .resolutionRejected]
            case .raise:
                serviceReasons = [.raiseRejected]
            case .focusWrite:
                serviceReasons = [.focusWriteRejected]
            case .readback:
                serviceReasons = [.readbackRejected]
            default:
                serviceReasons = []
            }
            return bindingKind != .none && selectionCurrent && bindingCurrent
                && [.unsupported, .timedOut, .vanished, .failed].contains(result)
                && serviceReasons.contains(blockReason)
        case .applied:
            return result == .applied && bindingKind != .none
                && selectionCurrent && bindingCurrent && blockReason == .none
        case .cancelled:
            guard result == .cancelled && bindingKind != .none else { return false }
            switch blockReason {
            case .selectionSuperseded:
                return !selectionCurrent
            case .bindingChanged:
                return selectionCurrent && !bindingCurrent
            case .inventoryChanged:
                return selectionCurrent && bindingCurrent
            default:
                return false
            }
        case .fallback:
            guard selectionCurrent && [.applied, .failed].contains(result) else { return false }
            switch blockReason {
            case .targetUnavailable, .bindingUnavailable:
                return bindingKind == .none && !bindingCurrent
            case .recoveryIncompatible, .activationRejected, .resolutionUnavailable,
                 .resolutionRejected, .raiseRejected, .focusWriteRejected,
                 .readbackRejected, .settledReadbackUnavailable, .fallbackRejected,
                 .transactionRejected:
                return bindingKind != .none && bindingCurrent
            default:
                return false
            }
        case .commit:
            return result == .applied && bindingKind != .none
                && selectionCurrent && bindingCurrent && blockReason == .none
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revision
        case stage
        case result
        case bindingKind
        case selectionCurrent
        case bindingCurrent
        case blockReason
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(UInt64.self, forKey: .revision),
            stage: try container.decode(FocusSemanticHUDActivationStage.self, forKey: .stage),
            result: try container.decode(FocusSemanticHUDActivationResult.self, forKey: .result),
            bindingKind: try container.decode(FocusSemanticHUDActivationBindingKind.self, forKey: .bindingKind),
            selectionCurrent: try container.decode(Bool.self, forKey: .selectionCurrent),
            bindingCurrent: try container.decode(Bool.self, forKey: .bindingCurrent),
            blockReason: try container.decode(FocusSemanticHUDActivationBlockReason.self, forKey: .blockReason)
        )
        guard isValidCombination else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid HUD activation combination")
            )
        }
    }
}

public struct FocusSemanticHUD: Codable, Equatable, Sendable {
    public let visible: Bool
    public let isKeyWindow: Bool
    public let inspectedScreenID: String?
    public let page: Int
    public let keyAssignmentRevision: UInt64
    public let presentationRevision: UInt64
    public let settledRevision: UInt64
    public let interactionRevision: UInt64
    public let renderedPresentationRevision: UInt64
    public let renderedInteractionRevision: UInt64
    public let renderedLayoutState: FocusSemanticHUDRenderedLayoutState
    public let renderedCellSize: Double?
    public let renderedVisibleIconSize: Double?
    public let renderedNameFontSize: Double?
    public let renderedBadgeSize: Double?
    public let renderedBadgeFontSize: Double?
    public let renderedAppTargetCount: Int
    public let renderedDismissTargetCount: Int
    public let renderedEmptyWorkspaceCount: Int
    public let hoverRevision: UInt64
    public let renderedHoverRevision: UInt64
    public let visibleNameCount: Int
    public let nameFocusSource: FocusSemanticHUDNameFocusSource
    public let inventoryStatus: String
    public let inventoryRevision: UInt64
    public let appIdentityHashes: [String]
    public let workspaceAppIdentityHashes: [String]
    public let layoutMode: FocusSemanticHUDLayoutMode
    public let workspaceSections: [FocusSemanticHUDWorkspaceSection]
    public let lastCloseReason: FocusSemanticHUDLastCloseReason
    public let lastMouseRoute: FocusSemanticHUDLastMouseRoute
    public let matchedFocusAttempt: Bool
    public let activation: FocusSemanticHUDActivation

    public init(
        visible: Bool,
        isKeyWindow: Bool = false,
        inspectedScreenID: String?,
        page: Int,
        keyAssignmentRevision: UInt64,
        presentationRevision: UInt64,
        settledRevision: UInt64,
        interactionRevision: UInt64 = 0,
        renderedPresentationRevision: UInt64 = 0,
        renderedInteractionRevision: UInt64 = 0,
        renderedLayoutState: FocusSemanticHUDRenderedLayoutState = .none,
        renderedCellSize: Double? = nil,
        renderedVisibleIconSize: Double? = nil,
        renderedNameFontSize: Double? = nil,
        renderedBadgeSize: Double? = nil,
        renderedBadgeFontSize: Double? = nil,
        renderedAppTargetCount: Int = 0,
        renderedDismissTargetCount: Int = 0,
        renderedEmptyWorkspaceCount: Int = 0,
        hoverRevision: UInt64 = 0,
        renderedHoverRevision: UInt64 = 0,
        visibleNameCount: Int = 0,
        nameFocusSource: FocusSemanticHUDNameFocusSource = .none,
        inventoryStatus: String = "loading",
        inventoryRevision: UInt64 = 0,
        appIdentityHashes: [String] = [],
        workspaceAppIdentityHashes: [String] = [],
        layoutMode: FocusSemanticHUDLayoutMode = .segmented,
        workspaceSections: [FocusSemanticHUDWorkspaceSection] = [],
        lastCloseReason: FocusSemanticHUDLastCloseReason = .none,
        lastMouseRoute: FocusSemanticHUDLastMouseRoute = .staleIgnored,
        matchedFocusAttempt: Bool = false,
        activation: FocusSemanticHUDActivation = .idle
    ) {
        self.visible = visible
        self.isKeyWindow = isKeyWindow
        self.inspectedScreenID = inspectedScreenID
        self.page = page
        self.keyAssignmentRevision = keyAssignmentRevision
        self.presentationRevision = presentationRevision
        self.settledRevision = settledRevision
        self.interactionRevision = interactionRevision
        self.renderedPresentationRevision = renderedPresentationRevision
        self.renderedInteractionRevision = renderedInteractionRevision
        self.renderedLayoutState = renderedLayoutState
        self.renderedCellSize = renderedCellSize
        self.renderedVisibleIconSize = renderedVisibleIconSize
        self.renderedNameFontSize = renderedNameFontSize
        self.renderedBadgeSize = renderedBadgeSize
        self.renderedBadgeFontSize = renderedBadgeFontSize
        self.renderedAppTargetCount = renderedAppTargetCount
        self.renderedDismissTargetCount = renderedDismissTargetCount
        self.renderedEmptyWorkspaceCount = renderedEmptyWorkspaceCount
        self.hoverRevision = hoverRevision
        self.renderedHoverRevision = renderedHoverRevision
        self.visibleNameCount = visibleNameCount
        self.nameFocusSource = nameFocusSource
        self.inventoryStatus = inventoryStatus
        self.inventoryRevision = inventoryRevision
        self.appIdentityHashes = appIdentityHashes
        self.workspaceAppIdentityHashes = workspaceAppIdentityHashes
        self.layoutMode = layoutMode
        self.workspaceSections = workspaceSections
        self.lastCloseReason = lastCloseReason
        self.lastMouseRoute = lastMouseRoute
        self.matchedFocusAttempt = matchedFocusAttempt
        self.activation = activation
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case visible
        case isKeyWindow
        case inspectedScreenID
        case page
        case keyAssignmentRevision
        case presentationRevision
        case settledRevision
        case interactionRevision
        case renderedPresentationRevision
        case renderedInteractionRevision
        case renderedLayoutState
        case renderedCellSize
        case renderedVisibleIconSize
        case renderedNameFontSize
        case renderedBadgeSize
        case renderedBadgeFontSize
        case renderedAppTargetCount
        case renderedDismissTargetCount
        case renderedEmptyWorkspaceCount
        case hoverRevision
        case renderedHoverRevision
        case visibleNameCount
        case nameFocusSource
        case inventoryStatus
        case inventoryRevision
        case appIdentityHashes
        case workspaceAppIdentityHashes
        case layoutMode
        case workspaceSections
        case lastCloseReason
        case lastMouseRoute
        case matchedFocusAttempt
        case activation
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            visible: try container.decode(Bool.self, forKey: .visible),
            isKeyWindow: try container.decodeIfPresent(Bool.self, forKey: .isKeyWindow) ?? false,
            inspectedScreenID: try container.decodeIfPresent(String.self, forKey: .inspectedScreenID),
            page: try container.decode(Int.self, forKey: .page),
            keyAssignmentRevision: try container.decode(UInt64.self, forKey: .keyAssignmentRevision),
            presentationRevision: try container.decode(UInt64.self, forKey: .presentationRevision),
            settledRevision: try container.decode(UInt64.self, forKey: .settledRevision),
            interactionRevision: try container.decodeIfPresent(
                UInt64.self,
                forKey: .interactionRevision
            ) ?? 0,
            renderedPresentationRevision: try container.decodeIfPresent(
                UInt64.self,
                forKey: .renderedPresentationRevision
            ) ?? 0,
            renderedInteractionRevision: try container.decodeIfPresent(
                UInt64.self,
                forKey: .renderedInteractionRevision
            ) ?? 0,
            renderedLayoutState: try container.decodeIfPresent(
                FocusSemanticHUDRenderedLayoutState.self,
                forKey: .renderedLayoutState
            ) ?? .none,
            renderedCellSize: try container.decodeIfPresent(Double.self, forKey: .renderedCellSize),
            renderedVisibleIconSize: try container.decodeIfPresent(
                Double.self,
                forKey: .renderedVisibleIconSize
            ),
            renderedNameFontSize: try container.decodeIfPresent(
                Double.self,
                forKey: .renderedNameFontSize
            ),
            renderedBadgeSize: try container.decodeIfPresent(Double.self, forKey: .renderedBadgeSize),
            renderedBadgeFontSize: try container.decodeIfPresent(
                Double.self,
                forKey: .renderedBadgeFontSize
            ),
            renderedAppTargetCount: try container.decodeIfPresent(
                Int.self,
                forKey: .renderedAppTargetCount
            ) ?? 0,
            renderedDismissTargetCount: try container.decodeIfPresent(
                Int.self,
                forKey: .renderedDismissTargetCount
            ) ?? 0,
            renderedEmptyWorkspaceCount: try container.decodeIfPresent(
                Int.self,
                forKey: .renderedEmptyWorkspaceCount
            ) ?? 0,
            hoverRevision: try container.decodeIfPresent(
                UInt64.self,
                forKey: .hoverRevision
            ) ?? 0,
            renderedHoverRevision: try container.decodeIfPresent(
                UInt64.self,
                forKey: .renderedHoverRevision
            ) ?? 0,
            visibleNameCount: try container.decodeIfPresent(
                Int.self,
                forKey: .visibleNameCount
            ) ?? 0,
            nameFocusSource: try container.decodeIfPresent(
                FocusSemanticHUDNameFocusSource.self,
                forKey: .nameFocusSource
            ) ?? .none,
            inventoryStatus: try container.decodeIfPresent(
                String.self,
                forKey: .inventoryStatus
            ) ?? "loading",
            inventoryRevision: try container.decodeIfPresent(
                UInt64.self,
                forKey: .inventoryRevision
            ) ?? 0,
            appIdentityHashes: try container.decodeIfPresent(
                [String].self,
                forKey: .appIdentityHashes
            ) ?? [],
            workspaceAppIdentityHashes: try container.decodeIfPresent(
                [String].self,
                forKey: .workspaceAppIdentityHashes
            ) ?? [],
            layoutMode: try container.decodeIfPresent(
                FocusSemanticHUDLayoutMode.self,
                forKey: .layoutMode
            ) ?? .segmented,
            workspaceSections: try container.decodeIfPresent(
                [FocusSemanticHUDWorkspaceSection].self,
                forKey: .workspaceSections
            ) ?? [],
            lastCloseReason: try container.decodeIfPresent(
                FocusSemanticHUDLastCloseReason.self,
                forKey: .lastCloseReason
            ) ?? .none,
            lastMouseRoute: try container.decodeIfPresent(
                FocusSemanticHUDLastMouseRoute.self,
                forKey: .lastMouseRoute
            ) ?? .staleIgnored,
            matchedFocusAttempt: try container.decodeIfPresent(
                Bool.self,
                forKey: .matchedFocusAttempt
            ) ?? false,
            activation: try container.decodeIfPresent(
                FocusSemanticHUDActivation.self,
                forKey: .activation
            ) ?? .idle
        )
    }
}

public struct FocusSemanticScreen: Codable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let lifecycle: String
    public let windowIDs: [String]
    public let activeWindowID: String?
    public let layoutRevision: UInt64

    public init(
        id: String,
        number: Int,
        lifecycle: String,
        windowIDs: [String],
        activeWindowID: String?,
        layoutRevision: UInt64
    ) {
        self.id = id
        self.number = number
        self.lifecycle = lifecycle
        self.windowIDs = windowIDs
        self.activeWindowID = activeWindowID
        self.layoutRevision = layoutRevision
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case number
        case lifecycle
        case windowIDs
        case activeWindowID
        case layoutRevision
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            number: try container.decode(Int.self, forKey: .number),
            lifecycle: try container.decode(String.self, forKey: .lifecycle),
            windowIDs: try container.decode([String].self, forKey: .windowIDs),
            activeWindowID: try container.decodeIfPresent(String.self, forKey: .activeWindowID),
            layoutRevision: try container.decode(UInt64.self, forKey: .layoutRevision)
        )
    }
}

public struct FocusSemanticWindow: Codable, Equatable, Sendable {
    public let id: String
    public let appIdentityHash: String
    public let screenID: String
    public let visible: Bool
    public let minimized: Bool
    public let focused: Bool
    public let frame: CanvasRect
    public let compatibility: String
    public let transactionRevision: UInt64

    public init(
        id: String,
        appIdentityHash: String,
        screenID: String,
        visible: Bool,
        minimized: Bool,
        focused: Bool,
        frame: CanvasRect,
        compatibility: String,
        transactionRevision: UInt64
    ) {
        self.id = id
        self.appIdentityHash = appIdentityHash
        self.screenID = screenID
        self.visible = visible
        self.minimized = minimized
        self.focused = focused
        self.frame = frame
        self.compatibility = compatibility
        self.transactionRevision = transactionRevision
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case appIdentityHash
        case screenID
        case visible
        case minimized
        case focused
        case frame
        case compatibility
        case transactionRevision
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            appIdentityHash: try container.decode(String.self, forKey: .appIdentityHash),
            screenID: try container.decode(String.self, forKey: .screenID),
            visible: try container.decode(Bool.self, forKey: .visible),
            minimized: try container.decode(Bool.self, forKey: .minimized),
            focused: try container.decode(Bool.self, forKey: .focused),
            frame: try container.decode(CanvasRect.self, forKey: .frame),
            compatibility: try container.decode(String.self, forKey: .compatibility),
            transactionRevision: try container.decode(UInt64.self, forKey: .transactionRevision)
        )
    }
}

public struct FocusSemanticCanvasRegion: Codable, Equatable, Sendable {
    public let id: String
    public let frame: CanvasRect
    public let scale: Double

    public init(id: String, frame: CanvasRect, scale: Double) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case frame
        case scale
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            frame: try container.decode(CanvasRect.self, forKey: .frame),
            scale: try container.decode(Double.self, forKey: .scale)
        )
    }
}

public struct FocusSemanticPointer: Codable, Equatable, Sendable {
    public let regionID: String?
    public let position: CanvasPoint?
    public let intendedWindowID: String?
    public let landingRevision: UInt64

    public init(
        regionID: String?,
        position: CanvasPoint?,
        intendedWindowID: String?,
        landingRevision: UInt64
    ) {
        self.regionID = regionID
        self.position = position
        self.intendedWindowID = intendedWindowID
        self.landingRevision = landingRevision
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case regionID
        case position
        case intendedWindowID
        case landingRevision
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regionID: try container.decodeIfPresent(String.self, forKey: .regionID),
            position: try container.decodeIfPresent(CanvasPoint.self, forKey: .position),
            intendedWindowID: try container.decodeIfPresent(String.self, forKey: .intendedWindowID),
            landingRevision: try container.decode(UInt64.self, forKey: .landingRevision)
        )
    }
}

public struct FocusScreenSemanticSnapshotV3: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let hud: FocusSemanticHUD
    public let screens: [FocusSemanticScreen]
    public let windows: [FocusSemanticWindow]
    public let canvasRegions: [FocusSemanticCanvasRegion]
    public let spaces: [FocusSemanticSpace]
    public let canvasTopology: FocusSemanticCanvasTopology?
    public let panes: [FocusSemanticPane]
    public let tabs: [FocusSemanticTab]
    public let pointer: FocusSemanticPointer
    public let stateRevision: UInt64

    public init(
        hud: FocusSemanticHUD,
        screens: [FocusSemanticScreen],
        windows: [FocusSemanticWindow],
        canvasRegions: [FocusSemanticCanvasRegion],
        spaces: [FocusSemanticSpace] = [],
        canvasTopology: FocusSemanticCanvasTopology? = nil,
        panes: [FocusSemanticPane] = [],
        tabs: [FocusSemanticTab] = [],
        pointer: FocusSemanticPointer,
        stateRevision: UInt64
    ) {
        schemaVersion = 3
        self.hud = hud
        self.screens = screens
        self.windows = windows
        self.canvasRegions = canvasRegions
        self.spaces = spaces
        self.canvasTopology = canvasTopology
        self.panes = panes
        self.tabs = tabs
        self.pointer = pointer
        self.stateRevision = stateRevision
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case hud
        case screens
        case windows
        case canvasRegions
        case spaces
        case canvasTopology
        case panes
        case tabs
        case pointer
        case stateRevision
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Focus screen semantic snapshot requires schema version 3"
            )
        }
        self.init(
            hud: try container.decode(FocusSemanticHUD.self, forKey: .hud),
            screens: try container.decode([FocusSemanticScreen].self, forKey: .screens),
            windows: try container.decode([FocusSemanticWindow].self, forKey: .windows),
            canvasRegions: try container.decode([FocusSemanticCanvasRegion].self, forKey: .canvasRegions),
            spaces: try container.decodeIfPresent([FocusSemanticSpace].self, forKey: .spaces) ?? [],
            canvasTopology: try container.decodeIfPresent(FocusSemanticCanvasTopology.self, forKey: .canvasTopology),
            panes: try container.decodeIfPresent([FocusSemanticPane].self, forKey: .panes) ?? [],
            tabs: try container.decodeIfPresent([FocusSemanticTab].self, forKey: .tabs) ?? [],
            pointer: try container.decode(FocusSemanticPointer.self, forKey: .pointer),
            stateRevision: try container.decode(UInt64.self, forKey: .stateRevision)
        )
    }
}

// MARK: - Phase 1B semantic projections

/// Content-free projection of a Saved Space. Projects presence (not the name
/// itself), lifecycle, layout revision, slot counts, binding state, and
/// auto-save suspension — never titles, document paths, or app content.
public struct FocusSemanticSpace: Codable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let namePresent: Bool
    public let lifecycle: String
    public let layoutRevision: UInt64
    public let windowSlotCount: Int
    public let resolvedSlotCount: Int
    public let boundScreenID: String?
    public let autoSaveSuspended: Bool

    public init(
        id: String,
        number: Int,
        namePresent: Bool,
        lifecycle: String,
        layoutRevision: UInt64,
        windowSlotCount: Int,
        resolvedSlotCount: Int,
        boundScreenID: String?,
        autoSaveSuspended: Bool
    ) {
        self.id = id
        self.number = number
        self.namePresent = namePresent
        self.lifecycle = lifecycle
        self.layoutRevision = layoutRevision
        self.windowSlotCount = windowSlotCount
        self.resolvedSlotCount = resolvedSlotCount
        self.boundScreenID = boundScreenID
        self.autoSaveSuspended = autoSaveSuspended
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case number
        case namePresent
        case lifecycle
        case layoutRevision
        case windowSlotCount
        case resolvedSlotCount
        case boundScreenID
        case autoSaveSuspended
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            number: try container.decode(Int.self, forKey: .number),
            namePresent: try container.decode(Bool.self, forKey: .namePresent),
            lifecycle: try container.decode(String.self, forKey: .lifecycle),
            layoutRevision: try container.decode(UInt64.self, forKey: .layoutRevision),
            windowSlotCount: try container.decode(Int.self, forKey: .windowSlotCount),
            resolvedSlotCount: try container.decode(Int.self, forKey: .resolvedSlotCount),
            boundScreenID: try container.decodeIfPresent(String.self, forKey: .boundScreenID),
            autoSaveSuspended: try container.decode(Bool.self, forKey: .autoSaveSuspended)
        )
    }
}

/// A seam between two adjacent Canvas regions in the semantic projection.
public struct FocusSemanticSeam: Codable, Equatable, Sendable {
    public let regionIDs: [String]
    public let edge: String

    public init(regionIDs: [String], edge: String) {
        self.regionIDs = regionIDs
        self.edge = edge
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case regionIDs
        case edge
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regionIDs: try container.decode([String].self, forKey: .regionIDs),
            edge: try container.decode(String.self, forKey: .edge)
        )
    }
}

/// Canvas topology projection: regions, seams, and a revision counter.
public struct FocusSemanticCanvasTopology: Codable, Equatable, Sendable {
    public let regions: [FocusSemanticCanvasRegion]
    public let seams: [FocusSemanticSeam]
    public let revision: UInt64

    public init(regions: [FocusSemanticCanvasRegion], seams: [FocusSemanticSeam], revision: UInt64) {
        self.regions = regions
        self.seams = seams
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case regions
        case seams
        case revision
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regions: try container.decode([FocusSemanticCanvasRegion].self, forKey: .regions),
            seams: try container.decode([FocusSemanticSeam].self, forKey: .seams),
            revision: try container.decode(UInt64.self, forKey: .revision)
        )
    }
}

// MARK: - Phase 1C semantic projections

/// Content-free projection of a Pane. Projects role, ratio, tab membership,
/// active tab, and frame — never window titles or app content.
public struct FocusSemanticPane: Codable, Equatable, Sendable {
    public let id: String
    public let screenID: String
    public let role: String?
    public let ratioPrimary: Double
    public let ratioSecondary: Double?
    public let tabIDs: [String]
    public let activeTabID: String?
    public let frame: CanvasRect

    public init(
        id: String,
        screenID: String,
        role: String?,
        ratioPrimary: Double,
        ratioSecondary: Double?,
        tabIDs: [String],
        activeTabID: String?,
        frame: CanvasRect
    ) {
        self.id = id
        self.screenID = screenID
        self.role = role
        self.ratioPrimary = ratioPrimary
        self.ratioSecondary = ratioSecondary
        self.tabIDs = tabIDs
        self.activeTabID = activeTabID
        self.frame = frame
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case screenID
        case role
        case ratioPrimary
        case ratioSecondary
        case tabIDs
        case activeTabID
        case frame
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            screenID: try container.decode(String.self, forKey: .screenID),
            role: try container.decodeIfPresent(String.self, forKey: .role),
            ratioPrimary: try container.decode(Double.self, forKey: .ratioPrimary),
            ratioSecondary: try container.decodeIfPresent(Double.self, forKey: .ratioSecondary),
            tabIDs: try container.decode([String].self, forKey: .tabIDs),
            activeTabID: try container.decodeIfPresent(String.self, forKey: .activeTabID),
            frame: try container.decode(CanvasRect.self, forKey: .frame)
        )
    }
}

/// Content-free projection of a Tab. Projects window binding, pane membership,
/// state, and order — never titles or content.
public struct FocusSemanticTab: Codable, Equatable, Sendable {
    public let id: String
    public let windowID: String
    public let paneID: String
    public let state: String
    public let order: Int

    public init(id: String, windowID: String, paneID: String, state: String, order: Int) {
        self.id = id
        self.windowID = windowID
        self.paneID = paneID
        self.state = state
        self.order = order
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case windowID
        case paneID
        case state
        case order
    }

    public init(from decoder: Decoder) throws {
        try ScreenDomainClosedDecoding.validateExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            windowID: try container.decode(String.self, forKey: .windowID),
            paneID: try container.decode(String.self, forKey: .paneID),
            state: try container.decode(String.self, forKey: .state),
            order: try container.decode(Int.self, forKey: .order)
        )
    }
}
