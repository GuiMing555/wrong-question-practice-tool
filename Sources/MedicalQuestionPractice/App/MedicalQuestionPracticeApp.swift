import SwiftUI

@main
struct MedicalQuestionPracticeApp: App {
    @NSApplicationDelegateAdaptor(PracticeAppDelegate.self) private var appDelegate
    @StateObject private var store = PracticeAppStore()

    var body: some Scene {
        WindowGroup("考试题本练习") {
            ContentView(store: store)
        }
        .defaultSize(width: 980, height: 720)

        Settings {
            SettingsView(store: store)
        }
    }
}
