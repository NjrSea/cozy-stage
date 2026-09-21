import Foundation
import CoreGraphics
import ScreenDomainCore

@MainActor
protocol WindowObservationService: AnyObject {
    func initialSnapshot() async throws -> [ObservedWindow]
    func refreshSnapshot() async throws -> WindowObservationSnapshot
    func start(_ handler: @escaping @MainActor (ObservedWindowEvent) -> Void) throws
    func stop()
}

extension WindowObservationService {
    func refreshSnapshot() async throws -> WindowObservationSnapshot {
        WindowObservationSnapshot(
            windows: try await initialSnapshot(),
            completeness: .complete
        )
    }
}

enum WindowObservationSnapshotCompleteness: Equatable {
    case complete
    case partial
}

struct WindowObservationSnapshot: Equatable {
    let windows: [ObservedWindow]
    let completeness: WindowObservationSnapshotCompleteness
}

enum WindowObservationServiceError: Error, Equatable {
    case initialSnapshotRequired
    case registrationFailed
}

struct ObservedWindow: Equatable {
    let id: ManagedWindowID
    let appID: String
    let appName: String
    let title: String
    let frame: CanvasRect
    let isFocused: Bool
    let isMinimized: Bool
    let isSettable: Bool
    let binding: WindowRuntimeBinding
}

enum ObservedWindowEvent: Equatable {
    case created(ObservedWindow)
    case focused(ManagedWindowID)
    case frameChanged(ManagedWindowID, CanvasRect)
    case minimizedChanged(ManagedWindowID, Bool)
    case destroyed(ManagedWindowID)
    case appTerminated(String)
}

/// A process-local capability for one concrete Accessibility window.
///
/// It intentionally has no Codable, Sendable, or textual representation.
private final class NativeExactWindowFocusBinding: @unchecked Sendable {
    let cgWindowID: CGWindowID

    private let lock = NSLock()
    private var element: NativeAXElementBox?

    init(cgWindowID: CGWindowID, element: NativeAXElementBox?) {
        self.cgWindowID = cgWindowID
        self.element = element
    }

    var retainedAXElement: NativeAXElementBox? {
        lock.lock()
        defer { lock.unlock() }
        return element
    }

    func invalidate(_ candidate: NativeAXElementBox) {
        lock.lock()
        defer { lock.unlock() }
        if element === candidate { element = nil }
    }
}

struct WindowRuntimeBinding: Equatable, Hashable {
    let launchGeneration: String
    let processIdentifier: pid_t
    fileprivate let element: AXElement
    private let exactWindowFocus: NativeExactWindowFocusBinding?

    init(
        launchGeneration: String,
        processIdentifier: pid_t,
        element: AXElement,
        cgWindowID: CGWindowID? = nil,
        retainedAXElement: NativeAXElementBox? = nil
    ) {
        self.launchGeneration = launchGeneration
        self.processIdentifier = processIdentifier
        self.element = element
        let resolvedWindowID: CGWindowID? = if let cgWindowID {
            cgWindowID
        } else if case let .windowServer(windowID) = element {
            windowID
        } else {
            nil
        }
        exactWindowFocus = resolvedWindowID.map {
            NativeExactWindowFocusBinding(cgWindowID: $0, element: retainedAXElement)
        }
    }

    /// Module-local access for bounded Accessibility command boundaries only.
    /// The opaque element must never enter persistence, logs, or evidence.
    var axElement: AXElement { element }
    var cgWindowID: CGWindowID? { exactWindowFocus?.cgWindowID }
    var retainedAXElement: NativeAXElementBox? { exactWindowFocus?.retainedAXElement }

    func invalidateRetainedAXElement(_ candidate: NativeAXElementBox) {
        exactWindowFocus?.invalidate(candidate)
    }

    static func == (lhs: WindowRuntimeBinding, rhs: WindowRuntimeBinding) -> Bool {
        lhs.launchGeneration == rhs.launchGeneration
            && lhs.processIdentifier == rhs.processIdentifier
            && lhs.element == rhs.element
            && lhs.cgWindowID == rhs.cgWindowID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(launchGeneration)
        hasher.combine(processIdentifier)
        hasher.combine(element)
        hasher.combine(cgWindowID)
    }
}

enum AXElement: Sendable, Hashable {
    case system(NativeAXElementBox)
    case windowServer(CGWindowID)
    case injected(String)
}

struct AXObservedApplication: Sendable, Hashable {
    let appID: String
    let appName: String
    let processIdentifier: pid_t
    let launchGeneration: String

    static func == (lhs: AXObservedApplication, rhs: AXObservedApplication) -> Bool {
        lhs.appID == rhs.appID
            && lhs.processIdentifier == rhs.processIdentifier
            && lhs.launchGeneration == rhs.launchGeneration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(appID)
        hasher.combine(processIdentifier)
        hasher.combine(launchGeneration)
    }
}

struct AXWindowState: Sendable {
    let title: String
    let frame: CanvasRect
    let isFocused: Bool
    let isMinimized: Bool
    let isSettable: Bool
    let role: String
    let subrole: String?
    let parent: AXElement?
    let isModal: Bool
    let isTransient: Bool
}

enum AXApplicationNotification {
    case created(AXElement)
    case focused(AXElement)
}

enum AXWindowNotification {
    case moved(AXElement)
    case resized(AXElement)
    case miniaturized(AXElement)
    case deminiaturized(AXElement)
    case destroyed(AXElement)
}

enum AXWorkspaceNotification {
    case launched(AXObservedApplication)
    case terminated(AXObservedApplication)
}

struct AXObservationToken: Hashable {
    let id: Int
}

@MainActor
protocol AXWindowSystem: AnyObject {
    var currentProcessIdentifier: pid_t { get }

    func runningApplications() async throws -> [AXObservedApplication]
    func applicationElement(for app: AXObservedApplication) -> AXElement
    func windows(for app: AXObservedApplication) async throws -> [AXElement]
    func state(
        of window: AXElement,
        in app: AXObservedApplication
    ) async throws -> AXWindowState
    func observeApplication(
        _ app: AXObservedApplication,
        handler: @escaping @MainActor (AXApplicationNotification) async -> Void
    ) throws -> AXObservationToken
    func observeWindow(
        _ window: AXElement,
        in app: AXObservedApplication,
        handler: @escaping @MainActor (AXWindowNotification) async -> Void
    ) throws -> AXObservationToken
    func observeWorkspace(
        _ handler: @escaping @MainActor (AXWorkspaceNotification) async -> Void
    ) throws -> AXObservationToken
    func removeObservation(_ token: AXObservationToken)
}

@MainActor
final class SystemWindowObservationService: WindowObservationService {
    private struct Entry {
        let app: AXObservedApplication
        var window: ObservedWindow
    }

    private let system: AXWindowSystem
    private let makeID: () -> ManagedWindowID
    private var entries: [Entry] = []
    private var knownApplications: [AXObservedApplication: AXObservedApplication] = [:]
    private var applicationTokens: [AXObservedApplication: AXObservationToken] = [:]
    private var windowTokens: [WindowRuntimeBinding: AXObservationToken] = [:]
    private var workspaceToken: AXObservationToken?
    private var handler: (@MainActor (ObservedWindowEvent) -> Void)?
    private var isStarted = false
    private var hasSuccessfulSnapshot = false
    private var successfulSnapshotEpoch: UInt64?
    private var lifecycleEpoch: UInt64 = 0
    private var inventoryRevision: UInt64 = 0
    private var eventTail: Task<Void, Never>?
    private struct ReconcileWork {
        let id: UUID
        let task: Task<Void, Never>
        var isDirty: Bool
    }
    private var reconcileWork: [WindowRuntimeBinding: ReconcileWork] = [:]

    convenience init() {
        self.init(system: SystemAXWindowSystem())
    }

    init(
        system: AXWindowSystem,
        idGenerator: @escaping () -> ManagedWindowID = { UUID().uuidString }
    ) {
        self.system = system
        self.makeID = idGenerator
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    func initialSnapshot() async throws -> [ObservedWindow] {
        try await refreshSnapshot().windows
    }

    func refreshSnapshot() async throws -> WindowObservationSnapshot {
        let epoch = lifecycleEpoch
        let started = isStarted
        let revision = inventoryRevision
        let runningApplications = try await system.runningApplications()
        try validateSnapshot(
            epoch: epoch,
            started: started,
            inventoryRevision: revision
        )
        let applications = uniqueApplications(
            runningApplications.filter(isEligibleApplication)
        )
        let active = Set(applications)
        var candidateEntries = entries.filter { active.contains($0.app) }
        var result: [ObservedWindow] = []
        var isComplete = true
        for app in applications {
            let elements = try? await system.windows(for: app)
            try validateSnapshot(
                epoch: epoch,
                started: started,
                inventoryRevision: revision
            )
            guard let elements else {
                isComplete = false
                result.append(contentsOf: candidateEntries.lazy
                    .filter { $0.app == app }
                    .map(\.window))
                continue
            }
            var presentBindings = Set<WindowRuntimeBinding>()
            var returnedBindings = Set<WindowRuntimeBinding>()
            for element in elements {
                let entryIndex: Int
                if let existingIndex = index(of: element, in: app, entries: candidateEntries) {
                    entryIndex = existingIndex
                    let existing = candidateEntries[entryIndex].window
                    let state = try? await system.state(of: element, in: app)
                    try validateSnapshot(
                        epoch: epoch,
                        started: started,
                        inventoryRevision: revision
                    )
                    guard let state else {
                        isComplete = false
                        presentBindings.insert(existing.binding)
                        if returnedBindings.insert(existing.binding).inserted {
                            result.append(existing)
                        }
                        continue
                    }
                    guard isOrdinaryTopLevel(state, in: app) else { continue }
                    candidateEntries[entryIndex].window = observedWindow(
                        id: existing.id,
                        binding: existing.binding,
                        app: app,
                        state: state
                    )
                } else {
                    let state = try? await system.state(of: element, in: app)
                    try validateSnapshot(
                        epoch: epoch,
                        started: started,
                        inventoryRevision: revision
                    )
                    guard let state else {
                        isComplete = false
                        continue
                    }
                    guard isOrdinaryTopLevel(state, in: app) else { continue }
                    let binding = WindowRuntimeBinding(
                        launchGeneration: app.launchGeneration,
                        processIdentifier: app.processIdentifier,
                        element: element
                    )
                    let entry = Entry(
                        app: app,
                        window: observedWindow(
                            id: makeID(),
                            binding: binding,
                            app: app,
                            state: state
                        )
                    )
                    candidateEntries.append(entry)
                    entryIndex = candidateEntries.count - 1
                }

                let window = candidateEntries[entryIndex].window
                presentBindings.insert(window.binding)
                if returnedBindings.insert(window.binding).inserted {
                    result.append(window)
                }
            }
            candidateEntries.removeAll {
                $0.app == app && !presentBindings.contains($0.window.binding)
            }
        }

        var candidateApplications: [AXObservedApplication: AXObservedApplication] = [:]
        for app in applications {
            candidateApplications[app] = app
        }

        var stagedApplicationTokens: [AXObservedApplication: AXObservationToken] = [:]
        var stagedWindowTokens: [WindowRuntimeBinding: AXObservationToken] = [:]
        if started {
            do {
                try validateSnapshot(
                    epoch: epoch,
                    started: started,
                    inventoryRevision: revision
                )
                for app in applications where applicationTokens[app] == nil {
                    stagedApplicationTokens[app] = try? registerApplication(app, epoch: epoch)
                    try validateSnapshot(
                        epoch: epoch,
                        started: started,
                        inventoryRevision: revision
                    )
                }
                for entry in candidateEntries where windowTokens[entry.window.binding] == nil {
                    stagedWindowTokens[entry.window.binding] = try? registerWindow(
                        entry,
                        epoch: epoch
                    )
                    try validateSnapshot(
                        epoch: epoch,
                        started: started,
                        inventoryRevision: revision
                    )
                }
            } catch {
                remove(tokens: Array(stagedWindowTokens.values))
                remove(tokens: Array(stagedApplicationTokens.values))
                throw error
            }
        }

        do {
            try validateSnapshot(
                epoch: epoch,
                started: started,
                inventoryRevision: revision
            )
        } catch {
            remove(tokens: Array(stagedWindowTokens.values))
            remove(tokens: Array(stagedApplicationTokens.values))
            throw error
        }

        if started {
            let obsoleteWindowTokens = windowTokens.filter { binding, _ in
                !candidateEntries.contains(where: { $0.window.binding == binding })
            }
            for (binding, token) in obsoleteWindowTokens {
                system.removeObservation(token)
                windowTokens.removeValue(forKey: binding)
            }
            let obsoleteApplicationTokens = applicationTokens.filter { app, _ in
                candidateApplications[app] == nil
            }
            for (app, token) in obsoleteApplicationTokens {
                system.removeObservation(token)
                applicationTokens.removeValue(forKey: app)
            }
            applicationTokens.merge(stagedApplicationTokens) { current, _ in current }
            windowTokens.merge(stagedWindowTokens) { current, _ in current }
        }

        entries = candidateEntries
        knownApplications = candidateApplications
        hasSuccessfulSnapshot = true
        successfulSnapshotEpoch = epoch
        markInventoryMutation()
        return WindowObservationSnapshot(
            windows: result,
            completeness: isComplete ? .complete : .partial
        )
    }

    func start(_ handler: @escaping @MainActor (ObservedWindowEvent) -> Void) throws {
        guard !isStarted else { return }
        guard hasSuccessfulSnapshot, successfulSnapshotEpoch == lifecycleEpoch else {
            throw WindowObservationServiceError.initialSnapshotRequired
        }
        let startEpoch = lifecycleEpoch &+ 1

        let newWorkspaceToken: AXObservationToken
        do {
            newWorkspaceToken = try system.observeWorkspace { [weak self] notification in
                await self?.serializeEvent(epoch: startEpoch) {
                    await self?.handleWorkspace(notification, epoch: startEpoch)
                }
            }
        } catch {
            throw WindowObservationServiceError.registrationFailed
        }

        var stagedApplicationTokens: [AXObservedApplication: AXObservationToken] = [:]
        var stagedWindowTokens: [WindowRuntimeBinding: AXObservationToken] = [:]
        for app in knownApplications.values {
            stagedApplicationTokens[app] = try? registerApplication(app, epoch: startEpoch)
        }
        for entry in entries {
            stagedWindowTokens[entry.window.binding] = try? registerWindow(
                entry,
                epoch: startEpoch
            )
        }

        workspaceToken = newWorkspaceToken
        applicationTokens = stagedApplicationTokens
        windowTokens = stagedWindowTokens
        self.handler = handler
        lifecycleEpoch = startEpoch
        successfulSnapshotEpoch = startEpoch
        isStarted = true
        markInventoryMutation()
    }

    func stop() {
        lifecycleEpoch &+= 1
        isStarted = false
        for work in reconcileWork.values {
            work.task.cancel()
        }
        reconcileWork.removeAll()
        for token in windowTokens.values {
            system.removeObservation(token)
        }
        for token in applicationTokens.values {
            system.removeObservation(token)
        }
        if let workspaceToken {
            system.removeObservation(workspaceToken)
        }
        windowTokens.removeAll()
        applicationTokens.removeAll()
        workspaceToken = nil
        handler = nil
        eventTail?.cancel()
        eventTail = nil
        entries.removeAll()
        knownApplications.removeAll()
        hasSuccessfulSnapshot = false
        successfulSnapshotEpoch = nil
        markInventoryMutation()
    }

    private func validateSnapshot(
        epoch: UInt64,
        started: Bool,
        inventoryRevision expectedRevision: UInt64
    ) throws {
        guard lifecycleEpoch == epoch,
              isStarted == started,
              inventoryRevision == expectedRevision,
              !Task.isCancelled
        else {
            throw CancellationError()
        }
    }

    private func markInventoryMutation() {
        inventoryRevision &+= 1
    }

    private func isEligibleApplication(_ app: AXObservedApplication) -> Bool {
        app.processIdentifier != system.currentProcessIdentifier
    }

    private func uniqueApplications(
        _ applications: [AXObservedApplication]
    ) -> [AXObservedApplication] {
        var seen = Set<AXObservedApplication>()
        return applications.filter { seen.insert($0).inserted }
    }

    private func isOrdinaryTopLevel(
        _ state: AXWindowState,
        in app: AXObservedApplication
    ) -> Bool {
        state.role == "AXWindow"
            && state.subrole == "AXStandardWindow"
            && state.parent == system.applicationElement(for: app)
            && !state.isModal
            && !state.isTransient
    }

    private func observedWindow(
        id: ManagedWindowID,
        binding: WindowRuntimeBinding,
        app: AXObservedApplication,
        state: AXWindowState
    ) -> ObservedWindow {
        ObservedWindow(
            id: id,
            appID: app.appID,
            appName: app.appName,
            title: state.title,
            frame: state.frame,
            isFocused: state.isFocused,
            isMinimized: state.isMinimized,
            isSettable: state.isSettable,
            binding: binding
        )
    }

    private func index(of element: AXElement, in app: AXObservedApplication) -> Int? {
        index(of: element, in: app, entries: entries)
    }

    private func index(
        of element: AXElement,
        in app: AXObservedApplication,
        entries: [Entry]
    ) -> Int? {
        entries.firstIndex {
            $0.app == app && $0.window.binding.element == element
        }
    }

    private func registerApplication(
        _ app: AXObservedApplication,
        epoch: UInt64
    ) throws -> AXObservationToken {
        try system.observeApplication(app) { [weak self] notification in
            await self?.serializeEvent(epoch: epoch) {
                await self?.handleApplication(notification, app: app, epoch: epoch)
            }
        }
    }

    private func registerWindow(_ entry: Entry, epoch: UInt64) throws -> AXObservationToken {
        let binding = entry.window.binding
        return try system.observeWindow(
            binding.element,
            in: entry.app
        ) { [weak self] notification in
            await self?.receiveWindowNotification(
                notification,
                app: entry.app,
                binding: binding,
                epoch: epoch
            )
        }
    }

    private func remove<S: Sequence>(tokens: S) where S.Element == AXObservationToken {
        for token in tokens {
            system.removeObservation(token)
        }
    }

    private func attachApplication(_ app: AXObservedApplication, epoch: UInt64) throws {
        guard applicationTokens[app] == nil else { return }
        applicationTokens[app] = try registerApplication(app, epoch: epoch)
        markInventoryMutation()
    }

    private func attachWindow(at index: Int, epoch: UInt64) throws {
        let entry = entries[index]
        guard windowTokens[entry.window.binding] == nil else { return }
        windowTokens[entry.window.binding] = try registerWindow(entry, epoch: epoch)
        markInventoryMutation()
    }

    private func serializeEvent(
        epoch: UInt64,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let previous = eventTail
        let next = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled,
                  self.isStarted,
                  self.lifecycleEpoch == epoch
            else { return }
            await operation()
        }
        eventTail = next
        await next.value
    }

    private func handleApplication(
        _ notification: AXApplicationNotification,
        app: AXObservedApplication,
        epoch: UInt64
    ) async {
        guard isActive(epoch: epoch, app: app) else { return }
        switch notification {
        case let .created(element):
            await createWindowIfEligible(element, in: app, epoch: epoch)
        case let .focused(element):
            guard let binding = binding(for: element, in: app) else { return }
            await requestReconcile(binding: binding, app: app, epoch: epoch)
        }
    }

    private func receiveWindowNotification(
        _ notification: AXWindowNotification,
        app: AXObservedApplication,
        binding: WindowRuntimeBinding,
        epoch: UInt64
    ) async {
        guard isActive(epoch: epoch, app: app), contains(binding: binding, app: app) else {
            return
        }
        switch notification {
        case let .moved(element), let .resized(element):
            guard element == binding.element else { return }
            await requestReconcile(binding: binding, app: app, epoch: epoch)
        case let .miniaturized(element), let .deminiaturized(element):
            guard element == binding.element else { return }
            await requestReconcile(binding: binding, app: app, epoch: epoch)
        case let .destroyed(element):
            guard element == binding.element else { return }
            await serializeEvent(epoch: epoch) { [weak self] in
                guard let self, self.contains(binding: binding, app: app) else { return }
                self.cancelReconcile(binding: binding)
                self.removeEntry(binding: binding, emitDestroyed: true)
            }
        }
    }

    private func handleWorkspace(
        _ notification: AXWorkspaceNotification,
        epoch: UInt64
    ) async {
        guard isStarted, lifecycleEpoch == epoch else { return }
        switch notification {
        case let .launched(app):
            guard isEligibleApplication(app) else { return }
            let replacedApplications = knownApplications.keys.filter {
                $0.processIdentifier == app.processIdentifier && $0 != app
            }
            for replaced in replacedApplications {
                detachApplication(
                    replaced,
                    emitDestroyed: true,
                    emitAppTerminated: false
                )
            }
            knownApplications[app] = app
            markInventoryMutation()
            for attempt in 0..<4 where applicationTokens[app] == nil {
                do {
                    try attachApplication(app, epoch: epoch)
                } catch {
                    guard isActive(epoch: epoch, app: app) else { return }
                    if attempt < 3 {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            guard let elements = try? await system.windows(for: app) else { return }
            guard isActive(epoch: epoch, app: app) else { return }
            for element in elements {
                await createWindowIfEligible(element, in: app, epoch: epoch)
            }
        case let .terminated(app):
            guard knownApplications[app] != nil else { return }
            detachApplication(
                app,
                emitDestroyed: true,
                emitAppTerminated: true
            )
        }
    }

    private func createWindowIfEligible(
        _ element: AXElement,
        in app: AXObservedApplication,
        epoch: UInt64
    ) async {
        let binding = WindowRuntimeBinding(
            launchGeneration: app.launchGeneration,
            processIdentifier: app.processIdentifier,
            element: element
        )
        guard isActive(epoch: epoch, app: app), !contains(binding: binding, app: app)
        else { return }
        var resolvedState: AXWindowState?
        for attempt in 0..<4 where resolvedState == nil {
            resolvedState = try? await system.state(of: element, in: app)
            if resolvedState == nil, attempt < 3, isActive(epoch: epoch, app: app) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard isActive(epoch: epoch, app: app),
              !Task.isCancelled,
              !contains(binding: binding, app: app),
              let state = resolvedState,
              isOrdinaryTopLevel(state, in: app)
        else { return }

        let window = observedWindow(
            id: makeID(),
            binding: binding,
            app: app,
            state: state
        )
        entries.append(Entry(app: app, window: window))
        markInventoryMutation()
        try? attachWindow(at: entries.count - 1, epoch: epoch)
        handler?(.created(window))
    }

    /// Reconciles a complete bounded state read. Public events always emit in
    /// geometry, minimized, then focus order regardless of notification kind.
    private func reconcileWindow(
        binding: WindowRuntimeBinding,
        app: AXObservedApplication,
        epoch: UInt64
    ) async {
        guard isActive(epoch: epoch, app: app), contains(binding: binding, app: app)
        else { return }
        let state = try? await system.state(of: binding.element, in: app)
        guard isActive(epoch: epoch, app: app),
              !Task.isCancelled,
              let entryIndex = index(of: binding, in: app),
              let state,
              isOrdinaryTopLevel(state, in: app)
        else { return }
        let existing = entries[entryIndex].window
        if state.isFocused {
            for index in entries.indices
            where index != entryIndex
                && entries[index].app == app
                && entries[index].window.isFocused {
                entries[index].window = replacingFocus(
                    in: entries[index].window,
                    with: false
                )
            }
        }
        let updated = observedWindow(
            id: existing.id,
            binding: existing.binding,
            app: app,
            state: state
        )
        entries[entryIndex].window = updated
        markInventoryMutation()

        if updated.frame != existing.frame {
            handler?(.frameChanged(existing.id, updated.frame))
        }
        if updated.isMinimized != existing.isMinimized {
            handler?(.minimizedChanged(existing.id, updated.isMinimized))
        }
        if updated.isFocused && !existing.isFocused {
            handler?(.focused(existing.id))
        }
    }

    private func requestReconcile(
        binding: WindowRuntimeBinding,
        app: AXObservedApplication,
        epoch: UInt64
    ) async {
        scheduleReconcile(binding: binding, app: app, epoch: epoch)
        while let current = reconcileWork[binding] {
            await current.task.value
            guard lifecycleEpoch == epoch else { return }
        }
    }

    private func scheduleReconcile(
        binding: WindowRuntimeBinding,
        app: AXObservedApplication,
        epoch: UInt64
    ) {
        guard isActive(epoch: epoch, app: app), contains(binding: binding, app: app)
        else { return }
        if var current = reconcileWork[binding] {
            current.isDirty = true
            reconcileWork[binding] = current
            return
        }
        let workID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReconcile(
                binding: binding,
                app: app,
                epoch: epoch,
                workID: workID
            )
        }
        reconcileWork[binding] = ReconcileWork(id: workID, task: task, isDirty: false)
    }

    private func runReconcile(
        binding: WindowRuntimeBinding,
        app: AXObservedApplication,
        epoch: UInt64,
        workID: UUID
    ) async {
        for _ in 0..<2 {
            guard var current = reconcileWork[binding], current.id == workID else { return }
            current.isDirty = false
            reconcileWork[binding] = current
            await reconcileWindow(binding: binding, app: app, epoch: epoch)
            guard let updated = reconcileWork[binding], updated.id == workID else { return }
            if !updated.isDirty {
                reconcileWork.removeValue(forKey: binding)
                return
            }
        }
        guard let current = reconcileWork[binding], current.id == workID else { return }
        let needsFollowUp = current.isDirty && isActive(epoch: epoch, app: app)
        reconcileWork.removeValue(forKey: binding)
        if needsFollowUp {
            scheduleReconcile(binding: binding, app: app, epoch: epoch)
        }
    }

    private func cancelReconcile(binding: WindowRuntimeBinding) {
        reconcileWork.removeValue(forKey: binding)?.task.cancel()
    }

    private func isActive(epoch: UInt64, app: AXObservedApplication) -> Bool {
        isStarted && lifecycleEpoch == epoch && knownApplications[app] != nil
    }

    private func binding(for element: AXElement, in app: AXObservedApplication) -> WindowRuntimeBinding? {
        entries.first { $0.app == app && $0.window.binding.element == element }?.window.binding
    }

    private func contains(binding: WindowRuntimeBinding, app: AXObservedApplication) -> Bool {
        index(of: binding, in: app) != nil
    }

    private func index(of binding: WindowRuntimeBinding, in app: AXObservedApplication) -> Int? {
        entries.firstIndex { $0.app == app && $0.window.binding == binding }
    }

    private func replacingFocus(
        in window: ObservedWindow,
        with isFocused: Bool
    ) -> ObservedWindow {
        ObservedWindow(
            id: window.id,
            appID: window.appID,
            appName: window.appName,
            title: window.title,
            frame: window.frame,
            isFocused: isFocused,
            isMinimized: window.isMinimized,
            isSettable: window.isSettable,
            binding: window.binding
        )
    }

    private func removeEntry(binding: WindowRuntimeBinding, emitDestroyed: Bool) {
        guard let index = entries.firstIndex(where: { $0.window.binding == binding }) else { return }
        cancelReconcile(binding: binding)
        if let token = windowTokens.removeValue(forKey: binding) {
            system.removeObservation(token)
        }
        let removed = entries.remove(at: index)
        markInventoryMutation()
        if emitDestroyed {
            handler?(.destroyed(removed.window.id))
        }
    }

    private func detachApplication(
        _ app: AXObservedApplication,
        emitDestroyed: Bool,
        emitAppTerminated: Bool
    ) {
        if let token = applicationTokens.removeValue(forKey: app) {
            system.removeObservation(token)
            markInventoryMutation()
        }
        let ownedBindings = entries.compactMap { entry in
            entry.app == app ? entry.window.binding : nil
        }
        for binding in ownedBindings {
            removeEntry(binding: binding, emitDestroyed: emitDestroyed)
        }
        if knownApplications.removeValue(forKey: app) != nil {
            markInventoryMutation()
        }
        if emitAppTerminated {
            handler?(.appTerminated(app.appID))
        }
    }
}
