import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: PracticeAppStore
    @StateObject private var databaseChanges = DatabaseChangeObserver()
    @State private var navigationPath: [StudyCatalogDestination] = []

    var body: some View {
        Group {
            if store.session != nil {
                PracticeView(store: store)
            } else {
                NavigationStack(path: $navigationPath) {
                    StudyCatalogRootView { navigationPath.append($0) }
                        .navigationDestination(for: StudyCatalogDestination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .task {
            if store.session == nil {
                await store.refreshDashboard()
            }
        }
        .onChange(of: databaseChanges.revision) { _ in
            guard store.session == nil else { return }
            Task { await store.refreshDashboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard store.session == nil else { return }
            Task { await store.refreshDashboard() }
        }
        .alert(item: $store.presentedError) { error in
            Alert(
                title: Text("操作未完成"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    @ViewBuilder
    private func destinationView(for destination: StudyCatalogDestination) -> some View {
        switch destination {
        case .education:
            EducationSubjectSelectionView { navigationPath.append($0) }
        case .medicalComprehensive:
            HomeView(store: store, scope: .education(.medicalComprehensive))
        case .politics:
            HomeView(store: store, scope: .education(.politics))
        case .english:
            HomeView(store: store, scope: .education(.english))
        case .civilService:
            CivilServiceSelectionView { navigationPath.append($0) }
        case .xingce:
            XingceCategorySelectionView { navigationPath.append($0) }
        case .xingceCategory(let category):
            HomeView(store: store, scope: .xingce(category))
        case .civilServiceEssay:
            PendingStudyEntryView(
                title: "申论",
                detail: "申论题本和训练方式尚未接入，当前仅保留入口。",
                icon: "square.and.pencil"
            )
        case .civilServiceInterview:
            PendingStudyEntryView(
                title: "面试",
                detail: "面试题本和训练方式尚未接入，当前仅保留入口。",
                icon: "person.2.wave.2.fill"
            )
        }
    }
}
