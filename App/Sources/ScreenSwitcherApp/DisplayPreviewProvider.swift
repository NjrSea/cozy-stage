import AppKit
import CoreGraphics

public enum DisplayPreviewSemanticSnapshot: Equatable, CustomStringConvertible, Sendable {
    case currentDisplayImageInMemory
    case schematic(style: String)

    public var description: String {
        switch self {
        case .currentDisplayImageInMemory:
            return "current-display-image-in-memory"
        case let .schematic(style):
            return "schematic:\(style)"
        }
    }
}

@MainActor
public struct DisplayPreview {
    public let image: NSImage?
    public let semanticSnapshot: DisplayPreviewSemanticSnapshot

    public init(image: NSImage?, semanticSnapshot: DisplayPreviewSemanticSnapshot) {
        self.image = image
        self.semanticSnapshot = semanticSnapshot
    }
}

@MainActor
public protocol DisplayPreviewProviding: AnyObject {
    func preview(for display: DisplayDescriptor) -> DisplayPreview
    func requestPreview(for display: DisplayDescriptor, targetPixelSize: CGSize) async
    func close()
}

@MainActor
public final class DeterministicDisplayPreviewProvider: DisplayPreviewProviding {
    public init() {}

    public func preview(for display: DisplayDescriptor) -> DisplayPreview {
        DisplayPreview(
            image: nil,
            semanticSnapshot: .schematic(style: "display-window-grid-v1")
        )
    }

    public func requestPreview(for display: DisplayDescriptor, targetPixelSize: CGSize) async {}
    public func close() {}
}

public struct DisplayPreviewCapture: Equatable, Sendable {
    public let pixelData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bytesPerRow: Int

    public init(pixelData: Data, pixelWidth: Int, pixelHeight: Int, bytesPerRow: Int) {
        self.pixelData = pixelData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytesPerRow = bytesPerRow
    }

    public var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }
}

public protocol DisplayPreviewCapturing: Sendable {
    func capture(
        displayID: CGDirectDisplayID,
        targetPixelSize: CGSize
    ) async -> DisplayPreviewCapture?
}

struct DeterministicDisplayPreviewCapturer: DisplayPreviewCapturing {
    func capture(
        displayID: CGDirectDisplayID,
        targetPixelSize: CGSize
    ) async -> DisplayPreviewCapture? {
        nil
    }
}

@MainActor
public final class DisplayPreviewProvider: DisplayPreviewProviding {
    private struct CacheKey: Hashable {
        let displayID: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private let capturer: any DisplayPreviewCapturing
    private let maximumPixelSize: CGSize
    private var cache: [CacheKey: DisplayPreview] = [:]
    private var latestByDisplayID: [String: DisplayPreview] = [:]
    private var generation: UInt64 = 0
    private var isClosed = false

    public init(
        capturer: any DisplayPreviewCapturing,
        maximumPixelSize: CGSize = CGSize(width: 1_600, height: 1_200)
    ) {
        self.capturer = capturer
        self.maximumPixelSize = Self.sanitizedMaximum(maximumPixelSize)
    }

    public convenience init() {
        self.init(
            capturer: DeterministicDisplayPreviewCapturer()
        )
    }

    public func preview(for display: DisplayDescriptor) -> DisplayPreview {
        latestByDisplayID[display.id] ?? Self.schematic
    }

    public func requestPreview(
        for display: DisplayDescriptor,
        targetPixelSize: CGSize
    ) async {
        guard !isClosed,
              let displayID = Self.coreGraphicsID(display.id)
        else { return }
        let target = boundedTarget(targetPixelSize)
        let key = CacheKey(
            displayID: display.id,
            pixelWidth: Int(target.width.rounded()),
            pixelHeight: Int(target.height.rounded())
        )
        if let cached = cache[key] {
            latestByDisplayID[display.id] = cached
            return
        }

        generation &+= 1
        let requestGeneration = generation
        guard let capture = await capturer.capture(displayID: displayID, targetPixelSize: target),
              !Task.isCancelled,
              !isClosed,
              requestGeneration == generation,
              let image = Self.makeImage(from: capture)
        else { return }
        let preview = DisplayPreview(
            image: image,
            semanticSnapshot: .currentDisplayImageInMemory
        )
        cache[key] = preview
        latestByDisplayID[display.id] = preview
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        generation &+= 1
        cache.removeAll()
        latestByDisplayID.removeAll()
    }

    private func boundedTarget(_ requested: CGSize) -> CGSize {
        let width = requested.width.isFinite ? max(requested.width, 1) : 1
        let height = requested.height.isFinite ? max(requested.height, 1) : 1
        let scale = min(maximumPixelSize.width / width, maximumPixelSize.height / height, 1)
        return CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    private static func coreGraphicsID(_ id: String) -> CGDirectDisplayID? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "display" else { return nil }
        return CGDirectDisplayID(parts[1])
    }

    private static func sanitizedMaximum(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? max(size.width, 1) : 1_600,
            height: size.height.isFinite ? max(size.height, 1) : 1_200
        )
    }

    private static func makeImage(from capture: DisplayPreviewCapture) -> NSImage? {
        guard capture.pixelWidth > 0,
              capture.pixelHeight > 0,
              capture.bytesPerRow >= capture.pixelWidth * 4,
              capture.pixelData.count >= capture.bytesPerRow * capture.pixelHeight,
              let provider = CGDataProvider(data: capture.pixelData as CFData),
              let image = CGImage(
                width: capture.pixelWidth,
                height: capture.pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: capture.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: capture.pixelWidth, height: capture.pixelHeight)
        )
    }

    private static let schematic = DisplayPreview(
        image: nil,
        semanticSnapshot: .schematic(style: "display-window-grid-v1")
    )
}
