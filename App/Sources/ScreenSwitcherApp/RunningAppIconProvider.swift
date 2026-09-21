import AppKit
import Foundation

public enum RunningAppIconAvailability: String, Codable, Equatable, Sendable {
    case available
    case fallback
    case unavailable
}

@MainActor
public protocol RunningAppIconProviding {
    func icon(for bundleIdentifier: String) -> NSImage?
    func iconAvailability(
        for bundleIdentifiers: [String]
    ) -> [String: RunningAppIconAvailability]
}

public extension RunningAppIconProviding {
    func iconAvailability(
        for bundleIdentifiers: [String]
    ) -> [String: RunningAppIconAvailability] {
        Dictionary(uniqueKeysWithValues: stableUnique(bundleIdentifiers).map { bundleIdentifier in
            (
                bundleIdentifier,
                icon(for: bundleIdentifier) == nil ? .fallback : .available
            )
        })
    }
}

@MainActor
public struct SystemRunningAppIconProvider: RunningAppIconProviding {
    private let iconLookup: @MainActor (String) -> NSImage?
    private let iconAvailabilityLookup: @MainActor ([String]) -> [String: RunningAppIconAvailability]

    public init() {
        self.iconLookup = { bundleIdentifier in
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == bundleIdentifier
            }?.icon
        }
        self.iconAvailabilityLookup = { bundleIdentifiers in
            let bundleIdentifiers = stableUnique(bundleIdentifiers)
            let requestedIdentifiers = Set(bundleIdentifiers)
            let availableIdentifiers = Set<String>(
                NSWorkspace.shared.runningApplications.compactMap { application in
                    guard let bundleIdentifier = application.bundleIdentifier,
                          requestedIdentifiers.contains(bundleIdentifier),
                          application.icon != nil else {
                        return nil
                    }
                    return bundleIdentifier
                }
            )
            return Dictionary(uniqueKeysWithValues: bundleIdentifiers.map { bundleIdentifier in
                (
                    bundleIdentifier,
                    availableIdentifiers.contains(bundleIdentifier) ? .available : .fallback
                )
            })
        }
    }

    init(iconLookup: @escaping @MainActor (String) -> NSImage?) {
        self.iconLookup = iconLookup
        self.iconAvailabilityLookup = { bundleIdentifiers in
            Dictionary(uniqueKeysWithValues: stableUnique(bundleIdentifiers).map { bundleIdentifier in
                (
                    bundleIdentifier,
                    iconLookup(bundleIdentifier) == nil ? .fallback : .available
                )
            })
        }
    }

    public func icon(for bundleIdentifier: String) -> NSImage? {
        iconLookup(bundleIdentifier)
    }

    public func iconAvailability(
        for bundleIdentifiers: [String]
    ) -> [String: RunningAppIconAvailability] {
        iconAvailabilityLookup(bundleIdentifiers)
    }
}

@MainActor
public struct RunningAppIconResolution {
    public let image: NSImage?
    public let availability: RunningAppIconAvailability

    public init(
        image: NSImage?,
        availability: RunningAppIconAvailability
    ) {
        self.image = image
        self.availability = availability
    }
}

/// Resolves icons once per panel session so a changing NSWorkspace list cannot
/// reorder or visually swap an item while the ring is open.
@MainActor
public final class RunningAppIconSession {
    private let provider: RunningAppIconProviding
    private let fallbackIcon: NSImage?
    private var resolutions: [String: RunningAppIconResolution] = [:]

    public init(
        provider: RunningAppIconProviding? = nil,
        fallbackIcon: NSImage? = nil
    ) {
        self.provider = provider ?? SystemRunningAppIconProvider()
        self.fallbackIcon = fallbackIcon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "App")
    }

    public func resolve(bundleIdentifier: String) -> RunningAppIconResolution {
        if let cached = resolutions[bundleIdentifier] {
            return cached
        }

        let resolution: RunningAppIconResolution
        if let image = provider.icon(for: bundleIdentifier) {
            resolution = RunningAppIconResolution(
                image: image,
                availability: .available
            )
        } else {
            resolution = fallbackResolution
        }

        resolutions[bundleIdentifier] = resolution
        return resolution
    }

    public func preload(bundleIdentifiers: [String]) {
        for bundleIdentifier in stableUnique(bundleIdentifiers) {
            _ = resolve(bundleIdentifier: bundleIdentifier)
        }
    }

    /// A presentation-only read. Session owners preload before installing a
    /// SwiftUI root view, so body evaluation never reaches NSWorkspace.
    public func presentation(bundleIdentifier: String) -> RunningAppIconResolution {
        resolutions[bundleIdentifier] ?? fallbackResolution
    }

    public func icon(for bundleIdentifier: String) -> NSImage? {
        resolve(bundleIdentifier: bundleIdentifier).image
    }

    private var fallbackResolution: RunningAppIconResolution {
        if let fallbackIcon {
            return RunningAppIconResolution(image: fallbackIcon, availability: .fallback)
        }
        return RunningAppIconResolution(image: nil, availability: .unavailable)
    }
}
