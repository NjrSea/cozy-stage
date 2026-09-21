import ApplicationServices
import Darwin
import Foundation
import ScreenDomainCore

enum NativeExactWindowFocusFailure: String, Equatable, Hashable, Sendable {
    case symbolUnavailable = "symbol_unavailable"
    case processResolutionFailed = "process_resolution_failed"
    case frontProcessRejected = "front_process_rejected"
    case keyEventRejected = "key_event_rejected"
}

struct NativeExactWindowFocusSession: @unchecked Sendable {
    private let restoration: () -> Void

    init(_ restoration: @escaping () -> Void) {
        self.restoration = restoration
    }

    func restoreOrigin() {
        restoration()
    }
}

enum NativeExactWindowFocusPreparation {
    case ready(NativeExactWindowFocusSession)
    case failed(NativeExactWindowFocusFailure)
}

enum NativeExactWindowFocusEventRecord {
    private static let leftMouseDown: UInt8 = 0x01

    static func makeKeySequence(windowID: CGWindowID) -> [[UInt8]] {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x08] = leftMouseDown
        bytes[0x3a] = 0x10
        var windowID = windowID
        var point = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &windowID) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        withUnsafeBytes(of: &point) { bytes.replaceSubrange(0x20..<0x30, with: $0) }
        return [bytes]
    }
}

struct NativeExactWindowFocusTransaction {
    typealias ProcessResolver = (pid_t) -> ProcessSerialNumber?
    typealias Front = (ProcessSerialNumber, CGWindowID, UInt32) -> CGError
    typealias PostEvent = (ProcessSerialNumber, [UInt8]) -> CGError

    let resolveProcess: ProcessResolver?
    let front: Front?
    let postEvent: PostEvent?

    func prepare(
        cgWindowID: CGWindowID,
        processIdentifier: pid_t,
        restoration: @escaping () -> Void
    ) -> NativeExactWindowFocusPreparation {
        guard let resolveProcess, let front, let postEvent else {
            return .failed(.symbolUnavailable)
        }
        guard let targetPSN = resolveProcess(processIdentifier) else {
            return .failed(.processResolutionFailed)
        }

        let session = NativeExactWindowFocusSession(restoration)
        guard front(targetPSN, cgWindowID, 0x200) == .success else {
            session.restoreOrigin()
            return .failed(.frontProcessRejected)
        }
        for event in NativeExactWindowFocusEventRecord.makeKeySequence(windowID: cgWindowID) {
            guard postEvent(targetPSN, event) == .success else {
                session.restoreOrigin()
                return .failed(.keyEventRejected)
            }
        }
        return .ready(session)
    }
}

/// Begins exact WindowServer focus. The returned session owns restoration of
/// the origin Space after the caller completes AX raise/readback.
enum NativeSpaceWindowFocus {
    static func prepare(
        cgWindowID: CGWindowID,
        processIdentifier: pid_t,
        originProcessIdentifier: pid_t?
    ) -> NativeExactWindowFocusPreparation {
        NativeSpaceAPI.shared.prepareWindowFocus(
            cgWindowID: cgWindowID,
            processIdentifier: processIdentifier,
            originProcessIdentifier: originProcessIdentifier
        )
    }
}

struct NativeDesktopSnapshot: Equatable, Sendable {
    struct Desktop: Equatable, Sendable {
        let id: UInt64
        let number: Int
        let name: String
        let isActive: Bool
        /// The anchor Space plus every non-anchor display's currently visible
        /// Space. A window belongs to this HUD Screen when the sets intersect.
        let memberDesktopIDs: [UInt64]

        init(
            id: UInt64,
            number: Int,
            name: String? = nil,
            isActive: Bool,
            memberDesktopIDs: [UInt64]? = nil
        ) {
            self.id = id
            self.number = number
            self.name = name ?? NativeSpaceName.desktop(number)
            self.isActive = isActive
            self.memberDesktopIDs = memberDesktopIDs ?? [id]
        }
    }

    struct Window: Equatable, Sendable {
        let id: CGWindowID
        let sourceWindowID: ManagedWindowID?
        let desktopIDs: [UInt64]
        let processIdentifier: pid_t
        let ownerName: String
        let title: String
        let frame: CanvasRect
        let attributes: UInt64
        let tags: UInt64
        let isInVisibleList: Bool
        let isFocused: Bool
        let zOrder: Int

        init(
            id: CGWindowID,
            sourceWindowID: ManagedWindowID? = nil,
            desktopIDs: [UInt64],
            processIdentifier: pid_t,
            ownerName: String,
            title: String,
            frame: CanvasRect,
            attributes: UInt64 = 0,
            tags: UInt64 = 0,
            isInVisibleList: Bool = true,
            isFocused: Bool = false,
            zOrder: Int = 0
        ) {
            self.id = id
            self.sourceWindowID = sourceWindowID
            self.desktopIDs = desktopIDs
            self.processIdentifier = processIdentifier
            self.ownerName = ownerName
            self.title = title
            self.frame = frame
            self.attributes = attributes
            self.tags = tags
            self.isInVisibleList = isInVisibleList
            self.isFocused = isFocused
            self.zOrder = zOrder
        }
    }

    let desktops: [Desktop]
    let visibleDesktopIDs: Set<UInt64>
    let windowDesktopIDs: [ManagedWindowID: [UInt64]]
    /// `nil` means the filtered WindowServer query is unavailable. An empty
    /// array is an authoritative empty workspace inventory.
    let windows: [Window]?

    init(
        desktops: [Desktop],
        visibleDesktopIDs: Set<UInt64>? = nil,
        windowDesktopIDs: [ManagedWindowID: [UInt64]],
        windows: [Window]? = nil
    ) {
        self.desktops = desktops
        self.visibleDesktopIDs = visibleDesktopIDs
            ?? Set(desktops.filter(\.isActive).flatMap(\.memberDesktopIDs))
        self.windowDesktopIDs = windowDesktopIDs
        self.windows = windows
    }
}

protocol NativeSpaceCataloging: Sendable {
    func snapshot(
        windowBindings: [ManagedWindowID: WindowRuntimeBinding],
        focusedWindowID: ManagedWindowID?
    ) async -> NativeDesktopSnapshot?

    func switchToDesktop(id: UInt64) async -> Bool
}

enum NativeWorkspaceWindowPolicy {
    private static let minimizedTag = UInt64(1) << 60
    private static let hiddenTag = UInt64(1) << 39

    /// Mirrors AltTab's ordering of the useful WindowServer signals. Fixed
    /// high-order tag masks are deliberately avoided: legitimate macOS 26
    /// windows do not share one stable content-bit signature.
    static func isSwitchTarget(
        isInVisibleList: Bool,
        isInAllList: Bool = true,
        desktopIDs: [UInt64],
        visibleDesktopIDs: Set<UInt64>,
        tags: UInt64,
        isApplicationHidden: Bool,
        isFocused: Bool
    ) -> Bool {
        if tags & minimizedTag != 0
            || tags & hiddenTag != 0
            || isApplicationHidden {
            return true
        }
        guard isInAllList else { return false }
        if isInVisibleList { return true }
        if !desktopIDs.isEmpty,
           Set(desktopIDs).isDisjoint(with: visibleDesktopIDs) {
            return true
        }
        if isFocused { return true }
        // Invisible while assigned to a visible Space is the useful weak
        // signal for closed/orderOut ghost surfaces.
        return false
    }

    static func isMinimized(tags: UInt64) -> Bool {
        tags & minimizedTag != 0
    }
}

/// Reads native macOS Spaces through a narrow CGS/SLS runtime boundary.
/// Private symbols are resolved dynamically so an OS change fails soft.
final class SystemNativeSpaceCatalog: NativeSpaceCataloging, @unchecked Sendable {
    private let executor = NativeAXReadExecutor(
        label: "com.indie-mono.screen-switcher.native-spaces"
    )

    func snapshot(
        windowBindings: [ManagedWindowID: WindowRuntimeBinding],
        focusedWindowID: ManagedWindowID?
    ) async -> NativeDesktopSnapshot? {
        try? await executor.execute {
            NativeSpaceAPI.shared.snapshot(
                windowBindings: windowBindings,
                focusedWindowID: focusedWindowID
            )
        }
    }

    func switchToDesktop(id: UInt64) async -> Bool {
        (try? await executor.execute {
            NativeSpaceAPI.shared.switchToDesktop(id: id)
        }) ?? false
    }

    static func uniqueSourceWindowIDs(
        candidates: [(
            managedWindowID: ManagedWindowID,
            processIdentifier: pid_t,
            cgWindowID: CGWindowID
        )],
        windows: [(
            cgWindowID: CGWindowID,
            processIdentifier: pid_t
        )]
    ) -> [CGWindowID: ManagedWindowID] {
        let candidatesByCGWindowID = Dictionary(grouping: candidates, by: \.cgWindowID)
        var result: [CGWindowID: ManagedWindowID] = [:]
        for window in windows {
            guard let matches = candidatesByCGWindowID[window.cgWindowID],
                  matches.count == 1,
                  matches[0].processIdentifier == window.processIdentifier
            else { continue }
            result[window.cgWindowID] = matches[0].managedWindowID
        }
        return result
    }
}

enum NativeSpaceSwitchPlan {
    static func distance(
        from currentDesktopID: UInt64,
        to targetDesktopID: UInt64,
        orderedDesktopIDs: [UInt64]
    ) -> Int? {
        guard let currentIndex = orderedDesktopIDs.firstIndex(of: currentDesktopID),
              let targetIndex = orderedDesktopIDs.firstIndex(of: targetDesktopID)
        else { return nil }
        return targetIndex - currentIndex
    }
}

private final class NativeSpaceAPI: @unchecked Sendable {
    private struct Display {
        let identifier: String
        let desktopIDs: [UInt64]
        let namesByDesktopID: [UInt64: String]
        let currentDesktopID: UInt64
    }

    private struct CatalogWindow {
        let id: CGWindowID
        let processIdentifier: pid_t
        let title: String
        let bounds: CGRect
        let attributes: UInt64
        let tags: UInt64
        let isInVisibleList: Bool
        let zOrder: Int
    }

    private struct Catalog {
        let desktopIDsByWindowID: [CGWindowID: [UInt64]]
        let windows: [CatalogWindow]
    }

    typealias ConnectionID = Int32
    typealias DefaultConnection = @convention(c) () -> ConnectionID
    typealias CopyManagedDisplaySpaces = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    typealias CopyActiveDisplay = @convention(c) (ConnectionID) -> Unmanaged<CFString>?
    typealias CopySpacesForWindows = @convention(c) (
        ConnectionID,
        Int32,
        CFArray
    ) -> Unmanaged<CFArray>?
    typealias CopyWindowsWithOptionsAndTags = @convention(c) (
        ConnectionID,
        UInt32,
        CFArray,
        UInt32,
        UnsafePointer<UInt64>,
        UnsafePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    typealias GetWindowID = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError
    typealias GetProcessForPID = @convention(c) (
        pid_t,
        UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus
    typealias SetFrontProcessWithOptions = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>,
        CGWindowID,
        UInt32
    ) -> CGError
    typealias PostEventRecordTo = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>,
        UnsafeMutablePointer<UInt8>
    ) -> CGError
    typealias SpaceSetFrontPSN = @convention(c) (
        ConnectionID,
        UInt64,
        ProcessSerialNumber
    ) -> CGError
    typealias QueryWindows = @convention(c) (
        ConnectionID,
        CFArray,
        Int32
    ) -> Unmanaged<CFTypeRef>?
    typealias CopyWindowIterator = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias AdvanceWindowIterator = @convention(c) (CFTypeRef) -> Bool
    typealias WindowIteratorID = @convention(c) (CFTypeRef) -> CGWindowID
    typealias WindowIteratorPID = @convention(c) (CFTypeRef) -> pid_t
    typealias WindowIteratorLevel = @convention(c) (CFTypeRef) -> Int32
    typealias WindowIteratorAttributes = @convention(c) (CFTypeRef) -> UInt64
    typealias WindowIteratorTags = @convention(c) (CFTypeRef) -> UInt64
    typealias WindowIteratorBounds = @convention(c) (UnsafeRawPointer) -> CGRect
    typealias WindowIteratorCopyTitle = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?

    static let shared = NativeSpaceAPI()

    private let skyLightHandle: UnsafeMutableRawPointer?
    private let processHandle: UnsafeMutableRawPointer?
    private let defaultConnection: DefaultConnection?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces?
    private let copyActiveDisplay: CopyActiveDisplay?
    private let copySpacesForWindows: CopySpacesForWindows?
    private let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTags?
    private let getWindowID: GetWindowID?
    private let queryWindows: QueryWindows?
    private let copyWindowIterator: CopyWindowIterator?
    private let advanceWindowIterator: AdvanceWindowIterator?
    private let windowIteratorID: WindowIteratorID?
    private let windowIteratorPID: WindowIteratorPID?
    private let windowIteratorLevel: WindowIteratorLevel?
    private let windowIteratorAttributes: WindowIteratorAttributes?
    private let windowIteratorTags: WindowIteratorTags?
    private let windowIteratorBounds: WindowIteratorBounds?
    private let windowIteratorCopyTitle: WindowIteratorCopyTitle?
    private let getProcessForPID: GetProcessForPID?
    private let setFrontProcessWithOptions: SetFrontProcessWithOptions?
    private let postEventRecordTo: PostEventRecordTo?
    private let spaceSetFrontPSN: SpaceSetFrontPSN?

    private init() {
        skyLightHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        )
        processHandle = dlopen(nil, RTLD_LAZY)
        defaultConnection = Self.symbol("_CGSDefaultConnection", in: skyLightHandle)
        copyManagedDisplaySpaces = Self.symbol("CGSCopyManagedDisplaySpaces", in: skyLightHandle)
        copyActiveDisplay = Self.symbol("CGSCopyActiveMenuBarDisplayIdentifier", in: skyLightHandle)
        copySpacesForWindows = Self.symbol("SLSCopySpacesForWindows", in: skyLightHandle)
        copyWindowsWithOptionsAndTags = Self.symbol("CGSCopyWindowsWithOptionsAndTags", in: skyLightHandle)
        queryWindows = Self.symbol("SLSWindowQueryWindows", in: skyLightHandle)
        copyWindowIterator = Self.symbol("SLSWindowQueryResultCopyWindows", in: skyLightHandle)
        advanceWindowIterator = Self.symbol("SLSWindowIteratorAdvance", in: skyLightHandle)
        windowIteratorID = Self.symbol("SLSWindowIteratorGetWindowID", in: skyLightHandle)
        windowIteratorPID = Self.symbol("SLSWindowIteratorGetPID", in: skyLightHandle)
        windowIteratorLevel = Self.symbol("SLSWindowIteratorGetLevel", in: skyLightHandle)
        windowIteratorAttributes = Self.symbol("SLSWindowIteratorGetAttributes", in: skyLightHandle)
        windowIteratorTags = Self.symbol("SLSWindowIteratorGetTags", in: skyLightHandle)
        windowIteratorBounds = Self.symbol("SLSWindowIteratorGetBounds", in: skyLightHandle)
        windowIteratorCopyTitle = Self.symbol("SLSWindowIteratorCopyTitle", in: skyLightHandle)
        getWindowID = Self.symbol("_AXUIElementGetWindow", in: processHandle)
        getProcessForPID = Self.symbol("GetProcessForPID", in: processHandle)
        setFrontProcessWithOptions = Self.symbol(
            "_SLPSSetFrontProcessWithOptions",
            in: skyLightHandle
        ) ?? Self.symbol("_SLPSSetFrontProcessWithOptions", in: processHandle)
        postEventRecordTo = Self.symbol("SLPSPostEventRecordTo", in: skyLightHandle)
            ?? Self.symbol("SLPSPostEventRecordTo", in: processHandle)
        spaceSetFrontPSN = Self.symbol("SLSSpaceSetFrontPSN", in: skyLightHandle)
            ?? Self.symbol("SLSSpaceSetFrontPSN", in: processHandle)
    }

    func snapshot(
        windowBindings: [ManagedWindowID: WindowRuntimeBinding],
        focusedWindowID: ManagedWindowID?
    ) -> NativeDesktopSnapshot? {
        guard let defaultConnection else { return nil }
        let connection = defaultConnection()
        guard let (displays, anchor) = displayTopology(connection: connection) else { return nil }
        let companionDesktopIDs = displays
            .filter { $0.identifier != anchor.identifier }
            .map(\.currentDesktopID)
        let desktops = anchor.desktopIDs.enumerated().map { index, desktopID in
            NativeDesktopSnapshot.Desktop(
                id: desktopID,
                number: index + 1,
                name: anchor.namesByDesktopID[desktopID],
                isActive: desktopID == anchor.currentDesktopID,
                memberDesktopIDs: Self.unique([desktopID] + companionDesktopIDs)
            )
        }
        let allDesktopIDs = Self.unique(displays.flatMap(\.desktopIDs))
        let visibleDesktopIDs = Set(displays.map(\.currentDesktopID))
        let catalog = catalog(connection: connection, desktopIDs: allDesktopIDs)

        let sourceWindowCandidates: [(
            managedWindowID: ManagedWindowID,
            processIdentifier: pid_t,
            cgWindowID: CGWindowID
        )] = windowBindings.compactMap { managedWindowID, binding in
            guard let cgWindowID = cgWindowID(for: binding)
            else { return nil }
            return (
                managedWindowID: managedWindowID,
                processIdentifier: binding.processIdentifier,
                cgWindowID: cgWindowID
            )
        }

        let focusedCGWindowID = focusedWindowID
            .flatMap { windowBindings[$0] }
            .flatMap(cgWindowID)
        var windowDesktopIDs: [ManagedWindowID: [UInt64]] = [:]
        if let catalog {
            for (managedWindowID, binding) in windowBindings {
                guard let cgWindowID = cgWindowID(for: binding),
                      let desktopIDs = catalog.desktopIDsByWindowID[cgWindowID]
                else { continue }
                windowDesktopIDs[managedWindowID] = desktopIDs
            }
        } else if let copySpacesForWindows {
            let knownDesktopIDs = Set(allDesktopIDs)
            for (managedWindowID, binding) in windowBindings {
                guard let cgWindowID = cgWindowID(for: binding),
                      let rawIDs = copySpacesForWindows(
                        connection,
                        0x7,
                        [cgWindowID] as CFArray
                      )?.takeRetainedValue() as? [NSNumber]
                else { continue }
                let desktopIDs = Self.unique(
                    rawIDs.map(\.uint64Value).filter(knownDesktopIDs.contains)
                )
                if !desktopIDs.isEmpty {
                    windowDesktopIDs[managedWindowID] = desktopIDs
                }
            }
        }

        return NativeDesktopSnapshot(
            desktops: desktops,
            visibleDesktopIDs: visibleDesktopIDs,
            windowDesktopIDs: windowDesktopIDs,
            windows: catalog.map {
                catalogWindows(
                    $0,
                    focusedCGWindowID: focusedCGWindowID,
                    sourceWindowIDs: SystemNativeSpaceCatalog.uniqueSourceWindowIDs(
                        candidates: sourceWindowCandidates,
                        windows: $0.windows.map { window in
                            (
                                cgWindowID: window.id,
                                processIdentifier: window.processIdentifier
                            )
                        }
                    )
                )
            }
        )
    }

    func switchToDesktop(id targetDesktopID: UInt64) -> Bool {
        guard let defaultConnection else { return false }
        let connection = defaultConnection()
        guard let (_, anchor) = displayTopology(connection: connection),
              let distance = NativeSpaceSwitchPlan.distance(
                from: anchor.currentDesktopID,
                to: targetDesktopID,
                orderedDesktopIDs: anchor.desktopIDs
              )
        else { return false }
        guard distance != 0 else { return true }

        let direction = distance > 0 ? 1.0 : -1.0
        guard let event = CGEvent(source: nil) else { return false }
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: direction)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: direction * 3)
        for _ in 0..<abs(distance) {
            event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 1)
            event.post(tap: .cgSessionEventTap)
            event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 4)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    private func displayTopology(connection: ConnectionID) -> ([Display], Display)? {
        guard let copyManagedDisplaySpaces,
              let rawDisplays = copyManagedDisplaySpaces(connection)?
                .takeRetainedValue() as? [NSDictionary]
        else { return nil }
        let displays = rawDisplays.compactMap(Self.display)
        guard !displays.isEmpty else { return nil }
        let activeDisplayIdentifier = copyActiveDisplay?(connection)?
            .takeRetainedValue() as String?
        let anchor = displays.first { $0.identifier == activeDisplayIdentifier }
            ?? displays.first { $0.identifier == "Main" }
            ?? displays[0]
        return (displays, anchor)
    }

    private func catalog(
        connection: ConnectionID,
        desktopIDs: [UInt64]
    ) -> Catalog? {
        guard !desktopIDs.isEmpty,
              let visibleWindowIDs = windowIDs(
                connection: connection,
                desktopIDs: desktopIDs,
                includeInvisible: false
              )
        else { return nil }

        var desktopIDsByWindowID: [CGWindowID: [UInt64]] = [:]
        var orderedWindowIDs: [CGWindowID] = []
        for desktopID in desktopIDs {
            guard let windowIDs = windowIDs(
                connection: connection,
                desktopIDs: [desktopID],
                includeInvisible: true
            ) else { return nil }
            for windowID in windowIDs {
                if desktopIDsByWindowID[windowID] == nil {
                    orderedWindowIDs.append(windowID)
                }
                desktopIDsByWindowID[windowID, default: []].append(desktopID)
            }
        }
        guard let windows = catalogWindows(
            connection: connection,
            orderedWindowIDs: orderedWindowIDs,
            visibleWindowIDs: Set(visibleWindowIDs)
        ) else { return nil }
        return Catalog(
            desktopIDsByWindowID: desktopIDsByWindowID.mapValues(Self.unique),
            windows: windows
        )
    }

    private func windowIDs(
        connection: ConnectionID,
        desktopIDs: [UInt64],
        includeInvisible: Bool
    ) -> [CGWindowID]? {
        guard let copyWindowsWithOptionsAndTags else { return nil }
        var setTags = UInt64(0)
        var clearTags = UInt64(0)
        // bit 1 includes All-Spaces windows; bits 0 and 2 include both
        // WindowServer invisible classes.
        let options: UInt32 = includeInvisible ? 0b111 : 0b010
        guard let values = copyWindowsWithOptionsAndTags(
            connection,
            0,
            desktopIDs as CFArray,
            options,
            &setTags,
            &clearTags
        )?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return values.map(\.uint32Value)
    }

    private func catalogWindows(
        connection: ConnectionID,
        orderedWindowIDs: [CGWindowID],
        visibleWindowIDs: Set<CGWindowID>
    ) -> [CatalogWindow]? {
        guard !orderedWindowIDs.isEmpty else { return [] }
        guard let queryWindows,
              let copyWindowIterator,
              let advanceWindowIterator,
              let windowIteratorID,
              let windowIteratorPID,
              let windowIteratorLevel,
              let windowIteratorTags,
              let windowIteratorBounds,
              let query = queryWindows(
                connection,
                orderedWindowIDs as CFArray,
                Int32(orderedWindowIDs.count)
              )?.takeRetainedValue(),
              let iterator = copyWindowIterator(query)?.takeRetainedValue()
        else { return nil }

        let orderByWindowID = Dictionary(
            uniqueKeysWithValues: orderedWindowIDs.enumerated().map { ($1, $0) }
        )
        var result: [CatalogWindow] = []
        while advanceWindowIterator(iterator) {
            let windowID = windowIteratorID(iterator)
            let bounds = windowIteratorBounds(
                Unmanaged.passUnretained(iterator).toOpaque()
            )
            let processIdentifier = windowIteratorPID(iterator)
            guard windowIteratorLevel(iterator) == 0,
                  processIdentifier > 0,
                  bounds.width >= 80,
                  bounds.height >= 60
            else { continue }
            result.append(CatalogWindow(
                id: windowID,
                processIdentifier: processIdentifier,
                title: windowIteratorCopyTitle?(iterator)?
                    .takeRetainedValue() as String? ?? "",
                bounds: bounds,
                attributes: windowIteratorAttributes?(iterator) ?? 0,
                tags: windowIteratorTags(iterator),
                isInVisibleList: visibleWindowIDs.contains(windowID),
                zOrder: orderByWindowID[windowID] ?? Int.max
            ))
        }
        return result.sorted { $0.zOrder < $1.zOrder }
    }

    private func catalogWindows(
        _ catalog: Catalog,
        focusedCGWindowID: CGWindowID?,
        sourceWindowIDs: [CGWindowID: ManagedWindowID]
    ) -> [NativeDesktopSnapshot.Window] {
        catalog.windows.compactMap { window in
            guard let desktopIDs = catalog.desktopIDsByWindowID[window.id] else { return nil }
            return NativeDesktopSnapshot.Window(
                id: window.id,
                sourceWindowID: sourceWindowIDs[window.id],
                desktopIDs: desktopIDs,
                processIdentifier: window.processIdentifier,
                ownerName: "",
                title: window.title,
                frame: CanvasRect(
                    x: window.bounds.origin.x,
                    y: window.bounds.origin.y,
                    width: window.bounds.width,
                    height: window.bounds.height
                ),
                attributes: window.attributes,
                tags: window.tags,
                isInVisibleList: window.isInVisibleList,
                isFocused: window.id == focusedCGWindowID,
                zOrder: window.zOrder
            )
        }
    }

    private func cgWindowID(for binding: WindowRuntimeBinding) -> CGWindowID? {
        if let cgWindowID = binding.cgWindowID { return cgWindowID }
        switch binding.axElement {
        case let .system(box):
            guard let getWindowID else { return nil }
            var id = CGWindowID(0)
            return getWindowID(box.rawValue, &id) == .success && id != 0 ? id : nil
        case let .windowServer(id):
            return id
        case .injected:
            return nil
        }
    }

    private static func display(_ raw: NSDictionary) -> Display? {
        guard let identifier = raw["Display Identifier"] as? String,
              let rawSpaces = raw["Spaces"] as? [NSDictionary]
        else { return nil }
        var desktopNumber = 0
        var namesByDesktopID: [UInt64: String] = [:]
        let desktopIDs = unique(rawSpaces.compactMap { space in
            guard let id = spaceID(space) else { return nil }
            if (space["type"] as? NSNumber)?.intValue == 0 { desktopNumber += 1 }
            namesByDesktopID[id] = NativeSpaceName.resolve(
                space,
                desktopNumber: max(desktopNumber, 1)
            )
            return id
        })
        guard !desktopIDs.isEmpty else { return nil }
        let currentDesktopID = (raw["Current Space"] as? NSDictionary)
            .flatMap(spaceID)
            .flatMap { desktopIDs.contains($0) ? $0 : nil }
            ?? desktopIDs[0]
        return Display(
            identifier: identifier,
            desktopIDs: desktopIDs,
            namesByDesktopID: namesByDesktopID,
            currentDesktopID: currentDesktopID
        )
    }

    private static func spaceID(_ space: NSDictionary) -> UInt64? {
        (space["id64"] as? NSNumber)?.uint64Value
            ?? (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    private static func unique(_ values: [UInt64]) -> [UInt64] {
        var seen = Set<UInt64>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func symbol<T>(
        _ name: String,
        in handle: UnsafeMutableRawPointer?
    ) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    // MARK: - Exact window focus

    /// AltTab's exact-window sequence: front the target, post a safe synthetic
    /// make-key event, then let the caller AX raise/read back before restoration.
    func prepareWindowFocus(
        cgWindowID: CGWindowID,
        processIdentifier: pid_t,
        originProcessIdentifier: pid_t?
    ) -> NativeExactWindowFocusPreparation {
        guard let getProcessForPID,
              let setFrontProcessWithOptions,
              let postEventRecordTo
        else { return .failed(.symbolUnavailable) }

        var targetPSN = ProcessSerialNumber()
        guard getProcessForPID(processIdentifier, &targetPSN) == 0 else {
            return .failed(.processResolutionFailed)
        }
        var restore: (() -> Void)?
        if let defaultConnection,
           let (displays, anchor) = displayTopology(connection: defaultConnection()),
           let targetSpaceIDs = copySpacesForWindows?(
               defaultConnection(),
               0x7,
               [cgWindowID] as CFArray
           )?.takeRetainedValue() as? [NSNumber],
           !targetSpaceIDs.isEmpty,
           Set(targetSpaceIDs.map(\.uint64Value)).isDisjoint(
               with: Set(displays.map(\.currentDesktopID))
           ),
           let originPID = originProcessIdentifier,
           originPID != processIdentifier {
            guard let spaceSetFrontPSN else { return .failed(.symbolUnavailable) }
            var originPSN = ProcessSerialNumber()
            guard getProcessForPID(originPID, &originPSN) == 0 else {
                return .failed(.processResolutionFailed)
            }
            let connection = defaultConnection()
            let originSpaceID = anchor.currentDesktopID
            restore = {
                _ = spaceSetFrontPSN(connection, originSpaceID, originPSN)
            }
        }

        return NativeExactWindowFocusTransaction(
            resolveProcess: { _ in targetPSN },
            front: { psn, windowID, options in
                var psn = psn
                return setFrontProcessWithOptions(&psn, windowID, options)
            },
            postEvent: { psn, event in
                var psn = psn
                var event = event
                return event.withUnsafeMutableBufferPointer { buffer in
                    postEventRecordTo(&psn, buffer.baseAddress!)
                }
            }
        ).prepare(
            cgWindowID: cgWindowID,
            processIdentifier: processIdentifier,
            restoration: { restore?() }
        )
    }
}

enum NativeSpaceName {
    private static let dockBundle = Bundle(path: "/System/Library/CoreServices/Dock.app")

    static func resolve(_ space: NSDictionary, desktopNumber: Int) -> String {
        if (space["type"] as? NSNumber)?.intValue == 0 {
            return desktop(desktopNumber)
        }
        let tiles = (space["TileLayoutManager"] as? NSDictionary)?["TileSpaces"] as? [NSDictionary] ?? []
        let names = unique(tiles.compactMap {
            nonEmpty($0["appName"]) ?? nonEmpty($0["name"])
        })
        if names.count == 1 { return names[0] }
        if names.count == 2 {
            return String(
                format: localized("2_APP_TILED_SPACE", fallback: "%@ & %@"),
                locale: .current,
                names[0], names[1]
            )
        }
        return nonEmpty(space["appName"])
            ?? nonEmpty(space["name"])
            ?? localized("Fullscreen", fallback: "Fullscreen")
    }

    static func desktop(_ number: Int) -> String {
        String(
            format: localized("DesktopNum", fallback: "Desktop %@"),
            locale: .current,
            String(number)
        )
    }

    private static func localized(_ key: String, fallback: String) -> String {
        dockBundle?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
