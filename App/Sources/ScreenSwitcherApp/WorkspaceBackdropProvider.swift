import AppKit
import CoreImage

public enum WorkspaceBackdrop {
    case image(NSImage)
    case semanticGradient
}

@MainActor
public protocol WorkspaceAccessibilityPreferencesProviding {
    var reduceTransparencyEnabled: Bool { get }
}

@MainActor
public struct SystemWorkspaceAccessibilityPreferences: WorkspaceAccessibilityPreferencesProviding {
    public init() {}

    public var reduceTransparencyEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

@MainActor
public protocol WorkspaceBackdropProviding {
    func resolveBackdrop(
        for displayID: String,
        screen: NSScreen?,
        completion: @escaping @MainActor (WorkspaceBackdrop) -> Void
    ) -> WorkspaceBackdrop
}

@MainActor
public final class WorkspaceBackdropProvider: WorkspaceBackdropProviding {
    public typealias WallpaperURL = @MainActor (NSScreen?) -> URL?
    public typealias ImageLoader = @Sendable (URL) -> NSImage?
    public typealias ImageProcessor = @Sendable (NSImage) -> NSImage?

    private struct CacheKey: Hashable {
        let displayID: String
        let wallpaperIdentity: URL
    }

    private struct InFlightResolution {
        let task: Task<NSImage?, Never>
        var completions: [@MainActor (WorkspaceBackdrop) -> Void]
    }

    private let accessibilityPreferences: any WorkspaceAccessibilityPreferencesProviding
    private let wallpaperURL: WallpaperURL
    private let imageLoader: ImageLoader
    private let imageProcessor: ImageProcessor
    private var currentKeyByDisplayID: [String: CacheKey] = [:]
    private var cache: [CacheKey: WorkspaceBackdrop] = [:]
    private var inFlight: [CacheKey: InFlightResolution] = [:]

    public convenience init() {
        self.init(
            accessibilityPreferences: SystemWorkspaceAccessibilityPreferences(),
            wallpaperURL: { screen in
                guard let screen else { return nil }
                return NSWorkspace.shared.desktopImageURL(for: screen)
            },
            imageLoader: { NSImage(contentsOf: $0) },
            imageProcessor: { WorkspaceBackdropProvider.process($0) }
        )
    }

    public convenience init(
        wallpaperURL: @escaping WallpaperURL,
        imageLoader: @escaping ImageLoader
    ) {
        self.init(
            accessibilityPreferences: SystemWorkspaceAccessibilityPreferences(),
            wallpaperURL: wallpaperURL,
            imageLoader: imageLoader,
            imageProcessor: { WorkspaceBackdropProvider.process($0) }
        )
    }

    public init(
        accessibilityPreferences: any WorkspaceAccessibilityPreferencesProviding,
        wallpaperURL: @escaping WallpaperURL,
        imageLoader: @escaping ImageLoader,
        imageProcessor: @escaping ImageProcessor
    ) {
        self.accessibilityPreferences = accessibilityPreferences
        self.wallpaperURL = wallpaperURL
        self.imageLoader = imageLoader
        self.imageProcessor = imageProcessor
    }

    public func resolveBackdrop(
        for displayID: String,
        screen: NSScreen?,
        completion: @escaping @MainActor (WorkspaceBackdrop) -> Void
    ) -> WorkspaceBackdrop {
        guard !accessibilityPreferences.reduceTransparencyEnabled else {
            invalidate(displayID: displayID)
            return .semanticGradient
        }
        guard let source = wallpaperURL(screen) else {
            invalidate(displayID: displayID)
            return .semanticGradient
        }

        let key = CacheKey(displayID: displayID, wallpaperIdentity: source.standardizedFileURL)
        replaceIdentityIfNeeded(with: key)
        if let cached = cache[key] {
            return cached
        }
        if inFlight[key] != nil {
            inFlight[key]?.completions.append(completion)
            return .semanticGradient
        }

        let imageLoader = self.imageLoader
        let imageProcessor = self.imageProcessor
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard !Task.isCancelled,
                  let image = imageLoader(source),
                  !Task.isCancelled
            else { return nil }
            return imageProcessor(image)
        }
        inFlight[key] = InFlightResolution(task: task, completions: [completion])
        Task { @MainActor [weak self] in
            let image = await task.value
            self?.complete(key: key, image: image)
        }
        return .semanticGradient
    }

    private func replaceIdentityIfNeeded(with key: CacheKey) {
        guard let previous = currentKeyByDisplayID[key.displayID], previous != key else {
            currentKeyByDisplayID[key.displayID] = key
            return
        }
        cache.removeValue(forKey: previous)
        inFlight.removeValue(forKey: previous)?.task.cancel()
        currentKeyByDisplayID[key.displayID] = key
    }

    private func invalidate(displayID: String) {
        guard let key = currentKeyByDisplayID.removeValue(forKey: displayID) else { return }
        cache.removeValue(forKey: key)
        inFlight.removeValue(forKey: key)?.task.cancel()
    }

    private func complete(key: CacheKey, image: NSImage?) {
        guard let resolution = inFlight.removeValue(forKey: key),
              currentKeyByDisplayID[key.displayID] == key
        else { return }
        let backdrop = image.map(WorkspaceBackdrop.image) ?? .semanticGradient
        cache[key] = backdrop
        resolution.completions.forEach { $0(backdrop) }
    }

    private nonisolated static func process(_ image: NSImage) -> NSImage? {
        guard let data = image.tiffRepresentation,
              let input = CIImage(data: data)
        else { return nil }

        let desaturated = input.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0.38,
                kCIInputBrightnessKey: -0.08,
                kCIInputContrastKey: 0.92
            ]
        )
        let blurred = desaturated
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28.0])
            .cropped(to: input.extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let output = context.createCGImage(blurred, from: input.extent) else { return nil }
        return NSImage(cgImage: output, size: image.size)
    }
}
