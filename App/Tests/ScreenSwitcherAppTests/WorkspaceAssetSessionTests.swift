import AppKit
import XCTest
@testable import ScreenSwitcherApp

@MainActor
final class WorkspaceAssetSessionTests: XCTestCase {
    func testPreviewReadIsPureAndExplicitRequestStartsCapture() async {
        let capture = AssetCaptureProbe()
        let provider = DisplayPreviewProvider(
            capturer: capture
        )
        let display = fixtureDisplay("display-42")

        XCTAssertEqual(provider.preview(for: display).semanticSnapshot, .schematic(style: "display-window-grid-v1"))
        let requestsBefore = await capture.requests()
        XCTAssertEqual(requestsBefore, [])
        await provider.requestPreview(for: display, targetPixelSize: CGSize(width: 900, height: 600))
        let requestsAfter = await capture.requests()
        XCTAssertEqual(requestsAfter, [CGSize(width: 900, height: 600)])
    }

    func testPreviewCachesByDisplayAndBoundedTargetSize() async {
        let capture = AssetCaptureProbe()
        let provider = DisplayPreviewProvider(
            capturer: capture,
            maximumPixelSize: CGSize(width: 1_600, height: 1_200)
        )
        let display = fixtureDisplay("display-42")

        await provider.requestPreview(for: display, targetPixelSize: CGSize(width: 6_000, height: 4_000))
        await provider.requestPreview(for: display, targetPixelSize: CGSize(width: 6_000, height: 4_000))

        let requests = await capture.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertLessThanOrEqual(requests[0].width, 1_600)
        XCTAssertLessThanOrEqual(requests[0].height, 1_200)
        XCTAssertEqual(provider.preview(for: display).semanticSnapshot, .currentDisplayImageInMemory)
        XCTAssertLessThanOrEqual(provider.preview(for: display).image?.size.width ?? .infinity, 1_600)
        XCTAssertLessThanOrEqual(provider.preview(for: display).image?.size.height ?? .infinity, 1_200)
    }

    func testStaleGenerationAndClosedSessionCannotWritePreview() async {
        let capture = DeferredAssetCapturer()
        let provider = DisplayPreviewProvider(
            capturer: capture
        )
        let first = fixtureDisplay("display-1")
        let second = fixtureDisplay("display-2")

        let firstTask = Task { await provider.requestPreview(for: first, targetPixelSize: CGSize(width: 800, height: 500)) }
        await Task.yield()
        let secondTask = Task { await provider.requestPreview(for: second, targetPixelSize: CGSize(width: 800, height: 500)) }
        await Task.yield()
        await capture.complete(displayID: "display-2")
        await secondTask.value
        await capture.complete(displayID: "display-1")
        await firstTask.value

        XCTAssertEqual(provider.preview(for: second).semanticSnapshot, .currentDisplayImageInMemory)
        XCTAssertEqual(provider.preview(for: first).semanticSnapshot, .schematic(style: "display-window-grid-v1"))

        let closedCapture = DeferredAssetCapturer()
        let closedProvider = DisplayPreviewProvider(
            capturer: closedCapture
        )
        let closedTask = Task { await closedProvider.requestPreview(for: first, targetPixelSize: CGSize(width: 800, height: 500)) }
        await Task.yield()
        closedProvider.close()
        await closedCapture.complete(displayID: "display-1")
        await closedTask.value
        XCTAssertEqual(closedProvider.preview(for: first).semanticSnapshot, .schematic(style: "display-window-grid-v1"))
    }

    func testIconPresentationResolvesEachBundleOncePerSession() {
        let icons = CountingAssetIconProvider()
        let session = RunningAppIconSession(provider: icons)
        let content = fixtureContent(appIDs: ["app-a", "app-a", "app-b"])

        session.preload(bundleIdentifiers: content.selectedWorkspace.apps.map(\.id))
        session.preload(bundleIdentifiers: content.selectedWorkspace.apps.map(\.id))
        _ = SwitchTabPresentation(content: content, iconSession: session)
        _ = SwitchTabPresentation(content: content, iconSession: session)

        XCTAssertEqual(icons.counts, ["app-a": 1, "app-b": 1])
    }

    func testPresentationReadDoesNotResolveUncachedIcons() {
        let icons = CountingAssetIconProvider()
        let session = RunningAppIconSession(provider: icons)

        _ = SwitchTabPresentation(
            content: fixtureContent(appIDs: ["app-a", "app-b"]),
            iconSession: session
        )

        XCTAssertEqual(icons.counts, [:])
    }

    private func fixtureDisplay(_ id: String) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            frame: try! RectDescriptor(x: 0, y: 0, width: 1_512, height: 982),
            isCurrent: true
        )
    }

    private func fixtureContent(appIDs: [String]) -> SwitchWorkspaceContent {
        SwitchWorkspaceContent(
            workspaces: [DisplayWorkspaceSnapshot(
                display: fixtureDisplay("display-42"),
                apps: appIDs.enumerated().map { index, id in
                    RunningAppDescriptor(id: id, displayName: "App \(index)", mostRecentWindow: nil)
                },
                previewAvailability: .schematicFallback
            )],
            selectedDisplayID: "display-42"
        )
    }
}

@MainActor
private struct AssetPermissionChecker {
    let granted: Bool
    func hasScreenRecordingAccess() -> Bool { granted }
    func requestScreenRecordingAccess() -> Bool { granted }
}

private actor AssetCaptureProbe: DisplayPreviewCapturing {
    private var recordedRequests: [CGSize] = []

    func capture(displayID: CGDirectDisplayID, targetPixelSize: CGSize) async -> DisplayPreviewCapture? {
        recordedRequests.append(targetPixelSize)
        return makeAssetCapture(size: targetPixelSize)
    }

    func requests() -> [CGSize] { recordedRequests }
}

private actor DeferredAssetCapturer: DisplayPreviewCapturing {
    private var continuations: [String: CheckedContinuation<DisplayPreviewCapture?, Never>] = [:]

    func capture(displayID: CGDirectDisplayID, targetPixelSize: CGSize) async -> DisplayPreviewCapture? {
        await withCheckedContinuation { continuation in
            continuations["display-\(displayID)"] = continuation
        }
    }

    func complete(displayID: String) {
        continuations.removeValue(forKey: displayID)?.resume(
            returning: makeAssetCapture(size: CGSize(width: 400, height: 250))
        )
    }
}

private func makeAssetCapture(size: CGSize) -> DisplayPreviewCapture {
    let width = max(Int(size.width.rounded()), 1)
    let height = max(Int(size.height.rounded()), 1)
    return DisplayPreviewCapture(
        pixelData: Data(repeating: 0, count: width * height * 4),
        pixelWidth: width,
        pixelHeight: height,
        bytesPerRow: width * 4
    )
}

@MainActor
private final class CountingAssetIconProvider: RunningAppIconProviding {
    private(set) var counts: [String: Int] = [:]
    func icon(for bundleIdentifier: String) -> NSImage? {
        counts[bundleIdentifier, default: 0] += 1
        return NSImage(size: NSSize(width: 48, height: 48))
    }
}
