import AppKit
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class DisplayScopedAppCatalogTests: XCTestCase {
    func testWindowCenterAssociatesAppWithContainingDisplay() throws {
        let displays = try makeDisplays()
        let catalog = makeCatalog(
            appIDs: ["com.example.editor"],
            windows: [
                "com.example.editor": try window(x: 120, y: 10, width: 40, height: 40)
            ]
        )

        let result = catalog.displayScopedSnapshot(
            displays: displays,
            pointerLocation: PointSnapshot(x: 10, y: 10)
        )

        XCTAssertEqual(result.workspaces.map(\.display.id), ["display-left", "display-right"])
        XCTAssertEqual(result.workspaces[0].apps, [])
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.editor"])
    }

    func testSharedHalfOpenEdgeBelongsToRightOrUpperDisplay() throws {
        let displays = [
            DisplayDescriptor(id: "display-left", frame: try rect(x: 0, y: 0), isCurrent: false),
            DisplayDescriptor(id: "display-right", frame: try rect(x: 100, y: 0), isCurrent: true),
            DisplayDescriptor(id: "display-upper", frame: try rect(x: 0, y: 100), isCurrent: false)
        ]
        let catalog = makeCatalog(
            appIDs: ["com.example.right", "com.example.upper"],
            windows: [
                "com.example.right": try window(x: 90, y: 40, width: 20, height: 20),
                "com.example.upper": try window(x: 40, y: 90, width: 20, height: 20)
            ]
        )

        let result = catalog.displayScopedSnapshot(displays: displays, pointerLocation: nil)

        XCTAssertEqual(result.workspaces[0].apps, [])
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.right"])
        XCTAssertEqual(result.workspaces[2].apps.map(\.id), ["com.example.upper"])
    }

    func testNoWindowFallsBackOnlyToPointerDisplay() throws {
        let displays = try makeDisplays(currentID: "display-right")
        let catalog = makeCatalog(appIDs: ["com.example.notes"])

        let result = catalog.displayScopedSnapshot(
            displays: displays,
            pointerLocation: PointSnapshot(x: 150, y: 50)
        )

        XCTAssertEqual(result.workspaces[0].apps, [])
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.notes"])
    }

    func testOffDisplayAndOffScreenWindowsUsePointerFallback() throws {
        let displays = try makeDisplays(currentID: "display-left")
        let catalog = makeCatalog(
            appIDs: ["com.example.offdisplay", "com.example.offscreen"],
            windows: [
                "com.example.offdisplay": try window(x: 500, y: 500, width: 20, height: 20),
                "com.example.offscreen": try window(
                    x: 120,
                    y: 10,
                    width: 20,
                    height: 20,
                    isOnScreen: false
                )
            ]
        )

        let result = catalog.displayScopedSnapshot(
            displays: displays,
            pointerLocation: PointSnapshot(x: 50, y: 50)
        )

        XCTAssertEqual(
            result.workspaces[0].apps.map(\.id),
            ["com.example.offdisplay", "com.example.offscreen"]
        )
        XCTAssertEqual(result.workspaces[1].apps, [])
    }

    func testNoPointerDoesNotUseCurrentOrFirstDisplayAsFallback() throws {
        let displays = try makeDisplays(currentID: "display-right")
        let catalog = makeCatalog(appIDs: ["com.example.editor"])

        let result = catalog.displayScopedSnapshot(displays: displays, pointerLocation: nil)

        XCTAssertEqual(result.workspaces[0].apps, [])
        XCTAssertEqual(result.workspaces[1].apps, [])
        XCTAssertEqual(result.runningApps.map(\.id), ["com.example.editor"])
    }

    func testPointerOutsideAllDisplaysDoesNotAssignWindowlessApp() throws {
        let catalog = makeCatalog(appIDs: ["com.example.editor"])

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(currentID: "display-left"),
            pointerLocation: PointSnapshot(x: 500, y: 500)
        )

        XCTAssertTrue(result.workspaces.allSatisfy(\.apps.isEmpty))
        XCTAssertEqual(result.runningApps.map(\.id), ["com.example.editor"])
    }

    func testWorkspaceAppsUseBundleIDThenDisplayNameOrderingAndNeverDuplicate() throws {
        let displays = try makeDisplays(currentID: "display-left")
        let discovery = TestRunningAppDiscovery(apps: [
            source(id: "com.example.zeta", name: "Alpha"),
            source(id: "com.example.alpha", name: "Zulu"),
            source(id: "com.example.zeta", name: "Later duplicate")
        ])
        let catalog = makeCatalog(discovery: discovery)
        catalog.recordActivation(appID: "com.example.zeta")

        let result = catalog.displayScopedSnapshot(
            displays: displays,
            pointerLocation: PointSnapshot(x: 50, y: 50)
        )
        let assignedIDs = result.workspaces.flatMap(\.apps).map(\.id)

        XCTAssertEqual(result.runningApps.map(\.id), ["com.example.zeta", "com.example.alpha"])
        XCTAssertEqual(result.workspaces[0].apps.map(\.id), ["com.example.alpha", "com.example.zeta"])
        XCTAssertEqual(Set(assignedIDs).count, assignedIDs.count)
        XCTAssertEqual(assignedIDs.sorted(), ["com.example.alpha", "com.example.zeta"])
    }

    func testFreshLiveSnapshotDropsRemovedDisplayWorkspace() throws {
        let displayDiscovery = TestDisplayDiscovery(displays: [
            DisplaySource(id: "display-left", frame: try rect(x: 0, y: 0)),
            DisplaySource(id: "display-right", frame: try rect(x: 100, y: 0))
        ])
        let pointer = TestPointerProvider(location: PointSnapshot(x: 150, y: 50))
        let state = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(discovery: displayDiscovery, pointerLocation: pointer),
            runningAppCatalog: makeCatalog(appIDs: ["com.example.editor"]),
            pointerLocation: pointer,
            frontmostState: TestFrontmostProvider(appID: nil)
        )

        XCTAssertEqual(state.liveSnapshot().workspaces.map(\.display.id), ["display-left", "display-right"])

        displayDiscovery.displays = [
            DisplaySource(id: "display-left", frame: try rect(x: 0, y: 0))
        ]
        pointer.location = PointSnapshot(x: 50, y: 50)
        let refreshed = state.liveSnapshot()

        XCTAssertEqual(refreshed.displays.map(\.id), ["display-left"])
        XCTAssertEqual(refreshed.workspaces.map(\.display.id), ["display-left"])
        XCTAssertEqual(refreshed.workspaces[0].apps.map(\.id), ["com.example.editor"])
    }

    func testMissingSystemIconUsesGenericFallbackWithoutDroppingApp() throws {
        let catalog = makeCatalog(
            appIDs: ["com.example.noicon"],
            iconProvider: TestIconProvider(icons: [:])
        )

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(currentID: "display-left"),
            pointerLocation: PointSnapshot(x: 50, y: 50)
        )

        XCTAssertEqual(result.runningApps[0].iconAvailability, .fallback)
        XCTAssertEqual(result.workspaces[0].apps[0].iconAvailability, .fallback)
    }

    func testPanelSessionDefersCatalogIconAvailabilityButLiveSnapshotStillResolvesIt() throws {
        let iconProvider = TestBatchIconProvider()
        let pointer = TestPointerProvider(location: PointSnapshot(x: 50, y: 50))
        let state = SwitcherRuntimeState(
            displayCatalog: DisplayCatalog(
                discovery: TestDisplayDiscovery(displays: [
                    DisplaySource(id: "display-main", frame: try rect(x: 0, y: 0))
                ]),
                pointerLocation: pointer
            ),
            runningAppCatalog: makeCatalog(
                appIDs: ["com.example.editor"],
                iconProvider: iconProvider
            ),
            pointerLocation: pointer,
            frontmostState: TestFrontmostProvider(appID: nil)
        )

        let panelSnapshot = state.beginPanelSession()

        XCTAssertEqual(iconProvider.batchRequestCount, 0)
        XCTAssertEqual(panelSnapshot.runningApps.first?.iconAvailability, .fallback)

        let liveSnapshot = state.liveSnapshot()

        XCTAssertEqual(iconProvider.batchRequestCount, 1)
        XCTAssertEqual(liveSnapshot.runningApps.first?.iconAvailability, .fallback)
    }

    func testPreviewAvailabilityUsesSchematicFallbackWithoutScreenCaptureDependency() throws {
        let granted = makeCatalog(
            appIDs: [],
            screenRecordingGranted: true,
            accessibilityGranted: false
        ).displayScopedSnapshot(displays: try makeDisplays(), pointerLocation: nil)
        let missing = makeCatalog(
            appIDs: [],
            screenRecordingGranted: false,
            accessibilityGranted: true
        ).displayScopedSnapshot(displays: try makeDisplays(), pointerLocation: nil)

        XCTAssertTrue(granted.workspaces.allSatisfy { $0.previewAvailability == .schematicFallback })
        XCTAssertTrue(missing.workspaces.allSatisfy { $0.previewAvailability == .schematicFallback })
    }

    func testAccessibilityGeometryScopesAppWhenScreenRecordingIsMissing() throws {
        let axReader = TestAXMetadataCandidateReader(candidatesByProcess: [42: [
            try candidate(id: "ax-right", x: 120, y: 50, width: 40, height: 40),
            try candidate(id: "ax-later", x: 10, y: 70, width: 20, height: 20)
        ]])
        let permissionService = testPermissionService(
            screenRecordingGranted: false,
            accessibilityGranted: true
        )
        let windowReader = AppKitWindowMetadataReader(
            permissionService: permissionService,
            processIdentifierProvider: TestProcessIdentifierProvider(
                processIdentifiers: ["com.example.editor": 42]
            ),
            candidateReader: axReader,
            appKitMainDisplayMaxY: 100,
            refreshScheduler: TestImmediateRefreshScheduler()
        )
        _ = windowReader.mostRecentWindows(
            for: ["com.example.editor"],
            displays: []
        )
        let catalog = makeCatalog(
            appIDs: ["com.example.editor"],
            windowReader: windowReader,
            permissionService: permissionService
        )

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(currentID: "display-left"),
            pointerLocation: PointSnapshot(x: 50, y: 50)
        )

        XCTAssertEqual(result.runningApps[0].mostRecentWindow?.id, "accessibility-ax-right")
        XCTAssertEqual(result.workspaces[0].apps, [])
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.editor"])
        XCTAssertTrue(result.workspaces.allSatisfy {
            $0.previewAvailability == .schematicFallback
        })
        XCTAssertEqual(axReader.requestedProcessIdentifiers, [42])
    }

    func testAccessibilityMissingSkipsGeometryAndUsesRealPointerFallback() throws {
        let axReader = TestAXMetadataCandidateReader(candidatesByProcess: [42: [
            try candidate(id: "ax-right", x: 120, y: 50, width: 40, height: 40)
        ]])
        let permissionService = testPermissionService(
            screenRecordingGranted: true,
            accessibilityGranted: false
        )
        let windowReader = AppKitWindowMetadataReader(
            permissionService: permissionService,
            processIdentifierProvider: TestProcessIdentifierProvider(
                processIdentifiers: ["com.example.editor": 42]
            ),
            candidateReader: axReader,
            appKitMainDisplayMaxY: 100,
            refreshScheduler: TestImmediateRefreshScheduler()
        )
        _ = windowReader.mostRecentWindows(
            for: ["com.example.editor"],
            displays: []
        )
        let catalog = makeCatalog(
            appIDs: ["com.example.editor"],
            windowReader: windowReader,
            permissionService: permissionService
        )

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(),
            pointerLocation: PointSnapshot(x: 50, y: 50)
        )

        XCTAssertNil(result.runningApps[0].mostRecentWindow)
        XCTAssertEqual(result.workspaces[0].apps.map(\.id), ["com.example.editor"])
        XCTAssertEqual(result.workspaces[1].apps, [])
        XCTAssertEqual(axReader.requestedProcessIdentifiers, [])
    }

    func testAccessibilityReaderWithNoWindowsReturnsNilSafely() throws {
        let axReader = TestAXMetadataCandidateReader(candidatesByProcess: [42: []])
        let permissionService = testPermissionService(
            screenRecordingGranted: false,
            accessibilityGranted: true
        )
        let windowReader = AppKitWindowMetadataReader(
            permissionService: permissionService,
            processIdentifierProvider: TestProcessIdentifierProvider(
                processIdentifiers: ["com.example.editor": 42]
            ),
            candidateReader: axReader,
            appKitMainDisplayMaxY: 100,
            refreshScheduler: TestImmediateRefreshScheduler()
        )
        _ = windowReader.mostRecentWindows(
            for: ["com.example.editor"],
            displays: []
        )
        let catalog = makeCatalog(
            appIDs: ["com.example.editor"],
            windowReader: windowReader,
            permissionService: permissionService
        )

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(),
            pointerLocation: PointSnapshot(x: 150, y: 50)
        )

        XCTAssertNil(result.runningApps[0].mostRecentWindow)
        XCTAssertEqual(result.workspaces[0].apps, [])
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.editor"])
        XCTAssertEqual(axReader.requestedProcessIdentifiers, [42])
    }

    func testAXFramesNormalizeForVerticallyStackedDisplays() throws {
        let displays = [
            DisplayDescriptor(id: "display-main", frame: try rect(x: 0, y: 0), isCurrent: true),
            DisplayDescriptor(id: "display-upper", frame: try rect(x: 0, y: 100), isCurrent: false)
        ]
        let candidateReader = TestAXMetadataCandidateReader(candidatesByProcess: [
            42: [
                AXWindowMetadataCandidate(
                    id: "upper",
                    axFrame: try RectDescriptor(x: 20, y: -80, width: 40, height: 20),
                    isFocused: true,
                    isMain: true,
                    isMinimized: false
                )
            ]
        ])
        let catalog = makeBatchedCatalog(
            appIDs: ["com.example.editor"],
            processIdentifiers: ["com.example.editor": [42]],
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100
        )

        let result = catalog.displayScopedSnapshot(displays: displays, pointerLocation: nil)

        XCTAssertEqual(result.runningApps[0].mostRecentWindow?.frame.y, 160)
        XCTAssertEqual(result.workspaces[0].apps, [])
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.editor"])
    }

    func testAXFramesNormalizeAcrossNegativeAppKitCoordinates() throws {
        let displays = [
            DisplayDescriptor(id: "display-left", frame: try rect(x: -100, y: 0), isCurrent: false),
            DisplayDescriptor(id: "display-below", frame: try rect(x: 0, y: -100), isCurrent: true)
        ]
        let candidateReader = TestAXMetadataCandidateReader(candidatesByProcess: [
            41: [
                AXWindowMetadataCandidate(
                    id: "left",
                    axFrame: try RectDescriptor(x: -80, y: 20, width: 20, height: 20),
                    isFocused: false,
                    isMain: true,
                    isMinimized: false
                )
            ],
            42: [
                AXWindowMetadataCandidate(
                    id: "below",
                    axFrame: try RectDescriptor(x: 20, y: 120, width: 20, height: 20),
                    isFocused: true,
                    isMain: true,
                    isMinimized: false
                )
            ]
        ])
        let catalog = makeBatchedCatalog(
            appIDs: ["com.example.left", "com.example.below"],
            processIdentifiers: [
                "com.example.left": [41],
                "com.example.below": [42]
            ],
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100
        )

        let result = catalog.displayScopedSnapshot(displays: displays, pointerLocation: nil)

        XCTAssertEqual(result.workspaces[0].apps.map(\.id), ["com.example.left"])
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.below"])
        XCTAssertEqual(result.runningApps.first { $0.id == "com.example.below" }?.mostRecentWindow?.frame.y, -40)
    }

    func testOffDisplayCandidateIsSkippedForLaterOnlineCandidate() throws {
        let candidateReader = TestAXMetadataCandidateReader(candidatesByProcess: [
            42: [
                AXWindowMetadataCandidate(
                    id: "off-display",
                    axFrame: try RectDescriptor(x: 500, y: 20, width: 20, height: 20),
                    isFocused: true,
                    isMain: true,
                    isMinimized: false
                ),
                AXWindowMetadataCandidate(
                    id: "eligible",
                    axFrame: try RectDescriptor(x: 120, y: 20, width: 20, height: 20),
                    isFocused: false,
                    isMain: false,
                    isMinimized: false
                )
            ]
        ])
        let catalog = makeBatchedCatalog(
            appIDs: ["com.example.editor"],
            processIdentifiers: ["com.example.editor": [42]],
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100
        )

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(),
            pointerLocation: nil
        )

        XCTAssertEqual(result.runningApps[0].mostRecentWindow?.id, "accessibility-eligible")
        XCTAssertEqual(result.runningApps[0].mostRecentWindow?.isMain, false)
        XCTAssertEqual(result.workspaces[1].apps.map(\.id), ["com.example.editor"])
    }

    func testMinimizedCandidateIsSkippedAndFocusedStateDeterminesMainFlag() throws {
        let candidateReader = TestAXMetadataCandidateReader(candidatesByProcess: [
            42: [
                AXWindowMetadataCandidate(
                    id: "minimized",
                    axFrame: try RectDescriptor(x: 120, y: 20, width: 20, height: 20),
                    isFocused: true,
                    isMain: true,
                    isMinimized: true
                ),
                AXWindowMetadataCandidate(
                    id: "focused",
                    axFrame: try RectDescriptor(x: 20, y: 20, width: 20, height: 20),
                    isFocused: true,
                    isMain: false,
                    isMinimized: false
                )
            ]
        ])
        let catalog = makeBatchedCatalog(
            appIDs: ["com.example.editor"],
            processIdentifiers: ["com.example.editor": [42]],
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100
        )

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(),
            pointerLocation: nil
        )

        XCTAssertEqual(result.runningApps[0].mostRecentWindow?.id, "accessibility-focused")
        XCTAssertEqual(result.runningApps[0].mostRecentWindow?.isMain, true)
        XCTAssertEqual(result.workspaces[0].apps.map(\.id), ["com.example.editor"])
    }

    func testMultipleProcessesForBundleUseLowestPIDAsDeterministicTieBreak() throws {
        let candidateReader = TestAXMetadataCandidateReader(candidatesByProcess: [
            42: [try candidate(id: "second", x: 20, y: 70, width: 20, height: 20)],
            41: [try candidate(id: "first", x: 20, y: 70, width: 20, height: 20)]
        ])
        let catalog = makeBatchedCatalog(
            appIDs: ["com.example.editor"],
            processIdentifiers: ["com.example.editor": [42, 41, 42]],
            candidateReader: candidateReader,
            appKitMainDisplayMaxY: 100
        )

        let result = catalog.displayScopedSnapshot(
            displays: try makeDisplays(),
            pointerLocation: nil
        )

        XCTAssertEqual(result.runningApps[0].mostRecentWindow?.id, "accessibility-first")
        XCTAssertEqual(Set(candidateReader.requestedProcessIdentifiers), [41, 42])
    }

    func testDirectDisplayScopedSnapshotDeduplicatesDisplayIDsByFirstOccurrence() throws {
        let displays = [
            DisplayDescriptor(id: "display-1", frame: try rect(x: 0, y: 0), isCurrent: true),
            DisplayDescriptor(id: "display-1", frame: try rect(x: 100, y: 0), isCurrent: false),
            DisplayDescriptor(id: "display-2", frame: try rect(x: 200, y: 0), isCurrent: false)
        ]
        let catalog = makeCatalog(appIDs: ["com.example.editor"])

        let result = catalog.displayScopedSnapshot(
            displays: displays,
            pointerLocation: PointSnapshot(x: 50, y: 50)
        )

        XCTAssertEqual(result.workspaces.map(\.display.id), ["display-1", "display-2"])
        XCTAssertEqual(result.workspaces[0].display.frame.x, 0)
        XCTAssertEqual(result.workspaces[0].apps.map(\.id), ["com.example.editor"])
    }

    func testTwentySixAppCacheMissReturnsWithoutStartingAXOnMainActor() throws {
        let appIDs = (0..<26).map { String(format: "com.example.app%02d", $0) }
        let discovery = TestRunningAppDiscovery(
            apps: appIDs.map { source(id: $0, name: $0) }
        )
        let processProvider = TestBatchProcessIdentifierProvider(
            processIdentifiersByAppID: Dictionary(uniqueKeysWithValues: appIDs.enumerated().map {
                ($0.element, [pid_t(100 + $0.offset)])
            })
        )
        let iconProvider = TestBatchIconProvider()
        let candidateReader = TestBudgetedAXMetadataCandidateReader(
            mainThreadDelay: 0.02,
            backgroundDelay: 0.5
        )
        let permissionService = testPermissionService(
            screenRecordingGranted: false,
            accessibilityGranted: true
        )
        let scheduler = TestQueuedRefreshScheduler()
        let catalog = RunningAppCatalog(
            discovery: discovery,
            windowReader: AppKitWindowMetadataReader(
                permissionService: permissionService,
                processIdentifierProvider: processProvider,
                candidateReader: candidateReader,
                appKitMainDisplayMaxY: 100,
                globalBudget: 0.05,
                refreshScheduler: scheduler
            ),
            activationObserver: TestActivationObserver(),
            permissionService: permissionService,
            iconProvider: iconProvider
        )

        let started = ContinuousClock.now
        let result = catalog.displayScopedSnapshot(
            displays: [
                DisplayDescriptor(
                    id: "display-main",
                    frame: try rect(x: 0, y: 0),
                    isCurrent: true
                )
            ],
            pointerLocation: PointSnapshot(x: 50, y: 50)
        )
        let elapsed = started.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(300))
        XCTAssertEqual(discovery.discoveryCount, 1)
        XCTAssertEqual(discovery.discoveryMainThreadValues, [true])
        XCTAssertEqual(processProvider.batchRequestCount, 1)
        XCTAssertEqual(processProvider.batchRequestMainThreadValues, [true])
        XCTAssertEqual(iconProvider.batchRequestCount, 1)
        XCTAssertEqual(iconProvider.batchRequestMainThreadValues, [true])
        XCTAssertEqual(candidateReader.startedCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 26)
        XCTAssertEqual(result.runningApps.count, 26)
        XCTAssertEqual(result.workspaces[0].apps.count, 26)
    }

    func testLegacyJSONWithoutWorkspacesDecodesToSafeDefault() throws {
        let legacy = """
        {
          "displays": [],
          "runningApps": [],
          "pointerLocation": null,
          "frontmostAppID": null
        }
        """.data(using: .utf8)!

        let decoded = try SwitcherSnapshot.decodeJSON(legacy)

        XCTAssertEqual(decoded.workspaces, [])
        XCTAssertEqual(decoded.runningApps, [])
    }

    func testNewWorkspaceJSONRoundTripsWithDeterministicSchema() throws {
        let display = DisplayDescriptor(
            id: "display-1",
            frame: try rect(x: 0, y: 0),
            isCurrent: true
        )
        let app = RunningAppDescriptor(
            id: "com.example.editor",
            displayName: "Editor",
            mostRecentWindow: nil,
            iconAvailability: .available
        )
        let snapshot = SwitcherSnapshot(
            displays: [display],
            runningApps: [app],
            pointerLocation: PointSnapshot(x: 10, y: 10),
            frontmostAppID: app.id,
            workspaces: [
                DisplayWorkspaceSnapshot(
                    display: display,
                    apps: [app],
                    previewAvailability: .available
                )
            ]
        )

        let first = try snapshot.encodedJSON()
        let second = try snapshot.encodedJSON()
        let decoded = try SwitcherSnapshot.decodeJSON(first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let workspace = try XCTUnwrap((object["workspaces"] as? [[String: Any]])?.first)

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(Set(workspace.keys), ["apps", "display", "previewAvailability"])
        XCTAssertEqual(workspace["previewAvailability"] as? String, "available")
    }
}

@MainActor
private final class TestRunningAppDiscovery: RunningAppDiscovering {
    var apps: [RunningAppSource]
    private(set) var discoveryCount = 0
    private(set) var discoveryMainThreadValues: [Bool] = []

    init(apps: [RunningAppSource]) {
        self.apps = apps
    }

    func discoverRunningApps() -> [RunningAppSource] {
        discoveryCount += 1
        discoveryMainThreadValues.append(Thread.isMainThread)
        return apps
    }
}

@MainActor
private struct TestWindowReader: WindowMetadataReading {
    let windows: [String: WindowDescriptor]

    func mostRecentWindow(for appID: String) -> WindowDescriptor? {
        windows[appID]
    }
}

/// Test-only mutable observations are protected by `lock`.
private final class TestAXMetadataCandidateReader: @unchecked Sendable, AXWindowMetadataCandidateReading {
    private let lock = NSLock()
    let candidatesByProcess: [pid_t: [AXWindowMetadataCandidate]]
    private var recordedProcessIdentifiers: [pid_t] = []

    init(candidatesByProcess: [pid_t: [AXWindowMetadataCandidate]]) {
        self.candidatesByProcess = candidatesByProcess
    }

    var requestedProcessIdentifiers: [pid_t] {
        lock.withLock { recordedProcessIdentifiers }
    }

    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        lock.withLock { recordedProcessIdentifiers.append(processIdentifier) }
        return candidatesByProcess[processIdentifier] ?? []
    }
}

private final class TestBudgetedAXMetadataCandidateReader: @unchecked Sendable,
    AXWindowMetadataCandidateReading {
    private let lock = NSLock()
    private let mainThreadDelay: TimeInterval
    private let backgroundDelay: TimeInterval
    private var recordedMainThreadValues: [Bool] = []
    private var recordedMessagingTimeouts: [TimeInterval] = []

    init(mainThreadDelay: TimeInterval, backgroundDelay: TimeInterval) {
        self.mainThreadDelay = mainThreadDelay
        self.backgroundDelay = backgroundDelay
    }

    var startedCount: Int {
        lock.withLock { recordedMainThreadValues.count }
    }

    var mainThreadValues: [Bool] {
        lock.withLock { recordedMainThreadValues }
    }

    var messagingTimeouts: [TimeInterval] {
        lock.withLock { recordedMessagingTimeouts }
    }

    func candidates(
        for processIdentifier: pid_t,
        messagingTimeout: TimeInterval
    ) -> [AXWindowMetadataCandidate] {
        let isMainThread = Thread.isMainThread
        lock.withLock {
            recordedMainThreadValues.append(isMainThread)
            recordedMessagingTimeouts.append(messagingTimeout)
        }
        Thread.sleep(forTimeInterval: isMainThread ? mainThreadDelay : backgroundDelay)
        return []
    }
}

private struct TestImmediateRefreshScheduler: WindowMetadataRefreshScheduling {
    func schedule(_ operation: @escaping @Sendable () -> Void) {
        operation()
    }
}

private final class TestQueuedRefreshScheduler: @unchecked Sendable,
    WindowMetadataRefreshScheduling {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { operations.count } }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }
}

@MainActor
private struct TestProcessIdentifierProvider:
    RunningAppProcessIdentifierProviding,
    RunningAppProcessGenerationProviding {
    let processIdentifiers: [String: pid_t]

    func processIdentifier(for appID: String) -> pid_t? {
        processIdentifiers[appID]
    }

    func activeProcessGenerations() -> [RunningAppProcessGeneration] {
        processIdentifiers.map { appID, processIdentifier in
            RunningAppProcessGeneration(
                bundleIdentifier: appID,
                processIdentifier: processIdentifier,
                launchIdentity: "test-launch-\(appID)-\(processIdentifier)"
            )
        }
    }
}

@MainActor
private final class TestBatchProcessIdentifierProvider:
    RunningAppProcessIdentifierProviding,
    RunningAppProcessGenerationProviding {
    let processIdentifiersByAppID: [String: [pid_t]]
    private(set) var batchRequestCount = 0
    private(set) var batchRequestMainThreadValues: [Bool] = []

    init(processIdentifiersByAppID: [String: [pid_t]]) {
        self.processIdentifiersByAppID = processIdentifiersByAppID
    }

    func processIdentifier(for appID: String) -> pid_t? {
        processIdentifiersByAppID[appID]?.sorted().first
    }

    func processIdentifiers(for appIDs: [String]) -> [String: [pid_t]] {
        batchRequestCount += 1
        batchRequestMainThreadValues.append(Thread.isMainThread)
        return Dictionary(uniqueKeysWithValues: appIDs.map { appID in
            (appID, processIdentifiersByAppID[appID, default: []])
        })
    }

    func activeProcessGenerations() -> [RunningAppProcessGeneration] {
        batchRequestCount += 1
        batchRequestMainThreadValues.append(Thread.isMainThread)
        return processIdentifiersByAppID.flatMap { appID, processIdentifiers in
            processIdentifiers.map { processIdentifier in
                RunningAppProcessGeneration(
                    bundleIdentifier: appID,
                    processIdentifier: processIdentifier,
                    launchIdentity: "test-launch-\(appID)-\(processIdentifier)"
                )
            }
        }
    }
}

@MainActor
private final class TestBatchIconProvider: RunningAppIconProviding {
    private(set) var batchRequestCount = 0
    private(set) var batchRequestMainThreadValues: [Bool] = []

    func icon(for bundleIdentifier: String) -> NSImage? {
        nil
    }

    func iconAvailability(
        for bundleIdentifiers: [String]
    ) -> [String: RunningAppIconAvailability] {
        batchRequestCount += 1
        batchRequestMainThreadValues.append(Thread.isMainThread)
        return Dictionary(uniqueKeysWithValues: bundleIdentifiers.map { ($0, .fallback) })
    }
}

@MainActor
private final class TestDisplayDiscovery: DisplayDiscovering {
    var displays: [DisplaySource]

    init(displays: [DisplaySource]) {
        self.displays = displays
    }

    func discoverDisplays() -> [DisplaySource] {
        displays
    }
}

@MainActor
private final class TestPointerProvider: PointerLocationProviding {
    var location: PointSnapshot?

    init(location: PointSnapshot?) {
        self.location = location
    }

    func currentPointerLocation() -> PointSnapshot? {
        location
    }
}

@MainActor
private struct TestFrontmostProvider: FrontmostStateProviding {
    let appID: String?

    func frontmostApplicationID() -> String? {
        appID
    }
}

@MainActor
private struct TestIconProvider: RunningAppIconProviding {
    let icons: [String: NSImage]

    func icon(for bundleIdentifier: String) -> NSImage? {
        icons[bundleIdentifier]
    }
}

@MainActor
private struct TestActivationObserver: RunningAppActivationObserving {
    func startObserving(
        _ handler: @escaping @MainActor (String) -> Void
    ) -> RunningAppActivationObservation {
        TestActivationObservation()
    }
}

@MainActor
private final class TestActivationObservation: RunningAppActivationObservation {
    func cancel() {}
}

@MainActor
private struct TestAccessibilityChecker: AccessibilityChecking {
    let granted: Bool

    func isAccessibilityTrusted() -> Bool { granted }
    func requestAccessibilityAccess() -> Bool { granted }
}

@MainActor
private struct TestScreenRecordingChecker {
    let granted: Bool

    func hasScreenRecordingAccess() -> Bool { granted }
    func requestScreenRecordingAccess() -> Bool { granted }
}

@MainActor
private struct TestSettingsOpener: PermissionSettingsOpening {
    func openSettings(for kind: PermissionKind) -> Bool { true }
}

@MainActor
private func makeCatalog(
    appIDs: [String],
    windows: [String: WindowDescriptor] = [:],
    windowReader: WindowMetadataReading? = nil,
    iconProvider: RunningAppIconProviding = TestIconProvider(icons: [:]),
    screenRecordingGranted: Bool = true,
    accessibilityGranted: Bool = true,
    permissionService: PermissionService? = nil
) -> RunningAppCatalog {
    makeCatalog(
        discovery: TestRunningAppDiscovery(apps: appIDs.map { source(id: $0, name: $0) }),
        windows: windows,
        windowReader: windowReader,
        iconProvider: iconProvider,
        screenRecordingGranted: screenRecordingGranted,
        accessibilityGranted: accessibilityGranted,
        permissionService: permissionService
    )
}

@MainActor
private func makeCatalog(
    discovery: TestRunningAppDiscovery,
    windows: [String: WindowDescriptor] = [:],
    windowReader: WindowMetadataReading? = nil,
    iconProvider: RunningAppIconProviding = TestIconProvider(icons: [:]),
    screenRecordingGranted: Bool = true,
    accessibilityGranted: Bool = true,
    permissionService: PermissionService? = nil
) -> RunningAppCatalog {
    let permissionService = permissionService ?? testPermissionService(
        screenRecordingGranted: screenRecordingGranted,
        accessibilityGranted: accessibilityGranted
    )
    return RunningAppCatalog(
        discovery: discovery,
        windowReader: windowReader ?? TestWindowReader(windows: windows),
        activationObserver: TestActivationObserver(),
        permissionService: permissionService,
        iconProvider: iconProvider
    )
}

@MainActor
private func testPermissionService(
    screenRecordingGranted: Bool,
    accessibilityGranted: Bool
) -> PermissionService {
    PermissionService(
        accessibilityChecker: TestAccessibilityChecker(granted: accessibilityGranted),
        settingsOpener: TestSettingsOpener()
    )
}

@MainActor
private func makeBatchedCatalog(
    appIDs: [String],
    processIdentifiers: [String: [pid_t]],
    candidateReader: AXWindowMetadataCandidateReading,
    appKitMainDisplayMaxY: Double,
    globalBudget: TimeInterval = 0.25
) -> RunningAppCatalog {
    let permissionService = testPermissionService(
        screenRecordingGranted: false,
        accessibilityGranted: true
    )
    let windowReader = AppKitWindowMetadataReader(
        permissionService: permissionService,
        processIdentifierProvider: TestBatchProcessIdentifierProvider(
            processIdentifiersByAppID: processIdentifiers
        ),
        candidateReader: candidateReader,
        appKitMainDisplayMaxY: appKitMainDisplayMaxY,
        globalBudget: globalBudget,
        refreshScheduler: TestImmediateRefreshScheduler()
    )
    _ = windowReader.mostRecentWindows(for: appIDs, displays: [])
    return RunningAppCatalog(
        discovery: TestRunningAppDiscovery(apps: appIDs.map { source(id: $0, name: $0) }),
        windowReader: windowReader,
        activationObserver: TestActivationObserver(),
        permissionService: permissionService,
        iconProvider: TestIconProvider(icons: [:])
    )
}

private func source(id: String, name: String) -> RunningAppSource {
    RunningAppSource(id: id, displayName: name, activationPolicy: .regular)
}

private func rect(x: Double, y: Double) throws -> RectDescriptor {
    try RectDescriptor(x: x, y: y, width: 100, height: 100)
}

private func window(
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    isOnScreen: Bool = true
) throws -> WindowDescriptor {
    WindowDescriptor(
        id: "window-\(x)-\(y)",
        frame: try RectDescriptor(x: x, y: y, width: width, height: height),
        isOnScreen: isOnScreen,
        isMain: true
    )
}

private func candidate(
    id: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    isFocused: Bool = false,
    isMain: Bool = false,
    isMinimized: Bool = false
) throws -> AXWindowMetadataCandidate {
    AXWindowMetadataCandidate(
        id: id,
        axFrame: try RectDescriptor(x: x, y: y, width: width, height: height),
        isFocused: isFocused,
        isMain: isMain,
        isMinimized: isMinimized
    )
}

private func makeDisplays(currentID: String? = "display-left") throws -> [DisplayDescriptor] {
    [
        DisplayDescriptor(
            id: "display-left",
            frame: try rect(x: 0, y: 0),
            isCurrent: currentID == "display-left"
        ),
        DisplayDescriptor(
            id: "display-right",
            frame: try rect(x: 100, y: 0),
            isCurrent: currentID == "display-right"
        )
    ]
}
