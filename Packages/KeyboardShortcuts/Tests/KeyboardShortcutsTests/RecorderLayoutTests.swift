import Testing
import Foundation
import AppKit
@testable import KeyboardShortcuts

@Suite("RecorderCocoa Layout Tests")
struct RecorderCocoaLayoutTests {
	@Test("RecorderCocoa has default size")
	func testRecorderDefaultSize() throws {
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test"))

		#expect(recorder.frame.width >= 130)
		#expect(recorder.frame.height > 0)
	}

	@Test("RecorderCocoa works with addSubview")
	@MainActor
	func testRecorderAddSubview() throws {
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test"))
		let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))

		containerView.addSubview(recorder)

		#expect(recorder.frame.size != .zero)
	}

	@Test("Packaged app resources resolve from Contents/Resources")
	func packagedAppResourcesResolveFromContentsResources() throws {
		let resourcesURL = FileManager.default.temporaryDirectory
			.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		let packagedBundleURL = resourcesURL.appending(
			path: "KeyboardShortcuts_KeyboardShortcuts.bundle",
			directoryHint: .isDirectory
		)
		try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: resourcesURL) }
		try FileManager.default.copyItem(at: Bundle.module.bundleURL, to: packagedBundleURL)

		let resolved = Bundle.keyboardShortcutsResources(mainResourceURL: resourcesURL)

		#expect(resolved.bundleURL.standardizedFileURL == packagedBundleURL.standardizedFileURL)
	}
}
