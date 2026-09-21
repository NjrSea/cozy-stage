import AppKit
import Foundation

func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

@MainActor
public protocol RunningAppDiscovering {
    func discoverRunningApps() -> [RunningAppSource]
}

@MainActor
public protocol RunningAppActivationObservation: AnyObject {
    func cancel()
}

@MainActor
public protocol RunningAppActivationObserving {
    func startObserving(
        _ handler: @escaping @MainActor (String) -> Void
    ) -> RunningAppActivationObservation
}

@MainActor
public protocol WindowMetadataReading {
    func mostRecentWindow(for appID: String) -> WindowDescriptor?
}

@MainActor
public protocol RunningAppProcessIdentifierProviding {
    func processIdentifier(for appID: String) -> pid_t?
    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]]
}

public enum RunningAppIconAvailabilityResolutionPolicy: Sendable {
    case resolve
    case deferToPresentation
}

/// Process-generation identity is internal runtime metadata. It keys AX cache
/// entries but never enters WindowDescriptor Codable/evidence state.
struct RunningAppProcessGeneration: Hashable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let launchIdentity: String
    let isCacheable: Bool

    init(
        bundleIdentifier: String,
        processIdentifier: pid_t,
        launchIdentity: String,
        isCacheable: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.launchIdentity = launchIdentity
        self.isCacheable = isCacheable
    }
}

@MainActor
protocol RunningAppProcessGenerationProviding {
    func activeProcessGenerations() -> [RunningAppProcessGeneration]
}

extension RunningAppProcessGenerationProviding {
    func processGenerations(
        for appIDs: [String]
    ) -> [String: [RunningAppProcessGeneration]] {
        let generations = activeProcessGenerations()
        return Dictionary(uniqueKeysWithValues: stableUnique(appIDs).map { appID in
            (appID, generations.filter { $0.bundleIdentifier == appID })
        })
    }
}

public extension RunningAppProcessIdentifierProviding {
    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        Dictionary(uniqueKeysWithValues: stableUnique(appIDs).map { appID in
            (appID, processIdentifier(for: appID).map { [$0] } ?? [])
        })
    }
}

@MainActor
public struct NSWorkspaceRunningAppProcessIdentifierProvider:
    RunningAppProcessIdentifierProviding,
    RunningAppProcessGenerationProviding {
    public init() {}

    public func processIdentifier(for appID: String) -> pid_t? {
        processIdentifiers(for: [appID])[appID]?.first
    }

    public func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        Dictionary(uniqueKeysWithValues: processGenerations(for: appIDs).map { appID, values in
            (appID, values.map(\.processIdentifier))
        })
    }

    func activeProcessGenerations() -> [RunningAppProcessGeneration] {
        let generations: [RunningAppProcessGeneration] = NSWorkspace.shared
            .runningApplications.compactMap { application in
                guard let appID = application.bundleIdentifier,
                      let launchDate = application.launchDate else {
                    return nil
                }
                return RunningAppProcessGeneration(
                    bundleIdentifier: appID,
                    processIdentifier: application.processIdentifier,
                    launchIdentity: String(
                        launchDate.timeIntervalSinceReferenceDate.bitPattern,
                        radix: 16
                    )
                )
            }
        return stableUnique(generations).sorted {
            if $0.bundleIdentifier != $1.bundleIdentifier {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            if $0.processIdentifier != $1.processIdentifier {
                return $0.processIdentifier < $1.processIdentifier
            }
            return $0.launchIdentity < $1.launchIdentity
        }
    }
}

public struct AXWindowMetadataCandidate: Equatable, Sendable {
    public let id: String
    public let axFrame: RectDescriptor
    public let isFocused: Bool
    public let isMain: Bool
    public let isMinimized: Bool

    public init(
        id: String,
        axFrame: RectDescriptor,
        isFocused: Bool,
        isMain: Bool,
        isMinimized: Bool
    ) {
        self.id = id
        self.axFrame = axFrame
        self.isFocused = isFocused
        self.isMain = isMain
        self.isMinimized = isMinimized
    }
}

public protocol AXWindowMetadataCandidateReading: Sendable {
    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate]
}

enum AXWindowMetadataCandidateQueryResult: Sendable {
    case success([AXWindowMetadataCandidate])
    case timedOut
    case unavailable
}

protocol AXWindowMetadataCandidateQuerying: AXWindowMetadataCandidateReading {
    func queryCandidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> AXWindowMetadataCandidateQueryResult
}

public struct AXAccessibilityWindowMetadataCandidateReader:
    AXWindowMetadataCandidateReading,
    AXWindowMetadataCandidateQuerying {
    public init() {}

    public func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        guard case let .success(candidates) = queryCandidates(
            for: processIdentifier,
            messagingTimeout: messagingTimeout
        ) else { return [] }
        return candidates
    }

    func queryCandidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> AXWindowMetadataCandidateQueryResult {
        let timeout = max(0.001, messagingTimeout)
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(
            application,
            Float(timeout)
        )
        var windowsValue: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        if windowsError == .cannotComplete { return .timedOut }
        guard windowsError == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return .unavailable
        }

        var result: [AXWindowMetadataCandidate] = []
        result.reserveCapacity(windows.count)
        for (index, element) in windows.enumerated() {
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { return .timedOut }
            // AX messaging timeouts are element-local. Apply the remaining
            // deadline to every child window before its IPC batch.
            _ = AXUIElementSetMessagingTimeout(element, Float(max(0.001, remaining)))
            guard let values = values(of: element) else { continue }
            guard let frame = frame(position: values.position, size: values.size) else {
                continue
            }
            result.append(AXWindowMetadataCandidate(
                id: "ax-\(index)",
                axFrame: frame,
                isFocused: values.isFocused,
                isMain: values.isMain,
                isMinimized: values.isMinimized
            ))
        }
        return .success(result)
    }

    private func frame(position: CGPoint, size: CGSize) -> RectDescriptor? {
        return try? RectDescriptor(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )
    }

    private func pointValue(_ rawValue: Any) -> CGPoint? {
        guard let value = axValue(rawValue) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeValue(_ rawValue: Any) -> CGSize? {
        guard let value = axValue(rawValue) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func axValue(_ rawValue: Any) -> AXValue? {
        let value = rawValue as CFTypeRef
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func values(of element: AXUIElement) -> (
        position: CGPoint,
        size: CGSize,
        isFocused: Bool,
        isMain: Bool,
        isMinimized: Bool
    )? {
        let attributes: [CFString] = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXFocusedAttribute as CFString,
            kAXMainAttribute as CFString,
            kAXMinimizedAttribute as CFString
        ]
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        ) == .success,
        let values = rawValues as? [Any],
        values.count == attributes.count,
        let position = pointValue(values[0]),
        let size = sizeValue(values[1]) else {
            return nil
        }
        return (
            position,
            size,
            (values[2] as? NSNumber)?.boolValue ?? false,
            (values[3] as? NSNumber)?.boolValue ?? false,
            (values[4] as? NSNumber)?.boolValue ?? false
        )
    }
}

@MainActor
public protocol DisplayScopedWindowMetadataReading: WindowMetadataReading {
    func mostRecentWindows(
        for appIDs: [String],
        displays: [DisplayDescriptor]
    ) -> [String: WindowDescriptor]
}

@MainActor
public protocol DisplayScopedWindowInventoryReading: DisplayScopedWindowMetadataReading {
    func eligibleWindows(
        for appIDs: [String],
        displays: [DisplayDescriptor]
    ) -> [String: [WindowDescriptor]]
}

@MainActor
public protocol FreshDisplayScopedWindowInventoryReading: DisplayScopedWindowInventoryReading {
    func freshEligibleWindows(
        for appIDs: [String],
        displays: [DisplayDescriptor]
    ) async -> Result<[String: [WindowDescriptor]], SwitcherActionFailure>
}

protocol WindowMetadataRefreshScheduling: Sendable {
    func schedule(_ operation: @escaping @Sendable () -> Void)
}

final class BoundedWindowMetadataRefreshScheduler: @unchecked Sendable,
    WindowMetadataRefreshScheduling {
    private let queue: OperationQueue

    init(maxConcurrentOperations: Int = 4) {
        let queue = OperationQueue()
        queue.name = "com.indie-mono.screen-switcher.ax-window-metadata"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentOperations)
        self.queue = queue
    }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        queue.addOperation(operation)
    }
}

private struct ObservedAXWindowMetadataCandidate: Sendable {
    let processIdentifier: pid_t
    let candidateIndex: Int
    let candidate: AXWindowMetadataCandidate
    let appKitFrame: RectDescriptor

    static func isOrderedBefore(
        _ lhs: ObservedAXWindowMetadataCandidate,
        _ rhs: ObservedAXWindowMetadataCandidate
    ) -> Bool {
        if lhs.candidate.isFocused != rhs.candidate.isFocused {
            return lhs.candidate.isFocused
        }
        if lhs.candidate.isMain != rhs.candidate.isMain {
            return lhs.candidate.isMain
        }
        if lhs.processIdentifier != rhs.processIdentifier {
            return lhs.processIdentifier < rhs.processIdentifier
        }
        return lhs.candidateIndex < rhs.candidateIndex
    }
}

private final class WindowMetadataRefreshNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func setHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func notify() {
        let currentHandler: (@Sendable () -> Void)? = lock.withLock { self.handler }
        currentHandler?()
    }
}

private final class AXWindowMetadataRefreshBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var updatedCache = false
    private let completion: @Sendable () -> Void

    init(count: Int, completion: @escaping @Sendable () -> Void) {
        remaining = count
        self.completion = completion
    }

    func finish(updatedCache: Bool) {
        let shouldNotify = lock.withLock {
            self.updatedCache = self.updatedCache || updatedCache
            remaining -= 1
            return remaining == 0 && self.updatedCache
        }
        if shouldNotify {
            completion()
        }
    }
}

/// Thread-safe process-generation cache. Reads return immutable values
/// immediately; one refresh per launch generation can be in flight. A late
/// completion is accepted only while that exact bundle/PID/launch is current.
private final class AXWindowMetadataRefreshCache: @unchecked Sendable {
    private struct Entry {
        let candidates: [ObservedAXWindowMetadataCandidate]
        let refreshedAt: DispatchTime
    }

    private let lock = NSLock()
    private let scheduler: WindowMetadataRefreshScheduling
    private let freshnessInterval: TimeInterval
    private var cachedByGeneration: [RunningAppProcessGeneration: Entry] = [:]
    private var inFlightGenerationTokens: [RunningAppProcessGeneration: UInt64] = [:]
    private var activeGenerations = Set<RunningAppProcessGeneration>()
    private var nextRefreshToken: UInt64 = 0

    init(
        scheduler: WindowMetadataRefreshScheduling,
        freshnessInterval: TimeInterval = 0.25
    ) {
        self.scheduler = scheduler
        self.freshnessInterval = max(0, freshnessInterval)
    }

    func snapshotAndRefresh(
        authoritativeGenerations: Set<RunningAppProcessGeneration>,
        processGenerations: [RunningAppProcessGeneration],
        reader: AXWindowMetadataCandidateReading,
        normalizer: TopLeftToAppKitCoordinateNormalizer,
        messagingTimeout: TimeInterval,
        refreshCompletion: @escaping @Sendable () -> Void
    ) -> [RunningAppProcessGeneration: [ObservedAXWindowMetadataCandidate]] {
        let authoritativeGenerations = Set(authoritativeGenerations.filter(\.isCacheable))
        let processGenerations = stableUnique(processGenerations).filter {
            $0.isCacheable && authoritativeGenerations.contains($0)
        }
        let state = lock.withLock { () -> (
            snapshot: [RunningAppProcessGeneration: [ObservedAXWindowMetadataCandidate]],
            refreshes: [(generation: RunningAppProcessGeneration, token: UInt64)]
        ) in
            let now = DispatchTime.now().uptimeNanoseconds
            let freshnessNanoseconds = UInt64(freshnessInterval * 1_000_000_000)
            activeGenerations = authoritativeGenerations
            let retiredCachedGenerations = cachedByGeneration.keys.filter {
                !activeGenerations.contains($0)
            }
            for generation in retiredCachedGenerations {
                cachedByGeneration.removeValue(forKey: generation)
            }
            let retiredInFlightGenerations = inFlightGenerationTokens.keys.filter {
                !activeGenerations.contains($0)
            }
            for generation in retiredInFlightGenerations {
                inFlightGenerationTokens.removeValue(forKey: generation)
            }

            let snapshot = Dictionary(uniqueKeysWithValues: processGenerations.compactMap {
                generation in
                cachedByGeneration[generation].map { (generation, $0.candidates) }
            })
            let refreshes = processGenerations.compactMap { generation -> (
                generation: RunningAppProcessGeneration,
                token: UInt64
            )? in
                guard inFlightGenerationTokens[generation] == nil else { return nil }
                if let entry = cachedByGeneration[generation],
                   now >= entry.refreshedAt.uptimeNanoseconds,
                   now - entry.refreshedAt.uptimeNanoseconds < freshnessNanoseconds {
                    return nil
                }
                nextRefreshToken &+= 1
                let token = nextRefreshToken
                inFlightGenerationTokens[generation] = token
                return (generation, token)
            }
            return (snapshot, refreshes)
        }

        let batch = state.refreshes.isEmpty ? nil : AXWindowMetadataRefreshBatch(
            count: state.refreshes.count,
            completion: refreshCompletion
        )
        for refresh in state.refreshes {
            let generation = refresh.generation
            let token = refresh.token
            scheduler.schedule { [weak self] in
                guard let self else {
                    batch?.finish(updatedCache: false)
                    return
                }
                let candidates = reader.candidates(
                    for: generation.processIdentifier,
                    messagingTimeout: messagingTimeout
                )
                let observed: [ObservedAXWindowMetadataCandidate] = candidates
                    .enumerated()
                    .compactMap { index, candidate in
                    guard !candidate.isMinimized,
                          let frame = normalizer.normalize(candidate.axFrame) else {
                        return nil
                    }
                    return ObservedAXWindowMetadataCandidate(
                        processIdentifier: generation.processIdentifier,
                        candidateIndex: index,
                        candidate: candidate,
                        appKitFrame: frame
                    )
                }
                let updatedCache = self.lock.withLock {
                    defer {
                        if self.inFlightGenerationTokens[generation] == token {
                            self.inFlightGenerationTokens.removeValue(forKey: generation)
                        }
                    }
                    guard self.activeGenerations.contains(generation),
                          self.inFlightGenerationTokens[generation] == token else {
                        return false
                    }
                    self.cachedByGeneration[generation] = Entry(
                        candidates: observed,
                        refreshedAt: .now()
                    )
                    return true
                }
                batch?.finish(updatedCache: updatedCache)
            }
        }
        return state.snapshot
    }
}

@MainActor
public final class AppKitWindowMetadataReader: FreshDisplayScopedWindowInventoryReading {
    private let permissionService: PermissionService
    private let processIdentifierProvider: RunningAppProcessIdentifierProviding
    private let candidateReader: AXWindowMetadataCandidateReading
    private let appKitMainDisplayMaxY: Double
    private let globalBudget: TimeInterval
    private let refreshCache: AXWindowMetadataRefreshCache
    private let refreshNotifier = WindowMetadataRefreshNotifier()

    public convenience init(
        permissionService: PermissionService? = nil,
        processIdentifierProvider: RunningAppProcessIdentifierProviding? = nil,
        candidateReader: AXWindowMetadataCandidateReading? = nil,
        appKitMainDisplayMaxY: Double? = nil,
        globalBudget: TimeInterval = 0.25
    ) {
        self.init(
            permissionService: permissionService,
            processIdentifierProvider: processIdentifierProvider,
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: appKitMainDisplayMaxY,
            globalBudget: globalBudget,
            refreshScheduler: BoundedWindowMetadataRefreshScheduler()
        )
    }

    init(
        permissionService: PermissionService? = nil,
        processIdentifierProvider: RunningAppProcessIdentifierProviding? = nil,
        candidateReader: AXWindowMetadataCandidateReading? = nil,
        appKitMainDisplayMaxY: Double? = nil,
        globalBudget: TimeInterval = 0.25,
        refreshScheduler: WindowMetadataRefreshScheduling,
        cacheFreshnessInterval: TimeInterval = 0.25
    ) {
        self.permissionService = permissionService ?? PermissionService()
        self.processIdentifierProvider = processIdentifierProvider
            ?? NSWorkspaceRunningAppProcessIdentifierProvider()
        self.candidateReader = candidateReader
            ?? AXAccessibilityWindowMetadataCandidateReader()
        let detectedMainDisplayMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let requestedMainDisplayMaxY = appKitMainDisplayMaxY ?? detectedMainDisplayMaxY
        self.appKitMainDisplayMaxY = requestedMainDisplayMaxY.isFinite
            ? requestedMainDisplayMaxY
            : detectedMainDisplayMaxY
        self.globalBudget = globalBudget.isFinite && globalBudget > 0 ? globalBudget : 0.25
        self.refreshCache = AXWindowMetadataRefreshCache(
            scheduler: refreshScheduler,
            freshnessInterval: cacheFreshnessInterval
        )
    }

    public func mostRecentWindow(for appID: String) -> WindowDescriptor? {
        return mostRecentWindows(for: [appID], displays: [])[appID]
    }

    public func mostRecentWindows(
        for appIDs: [String],
        displays: [DisplayDescriptor]
    ) -> [String: WindowDescriptor] {
        eligibleWindows(for: appIDs, displays: displays).reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.first
        }
    }

    public func eligibleWindows(
        for appIDs: [String],
        displays: [DisplayDescriptor]
    ) -> [String: [WindowDescriptor]] {
        guard permissionService.isAccessibilityGranted() else { return [:] }
        let appIDs = stableUnique(appIDs)
        let generationsByAppID: [String: [RunningAppProcessGeneration]]
        let authoritativeGenerations: Set<RunningAppProcessGeneration>
        if let provider = processIdentifierProvider as? RunningAppProcessGenerationProviding {
            let activeGenerations = stableUnique(provider.activeProcessGenerations())
            authoritativeGenerations = Set(activeGenerations.filter(\.isCacheable))
            generationsByAppID = Dictionary(uniqueKeysWithValues: appIDs.map { appID in
                (appID, activeGenerations.filter { $0.bundleIdentifier == appID })
            })
        } else {
            let identifiersByAppID = processIdentifierProvider.processIdentifiers(for: appIDs)
            authoritativeGenerations = []
            generationsByAppID = Dictionary(uniqueKeysWithValues: appIDs.map { appID in
                (
                    appID,
                    stableUnique(identifiersByAppID[appID, default: []]).map {
                        RunningAppProcessGeneration(
                            bundleIdentifier: appID,
                            processIdentifier: $0,
                            launchIdentity: UUID().uuidString,
                            isCacheable: false
                        )
                    }
                )
            })
        }
        let processGenerations = stableUnique(appIDs.flatMap {
            generationsByAppID[$0, default: []]
        })
        let cachedByGeneration = refreshCache.snapshotAndRefresh(
            authoritativeGenerations: authoritativeGenerations,
            processGenerations: processGenerations,
            reader: candidateReader,
            normalizer: TopLeftToAppKitCoordinateNormalizer(
                mainDisplayMaxY: appKitMainDisplayMaxY
            ),
            messagingTimeout: globalBudget,
            refreshCompletion: { [refreshNotifier] in refreshNotifier.notify() }
        )

        return Dictionary(uniqueKeysWithValues: appIDs.map { appID in
            let candidates = stableUnique(generationsByAppID[appID, default: []])
                .sorted {
                    if $0.processIdentifier != $1.processIdentifier {
                        return $0.processIdentifier < $1.processIdentifier
                    }
                    return $0.launchIdentity < $1.launchIdentity
                }
                .flatMap { cachedByGeneration[$0, default: []] }
                .filter { observed in
                    guard !displays.isEmpty else { return true }
                    let frame = observed.appKitFrame
                    let center = PointSnapshot(
                        x: frame.x + frame.width / 2,
                        y: frame.y + frame.height / 2
                    )
                    return displays.contains { $0.frame.contains(center) }
                }
            return (
                appID,
                candidates.sorted(
                    by: ObservedAXWindowMetadataCandidate.isOrderedBefore
                ).map { selected in
                    WindowDescriptor(
                        id: "accessibility-\(selected.candidate.id)",
                        frame: selected.appKitFrame,
                        isOnScreen: !displays.isEmpty,
                        isMain: selected.candidate.isFocused || selected.candidate.isMain,
                        runtimeIdentity: WindowRuntimeIdentity(
                            ownerProcessIdentifier: selected.processIdentifier,
                            captureWindowID: nil
                        )
                    )
                }
            )
        })
    }

    public func freshEligibleWindows(
        for appIDs: [String],
        displays: [DisplayDescriptor]
    ) async -> Result<[String: [WindowDescriptor]], SwitcherActionFailure> {
        guard permissionService.isAccessibilityGranted() else {
            return .failure(.accessibilityMissing)
        }
        let appIDs = stableUnique(appIDs)
        let identifiersByAppID = processIdentifierProvider.processIdentifiers(for: appIDs)
        let reader = candidateReader
        let normalizer = TopLeftToAppKitCoordinateNormalizer(
            mainDisplayMaxY: appKitMainDisplayMaxY
        )
        let budget = globalBudget

        let queryTask = Task.detached(priority: .userInitiated) {
            () -> Result<[String: [WindowDescriptor]], SwitcherActionFailure> in
            guard !Task.isCancelled else { return .failure(.actionOverloaded) }
            let deadline = ProcessInfo.processInfo.systemUptime + budget
            var observedByAppID: [String: [ObservedAXWindowMetadataCandidate]] = [:]
            var queriedAnyProcess = false
            var completedAnyQuery = false

            for appID in appIDs {
                guard !Task.isCancelled else { return .failure(.actionOverloaded) }
                for processIdentifier in stableUnique(
                    identifiersByAppID[appID, default: []]
                ).sorted() {
                    guard !Task.isCancelled else { return .failure(.actionOverloaded) }
                    queriedAnyProcess = true
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { return .failure(.windowQueryTimedOut) }
                    let query: AXWindowMetadataCandidateQueryResult
                    if let typedReader = reader as? any AXWindowMetadataCandidateQuerying {
                        query = typedReader.queryCandidates(
                            for: processIdentifier,
                            messagingTimeout: remaining
                        )
                    } else {
                        query = .success(reader.candidates(
                            for: processIdentifier,
                            messagingTimeout: remaining
                        ))
                    }
                    switch query {
                    case .timedOut:
                        return .failure(.windowQueryTimedOut)
                    case .unavailable:
                        continue
                    case let .success(candidates):
                        completedAnyQuery = true
                        observedByAppID[appID, default: []].append(contentsOf: candidates
                            .enumerated()
                            .compactMap { index, candidate in
                                guard !candidate.isMinimized,
                                      let frame = normalizer.normalize(candidate.axFrame)
                                else { return nil }
                                return ObservedAXWindowMetadataCandidate(
                                    processIdentifier: processIdentifier,
                                    candidateIndex: index,
                                    candidate: candidate,
                                    appKitFrame: frame
                                )
                            })
                    }
                    guard !Task.isCancelled else { return .failure(.actionOverloaded) }
                    guard ProcessInfo.processInfo.systemUptime <= deadline else {
                        return .failure(.windowQueryTimedOut)
                    }
                }
            }
            if queriedAnyProcess, !completedAnyQuery {
                return .failure(.windowQueryUnavailable)
            }
            guard !Task.isCancelled else { return .failure(.actionOverloaded) }
            return .success(Dictionary(uniqueKeysWithValues: appIDs.map { appID in
                let windows = observedByAppID[appID, default: []]
                    .filter { observed in
                        guard !displays.isEmpty else { return true }
                        let frame = observed.appKitFrame
                        return displays.contains { display in
                            display.frame.contains(PointSnapshot(
                                x: frame.x + frame.width / 2,
                                y: frame.y + frame.height / 2
                            ))
                        }
                    }
                    .sorted(by: ObservedAXWindowMetadataCandidate.isOrderedBefore)
                    .map { observed in
                        WindowDescriptor(
                            id: "accessibility-\(observed.candidate.id)",
                            frame: observed.appKitFrame,
                            isOnScreen: !displays.isEmpty,
                            isMain: observed.candidate.isFocused || observed.candidate.isMain,
                            runtimeIdentity: WindowRuntimeIdentity(
                                ownerProcessIdentifier: observed.processIdentifier,
                                captureWindowID: nil
                            )
                        )
                    }
                return (appID, windows)
            }))
        }
        return await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
    }

    func setCacheRefreshHandler(_ handler: @escaping @Sendable () -> Void) {
        refreshNotifier.setHandler(handler)
    }
}

@MainActor
public struct EmptyWindowMetadataReader: WindowMetadataReading {
    public init() {}

    public func mostRecentWindow(for appID: String) -> WindowDescriptor? {
        nil
    }
}

@MainActor
/// Reference semantics are intentional: aliases observe the same MRU and observer lifecycle.
public final class RunningAppCatalog {
    private let discovery: RunningAppDiscovering
    private let permissionService: PermissionService
    public let iconProvider: RunningAppIconProviding
    public let windowReader: WindowMetadataReading
    private var mruIDs: [String] = []
    private var activationObservation: RunningAppActivationObservation?
    private var windowMetadataRefreshObservers: [UUID: @MainActor () -> Void] = [:]

    @MainActor
    public init(
        discovery: RunningAppDiscovering? = nil,
        windowReader: WindowMetadataReading? = nil,
        activationObserver: RunningAppActivationObserving? = nil,
        permissionService: PermissionService? = nil,
        iconProvider: RunningAppIconProviding? = nil
    ) {
        let permissionService = permissionService ?? PermissionService()
        self.discovery = discovery ?? NSWorkspaceRunningAppDiscovery()
        self.permissionService = permissionService
        self.iconProvider = iconProvider ?? SystemRunningAppIconProvider()
        self.windowReader = windowReader ?? AppKitWindowMetadataReader(
            permissionService: permissionService
        )
        let observer = activationObserver ?? NSWorkspaceRunningAppActivationObserver()
        self.activationObservation = observer.startObserving { [weak self] appID in
            self?.recordActivation(appID: appID)
        }
        if let appKitReader = self.windowReader as? AppKitWindowMetadataReader {
            appKitReader.setCacheRefreshHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.notifyWindowMetadataRefresh()
                }
            }
        }
    }

    public func recordActivation(appID: String) {
        mruIDs.removeAll { $0 == appID }
        mruIDs.insert(appID, at: 0)
    }

    public func cancelActivationObservation() {
        activationObservation?.cancel()
        activationObservation = nil
    }

    func observeWindowMetadataRefresh(
        _ observer: @escaping @MainActor () -> Void
    ) -> RunningAppWindowMetadataObservation {
        let id = UUID()
        windowMetadataRefreshObservers[id] = observer
        return RunningAppWindowMetadataObservation { [weak self] in
            self?.windowMetadataRefreshObservers.removeValue(forKey: id)
        }
    }

    public func snapshot() -> [RunningAppDescriptor] {
        makeRunningAppSnapshot()
    }

    /// Execution-only discovery. It refreshes the live NSWorkspace app set and
    /// MRU ordering without touching the preview/background window cache.
    public func freshExecutionAppIDs() -> [String] {
        refreshRunningAppSources().orderedIDs
    }

    public func displayScopedSnapshot(
        displays: [DisplayDescriptor],
        pointerLocation: PointSnapshot?,
        iconAvailabilityPolicy: RunningAppIconAvailabilityResolutionPolicy = .resolve
    ) -> (
        runningApps: [RunningAppDescriptor],
        workspaces: [DisplayWorkspaceSnapshot]
    ) {
        var seenDisplayIDs = Set<String>()
        let displays = displays.filter { seenDisplayIDs.insert($0.id).inserted }
        let runningApps = makeRunningAppSnapshot(
            displays: displays,
            iconAvailabilityPolicy: iconAvailabilityPolicy
        )
        let previewAvailability: PreviewAvailability = .schematicFallback
        var appsByDisplayIndex = Array(repeating: [RunningAppDescriptor](), count: displays.count)
        var assignedAppIDs = Set<String>()
        let fallbackDisplayIndex = pointerLocation.flatMap { pointer in
            displays.firstIndex { $0.frame.contains(pointer) }
        }

        for app in runningApps where assignedAppIDs.insert(app.id).inserted {
            let windowDisplayIndex: Int? = app.mostRecentWindow.flatMap { window in
                guard window.isOnScreen else { return nil }
                let center = PointSnapshot(
                    x: window.frame.x + (window.frame.width / 2),
                    y: window.frame.y + (window.frame.height / 2)
                )
                return displays.firstIndex { $0.frame.contains(center) }
            }
            guard let displayIndex = windowDisplayIndex ?? fallbackDisplayIndex else {
                continue
            }
            appsByDisplayIndex[displayIndex].append(app)
        }

        let workspaces = displays.indices.map { index in
            DisplayWorkspaceSnapshot(
                display: displays[index],
                apps: appsByDisplayIndex[index].sorted(by: Self.isWorkspaceAppOrderedBefore),
                previewAvailability: previewAvailability
            )
        }
        return (runningApps: runningApps, workspaces: workspaces)
    }

    private func makeRunningAppSnapshot(
        displays: [DisplayDescriptor] = [],
        iconAvailabilityPolicy: RunningAppIconAvailabilityResolutionPolicy = .resolve
    ) -> [RunningAppDescriptor] {
        let refreshed = refreshRunningAppSources()
        let appsByID = refreshed.appsByID
        let orderedIDs = refreshed.orderedIDs
        let windowsByAppID: [String: WindowDescriptor]
        if let displayScopedReader = windowReader as? DisplayScopedWindowMetadataReading {
            windowsByAppID = displayScopedReader.mostRecentWindows(
                for: orderedIDs,
                displays: displays
            )
        } else {
            windowsByAppID = [:]
        }
        let iconAvailabilityByAppID: [String: RunningAppIconAvailability]
        switch iconAvailabilityPolicy {
        case .resolve:
            iconAvailabilityByAppID = iconProvider.iconAvailability(for: orderedIDs)
        case .deferToPresentation:
            iconAvailabilityByAppID = [:]
        }

        return orderedIDs.compactMap { id in
            guard let app = appsByID[id] else { return nil }
            return RunningAppDescriptor(
                id: app.id,
                displayName: app.displayName,
                mostRecentWindow: windowsByAppID[id]
                    ?? (displayScopedReaderMissing(windowReader)
                        ? windowReader.mostRecentWindow(for: app.id)
                        : nil),
                iconAvailability: iconAvailabilityByAppID[app.id] ?? .fallback
            )
        }
    }

    private func refreshRunningAppSources() -> (
        appsByID: [String: RunningAppSource],
        orderedIDs: [String]
    ) {
        let regularApps = discovery.discoverRunningApps()
            .filter { $0.activationPolicy == .regular }
            .sorted {
                if $0.id != $1.id {
                    return $0.id < $1.id
                }
                return $0.displayName < $1.displayName
            }

        var appsByID: [String: RunningAppSource] = [:]
        for app in regularApps where appsByID[app.id] == nil {
            appsByID[app.id] = app
        }

        let deterministicIDs = appsByID.keys.sorted()
        let knownMRU = mruIDs.filter { appsByID[$0] != nil }
        let unseenIDs = deterministicIDs.filter { !knownMRU.contains($0) }
        mruIDs = knownMRU + unseenIDs
        return (appsByID, mruIDs)
    }

    private func notifyWindowMetadataRefresh() {
        windowMetadataRefreshObservers.values.forEach { $0() }
    }

    private func displayScopedReaderMissing(_ reader: WindowMetadataReading) -> Bool {
        !(reader is DisplayScopedWindowMetadataReading)
    }

    private static func isWorkspaceAppOrderedBefore(
        _ lhs: RunningAppDescriptor,
        _ rhs: RunningAppDescriptor
    ) -> Bool {
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        return lhs.displayName < rhs.displayName
    }

    /// Exposes the shared permission seam to dev/test semantic adapters without
    /// exposing the checker or any AppKit object.
    public func permissionState() -> PermissionState {
        permissionService.state()
    }

}

@MainActor
final class RunningAppWindowMetadataObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
    }

    deinit {
        cancellation?()
    }
}

private final class ActivationCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
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

private final class ActivationCallbackGate: @unchecked Sendable {
    private let handler: @MainActor (String) -> Void
    private let cancellationState = ActivationCancellationState()

    init(handler: @escaping @MainActor (String) -> Void) {
        self.handler = handler
    }

    func enqueue(appID: String) {
        guard !cancellationState.isCancelled else { return }
        // Completed handles are intentionally not retained; the gate check is the
        // cancellation contract for tasks that are already queued.
        Task { @MainActor [weak self] in
            guard let self, !self.cancellationState.isCancelled else { return }
            self.handler(appID)
        }
    }

    func cancel() {
        cancellationState.cancel()
    }
}

@MainActor
public final class NSWorkspaceRunningAppActivationObserver: RunningAppActivationObserving {
    private let notificationCenter: NotificationCenter
    private var gate: ActivationCallbackGate?

    public init() {
        self.notificationCenter = NSWorkspace.shared.notificationCenter
    }

    internal init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    public func startObserving(
        _ handler: @escaping @MainActor (String) -> Void
    ) -> RunningAppActivationObservation {
        gate?.cancel()
        let gate = ActivationCallbackGate(handler: handler)
        self.gate = gate
        let token = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak gate] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                let appID = application.bundleIdentifier
            else {
                return
            }
            gate?.enqueue(appID: appID)
        }
        return NSWorkspaceRunningAppActivationObservation(
            notificationCenter: notificationCenter,
            token: token,
            gate: gate
        )
    }

    internal func enqueueActivationForTesting(appID: String) {
        gate?.enqueue(appID: appID)
    }
}

@MainActor
private final class NSWorkspaceRunningAppActivationObservation: RunningAppActivationObservation {
    private let notificationCenter: NotificationCenter
    private let token: NSObjectProtocol
    private let gate: ActivationCallbackGate

    init(
        notificationCenter: NotificationCenter,
        token: NSObjectProtocol,
        gate: ActivationCallbackGate
    ) {
        self.notificationCenter = notificationCenter
        self.token = token
        self.gate = gate
    }

    func cancel() {
        gate.cancel()
        notificationCenter.removeObserver(token)
    }

    deinit {
        gate.cancel()
        notificationCenter.removeObserver(token)
    }
}

@MainActor
public struct NSWorkspaceRunningAppDiscovery: RunningAppDiscovering {
    public init() {}

    public func discoverRunningApps() -> [RunningAppSource] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let id = application.bundleIdentifier else { return nil }
            return RunningAppSource(
                id: id,
                displayName: application.localizedName ?? id,
                activationPolicy: Self.policy(for: application.activationPolicy)
            )
        }
    }

    private static func policy(
        for policy: NSApplication.ActivationPolicy
    ) -> AppActivationPolicy {
        switch policy {
        case .regular:
            return .regular
        case .accessory:
            return .accessory
        case .prohibited:
            return .prohibited
        @unknown default:
            return .prohibited
        }
    }
}
