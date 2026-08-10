import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import QuestionBankCore

private let hotKeySignature: OSType = 0x57514350 // "WQCP"
private let setTargetHotKeyID: UInt32 = 1
private let captureHotKeyID: UInt32 = 2
private let captureBundleIdentifier = "com.guiming.wrong-question-daily-organizer"
private let captureActivationNotification = Notification.Name(
    "com.guiming.wrong-question-daily-organizer.activate-existing-instance"
)

private struct TargetWindow {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect

    var displayName: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? ownerName : "\(ownerName) — \(trimmedTitle)"
    }
}

private let globalHotKeyHandler: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.handleHotKey(hotKeyID.id)
    }
    return noErr
}

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var targetDescriptionItem: NSMenuItem!
    private var lastCaptureItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var targetWindow: TargetWindow?
    private var setTargetHotKey: EventHotKeyRef?
    private var captureHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var globalEventMonitor: Any?
    private var rightShiftIsDown = false
    private var rightShiftWasUsedAsModifier = false
    private var organizerIsRunning = false
    private var organizerStatusItem: NSMenuItem!
    private var settings = AppSettings.load()
    private var settingsWindowController: SettingsWindowController?
    private var apiSettingsWindowController: APISettingsWindowController?
    private var progressWindowController: OrganizeProgressWindowController?
    private var fullPageRenderer: BrowserFullPageRenderer?
    private var captureIsRunning = false
    private var singleInstanceLock: SingleInstanceLock?
    private var activationObserver: NSObjectProtocol?
    private var shouldRun = true

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            guard let lock = try SingleInstanceLock.acquire(identifier: captureBundleIdentifier) else {
                shouldRun = false
                requestExistingInstanceActivation()
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            singleInstanceLock = lock
            activationObserver = DistributedNotificationCenter.default().addObserver(
                forName: captureActivationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showSettings()
            }
        } catch {
            let hasExistingInstance = NSRunningApplication
                .runningApplications(withBundleIdentifier: captureBundleIdentifier)
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
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()
        registerGlobalHotKeys()
        installRightShiftMonitor()
        refreshAccessibilityPermission(requestOnceIfNeeded: true)
        _ = try? CaptureDiagnosticLogger.ensureLogFile()
        CaptureDiagnosticLogger.record(.info, event: "application_started")
        try? synchronizeWorkbookOutputPaths(exportImmediately: true)
        _ = try? synchronizeLocalSchedule(showErrors: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let setTargetHotKey { UnregisterEventHotKey(setTargetHotKey) }
        if let captureHotKey { UnregisterEventHotKey(captureHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        if let activationObserver {
            DistributedNotificationCenter.default().removeObserver(activationObserver)
        }
    }

    private func requestExistingInstanceActivation() {
        DistributedNotificationCenter.default().postNotificationName(
            captureActivationNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NSRunningApplication.runningApplications(withBundleIdentifier: captureBundleIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
            .activate(options: [.activateAllWindows])
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "题"
        statusItem.button?.toolTip = "错题每日自动化整理"

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "错题每日自动化整理", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let settingsItem = NSMenuItem(
            title: "打开设置…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        let apiSettingsItem = NSMenuItem(
            title: "API 设置…",
            action: #selector(showAPISettings),
            keyEquivalent: ""
        )
        apiSettingsItem.target = self
        menu.addItem(apiSettingsItem)
        let permissionsItem = NSMenuItem(
            title: "检查系统权限…",
            action: #selector(showSystemPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        menu.addItem(.separator())

        targetDescriptionItem = NSMenuItem(title: "目标：未设置", action: nil, keyEquivalent: "")
        targetDescriptionItem.isEnabled = false
        menu.addItem(targetDescriptionItem)

        let setTargetItem = NSMenuItem(
            title: "设定当前前台窗口为目标    ⌃⌥⇧1",
            action: #selector(setCurrentFrontmostWindow),
            keyEquivalent: ""
        )
        setTargetItem.target = self
        menu.addItem(setTargetItem)

        captureItem = NSMenuItem(
            title: "保存目标页面内容             \(settings.captureShortcut.menuTitle)",
            action: #selector(captureTargetWindow),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())

        lastCaptureItem = NSMenuItem(title: "最近采集：暂无", action: nil, keyEquivalent: "")
        lastCaptureItem.isEnabled = false
        menu.addItem(lastCaptureItem)

        let openFolderItem = NSMenuItem(
            title: "打开截图文件夹",
            action: #selector(openCaptureFolder),
            keyEquivalent: ""
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)
        let openCaptureLogItem = NSMenuItem(
            title: "打开采集日志",
            action: #selector(openCaptureLog),
            keyEquivalent: ""
        )
        openCaptureLogItem.target = self
        menu.addItem(openCaptureLogItem)
        let organizeItem = NSMenuItem(
            title: "立即整理题本",
            action: #selector(organizeNow),
            keyEquivalent: ""
        )
        organizeItem.target = self
        menu.addItem(organizeItem)

        let openBooksItem = NSMenuItem(
            title: "打开题本文件夹",
            action: #selector(openBooksFolder),
            keyEquivalent: ""
        )
        openBooksItem.target = self
        menu.addItem(openBooksItem)

        organizerStatusItem = NSMenuItem(title: scheduleStatusTitle, action: nil, keyEquivalent: "")
        organizerStatusItem.isEnabled = false
        menu.addItem(organizerStatusItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func registerGlobalHotKeys() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        let setStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_1),
            modifiers,
            EventHotKeyID(signature: hotKeySignature, id: setTargetHotKeyID),
            GetApplicationEventTarget(),
            0,
            &setTargetHotKey
        )
        if installStatus != noErr || setStatus != noErr {
            showAlert(
                title: "快捷键注册失败",
                message: "全局快捷键可能与其他应用冲突。请退出占用快捷键的应用后重新启动。"
            )
        }
        registerCaptureHotKey()
    }

    private func registerCaptureHotKey() {
        if let captureHotKey {
            UnregisterEventHotKey(captureHotKey)
            self.captureHotKey = nil
        }
        guard settings.captureShortcut != .rightShift else { return }

        let keyCode: UInt32
        let modifiers: UInt32
        switch settings.captureShortcut {
        case .rightShift:
            return
        case .controlOptionShift2:
            keyCode = UInt32(kVK_ANSI_2)
            modifiers = UInt32(controlKey | optionKey | shiftKey)
        case .controlOptionShiftS:
            keyCode = UInt32(kVK_ANSI_S)
            modifiers = UInt32(controlKey | optionKey | shiftKey)
        case .optionShiftS:
            keyCode = UInt32(kVK_ANSI_S)
            modifiers = UInt32(optionKey | shiftKey)
        }
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: hotKeySignature, id: captureHotKeyID),
            GetApplicationEventTarget(),
            0,
            &captureHotKey
        )
        if status != noErr {
            showAlert(title: "截图快捷键注册失败", message: "该组合键可能已被其他应用占用，请在设置中换一个快捷键。")
        }
    }

    func handleHotKey(_ id: UInt32) {
        switch id {
        case setTargetHotKeyID:
            setCurrentFrontmostWindow()
        case captureHotKeyID:
            captureTargetWindow()
        default:
            break
        }
    }

    private func installRightShiftMonitor() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .flagsChanged,
                .keyDown,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .scrollWheel
            ]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleGlobalEvent(event)
            }
        }
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        guard settings.captureShortcut == .rightShift else { return }
        if event.type == .flagsChanged, event.keyCode == UInt16(kVK_RightShift) {
            if rightShiftIsDown {
                let shouldCapture = !rightShiftWasUsedAsModifier
                rightShiftIsDown = false
                rightShiftWasUsedAsModifier = false
                if shouldCapture {
                    captureTargetWindow()
                }
            } else {
                rightShiftIsDown = true
                rightShiftWasUsedAsModifier = false
            }
            return
        }

        if rightShiftIsDown {
            rightShiftWasUsedAsModifier = true
        }
    }

    private func refreshAccessibilityPermission(requestOnceIfNeeded: Bool) {
        guard settings.captureShortcut == .rightShift else { return }
        if requestOnceIfNeeded {
            _ = CapturePermissionManager.requestAccessibilityOnceIfNeeded()
        }
        if !CapturePermissionManager.accessibilityGranted {
            lastCaptureItem.title = "轻点右⇧需要辅助功能权限，授权后请重启"
            statusItem.button?.title = "!"
        }
    }

    @objc private func setCurrentFrontmostWindow() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            showAlert(title: "无法识别窗口", message: "没有检测到前台应用。")
            return
        }

        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            showAlert(
                title: "请选择目标窗口",
                message: "先点一下需要截图的题库窗口，再按 Control + Option + Shift + 1。"
            )
            return
        }

        guard let window = largestOnScreenWindow(for: application.processIdentifier) else {
            showAlert(
                title: "未找到可截图窗口",
                message: "请确保目标窗口未最小化，并位于当前桌面。"
            )
            return
        }

        targetWindow = window
        targetDescriptionItem.title = "快照目标：\(shortened(window.displayName, limit: 40))"
        statusItem.button?.title = "✓"
        NSSound(named: "Tink")?.play()
    }

    @objc private func captureTargetWindow() {
        guard !captureIsRunning else {
            CaptureDiagnosticLogger.record(.warning, event: "capture_ignored_already_running")
            return
        }
        guard let targetWindow else {
            CaptureDiagnosticLogger.record(.warning, event: "capture_failed_no_target")
            showAlert(
                title: "尚未指定窗口",
                message: "先让题库窗口位于最前面，然后按 Control + Option + Shift + 1；以后使用“\(settings.captureShortcut.title)”截图。"
            )
            return
        }

        guard windowStillExists(targetWindow.id) else {
            CaptureDiagnosticLogger.record(.warning, event: "capture_failed_target_closed")
            self.targetWindow = nil
            targetDescriptionItem.title = "目标：窗口已关闭，请重新设置"
            statusItem.button?.title = "!"
            showAlert(title: "目标窗口已关闭", message: "请重新设定当前前台窗口。")
            return
        }

        captureIsRunning = true
        statusItem.button?.title = "…"
        let reader = BrowserWindowSnapshotReader()
        let readResult = reader.readPageTextCandidates(
            ownerPID: targetWindow.ownerPID,
            windowTitle: targetWindow.title,
            bounds: targetWindow.bounds
        )
        let organizer = WrongQuestionOrganizer()
        let evaluated = readResult.candidates.map { candidate in
            (candidate, organizer.pageSnapshotValidation(candidate.text))
        }
        for item in evaluated {
            CaptureDiagnosticLogger.record(
                item.1.isUsable ? .info : .warning,
                event: "page_text_candidate_evaluated",
                fields: [
                    "source": item.0.source.rawValue,
                    "characters": String(item.0.text.count),
                    "usable": String(item.1.isUsable),
                    "question_characters": String(item.1.questionCharacterCount),
                    "options": String(item.1.optionCount),
                    "explanation_characters": String(item.1.explanationCharacterCount),
                    "reasons": item.1.reasons.joined(separator: "；")
                ]
            )
        }
        for diagnostic in readResult.diagnostics {
            CaptureDiagnosticLogger.record(
                .warning,
                event: "page_text_reader_diagnostic",
                fields: ["reason": diagnostic]
            )
        }

        if let accepted = evaluated.first(where: { $0.1.isUsable }) {
            do {
                let outputURL = try save(pageText: accepted.0.text, target: targetWindow)
                lastCaptureItem.title = "最近页面数据：\(outputURL.lastPathComponent)"
                statusItem.button?.title = "✓"
                captureIsRunning = false
                CaptureDiagnosticLogger.record(
                    .info,
                    event: "page_text_saved",
                    fields: [
                        "source": accepted.0.source.rawValue,
                        "characters": String(accepted.0.text.count),
                        "file": outputURL.lastPathComponent
                    ]
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(outputURL.path, forType: .string)
                NSSound(named: "Pop")?.play()
            } catch {
                captureIsRunning = false
                statusItem.button?.title = "!"
                CaptureDiagnosticLogger.record(
                    .error,
                    event: "page_text_save_failed",
                    fields: ["reason": error.localizedDescription]
                )
                showAlert(title: "保存失败", message: error.localizedDescription)
            }
            return
        }

        CaptureDiagnosticLogger.record(
            .warning,
            event: "page_text_all_candidates_rejected",
            fields: [
                "candidate_count": String(evaluated.count),
                "reader_diagnostics": readResult.diagnostics.joined(separator: "；")
            ]
        )
        do {
            let archive = try reader.readPageArchive(windowTitle: targetWindow.title)
            let renderer = BrowserFullPageRenderer()
            fullPageRenderer = renderer
            lastCaptureItem.title = "页面文字不完整，正在离屏生成整页长图…"
            renderer.render(
                archive: archive,
                viewportWidth: targetWindow.bounds.width
            ) { [weak self] result in
                self?.finishFullPageCapture(result, targetWindow: targetWindow)
            }
            CaptureDiagnosticLogger.record(
                .info,
                event: "full_page_render_started",
                fields: ["html_characters": String(archive.html.count)]
            )
        } catch {
            captureIsRunning = false
            statusItem.button?.title = "!"
            lastCaptureItem.title = "页面文字和整页长图均保存失败"
            CaptureDiagnosticLogger.record(
                .error,
                event: "full_page_archive_failed",
                fields: ["reason": error.localizedDescription]
            )
            showAlert(
                title: "采集失败",
                message: "页面文字不完整，整页长图也无法生成。程序没有保存残缺的可见区域截图。\n\n原因：\(error.localizedDescription)\n\n日志：\(CaptureDiagnosticLogger.logURL.path)"
            )
        }
    }

    private func finishFullPageCapture(
        _ result: Result<CGImage, Error>,
        targetWindow: TargetWindow
    ) {
        captureIsRunning = false
        fullPageRenderer = nil
        switch result {
        case .success(let image):
            do {
                let outputURL = try save(image: image, target: targetWindow)
                lastCaptureItem.title = "页面文字不完整，已保存整页长图"
                statusItem.button?.title = "!"
                CaptureDiagnosticLogger.record(
                    .warning,
                    event: "full_page_image_saved",
                    fields: [
                        "width": String(image.width),
                        "height": String(image.height),
                        "file": outputURL.lastPathComponent
                    ]
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(outputURL.path, forType: .string)
                NSSound(named: "Pop")?.play()
            } catch {
                statusItem.button?.title = "!"
                CaptureDiagnosticLogger.record(
                    .error,
                    event: "full_page_image_save_failed",
                    fields: ["reason": error.localizedDescription]
                )
                showAlert(title: "长图保存失败", message: error.localizedDescription)
            }
        case .failure(let error):
            lastCaptureItem.title = "页面文字和整页长图均保存失败"
            statusItem.button?.title = "!"
            CaptureDiagnosticLogger.record(
                .error,
                event: "full_page_render_failed",
                fields: ["reason": error.localizedDescription]
            )
            showAlert(
                title: "整页长图生成失败",
                message: "程序没有保存残缺的可见区域截图。\n\n原因：\(error.localizedDescription)\n\n日志：\(CaptureDiagnosticLogger.logURL.path)"
            )
        }
    }

    private func largestOnScreenWindow(for pid: pid_t) -> TargetWindow? {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let candidates: [(TargetWindow, CGFloat)] = rawList.compactMap { info in
            guard
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                ownerPID == pid,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.width >= 240,
                bounds.height >= 160
            else {
                return nil
            }

            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? "未知应用"
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let target = TargetWindow(
                id: CGWindowID(windowNumber),
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title,
                bounds: bounds
            )
            return (target, bounds.width * bounds.height)
        }

        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    private func windowStillExists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
        }
    }

    private func save(image: CGImage, target: TargetWindow) throws -> URL {
        let folder = try datedCaptureFolder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"

        let windowLabel = sanitizeFileName(target.title.isEmpty ? target.ownerName : target.title)
        let fileName = "错题_\(formatter.string(from: Date()))_\(windowLabel).png"
        let outputURL = folder.appendingPathComponent(fileName)

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "WrongQuestionCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 图像。"]
            )
        }
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func save(pageText: String, target: TargetWindow) throws -> URL {
        let folder = try datedCaptureFolder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"

        let windowLabel = sanitizeFileName(target.title.isEmpty ? target.ownerName : target.title)
        let fileName = "错题_\(formatter.string(from: Date()))_\(windowLabel)\(PageSnapshotSidecar.standaloneSuffix)"
        let outputURL = folder.appendingPathComponent(fileName)
        try PageSnapshotSidecar.writeStandalone(pageText, to: outputURL)
        return outputURL
    }

    private func captureRootFolder() throws -> URL {
        let root = settings.captureFolderURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func datedCaptureFolder() throws -> URL {
        let root = try captureRootFolder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func sanitizeFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened(cleaned.isEmpty ? "窗口" : cleaned, limit: 50)
    }

    private func shortened(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    @objc private func openCaptureFolder() {
        do {
            NSWorkspace.shared.open(try captureRootFolder())
        } catch {
            showAlert(title: "无法打开文件夹", message: error.localizedDescription)
        }
    }

    @objc private func openCaptureLog() {
        do {
            let logURL = try CaptureDiagnosticLogger.ensureLogFile()
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } catch {
            showAlert(title: "无法打开采集日志", message: error.localizedDescription)
        }
    }

    @objc private func openBooksFolder() {
        do {
            NSWorkspace.shared.open(try WrongQuestionOrganizer.outputFolder(settings: settings))
        } catch {
            showAlert(title: "无法打开题本文件夹", message: error.localizedDescription)
        }
    }

    @objc private func organizeNow() {
        guard !organizerIsRunning else { return }
        organizerIsRunning = true
        organizerStatusItem.title = "正在识别并整理……"
        statusItem.button?.title = "…"
        let progressController = progressWindowController ?? OrganizeProgressWindowController()
        progressWindowController = progressController
        progressController.begin()
        NSApp.activate(ignoringOtherApps: true)
        progressController.showWindow(nil)
        progressController.window?.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try WrongQuestionOrganizer().run(
                    settings: self?.settings ?? .load(),
                    progress: { update in
                        DispatchQueue.main.async { [weak self] in
                            self?.progressWindowController?.update(update)
                        }
                    }
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.organizerIsRunning = false
                    self.organizerStatusItem.title = self.scheduleStatusTitle
                    self.statusItem.button?.title = "✓"
                    self.settingsWindowController?.showStatus(report.summary)
                    self.progressWindowController?.complete(report)
                    NSSound(named: "Glass")?.play()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.organizerIsRunning = false
                    self.organizerStatusItem.title = "整理失败：请查看提示"
                    self.statusItem.button?.title = "!"
                    self.settingsWindowController?.showStatus(error.localizedDescription, isError: true)
                    self.progressWindowController?.fail(error)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private var scheduleStatusTitle: String {
        settings.dailyOrganizeEnabled
            ? "本机每日 15:00 自动整理：已启用"
            : "本机每日 15:00 自动整理：已关闭"
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onSave = { [weak self] proposed in
                self?.saveSettings(proposed) ?? .failure(
                    NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "应用已退出。"])
                )
            }
            controller.onOrganize = { [weak self] in self?.organizeNow() }
            controller.onOpenAPISettings = { [weak self] in self?.showAPISettings() }
            controller.onOpenSystemPermissions = { [weak self] in self?.showSystemPermissions() }
            settingsWindowController = controller
        } else {
            settingsWindowController?.apply(settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAPISettings() {
        if apiSettingsWindowController == nil {
            let controller = APISettingsWindowController(settings: settings)
            controller.onSave = { [weak self] proposed in
                self?.saveSettings(proposed) ?? .failure(
                    NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "应用已退出。"])
                )
            }
            apiSettingsWindowController = controller
        } else {
            apiSettingsWindowController?.apply(settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        apiSettingsWindowController?.showWindow(nil)
        apiSettingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func saveSettings(_ proposed: AppSettings) -> Result<String, Error> {
        do {
            let normalized = proposed.normalized()
            let previousShortcut = settings.captureShortcut
            try normalized.save()
            settings = normalized
            captureItem.title = "保存目标页面内容             \(normalized.captureShortcut.menuTitle)"
            organizerStatusItem.title = scheduleStatusTitle
            rightShiftIsDown = false
            rightShiftWasUsedAsModifier = false
            registerCaptureHotKey()
            refreshAccessibilityPermission(
                requestOnceIfNeeded: previousShortcut != .rightShift && normalized.captureShortcut == .rightShift
            )
            try synchronizeLocalSchedule(showErrors: true)
            try synchronizeWorkbookOutputPaths(exportImmediately: true)
            settingsWindowController?.apply(normalized)
            apiSettingsWindowController?.apply(normalized)
            return .success("设置已保存到本机。")
        } catch {
            return .failure(error)
        }
    }

    @objc private func showSystemPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let needsAccessibility = settings.captureShortcut == .rightShift
        let accessibilityGranted = CapturePermissionManager.accessibilityGranted

        let alert = NSAlert()
        alert.messageText = "系统权限"
        alert.informativeText = [
            "辅助功能（右 Shift 快捷键）：\(needsAccessibility ? (accessibilityGranted ? "已开启" : "未开启") : "当前快捷键不需要")",
            "整页长图：由应用内部隐藏页面生成，不需要屏幕录制权限",
            "程序不会再在每次保存设置时重复申请权限。"
        ].joined(separator: "\n")
        alert.alertStyle = .informational

        var actions: [() -> Void] = []
        if needsAccessibility && !accessibilityGranted {
            alert.addButton(withTitle: "打开辅助功能设置")
            actions.append {
                CapturePermissionManager.requestAccessibility()
                CapturePermissionManager.openAccessibilitySettings()
            }
        }
        alert.addButton(withTitle: "关闭")

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0, index < actions.count {
            actions[index]()
        }
        refreshAccessibilityPermission(requestOnceIfNeeded: false)
    }

    private func synchronizeWorkbookOutputPaths(exportImmediately: Bool = false) throws {
        for subject in StudySubject.allCases {
            let store = try QuestionBankStore(
                databaseURL: QuestionBankPaths.defaultDatabaseURL(for: subject),
                sourceApplication: "capture-settings:\(subject.rawValue)"
            )
            let workbook = settings.outputFolderURL.appendingPathComponent(subject.workbookFilename)
            try store.configureWorkbookOutput(workbook)
            if exportImmediately { _ = try store.exportWorkbook(to: workbook) }
        }
    }

    @discardableResult
    private func synchronizeLocalSchedule(showErrors: Bool) throws -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        do {
            try LocalScheduler.sync(enabled: settings.dailyOrganizeEnabled, executableURL: executable)
            return true
        } catch {
            if showErrors { throw error }
            return false
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private func diagnosticLargestWindow(for pid: pid_t) -> TargetWindow? {
    guard let rawList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    return rawList.compactMap { info -> (TargetWindow, CGFloat)? in
        guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              ownerPID == pid,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.width >= 240,
              bounds.height >= 160
        else { return nil }
        let target = TargetWindow(
            id: CGWindowID(windowNumber),
            ownerPID: ownerPID,
            ownerName: (info[kCGWindowOwnerName as String] as? String) ?? "未知应用",
            title: (info[kCGWindowName as String] as? String) ?? "",
            bounds: bounds
        )
        return (target, bounds.width * bounds.height)
    }.max(by: { $0.1 < $1.1 })?.0
}

if let argument = CommandLine.arguments.first(where: {
    $0.hasPrefix("--inspect-window-snapshot-pid=") || $0.hasPrefix("--inspect-window-parsed-pid=")
}) {
    let parseSnapshot = argument.hasPrefix("--inspect-window-parsed-pid=")
    let rawPID = argument
        .replacingOccurrences(of: "--inspect-window-snapshot-pid=", with: "")
        .replacingOccurrences(of: "--inspect-window-parsed-pid=", with: "")
    guard let pid = pid_t(rawPID), let target = diagnosticLargestWindow(for: pid) else {
        FileHandle.standardError.write(Data("没有找到指定进程的可见窗口。\n".utf8))
        exit(EXIT_FAILURE)
    }
    guard let snapshot = BrowserWindowSnapshotReader().readPageText(
        ownerPID: target.ownerPID,
        windowTitle: target.title,
        bounds: target.bounds
    ) else {
        FileHandle.standardError.write(Data("没有读取到浏览器页面文字快照。\n".utf8))
        exit(EXIT_FAILURE)
    }
    print(parseSnapshot ? WrongQuestionOrganizer().diagnosticParsedSnapshot(snapshot) : snapshot)
    exit(EXIT_SUCCESS)
} else if CommandLine.arguments.contains("--self-test-capture-log") {
    CaptureDiagnosticLogger.record(
        .info,
        event: "capture_log_self_test",
        fields: ["contains_page_text": "false", "contains_secret": "false"]
    )
    CaptureDiagnosticLogger.flush()
    print(CaptureDiagnosticLogger.logURL.path)
    exit(EXIT_SUCCESS)
} else if let argument = CommandLine.arguments.first(where: {
    $0.hasPrefix("--self-test-full-page-render=")
}) {
    let outputPath = argument.replacingOccurrences(of: "--self-test-full-page-render=", with: "")
    guard !outputPath.isEmpty else {
        FileHandle.standardError.write(Data("必须提供长图自测输出路径。\n".utf8))
        exit(EXIT_FAILURE)
    }
    _ = NSApplication.shared
    let archive = BrowserPageArchive(
        pageURL: URL(string: "https://example.invalid/")!,
        html: """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        html, body { margin: 0; font-family: -apple-system; }
        section { height: 1100px; padding: 40px; box-sizing: border-box; font-size: 32px; }
        .first { background: #fff4f4; } .middle { background: #f4fff4; } .last { background: #f4f4ff; }
        </style></head><body>
        <section class="first">整页长图自测：顶部</section>
        <section class="middle">整页长图自测：中部</section>
        <section class="last">整页长图自测：底部</section>
        </body></html>
        """
    )
    let renderer = BrowserFullPageRenderer()
    var finished = false
    var exitCode = EXIT_FAILURE
    renderer.render(archive: archive, viewportWidth: 900) { result in
        defer { finished = true }
        switch result {
        case .success(let image):
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("长图自测无法编码 PNG。\n".utf8))
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                print("full_page_render_size=\(image.width)x\(image.height)")
                exitCode = image.height > 2_000 ? EXIT_SUCCESS : EXIT_FAILURE
            } catch {
                FileHandle.standardError.write(Data("长图自测保存失败：\(error.localizedDescription)\n".utf8))
            }
        case .failure(let error):
            FileHandle.standardError.write(Data("长图自测失败：\(error.localizedDescription)\n".utf8))
        }
    }
    let deadline = Date().addingTimeInterval(20)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if !finished {
        FileHandle.standardError.write(Data("长图自测超时。\n".utf8))
    }
    exit(exitCode)
} else if CommandLine.arguments.contains("--repair-pending-explanations-once") {
    do {
        let report = try WrongQuestionOrganizer().run(mode: .repairPendingExplanationsOnce)
        print(report.summary)
        exit(report.contentFailedCount == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    } catch {
        FileHandle.standardError.write(Data("一次性解析补全失败：\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--export-knowledge-documents") {
    do {
        let configuration = SharedContentServiceConfigurationStore.load().normalized()
        let outputFolder = URL(
            fileURLWithPath: configuration.knowledgeDocumentFolderPath,
            isDirectory: true
        )
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"

        var allRecords: [QuestionKnowledgeRecord] = []
        var wrongRecords: [QuestionKnowledgeRecord] = []
        for subject in StudySubject.allCases {
            let store = try QuestionBankStore(
                databaseURL: QuestionBankPaths.defaultDatabaseURL(for: subject),
                sourceApplication: "knowledge-document-export:\(subject.rawValue)"
            )
            allRecords += try store.knowledgeRecords(subject: subject, wrongBookOnly: false)
            wrongRecords += try store.knowledgeRecords(subject: subject, wrongBookOnly: true)
        }

        let allOutput = outputFolder.appendingPathComponent("\(formatter.string(from: now))全部知识点.docx")
        let wrongOutput = outputFolder.appendingPathComponent("当前错题知识点.docx")
        try KnowledgeDocumentWriter.write(
            records: allRecords,
            kind: .allKnowledge(updatedAt: now),
            to: allOutput
        )
        try KnowledgeDocumentWriter.write(
            records: wrongRecords,
            kind: .currentWrong(updatedAt: now),
            to: wrongOutput
        )
        print("全部知识点源题数：\(allRecords.count)")
        print("当前错题知识点源题数：\(wrongRecords.count)")
        print("全部知识点：\(allOutput.path)")
        print("错题知识点：\(wrongOutput.path)")
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("生成知识点失败：\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--organize-now") {
    do {
        let report = try WrongQuestionOrganizer().run()
        print(report.summary)
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("整理失败：\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.run()
}
