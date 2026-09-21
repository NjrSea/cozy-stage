import AppKit

@MainActor
public final class ScreenSwitcherApp {
    public let delegate: AppDelegate

    public init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    public convenience init() {
        self.init(delegate: AppDelegate())
    }

    public func start() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }

    public static func main() {
        ScreenSwitcherApp().start()
    }
}
