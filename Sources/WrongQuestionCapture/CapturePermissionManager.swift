import AppKit
import ApplicationServices
import CoreGraphics

enum CapturePermissionManager {
    private enum Key {
        static let accessibilityRequestAttempted = "accessibilityRequestAttemptedV1"
        static let screenCaptureRequestAttempted = "screenCaptureRequestAttemptedV1"
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var screenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
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

    @discardableResult
    static func requestScreenCaptureOnceIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard !screenCaptureGranted,
              !defaults.bool(forKey: Key.screenCaptureRequestAttempted)
        else { return false }
        defaults.set(true, forKey: Key.screenCaptureRequestAttempted)
        _ = CGRequestScreenCaptureAccess()
        return true
    }

    static func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        openSystemSettings(anchor: "Privacy_Accessibility")
    }

    static func openScreenCaptureSettings() {
        openSystemSettings(anchor: "Privacy_ScreenCapture")
    }

    private static func openSystemSettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
