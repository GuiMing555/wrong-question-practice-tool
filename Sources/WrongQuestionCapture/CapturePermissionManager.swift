import AppKit
import ApplicationServices

enum CapturePermissionManager {
    private enum Key {
        static let accessibilityRequestAttempted = "accessibilityRequestAttemptedV1"
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityOnceIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard !accessibilityGranted,
              !defaults.bool(forKey: Key.accessibilityRequestAttempted)
        else { return false }
        defaults.set(true, forKey: Key.accessibilityRequestAttempted)
        requestAccessibility()
        return true
    }

    static func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        openSystemSettings(anchor: "Privacy_Accessibility")
    }

    private static func openSystemSettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
