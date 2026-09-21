import Foundation
import ScreenDomainCore
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WindowObservationServiceTests: XCTestCase {
    func testInitialSnapshotIncludesOnlyOrdinaryTopLevelWindows() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let ordinaryA = system.element("ordinary-a")
        let ordinaryB = system.element("ordinary-b")
        let modalChild = system.element("modal-child")
        let utilityPanel = system.element("utility-panel")
        system.setWindows([ordinaryA, ordinaryB, modalChild, utilityPanel], for: app)
        system.setState(ordinaryState(title: "Document A", x: 10), for: ordinaryA, in: app)
        system.setState(ordinaryState(title: "Document B", x: 80), for: ordinaryB, in: app)
        system.setState(
            windowState(
                title: "Modal",
                x: 20,
                subrole: "AXDialog",
                parent: ordinaryA,
                isModal: true
            ),
            for: modalChild,
            in: app
        )
        system.setState(
            windowState(
                title: "Inspector",
                x: 30,
                subrole: "AXFloatingWindow",
                parent: system.applicationElement(for: app),
                isTransient: true
            ),
            for: utilityPanel,
            in: app
        )
        let service = makeService(system)

        let windows = try await service.initialSnapshot()

        XCTAssertEqual(windows.map(\.title), ["Document A", "Document B"])
        XCTAssertEqual(Set(windows.map(\.id)).count, 2)
        XCTAssertNotEqual(windows[0].binding, windows[1].binding)
        XCTAssertEqual(system.runningApplicationScanCount, 1)
        XCTAssertEqual(system.windowListReadCount, 1)
    }

    func testRefreshSnapshotDistinguishesUnreadableInventoryFromTrueEmpty() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("ordinary")
        system.setWindows([window], for: app)
        system.setStateFailure(for: window, in: app)
        let service = makeService(system)

        let unreadable = try await service.refreshSnapshot()

        XCTAssertEqual(unreadable.windows, [])
        XCTAssertEqual(unreadable.completeness, .partial)

        system.setState(ordinaryState(title: "Recovered", x: 10), for: window, in: app)
        let recovered = try await service.refreshSnapshot()

        XCTAssertEqual(recovered.windows.map(\.title), ["Recovered"])
        XCTAssertEqual(recovered.completeness, .complete)
    }

    func testRepeatedSnapshotPreservesIdentityAndBindingAcrossMutableMetadata() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("ordinary")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Before", x: 10), for: window, in: app)
        let service = makeService(system)

        let firstSnapshot = try await service.initialSnapshot()
        let first = try XCTUnwrap(firstSnapshot.first)
        system.setState(
            ordinaryState(
                title: "After",
                x: 220,
                isFocused: true,
                isMinimized: true,
                isSettable: false
            ),
            for: window,
            in: app
        )
        let secondSnapshot = try await service.initialSnapshot()
        let second = try XCTUnwrap(secondSnapshot.first)

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.binding, first.binding)
        XCTAssertEqual(second.title, "After")
        XCTAssertEqual(second.frame, rect(x: 220))
        XCTAssertTrue(second.isFocused)
        XCTAssertTrue(second.isMinimized)
        XCTAssertFalse(second.isSettable)
    }

    func testSnapshotPreservesPresentBindingAcrossTransientStateFailure() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let element = system.element("ordinary")
        system.setWindows([element], for: app)
        system.setState(ordinaryState(title: "Known", x: 10), for: element, in: app)
        let service = makeService(system)
        let firstSnapshot = try await service.initialSnapshot()
        let first = try XCTUnwrap(firstSnapshot.first)
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        system.setStateFailure(for: element, in: app)
        let unavailable = try await service.initialSnapshot()

        XCTAssertEqual(unavailable, [first])
        XCTAssertEqual(system.activeWindowObservationCount, 1)
        XCTAssertEqual(events, [])

        system.setState(ordinaryState(title: "Recovered", x: 40), for: element, in: app)
        let recoveredSnapshot = try await service.initialSnapshot()
        let recovered = try XCTUnwrap(recoveredSnapshot.first)
        XCTAssertEqual(recovered.id, first.id)
        XCTAssertEqual(recovered.binding, first.binding)
        XCTAssertEqual(recovered.title, "Recovered")
        XCTAssertEqual(recovered.frame, rect(x: 40))
    }

    func testLiveEventsRetainTheCreatedOpaqueIdentity() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let existing = system.element("existing")
        let created = system.element("created")
        system.setWindows([existing], for: app)
        system.setState(ordinaryState(title: "Existing", x: 10), for: existing, in: app)
        system.setState(ordinaryState(title: "Created", x: 40), for: created, in: app)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        await system.triggerApplication(.created(created), for: app)
        let createdWindow = try XCTUnwrap(events.createdWindows.first)
        system.setState(
            ordinaryState(title: "Created", x: 40, isFocused: true),
            for: created,
            in: app
        )
        await system.triggerApplication(.focused(created), for: app)
        system.setState(
            ordinaryState(title: "Created", x: 90, isFocused: true),
            for: created,
            in: app
        )
        await system.triggerWindow(.moved(created), for: created, in: app)
        system.setState(
            ordinaryState(
                title: "Created",
                x: 90,
                isFocused: true,
                isMinimized: true
            ),
            for: created,
            in: app
        )
        await system.triggerWindow(.miniaturized(created), for: created, in: app)
        system.setState(
            ordinaryState(title: "Created", x: 90, isFocused: true),
            for: created,
            in: app
        )
        await system.triggerWindow(.deminiaturized(created), for: created, in: app)
        await system.triggerWindow(.destroyed(created), for: created, in: app)

        XCTAssertEqual(createdWindow.binding.processIdentifier, app.processIdentifier)
        XCTAssertEqual(createdWindow.binding.launchGeneration, app.launchGeneration)
        XCTAssertEqual(events, [
            .created(createdWindow),
            .focused(createdWindow.id),
            .frameChanged(createdWindow.id, rect(x: 90)),
            .minimizedChanged(createdWindow.id, true),
            .minimizedChanged(createdWindow.id, false),
            .destroyed(createdWindow.id)
        ])
    }

    func testCreatedWindowRemainsVisibleWhenItsObserverCannotAttach() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let existing = system.element("existing")
        let created = system.element("created")
        system.setWindows([existing], for: app)
        system.setState(ordinaryState(title: "Existing", x: 10), for: existing, in: app)
        system.setState(ordinaryState(title: "Created", x: 40), for: created, in: app)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }
        system.setWindows([existing, created], for: app)
        system.windowRegistrationFailureCall = system.windowRegistrationCount + 1

        await system.triggerApplication(.created(created), for: app)

        let createdWindow = try XCTUnwrap(events.createdWindows.first)
        await system.triggerApplication(.created(created), for: app)
        XCTAssertEqual(createdWindow.title, "Created")
        XCTAssertEqual(events, [.created(createdWindow)])
        XCTAssertEqual(system.activeWindowObservationCount, 1)

        system.clearRegistrationFailures()
        let refreshed = try await service.initialSnapshot()
        XCTAssertEqual(refreshed.first { $0.title == "Created" }?.id, createdWindow.id)
        XCTAssertEqual(system.activeWindowObservationCount, 2)
    }

    func testFocusHandoffKeepsExactlyOneFocusedWindowPerAppGeneration() async throws {
        let app = observedApp()
        let unrelatedApp = observedApp(
            appID: "com.example.Other",
            processIdentifier: 84,
            launchGeneration: "other-launch"
        )
        let system = FakeAXWindowSystem(applications: [app, unrelatedApp])
        let windowA = system.element("window-a")
        let windowB = system.element("window-b")
        let vanished = system.element("vanished")
        let unrelatedWindow = system.element("unrelated-window")
        system.setWindows([windowA, windowB], for: app)
        system.setWindows([unrelatedWindow], for: unrelatedApp)
        system.setState(
            ordinaryState(title: "A", x: 10, isFocused: true),
            for: windowA,
            in: app
        )
        system.setState(
            ordinaryState(title: "B", x: 80),
            for: windowB,
            in: app
        )
        system.setState(
            ordinaryState(title: "Other", x: 140, isFocused: true),
            for: unrelatedWindow,
            in: unrelatedApp
        )
        let service = makeService(system)
        let initial = try await service.initialSnapshot()
        let idA = try XCTUnwrap(initial.first { $0.title == "A" }?.id)
        let idB = try XCTUnwrap(initial.first { $0.title == "B" }?.id)
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        system.setStateFailure(for: windowB, in: app)
        await system.triggerApplication(.focused(windowB), for: app)
        await system.triggerApplication(.focused(vanished), for: app)
        await system.triggerApplication(.focused(windowA), for: app)

        system.setState(
            ordinaryState(title: "B", x: 80, isFocused: true),
            for: windowB,
            in: app
        )
        await system.triggerApplication(.focused(windowB), for: app)
        await system.triggerApplication(.focused(windowB), for: app)
        await system.triggerApplication(.focused(unrelatedWindow), for: unrelatedApp)
        await system.triggerApplication(.focused(windowA), for: app)
        await system.triggerApplication(.focused(windowA), for: app)

        XCTAssertEqual(events, [.focused(idB), .focused(idA)])
    }

    func testEveryUpdateNotificationReconcilesAllStateInStableEventOrder() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let windowA = system.element("window-a")
        let windowB = system.element("window-b")
        system.setWindows([windowA, windowB], for: app)
        system.setState(
            ordinaryState(title: "A", x: 10, isFocused: true),
            for: windowA,
            in: app
        )
        system.setState(ordinaryState(title: "B", x: 80), for: windowB, in: app)
        let service = makeService(system)
        let initial = try await service.initialSnapshot()
        let idA = try XCTUnwrap(initial.first { $0.title == "A" }?.id)
        let idB = try XCTUnwrap(initial.first { $0.title == "B" }?.id)
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        system.setState(
            ordinaryState(
                title: "B",
                x: 100,
                isFocused: true,
                isMinimized: true
            ),
            for: windowB,
            in: app
        )
        await system.triggerWindow(.moved(windowB), for: windowB, in: app)

        system.setState(
            ordinaryState(
                title: "A",
                x: 30,
                isFocused: true,
                isMinimized: true
            ),
            for: windowA,
            in: app
        )
        await system.triggerWindow(.miniaturized(windowA), for: windowA, in: app)
        await system.triggerWindow(.miniaturized(windowA), for: windowA, in: app)
        system.setStateFailure(for: windowB, in: app)
        await system.triggerWindow(.resized(windowB), for: windowB, in: app)

        XCTAssertEqual(events, [
            .frameChanged(idB, rect(x: 100)),
            .minimizedChanged(idB, true),
            .focused(idB),
            .frameChanged(idA, rect(x: 30)),
            .minimizedChanged(idA, true),
            .focused(idA)
        ])
    }

    func testTerminationDestroysOwnedBindingsThenEmitsAppTerminated() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let firstElement = system.element("first")
        let secondElement = system.element("second")
        system.setWindows([firstElement, secondElement], for: app)
        system.setState(ordinaryState(title: "A", x: 10), for: firstElement, in: app)
        system.setState(ordinaryState(title: "B", x: 20), for: secondElement, in: app)
        let service = makeService(system)
        let snapshot = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        await system.triggerWorkspace(.terminated(app))

        XCTAssertEqual(events, snapshot.map { .destroyed($0.id) } + [.appTerminated(app.appID)])
        XCTAssertEqual(system.activeApplicationObservationCount, 0)
        XCTAssertEqual(system.activeWindowObservationCount, 0)
    }

    func testDestroyedReplacementAndPIDReuseReceiveNewIDs() async throws {
        let oldApp = observedApp(processIdentifier: 42, launchGeneration: "launch-1")
        let system = FakeAXWindowSystem(applications: [oldApp])
        let firstElement = system.element("first")
        system.setWindows([firstElement], for: oldApp)
        system.setState(ordinaryState(title: "First", x: 10), for: firstElement, in: oldApp)
        let service = makeService(system)
        let initialSnapshot = try await service.initialSnapshot()
        let initial = try XCTUnwrap(initialSnapshot.first)
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        await system.triggerWindow(.destroyed(firstElement), for: firstElement, in: oldApp)
        let replacement = system.element("replacement")
        system.setState(ordinaryState(title: "Replacement", x: 30), for: replacement, in: oldApp)
        await system.triggerApplication(.created(replacement), for: oldApp)
        let replacementWindow = try XCTUnwrap(events.createdWindows.last)
        XCTAssertNotEqual(replacementWindow.id, initial.id)

        await system.triggerWorkspace(.terminated(oldApp))
        let reusedApp = observedApp(processIdentifier: 42, launchGeneration: "launch-2")
        system.setApplications([reusedApp])
        system.setWindows([replacement], for: reusedApp)
        system.setState(ordinaryState(title: "Reused PID", x: 50), for: replacement, in: reusedApp)
        await system.triggerWorkspace(.launched(reusedApp))
        let reusedWindow = try XCTUnwrap(events.createdWindows.last)

        XCTAssertNotEqual(reusedWindow.id, replacementWindow.id)
        XCTAssertNotEqual(reusedWindow.binding, replacementWindow.binding)
        XCTAssertEqual(reusedWindow.binding.processIdentifier, replacementWindow.binding.processIdentifier)
    }

    func testSamePIDLaunchReplacesOldGenerationWithoutTerminationPayload() async throws {
        let oldApp = observedApp(processIdentifier: 42, launchGeneration: "launch-old")
        let newApp = observedApp(processIdentifier: 42, launchGeneration: "launch-new")
        let system = FakeAXWindowSystem(applications: [oldApp])
        let oldElement = system.element("old-window")
        let newElement = system.element("new-window")
        system.setWindows([oldElement], for: oldApp)
        system.setState(ordinaryState(title: "Old", x: 10), for: oldElement, in: oldApp)
        let service = makeService(system)
        let initial = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        system.setWindows([newElement], for: newApp)
        system.setState(ordinaryState(title: "New", x: 80), for: newElement, in: newApp)
        await system.triggerWorkspace(.launched(newApp))

        let created = try XCTUnwrap(events.createdWindows.first)
        XCTAssertEqual(events, [.destroyed(initial[0].id), .created(created)])
        XCTAssertNotEqual(created.id, initial[0].id)
        XCTAssertEqual(created.binding.launchGeneration, "launch-new")
        XCTAssertEqual(system.activeApplicationObservationCount, 1)
        XCTAssertEqual(system.activeWindowObservationCount, 1)

        await system.triggerWorkspace(.terminated(oldApp))
        XCTAssertEqual(events, [.destroyed(initial[0].id), .created(created)])
        XCTAssertEqual(system.activeApplicationObservationCount, 1)
        XCTAssertEqual(system.activeWindowObservationCount, 1)

        await system.triggerWorkspace(.terminated(newApp))
        await system.triggerWorkspace(.terminated(newApp))
        XCTAssertEqual(events, [
            .destroyed(initial[0].id),
            .created(created),
            .destroyed(created.id),
            .appTerminated(newApp.appID)
        ])
        XCTAssertEqual(system.activeApplicationObservationCount, 0)
        XCTAssertEqual(system.activeWindowObservationCount, 0)
    }

    func testCurrentProcessIsExcludedFromSnapshotAndObservers() async throws {
        let ownApp = observedApp(
            appID: "com.indie-mono.ScreenSwitcher",
            processIdentifier: 777,
            launchGeneration: "own"
        )
        let external = observedApp()
        let system = FakeAXWindowSystem(
            currentProcessIdentifier: 777,
            applications: [ownApp, external]
        )
        let ownWindow = system.element("own")
        let externalWindow = system.element("external")
        system.setWindows([ownWindow], for: ownApp)
        system.setWindows([externalWindow], for: external)
        system.setState(ordinaryState(title: "Own", x: 0), for: ownWindow, in: ownApp)
        system.setState(ordinaryState(title: "External", x: 10), for: externalWindow, in: external)
        let service = makeService(system)

        let snapshot = try await service.initialSnapshot()
        try service.start { _ in XCTFail("no event expected") }

        XCTAssertEqual(snapshot.map(\.appID), [external.appID])
        XCTAssertEqual(system.observedApplicationGenerations, [external.launchGeneration])
    }

    func testStartStopOwnsEveryTokenOnceAndNeverDuplicatesCallbacks() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Window", x: 10), for: window, in: app)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []

        try service.start { events.append($0) }
        try service.start { _ in XCTFail("repeated start must not replace the active handler") }
        XCTAssertEqual(system.workspaceRegistrationCount, 1)
        XCTAssertEqual(system.applicationRegistrationCount, 1)
        XCTAssertEqual(system.windowRegistrationCount, 1)
        XCTAssertEqual(system.activeTokenCount, 3)

        system.setState(ordinaryState(title: "Window", x: 30), for: window, in: app)
        await system.triggerWindow(.resized(window), for: window, in: app)
        XCTAssertEqual(events.count, 1)

        service.stop()
        service.stop()
        XCTAssertEqual(system.activeTokenCount, 0)
        XCTAssertEqual(system.removedTokenIDs.count, 3)
        XCTAssertEqual(Set(system.removedTokenIDs).count, 3)
        system.setState(ordinaryState(title: "Window", x: 60), for: window, in: app)
        await system.triggerAllRetiredCallbacks()
        XCTAssertEqual(events.count, 1)
    }

    func testStopReleasesInventoryAndRequiresFreshSnapshotBeforeRestart() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Window", x: 10), for: window, in: app)
        let service = makeService(system)

        XCTAssertThrowsError(try service.start { _ in }) { error in
            XCTAssertEqual(error as? WindowObservationServiceError, .initialSnapshotRequired)
        }
        XCTAssertEqual(system.activeTokenCount, 0)

        let initial = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }
        service.stop()
        service.stop()

        XCTAssertEqual(system.activeTokenCount, 0)
        XCTAssertEqual(system.removedTokenIDs.count, 3)
        XCTAssertThrowsError(try service.start { _ in }) { error in
            XCTAssertEqual(error as? WindowObservationServiceError, .initialSnapshotRequired)
        }
        system.setState(ordinaryState(title: "Window", x: 40), for: window, in: app)
        await system.triggerAllRetiredCallbacks()
        XCTAssertTrue(events.isEmpty)

        let fresh = try await service.initialSnapshot()
        XCTAssertEqual(system.runningApplicationScanCount, 2)
        XCTAssertNotEqual(fresh.first?.id, initial.first?.id)
        try service.start { events.append($0) }
        XCTAssertEqual(system.activeTokenCount, 3)
    }

    func testStopInvalidatesInFlightInitialSnapshotBeforeItCanRestoreInventory() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Window", x: 10), for: window, in: app)
        let blocked = system.blockNextStateRead(for: window, in: app)
        let service = makeService(system)

        let snapshot = Task { try await service.initialSnapshot() }
        await fulfillment(of: [blocked], timeout: 1)
        service.stop()
        system.releaseBlockedStateRead(for: window, in: app)

        await XCTAssertThrowsCancellationErrorAsync { try await snapshot.value }
        XCTAssertThrowsError(try service.start { _ in }) { error in
            XCTAssertEqual(error as? WindowObservationServiceError, .initialSnapshotRequired)
        }
        XCTAssertEqual(system.activeTokenCount, 0)
    }

    func testStartedSnapshotCannotOverwriteWindowCreatedWhileStateReadIsBlocked() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let existing = system.element("existing")
        let created = system.element("created")
        system.setWindows([existing], for: app)
        system.setState(ordinaryState(title: "Existing", x: 10), for: existing, in: app)
        system.setState(ordinaryState(title: "Created", x: 40), for: created, in: app)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        let blocked = system.blockNextStateRead(for: existing, in: app)
        let snapshot = Task { try await service.initialSnapshot() }
        await fulfillment(of: [blocked], timeout: 1)
        await system.triggerApplication(.created(created), for: app)
        let createdWindow = try XCTUnwrap(events.createdWindows.first)
        XCTAssertEqual(system.activeWindowObservationCount, 2)
        system.releaseBlockedStateRead(for: existing, in: app)

        await XCTAssertThrowsCancellationErrorAsync { try await snapshot.value }
        XCTAssertEqual(system.activeApplicationObservationCount, 1)
        XCTAssertEqual(system.activeWindowObservationCount, 2)
        system.setState(ordinaryState(title: "Created", x: 90), for: created, in: app)
        await system.triggerWindow(.moved(created), for: created, in: app)
        XCTAssertEqual(events.last, .frameChanged(createdWindow.id, rect(x: 90)))
    }

    func testStartedSnapshotCannotResurrectWindowDestroyedWhileStateReadIsBlocked() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Window", x: 10), for: window, in: app)
        let service = makeService(system)
        let initial = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        let blocked = system.blockNextStateRead(for: window, in: app)
        let snapshot = Task { try await service.initialSnapshot() }
        await fulfillment(of: [blocked], timeout: 1)
        await system.triggerWindow(.destroyed(window), for: window, in: app)
        XCTAssertEqual(events, [.destroyed(initial[0].id)])
        XCTAssertEqual(system.activeWindowObservationCount, 0)
        system.releaseBlockedStateRead(for: window, in: app)

        await XCTAssertThrowsCancellationErrorAsync { try await snapshot.value }
        XCTAssertEqual(system.activeApplicationObservationCount, 1)
        XCTAssertEqual(system.activeWindowObservationCount, 0)
        XCTAssertEqual(system.activeTokenCount, 2)
    }

    func testStartedSnapshotCannotOverwriteApplicationLaunchedWhileStateReadIsBlocked() async throws {
        let oldApp = observedApp()
        let newApp = observedApp(
            appID: "com.example.New",
            processIdentifier: 84,
            launchGeneration: "launch-new"
        )
        let system = FakeAXWindowSystem(applications: [oldApp])
        let oldWindow = system.element("old-window")
        let newWindow = system.element("new-window")
        system.setWindows([oldWindow], for: oldApp)
        system.setWindows([newWindow], for: newApp)
        system.setState(ordinaryState(title: "Old", x: 10), for: oldWindow, in: oldApp)
        system.setState(ordinaryState(title: "New", x: 80), for: newWindow, in: newApp)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        let blocked = system.blockNextStateRead(for: oldWindow, in: oldApp)
        let snapshot = Task { try await service.initialSnapshot() }
        await fulfillment(of: [blocked], timeout: 1)
        system.setApplications([oldApp, newApp])
        await system.triggerWorkspace(.launched(newApp))
        let createdWindow = try XCTUnwrap(events.createdWindows.first)
        XCTAssertEqual(system.activeApplicationObservationCount, 2)
        XCTAssertEqual(system.activeWindowObservationCount, 2)
        system.releaseBlockedStateRead(for: oldWindow, in: oldApp)

        await XCTAssertThrowsCancellationErrorAsync { try await snapshot.value }
        XCTAssertEqual(system.activeApplicationObservationCount, 2)
        XCTAssertEqual(system.activeWindowObservationCount, 2)
        system.setState(ordinaryState(title: "New", x: 120), for: newWindow, in: newApp)
        await system.triggerWindow(.moved(newWindow), for: newWindow, in: newApp)
        XCTAssertEqual(events.last, .frameChanged(createdWindow.id, rect(x: 120)))
    }

    func testLaunchedApplicationRetriesTransientObserverRegistrationFailure() async throws {
        let existingApp = observedApp()
        let launchedApp = observedApp(
            appID: "com.example.Launched",
            processIdentifier: 84,
            launchGeneration: "launch-new"
        )
        let system = FakeAXWindowSystem(applications: [existingApp])
        let existingWindow = system.element("existing-window")
        let launchedWindow = system.element("launched-window")
        system.setWindows([existingWindow], for: existingApp)
        system.setWindows([launchedWindow], for: launchedApp)
        system.setState(ordinaryState(title: "Existing", x: 10), for: existingWindow, in: existingApp)
        system.setState(ordinaryState(title: "Launched", x: 80), for: launchedWindow, in: launchedApp)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }
        system.applicationRegistrationFailureCall = system.applicationRegistrationCount + 1

        await system.triggerWorkspace(.launched(launchedApp))

        XCTAssertEqual(system.applicationRegistrationCount, 3)
        XCTAssertEqual(system.activeApplicationObservationCount, 2)
        XCTAssertEqual(events.createdWindows.map(\.appID), [launchedApp.appID])
    }

    func testLaunchedApplicationScansWindowsWhenApplicationObserverCannotAttach() async throws {
        let existingApp = observedApp()
        let launchedApp = observedApp(
            appID: "com.example.Launched",
            processIdentifier: 84,
            launchGeneration: "launch-new"
        )
        let system = FakeAXWindowSystem(applications: [existingApp])
        let existingWindow = system.element("existing-window")
        let launchedWindow = system.element("launched-window")
        system.setWindows([existingWindow], for: existingApp)
        system.setWindows([launchedWindow], for: launchedApp)
        system.setState(ordinaryState(title: "Existing", x: 10), for: existingWindow, in: existingApp)
        system.setState(ordinaryState(title: "Launched", x: 80), for: launchedWindow, in: launchedApp)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }
        system.applicationRegistrationFailureEnabled = true

        await system.triggerWorkspace(.launched(launchedApp))

        let created = try XCTUnwrap(events.createdWindows.first)
        XCTAssertEqual(system.applicationRegistrationCount, 5)
        XCTAssertEqual(system.activeApplicationObservationCount, 1)
        XCTAssertEqual(system.activeWindowObservationCount, 2)

        system.applicationRegistrationFailureEnabled = false
        system.setApplications([existingApp, launchedApp])
        let refreshed = try await service.initialSnapshot()
        XCTAssertEqual(refreshed.first { $0.appID == launchedApp.appID }?.id, created.id)
        XCTAssertEqual(system.activeApplicationObservationCount, 2)

        await system.triggerWorkspace(.launched(launchedApp))
        XCTAssertEqual(events, [.created(created)])
        XCTAssertEqual(system.activeTokenCount, 5)

        await system.triggerWorkspace(.terminated(launchedApp))
        XCTAssertEqual(events, [
            .created(created),
            .destroyed(created.id),
            .appTerminated(launchedApp.appID)
        ])
        XCTAssertEqual(system.activeTokenCount, 3)
        service.stop()
        XCTAssertEqual(system.activeTokenCount, 0)
    }

    func testLaunchedApplicationRetriesTransientWindowStateFailure() async throws {
        let existingApp = observedApp()
        let launchedApp = observedApp(
            appID: "com.example.Launched",
            processIdentifier: 84,
            launchGeneration: "launch-new"
        )
        let system = FakeAXWindowSystem(applications: [existingApp])
        let existingWindow = system.element("existing-window")
        let launchedWindow = system.element("launched-window")
        system.setWindows([existingWindow], for: existingApp)
        system.setWindows([launchedWindow], for: launchedApp)
        system.setState(ordinaryState(title: "Existing", x: 10), for: existingWindow, in: existingApp)
        system.setState(ordinaryState(title: "Launched", x: 80), for: launchedWindow, in: launchedApp)
        system.failNextStateRead(for: launchedWindow, in: launchedApp)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        await system.triggerWorkspace(.launched(launchedApp))

        XCTAssertEqual(system.activeApplicationObservationCount, 2)
        XCTAssertEqual(system.activeWindowObservationCount, 2)
        XCTAssertEqual(events.createdWindows.map(\.appID), [launchedApp.appID])
    }

    func testStartedSnapshotCannotResurrectApplicationTerminatedWhileStateReadIsBlocked() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Window", x: 10), for: window, in: app)
        let service = makeService(system)
        let initial = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        let blocked = system.blockNextStateRead(for: window, in: app)
        let snapshot = Task { try await service.initialSnapshot() }
        await fulfillment(of: [blocked], timeout: 1)
        await system.triggerWorkspace(.terminated(app))
        XCTAssertEqual(events, [.destroyed(initial[0].id), .appTerminated(app.appID)])
        XCTAssertEqual(system.activeApplicationObservationCount, 0)
        XCTAssertEqual(system.activeWindowObservationCount, 0)
        system.releaseBlockedStateRead(for: window, in: app)

        await XCTAssertThrowsCancellationErrorAsync { try await snapshot.value }
        XCTAssertEqual(system.activeApplicationObservationCount, 0)
        XCTAssertEqual(system.activeWindowObservationCount, 0)
        XCTAssertEqual(system.activeTokenCount, 1)
    }

    func testStoppedReconcileCannotMutateFreshRestartedInventory() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Before", x: 10), for: window, in: app)
        let service = makeService(system)
        let initial = try await service.initialSnapshot()
        try service.start { _ in }

        system.setState(ordinaryState(title: "Stale", x: 40), for: window, in: app)
        let blocked = system.blockNextStateRead(for: window, in: app)
        let staleReconcile = Task {
            await system.triggerWindow(.moved(window), for: window, in: app)
        }
        await fulfillment(of: [blocked], timeout: 1)

        service.stop()
        system.setState(ordinaryState(title: "Fresh", x: 90), for: window, in: app)
        let fresh = try await service.initialSnapshot()
        var restartedEvents: [ObservedWindowEvent] = []
        try service.start { restartedEvents.append($0) }
        system.releaseBlockedStateRead(for: window, in: app)
        await staleReconcile.value

        XCTAssertNotEqual(fresh.first?.id, initial.first?.id)
        XCTAssertTrue(restartedEvents.isEmpty)
        XCTAssertEqual(system.activeTokenCount, 3)
    }

    func testStoppedCreateReadCannotReattachAWindowObserver() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let existing = system.element("existing")
        let created = system.element("created")
        system.setWindows([existing], for: app)
        system.setState(ordinaryState(title: "Existing", x: 10), for: existing, in: app)
        system.setState(ordinaryState(title: "Created", x: 40), for: created, in: app)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        try service.start { _ in }

        let blocked = system.blockNextStateRead(for: created, in: app)
        let staleCreate = Task {
            await system.triggerApplication(.created(created), for: app)
        }
        await fulfillment(of: [blocked], timeout: 1)
        service.stop()
        system.releaseBlockedStateRead(for: created, in: app)
        await staleCreate.value

        XCTAssertEqual(system.activeTokenCount, 0)
        XCTAssertThrowsError(try service.start { _ in }) { error in
            XCTAssertEqual(error as? WindowObservationServiceError, .initialSnapshotRequired)
        }
    }

    func testBurstWindowUpdatesCoalesceToOneInFlightReadAndOneDirtyRead() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Before", x: 10), for: window, in: app)
        let service = makeService(system)
        let initial = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        let terminal = expectation(description: "terminal window state observed")
        try service.start {
            events.append($0)
            if $0 == .frameChanged(initial[0].id, self.rect(x: 90)) {
                terminal.fulfill()
            }
        }
        let baselineReads = system.stateReadCount

        system.setState(ordinaryState(title: "Intermediate", x: 40), for: window, in: app)
        let blocked = system.blockNextStateRead(for: window, in: app)
        let first = Task {
            await system.triggerWindow(.moved(window), for: window, in: app)
        }
        await fulfillment(of: [blocked], timeout: 1)

        system.setState(ordinaryState(title: "Terminal", x: 90), for: window, in: app)
        let burst = (0..<40).map { _ in
            Task { await system.triggerWindow(.resized(window), for: window, in: app) }
        }
        for _ in 0..<10 { await Task.yield() }
        system.releaseBlockedStateRead(for: window, in: app)
        await first.value
        for task in burst { await task.value }
        await fulfillment(of: [terminal], timeout: 1)

        XCTAssertLessThanOrEqual(system.stateReadCount - baselineReads, 2)
        XCTAssertEqual(events.last, .frameChanged(initial[0].id, rect(x: 90)))
    }

    func testStartKeepsWorkspaceApplicationAndSuccessfulWindowObserversAfterWindowFailure() async throws {
        let appA = observedApp()
        let appB = observedApp(
            appID: "com.example.Other",
            processIdentifier: 84,
            launchGeneration: "launch-2"
        )
        let system = FakeAXWindowSystem(applications: [appA, appB])
        let windowA = system.element("window-a")
        let windowB = system.element("window-b")
        system.setWindows([windowA], for: appA)
        system.setWindows([windowB], for: appB)
        system.setState(ordinaryState(title: "A", x: 10), for: windowA, in: appA)
        system.setState(ordinaryState(title: "B", x: 80), for: windowB, in: appB)
        let service = makeService(system)
        _ = try await service.initialSnapshot()

        system.windowRegistrationFailureCall = 2
        try service.start { _ in }

        XCTAssertEqual(system.activeApplicationObservationCount, 2)
        XCTAssertEqual(system.activeWindowObservationCount, 1)
        XCTAssertEqual(system.activeTokenCount, 4)

        service.stop()
        XCTAssertEqual(system.activeTokenCount, 0)
        XCTAssertEqual(system.removedTokenIDs.count, 4)
    }

    func testStartedSnapshotReturnsReadInventoryWhenNewApplicationAndWindowObserversFail() async throws {
        let oldApp = observedApp()
        let system = FakeAXWindowSystem(applications: [oldApp])
        let oldWindow = system.element("old-window")
        system.setWindows([oldWindow], for: oldApp)
        system.setState(ordinaryState(title: "Old", x: 10), for: oldWindow, in: oldApp)
        let service = makeService(system)
        let original = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        system.runningApplicationsFailureEnabled = true
        await XCTAssertThrowsErrorAsync { try await service.initialSnapshot() }
        XCTAssertEqual(system.activeApplicationObservationCount, 1)
        XCTAssertEqual(system.activeWindowObservationCount, 1)
        system.runningApplicationsFailureEnabled = false

        let appWithoutObserver = observedApp(
            appID: "com.example.NoAppObserver",
            processIdentifier: 84,
            launchGeneration: "launch-no-app-observer"
        )
        let appWithoutWindowObserver = observedApp(
            appID: "com.example.NoWindowObserver",
            processIdentifier: 85,
            launchGeneration: "launch-no-window-observer"
        )
        let windowWithoutAppObserver = system.element("window-no-app-observer")
        let windowWithoutWindowObserver = system.element("window-no-window-observer")
        system.setApplications([oldApp, appWithoutObserver, appWithoutWindowObserver])
        system.setWindows([windowWithoutAppObserver], for: appWithoutObserver)
        system.setWindows([windowWithoutWindowObserver], for: appWithoutWindowObserver)
        system.setState(
            ordinaryState(title: "No App Observer", x: 80),
            for: windowWithoutAppObserver,
            in: appWithoutObserver
        )
        system.setState(
            ordinaryState(title: "No Window Observer", x: 140),
            for: windowWithoutWindowObserver,
            in: appWithoutWindowObserver
        )
        system.applicationRegistrationFailureCall = system.applicationRegistrationCount + 1
        system.windowRegistrationFailureCall = system.windowRegistrationCount + 2

        let scanOnly = try await service.initialSnapshot()

        XCTAssertEqual(Set(scanOnly.map(\.title)), ["Old", "No App Observer", "No Window Observer"])
        XCTAssertEqual(system.activeApplicationObservationCount, 2)
        XCTAssertEqual(system.activeWindowObservationCount, 2)
        XCTAssertEqual(system.activeTokenCount, 5)
        system.setState(ordinaryState(title: "Old", x: 40), for: oldWindow, in: oldApp)
        await system.triggerWindow(.moved(oldWindow), for: oldWindow, in: oldApp)
        XCTAssertEqual(events, [.frameChanged(original[0].id, rect(x: 40))])

        system.clearRegistrationFailures()
        let refreshed = try await service.initialSnapshot()
        XCTAssertEqual(refreshed.count, 3)
        XCTAssertEqual(refreshed.first { $0.appID == oldApp.appID }?.id, original[0].id)
        XCTAssertEqual(system.activeApplicationObservationCount, 3)
        XCTAssertEqual(system.activeWindowObservationCount, 3)
        XCTAssertEqual(system.activeTokenCount, 7)
    }

    func testReleaseUnregistersObserversAndCannotReceiveCallbacks() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Window", x: 10), for: window, in: app)
        var service: SystemWindowObservationService? = makeService(system)
        _ = try await service?.initialSnapshot()
        var eventCount = 0
        try service?.start { _ in eventCount += 1 }
        weak var releasedService = service

        service = nil
        await system.triggerAllRetiredCallbacks()

        XCTAssertNil(releasedService)
        XCTAssertEqual(system.activeTokenCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    func testFailuresVanishedElementsAndDuplicateCallbacksFailClosed() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let ordinary = system.element("ordinary")
        let inaccessible = system.element("inaccessible")
        let child = system.element("child")
        system.setWindows([ordinary, ordinary, inaccessible, child], for: app)
        system.setState(ordinaryState(title: "Ordinary", x: 10), for: ordinary, in: app)
        system.setStateFailure(for: inaccessible, in: app)
        system.setState(
            windowState(
                title: "Child",
                x: 20,
                parent: ordinary
            ),
            for: child,
            in: app
        )
        let service = makeService(system)
        let snapshot = try await service.initialSnapshot()
        XCTAssertEqual(snapshot.count, 1)
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        await system.triggerApplication(.created(ordinary), for: app)
        await system.triggerApplication(.created(ordinary), for: app)
        await system.triggerWindow(.moved(inaccessible), for: inaccessible, in: app)
        await system.triggerWindow(.destroyed(ordinary), for: ordinary, in: app)
        await system.triggerWindow(.destroyed(ordinary), for: ordinary, in: app)
        XCTAssertEqual(events, [.destroyed(snapshot[0].id)])

        system.setWindows([], for: app)
        let vanishedSnapshot = try await service.initialSnapshot()
        XCTAssertEqual(vanishedSnapshot, [])
        system.setWindows([ordinary], for: app)
        system.setState(ordinaryState(title: "Returned", x: 70), for: ordinary, in: app)
        let returnedSnapshot = try await service.initialSnapshot()
        let returned = try XCTUnwrap(returnedSnapshot.first)
        XCTAssertNotEqual(returned.id, snapshot[0].id)
    }

    func testPassiveStateChangesProduceNoEventOrRescanUntilNotification() async throws {
        let app = observedApp()
        let system = FakeAXWindowSystem(applications: [app])
        let window = system.element("window")
        system.setWindows([window], for: app)
        system.setState(ordinaryState(title: "Window", x: 10), for: window, in: app)
        let service = makeService(system)
        _ = try await service.initialSnapshot()
        var events: [ObservedWindowEvent] = []
        try service.start { events.append($0) }

        system.setState(ordinaryState(title: "Window", x: 90), for: window, in: app)
        await Task.yield()

        XCTAssertEqual(events, [])
        XCTAssertEqual(system.runningApplicationScanCount, 1)
        XCTAssertEqual(system.windowListReadCount, 1)
        await system.triggerWindow(.moved(window), for: window, in: app)
        XCTAssertEqual(events, [.frameChanged("managed-1", rect(x: 90))])
        XCTAssertEqual(system.runningApplicationScanCount, 1)
        XCTAssertEqual(system.windowListReadCount, 1)
    }

    private func makeService(_ system: FakeAXWindowSystem) -> SystemWindowObservationService {
        var nextID = 0
        return SystemWindowObservationService(system: system) {
            nextID += 1
            return "managed-\(nextID)"
        }
    }

    private func observedApp(
        appID: String = "com.example.Editor",
        processIdentifier: pid_t = 42,
        launchGeneration: String = "launch-1"
    ) -> AXObservedApplication {
        AXObservedApplication(
            appID: appID,
            appName: "Editor",
            processIdentifier: processIdentifier,
            launchGeneration: launchGeneration
        )
    }

    private func ordinaryState(
        title: String,
        x: Double,
        isFocused: Bool = false,
        isMinimized: Bool = false,
        isSettable: Bool = true
    ) -> AXWindowState {
        windowState(
            title: title,
            x: x,
            parent: nil,
            isFocused: isFocused,
            isMinimized: isMinimized,
            isSettable: isSettable
        )
    }

    private func windowState(
        title: String,
        x: Double,
        role: String = "AXWindow",
        subrole: String? = "AXStandardWindow",
        parent: AXElement?,
        isModal: Bool = false,
        isTransient: Bool = false,
        isFocused: Bool = false,
        isMinimized: Bool = false,
        isSettable: Bool = true
    ) -> AXWindowState {
        AXWindowState(
            title: title,
            frame: rect(x: x),
            isFocused: isFocused,
            isMinimized: isMinimized,
            isSettable: isSettable,
            role: role,
            subrole: subrole,
            parent: parent,
            isModal: isModal,
            isTransient: isTransient
        )
    }

    private func rect(x: Double) -> CanvasRect {
        CanvasRect(x: x, y: 20, width: 50, height: 40)
    }
}

private extension Array where Element == ObservedWindowEvent {
    var createdWindows: [ObservedWindow] {
        compactMap { event in
            guard case let .created(window) = event else { return nil }
            return window
        }
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("expected operation to throw", file: file, line: line)
    } catch {}
}

@MainActor
private func XCTAssertThrowsCancellationErrorAsync<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("expected CancellationError", file: file, line: line)
    } catch is CancellationError {
    } catch {
        XCTFail("expected CancellationError, got \(error)", file: file, line: line)
    }
}

@MainActor
private final class FakeAXWindowSystem: AXWindowSystem {
    enum Failure: Error {
        case inaccessible
        case inventoryUnavailable
        case registrationFailed
    }

    private struct StateKey: Hashable {
        let generation: String
        let element: AXElement
    }

    let currentProcessIdentifier: pid_t
    private var applications: [AXObservedApplication]
    private var applicationElements: [String: AXElement] = [:]
    private var windowLists: [String: [AXElement]] = [:]
    private var states: [StateKey: Result<AXWindowState, Failure>] = [:]
    private var transientStateFailures: Set<StateKey> = []
    private var blockedStateReadExpectations: [StateKey: XCTestExpectation] = [:]
    private var blockedStateReadContinuations: [StateKey: CheckedContinuation<Void, Never>] = [:]
    private var nextTokenID = 0
    private var applicationCallbacks: [AXObservationToken: (
        AXObservedApplication,
        @MainActor (AXApplicationNotification) async -> Void
    )] = [:]
    private var windowCallbacks: [AXObservationToken: (
        AXObservedApplication,
        AXElement,
        @MainActor (AXWindowNotification) async -> Void
    )] = [:]
    private var workspaceCallbacks: [
        AXObservationToken: @MainActor (AXWorkspaceNotification) async -> Void
    ] = [:]
    private var retiredCallbacks: [@MainActor () async -> Void] = []

    private(set) var runningApplicationScanCount = 0
    private(set) var windowListReadCount = 0
    private(set) var stateReadCount = 0
    private(set) var workspaceRegistrationCount = 0
    private(set) var applicationRegistrationCount = 0
    private(set) var windowRegistrationCount = 0
    private(set) var removedTokenIDs: [Int] = []
    private(set) var observedApplicationGenerations: [String] = []
    var runningApplicationsFailureEnabled = false
    var applicationRegistrationFailureEnabled = false
    var applicationRegistrationFailureCall: Int?
    var windowRegistrationFailureCall: Int?

    var activeTokenCount: Int {
        workspaceCallbacks.count + applicationCallbacks.count + windowCallbacks.count
    }

    var activeApplicationObservationCount: Int { applicationCallbacks.count }
    var activeWindowObservationCount: Int { windowCallbacks.count }

    init(
        currentProcessIdentifier: pid_t = 999,
        applications: [AXObservedApplication]
    ) {
        self.currentProcessIdentifier = currentProcessIdentifier
        self.applications = applications
    }

    func element(_ identity: String) -> AXElement {
        .injected(identity)
    }

    func setApplications(_ applications: [AXObservedApplication]) {
        self.applications = applications
    }

    func clearRegistrationFailures() {
        applicationRegistrationFailureEnabled = false
        applicationRegistrationFailureCall = nil
        windowRegistrationFailureCall = nil
    }

    func setWindows(_ windows: [AXElement], for app: AXObservedApplication) {
        windowLists[app.launchGeneration] = windows
    }

    func setState(_ state: AXWindowState, for element: AXElement, in app: AXObservedApplication) {
        let resolvedState: AXWindowState
        if state.parent == nil {
            resolvedState = AXWindowState(
                title: state.title,
                frame: state.frame,
                isFocused: state.isFocused,
                isMinimized: state.isMinimized,
                isSettable: state.isSettable,
                role: state.role,
                subrole: state.subrole,
                parent: applicationElement(for: app),
                isModal: state.isModal,
                isTransient: state.isTransient
            )
        } else {
            resolvedState = state
        }
        states[StateKey(generation: app.launchGeneration, element: element)] = .success(resolvedState)
    }

    func setStateFailure(for element: AXElement, in app: AXObservedApplication) {
        states[StateKey(generation: app.launchGeneration, element: element)] = .failure(.inaccessible)
    }

    func failNextStateRead(for element: AXElement, in app: AXObservedApplication) {
        transientStateFailures.insert(StateKey(generation: app.launchGeneration, element: element))
    }

    func blockNextStateRead(
        for element: AXElement,
        in app: AXObservedApplication
    ) -> XCTestExpectation {
        let key = StateKey(generation: app.launchGeneration, element: element)
        let expectation = XCTestExpectation(description: "state read blocked")
        blockedStateReadExpectations[key] = expectation
        return expectation
    }

    func releaseBlockedStateRead(for element: AXElement, in app: AXObservedApplication) {
        let key = StateKey(generation: app.launchGeneration, element: element)
        blockedStateReadContinuations.removeValue(forKey: key)?.resume()
    }

    func runningApplications() async throws -> [AXObservedApplication] {
        runningApplicationScanCount += 1
        if runningApplicationsFailureEnabled {
            throw Failure.inventoryUnavailable
        }
        return applications
    }

    func applicationElement(for app: AXObservedApplication) -> AXElement {
        if let element = applicationElements[app.launchGeneration] { return element }
        let element = AXElement.injected("application-\(app.launchGeneration)")
        applicationElements[app.launchGeneration] = element
        return element
    }

    func windows(for app: AXObservedApplication) async throws -> [AXElement] {
        windowListReadCount += 1
        return windowLists[app.launchGeneration] ?? []
    }

    func state(
        of window: AXElement,
        in app: AXObservedApplication
    ) async throws -> AXWindowState {
        let key = StateKey(generation: app.launchGeneration, element: window)
        stateReadCount += 1
        if transientStateFailures.remove(key) != nil { throw Failure.inaccessible }
        let result = states[key]
        if let expectation = blockedStateReadExpectations.removeValue(forKey: key) {
            expectation.fulfill()
            await withCheckedContinuation { continuation in
                blockedStateReadContinuations[key] = continuation
            }
        }
        return try result?.get() ?? { throw Failure.inaccessible }()
    }

    func observeApplication(
        _ app: AXObservedApplication,
        handler: @escaping @MainActor (AXApplicationNotification) async -> Void
    ) throws -> AXObservationToken {
        applicationRegistrationCount += 1
        if applicationRegistrationFailureEnabled
            || applicationRegistrationCount == applicationRegistrationFailureCall {
            throw Failure.registrationFailed
        }
        observedApplicationGenerations.append(app.launchGeneration)
        let token = token()
        applicationCallbacks[token] = (app, handler)
        return token
    }

    func observeWindow(
        _ window: AXElement,
        in app: AXObservedApplication,
        handler: @escaping @MainActor (AXWindowNotification) async -> Void
    ) throws -> AXObservationToken {
        windowRegistrationCount += 1
        if windowRegistrationCount == windowRegistrationFailureCall {
            throw Failure.registrationFailed
        }
        let token = token()
        windowCallbacks[token] = (app, window, handler)
        return token
    }

    func observeWorkspace(
        _ handler: @escaping @MainActor (AXWorkspaceNotification) async -> Void
    ) throws -> AXObservationToken {
        workspaceRegistrationCount += 1
        let token = token()
        workspaceCallbacks[token] = handler
        return token
    }

    func removeObservation(_ token: AXObservationToken) {
        if let callback = applicationCallbacks.removeValue(forKey: token)?.1 {
            retiredCallbacks.append { await callback(.created(.injected("retired"))) }
        } else if let callback = windowCallbacks.removeValue(forKey: token)?.2 {
            retiredCallbacks.append { await callback(.moved(.injected("retired"))) }
        } else if let callback = workspaceCallbacks.removeValue(forKey: token) {
            let app = observedAppForRetiredCallback()
            retiredCallbacks.append { await callback(.launched(app)) }
        } else {
            XCTFail("token removed more than once: \(token.id)")
            return
        }
        removedTokenIDs.append(token.id)
    }

    func triggerApplication(
        _ notification: AXApplicationNotification,
        for app: AXObservedApplication
    ) async {
        let registrations = Array(applicationCallbacks.values)
        for registration in registrations
        where registration.0 == app {
            await registration.1(notification)
        }
    }

    func triggerWindow(
        _ notification: AXWindowNotification,
        for window: AXElement,
        in app: AXObservedApplication
    ) async {
        let registrations = Array(windowCallbacks.values)
        for registration in registrations
        where registration.0 == app && registration.1 == window {
            await registration.2(notification)
        }
    }

    func triggerWorkspace(_ notification: AXWorkspaceNotification) async {
        for callback in Array(workspaceCallbacks.values) {
            await callback(notification)
        }
    }

    func triggerAllRetiredCallbacks() async {
        for callback in retiredCallbacks {
            await callback()
        }
    }

    private func token() -> AXObservationToken {
        nextTokenID += 1
        return AXObservationToken(id: nextTokenID)
    }

    private func observedAppForRetiredCallback() -> AXObservedApplication {
        AXObservedApplication(
            appID: "com.example.Retired",
            appName: "Retired",
            processIdentifier: 123,
            launchGeneration: "retired"
        )
    }
}
