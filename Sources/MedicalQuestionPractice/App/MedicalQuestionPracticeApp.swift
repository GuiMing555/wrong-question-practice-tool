import SwiftUI

@main
struct MedicalQuestionPracticeApp: App {
    @NSApplicationDelegateAdaptor(PracticeAppDelegate.self) private var appDelegate
    @StateObject private var store = PracticeAppStore()

    var body: some Scene {
        WindowGroup("错题刷题工具") {
            ContentView(store: store)
        }
        .defaultSize(width: 980, height: 720)

        Settings {
            SettingsView(store: store)
        }
    }
}
