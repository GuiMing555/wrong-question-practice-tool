import AppKit

enum SettingsOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first { item in
            item.keyEquivalent == "," && item.keyEquivalentModifierMask.contains(.command)
        }
        let didOpen = settingsItem.flatMap { item in
            item.action.map { NSApp.sendAction($0, to: item.target, from: item) }
        } ?? false
        if !didOpen {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        DispatchQueue.main.async {
            NSApp.windows.first { window in
                window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            }?.makeKeyAndOrderFront(nil)
        }
    }
}
