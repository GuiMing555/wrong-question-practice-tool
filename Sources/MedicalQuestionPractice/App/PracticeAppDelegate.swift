import AppKit
import QuestionBankCore

final class PracticeAppDelegate: NSObject, NSApplicationDelegate {
    private let lockIdentifier = "com.guiming.medical-question-practice"
    private let activationNotification = Notification.Name(
        "com.guiming.medical-question-practice.activate-existing-instance"
    )
    private var singleInstanceLock: SingleInstanceLock?
    private var activationObserver: NSObjectProtocol?
    private var shouldRun = true

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            guard let lock = try SingleInstanceLock.acquire(identifier: lockIdentifier) else {
                shouldRun = false
                requestExistingInstanceActivation()
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            singleInstanceLock = lock
            activationObserver = DistributedNotificationCenter.default().addObserver(
                forName: activationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showMainWindow()
            }
        } catch {
            let hasExistingInstance = NSRunningApplication
                .runningApplications(withBundleIdentifier: lockIdentifier)
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if hasExistingInstance {
                shouldRun = false
                requestExistingInstanceActivation()
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldRun else { return }
        showMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            DistributedNotificationCenter.default().removeObserver(activationObserver)
        }
    }

    private func requestExistingInstanceActivation() {
        DistributedNotificationCenter.default().postNotificationName(
            activationNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NSRunningApplication.runningApplications(withBundleIdentifier: lockIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
            .activate(options: [.activateAllWindows])
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let mainWindow = NSApp.windows.first { window in
            window.canBecomeKey && window.title != "设置"
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}
