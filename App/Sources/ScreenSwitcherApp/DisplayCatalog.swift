import AppKit
import CoreGraphics

public protocol DisplayHardwareKindProviding {
    func hardwareKind(forDisplayID id: String) -> DisplayHardwareKind
}

public struct CGDisplayHardwareKindProvider: DisplayHardwareKindProviding {
    private let isBuiltin: @Sendable (CGDirectDisplayID) -> Bool

    public init() {
        isBuiltin = { CGDisplayIsBuiltin($0) != 0 }
    }

    init(isBuiltin: @escaping @Sendable (CGDirectDisplayID) -> Bool) {
        self.isBuiltin = isBuiltin
    }

    public func hardwareKind(forDisplayID id: String) -> DisplayHardwareKind {
        let components = id.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "display",
              let displayID = CGDirectDisplayID(components[1]) else {
            return .unknown
        }
        return isBuiltin(displayID) ? .builtIn : .external
    }
}

@MainActor
public protocol DisplayDiscovering {
    func discoverDisplays() -> [DisplaySource]
}

@MainActor
public struct DisplayCatalog {
    private let discovery: DisplayDiscovering
    private let pointerLocation: PointerLocationProviding

    public init(
        discovery: DisplayDiscovering? = nil,
        pointerLocation: PointerLocationProviding? = nil
    ) {
        self.discovery = discovery ?? NSScreenDisplayDiscovery()
        self.pointerLocation = pointerLocation ?? NSEventPointerLocationProvider()
    }

    public func snapshot() -> [DisplayDescriptor] {
        snapshot(at: pointerLocation.currentPointerLocation())
    }

    public func snapshot(at pointer: PointSnapshot?) -> [DisplayDescriptor] {
        discovery.discoverDisplays()
            .filter { $0.frame.isValid }
            .sorted(by: Self.isOrderedBefore)
            .map { display in
                DisplayDescriptor(
                    id: display.id,
                    frame: display.frame,
                    isCurrent: pointer.map(display.frame.contains) ?? false,
                    hardwareKind: display.hardwareKind
                )
            }
    }

    private static func isOrderedBefore(_ lhs: DisplaySource, _ rhs: DisplaySource) -> Bool {
        let lhsMinX = lhs.frame.x
        let rhsMinX = rhs.frame.x
        let lhsIsFinite = lhsMinX.isFinite
        let rhsIsFinite = rhsMinX.isFinite

        if lhsIsFinite != rhsIsFinite {
            return lhsIsFinite
        }
        if lhsIsFinite, lhsMinX != rhsMinX {
            return lhsMinX < rhsMinX
        }
        return lhs.id < rhs.id
    }
}

@MainActor
public struct NSScreenDisplayDiscovery: DisplayDiscovering {
    private let hardwareKindProvider: any DisplayHardwareKindProviding

    public init(
        hardwareKindProvider: any DisplayHardwareKindProviding = CGDisplayHardwareKindProvider()
    ) {
        self.hardwareKindProvider = hardwareKindProvider
    }

    public func discoverDisplays() -> [DisplaySource] {
        NSScreen.screens.compactMap { screen in
            let frame = screen.frame
            guard let descriptor = try? RectDescriptor(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            ) else {
                return nil
            }
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = screenNumber.map { "display-\($0.uint32Value)" }
                ?? "display-\(descriptor.x)-\(descriptor.y)-\(descriptor.width)-\(descriptor.height)"
            return DisplaySource(
                id: id,
                frame: descriptor,
                hardwareKind: hardwareKindProvider.hardwareKind(forDisplayID: id)
            )
        }
    }
}
