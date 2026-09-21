import AppKit
import os
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WorkspaceBackdropProviderTests: XCTestCase {
    func testReduceTransparencyReturnsSemanticGradientWithoutReadingWallpaper() {
        let probe = OSAllocatedUnfairLock(initialState: BackdropWorkProbe())
        let provider = WorkspaceBackdropProvider(
            accessibilityPreferences: FixtureWorkspaceAccessibilityPreferences(reduceTransparencyEnabled: true),
            wallpaperURL: { _ in
                probe.withLock { $0.wallpaperReadCount += 1 }
                return URL(fileURLWithPath: "/private/wallpaper")
            },
            imageLoader: { _ in
                probe.withLock { $0.loadCount += 1 }
                return NSImage(size: NSSize(width: 2, height: 2))
            },
            imageProcessor: { image in
                probe.withLock { $0.processCount += 1 }
                return image
            }
        )

        let initial = provider.resolveBackdrop(for: "display-main", screen: nil) { _ in
            XCTFail("Reduce Transparency must not schedule a wallpaper update")
        }

        assertSemanticGradient(initial)
        XCTAssertEqual(probe.withLock { $0 }, BackdropWorkProbe())
    }

    func testWallpaperLoadingAndProcessingRunOffMainActorWhenTransparencyIsAllowed() async {
        let completion = expectation(description: "processed backdrop delivered")
        let probe = OSAllocatedUnfairLock(initialState: BackdropWorkProbe())
        let provider = makeProvider(probe: probe)

        let initial = provider.resolveBackdrop(for: "display-main", screen: nil) { backdrop in
            guard case .image = backdrop else {
                return XCTFail("Successful processing must deliver an image")
            }
            completion.fulfill()
        }

        assertSemanticGradient(initial)
        await fulfillment(of: [completion], timeout: 1)
        let state = probe.withLock { $0 }
        XCTAssertEqual(state.loadCount, 1)
        XCTAssertEqual(state.processCount, 1)
        XCTAssertFalse(state.loaderWasMainThread)
        XCTAssertFalse(state.processorWasMainThread)
    }

    func testRepeatedReconcileTabAndOpenRequestsShareInFlightWorkThenUseCache() async {
        let updates = expectation(description: "all in-flight subscribers receive one result")
        updates.expectedFulfillmentCount = 3
        let probe = OSAllocatedUnfairLock(initialState: BackdropWorkProbe())
        let provider = makeProvider(probe: probe)

        for _ in 0..<3 {
            let initial = provider.resolveBackdrop(for: "display-main", screen: nil) { backdrop in
                guard case .image = backdrop else {
                    return XCTFail("Shared processing must deliver an image")
                }
                updates.fulfill()
            }
            assertSemanticGradient(initial)
        }

        await fulfillment(of: [updates], timeout: 1)
        XCTAssertEqual(probe.withLock { $0.loadCount }, 1)
        XCTAssertEqual(probe.withLock { $0.processCount }, 1)

        let cached = provider.resolveBackdrop(for: "display-main", screen: nil) { _ in
            XCTFail("A cached backdrop must be returned synchronously without another update")
        }
        guard case .image = cached else {
            return XCTFail("The processed backdrop must be cached")
        }
        XCTAssertEqual(probe.withLock { $0.loadCount }, 1)
        XCTAssertEqual(probe.withLock { $0.processCount }, 1)
    }

    func testWallpaperIdentityChangeInvalidatesThePreviousProcessedBackdrop() async {
        var wallpaper = URL(fileURLWithPath: "/private/wallpaper-a")
        let probe = OSAllocatedUnfairLock(initialState: BackdropWorkProbe())
        let provider = WorkspaceBackdropProvider(
            accessibilityPreferences: FixtureWorkspaceAccessibilityPreferences(reduceTransparencyEnabled: false),
            wallpaperURL: { _ in wallpaper },
            imageLoader: { _ in
                probe.withLock { $0.loadCount += 1 }
                return NSImage(size: NSSize(width: 2, height: 2))
            },
            imageProcessor: { image in
                probe.withLock { $0.processCount += 1 }
                return image
            }
        )
        let first = expectation(description: "first wallpaper")
        _ = provider.resolveBackdrop(for: "display-main", screen: nil) { _ in first.fulfill() }
        await fulfillment(of: [first], timeout: 1)

        wallpaper = URL(fileURLWithPath: "/private/wallpaper-b")
        let second = expectation(description: "replacement wallpaper")
        let replacementInitial = provider.resolveBackdrop(for: "display-main", screen: nil) { _ in second.fulfill() }

        assertSemanticGradient(replacementInitial)
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(probe.withLock { $0.loadCount }, 2)
        XCTAssertEqual(probe.withLock { $0.processCount }, 2)
    }

    func testLoadFailureFallsBackAndCachesSemanticGradient() async {
        let completion = expectation(description: "fallback delivered")
        let probe = OSAllocatedUnfairLock(initialState: BackdropWorkProbe())
        let provider = WorkspaceBackdropProvider(
            accessibilityPreferences: FixtureWorkspaceAccessibilityPreferences(reduceTransparencyEnabled: false),
            wallpaperURL: { _ in URL(fileURLWithPath: "/private/missing-wallpaper") },
            imageLoader: { _ in
                probe.withLock { $0.loadCount += 1 }
                return nil
            },
            imageProcessor: { image in
                probe.withLock { $0.processCount += 1 }
                return image
            }
        )

        let initial = provider.resolveBackdrop(for: "display-main", screen: nil) { backdrop in
            self.assertSemanticGradient(backdrop)
            completion.fulfill()
        }
        assertSemanticGradient(initial)
        await fulfillment(of: [completion], timeout: 1)

        let cachedFallback = provider.resolveBackdrop(for: "display-main", screen: nil) { _ in
            XCTFail("Cached fallback must not retry failed work")
        }
        assertSemanticGradient(cachedFallback)
        XCTAssertEqual(probe.withLock { $0.loadCount }, 1)
        XCTAssertEqual(probe.withLock { $0.processCount }, 0)
    }

    func testProcessingFailureFallsBackToSemanticGradient() async {
        let completion = expectation(description: "processing fallback delivered")
        let probe = OSAllocatedUnfairLock(initialState: BackdropWorkProbe())
        let provider = WorkspaceBackdropProvider(
            accessibilityPreferences: FixtureWorkspaceAccessibilityPreferences(reduceTransparencyEnabled: false),
            wallpaperURL: { _ in URL(fileURLWithPath: "/private/unprocessable-wallpaper") },
            imageLoader: { _ in
                probe.withLock { $0.loadCount += 1 }
                return NSImage(size: NSSize(width: 2, height: 2))
            },
            imageProcessor: { _ in
                probe.withLock { $0.processCount += 1 }
                return nil
            }
        )

        _ = provider.resolveBackdrop(for: "display-main", screen: nil) { backdrop in
            self.assertSemanticGradient(backdrop)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)

        XCTAssertEqual(probe.withLock { $0.loadCount }, 1)
        XCTAssertEqual(probe.withLock { $0.processCount }, 1)
    }

    private func makeProvider(
        probe: OSAllocatedUnfairLock<BackdropWorkProbe>
    ) -> WorkspaceBackdropProvider {
        WorkspaceBackdropProvider(
            accessibilityPreferences: FixtureWorkspaceAccessibilityPreferences(reduceTransparencyEnabled: false),
            wallpaperURL: { _ in URL(fileURLWithPath: "/private/wallpaper") },
            imageLoader: { _ in
                probe.withLock {
                    $0.loadCount += 1
                    $0.loaderWasMainThread = Thread.isMainThread
                }
                return NSImage(size: NSSize(width: 2, height: 2))
            },
            imageProcessor: { image in
                probe.withLock {
                    $0.processCount += 1
                    $0.processorWasMainThread = Thread.isMainThread
                }
                return image
            }
        )
    }

    private func assertSemanticGradient(
        _ backdrop: WorkspaceBackdrop,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .semanticGradient = backdrop else {
            return XCTFail("Expected semantic gradient", file: file, line: line)
        }
    }
}

private struct BackdropWorkProbe: Equatable {
    var wallpaperReadCount = 0
    var loadCount = 0
    var processCount = 0
    var loaderWasMainThread = false
    var processorWasMainThread = false
}

@MainActor
private struct FixtureWorkspaceAccessibilityPreferences: WorkspaceAccessibilityPreferencesProviding {
    let reduceTransparencyEnabled: Bool
}
