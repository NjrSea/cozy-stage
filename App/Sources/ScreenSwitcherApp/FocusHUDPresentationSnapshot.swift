import AppKit
import ScreenDomainCore

enum FocusHUDIconArtwork {
    static func leadingInsetFraction(for image: NSImage?) -> CGFloat {
        guard let image,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: 32,
                  pixelsHigh: 32,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return 0 }

        bitmap.size = NSSize(width: 32, height: 32)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        return leadingInsetFraction(in: bitmap)
    }

    static func leadingInsetFraction(in bitmap: NSBitmapImageRep) -> CGFloat {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return 0 }
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                return CGFloat(x) / CGFloat(bitmap.pixelsWide)
            }
        }
        return 0
    }
}

/// Immutable App-layer content used for one HUD presentation.
struct FocusHUDAppEntry: Identifiable, Equatable {
    let id: ManagedWindowID
    let screenID: FocusScreenID
    let appIdentityHash: String
    let appName: String
    let appIcon: NSImage?
    let iconLeadingInsetFraction: CGFloat
    let windowTitle: String
    let shortcut: FocusHUDShortcut?
    let isCurrent: Bool
}

struct FocusHUDWorkspaceSection: Identifiable, Equatable {
    let id: FocusScreenID
    let screenID: FocusScreenID
    let ordinal: Int
    let name: String
    let isCurrent: Bool
    let apps: [FocusHUDAppEntry]
}

struct FocusHUDPresentationSnapshot: Equatable {
    let sections: [FocusHUDWorkspaceSection]
    let layout: FocusHUDOverviewLayoutResult
    let inventoryRevision: UInt64
    let keyAssignmentRevision: UInt64
    let presentationRevision: UInt64
}

enum FocusHUDPresentationError: Error, Equatable {
    case revisionExhausted
}
