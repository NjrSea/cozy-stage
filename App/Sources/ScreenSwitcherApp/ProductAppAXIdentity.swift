import CryptoKit
import Foundation

enum ProductAppAXIdentity {
    private static let tokenPrefix = "bundle:"
    private static let accessibilityPrefix = "screen-switcher.workspace.switch.app."

    static func opaqueToken(forBundleIdentifier bundleIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(bundleIdentifier.utf8))
        return tokenPrefix + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func accessibilityIdentifier(forBundleIdentifier bundleIdentifier: String) -> String {
        accessibilityPrefix + opaqueToken(forBundleIdentifier: bundleIdentifier)
    }
}
