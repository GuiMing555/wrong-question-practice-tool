import AppKit
import QuestionBankCore

final class SettingsWindowController: NSWindowController {
    var onSave: ((AppSettings) -> Result<String, Error>)?
    var onOrganize: (() -> Void)?
    var onOpenAPISettings: (() -> Void)?
    var onOpenSystemPermissions: (() -> Void)?

    private let shortcutPopup = NSPopUpButton()
    private let recognitionPopup = NSPopUpButton()
    private let recognitionHint = NSTextField(wrappingLabelWithString: "")
    private let contentServiceCheckbox = NSButton(checkboxWithTitle: "启用题目分析 API", target: nil, action: nil)
    private let contentServiceEndpointField = NSTextField()
    private let contentServiceModelField = NSTextField()
    private let contentServiceAccessKeyField = NSSecureTextField()
    private let contentServiceTestButton = NSButton(title: "测试接口", target: nil, action: nil)
    private let capturePathField = NSTextField()
    private let outputPathField = NSTextField()
    private let generateWordCheckbox = NSButton(checkboxWithTitle: "生成可打印 Word 文档（默认关闭）", target: nil, action: nil)
    private let dailyCheckbox = NSButton(checkboxWithTitle: "每天 15:00 由本机自动整理", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    convenience init(settings: AppSettings) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 690),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "错题每日自动化整理 · 设置"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildInterface()
        apply(settings)
    }

    func apply(_ settings: AppSettings) {
        capturePathField.stringValue = settings.captureFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.outputFolderURL.deletingLastPathComponent().path
            : settings.captureFolderPath
        outputPathField.stringValue = settings.outputFolderPath
        dailyCheckbox.state = settings.dailyOrganizeEnabled ? .on : .off
        shortcutPopup.selectItem(at: CaptureShortcut.allCases.firstIndex(of: settings.captureShortcut) ?? 0)
        recognitionPopup.selectItem(at: RecognitionMode.allCases.firstIndex(of: settings.recognitionMode) ?? 0)
        contentServiceCheckbox.state = settings.contentServiceEnabled ? .on : .off
        contentServiceEndpointField.stringValue = settings.contentServiceEndpoint
        contentServiceModelField.stringValue = settings.contentServiceModel
        contentServiceAccessKeyField.stringValue = settings.contentServiceAccessKey
        generateWordCheckbox.state = settings.generateWordDocuments ? .on : .off
        updateRecognitionHint()
        updateContentServiceFields()
    }

    func showStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "截图与题本设置")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "绑定浏览器窗口后，快捷键会直接读取当前标签页的页面数据。题干、选项、答案和解析校验通过时只保存文字，不生成图片；只有数据不完整时才回退截图和 OCR。全部处理均在本机完成。")
        intro.textColor = .secondaryLabelColor

        shortcutPopup.addItems(withTitles: CaptureShortcut.allCases.map(\.title))
        recognitionPopup.addItems(withTitles: RecognitionMode.allCases.map(\.title))
        recognitionPopup.target = self
        recognitionPopup.action = #selector(recognitionModeChanged)

        let captureRow = folderRow(
            label: "截图保存位置",
            field: capturePathField,
            action: #selector(chooseCaptureFolder)
        )
        let outputRow = folderRow(
            label: "整理文件位置",
            field: outputPathField,
            action: #selector(chooseOutputFolder)
        )

        let shortcutLabel = NSTextField(labelWithString: "截图快捷键")
        shortcutLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let targetHint = NSTextField(wrappingLabelWithString: "设定目标窗口的快捷键固定为 Control + Option + Shift + 1。绑定 Chrome 题库窗口后，单独轻点右 Shift 会直接读取并校验标签页数据；通过时只写入小型文字文件，不改变页面焦点、选区或剪贴板。")
        targetHint.textColor = .secondaryLabelColor
        targetHint.font = .systemFont(ofSize: 11)
        let permissionsButton = NSButton(
            title: "检查系统权限…",
            target: self,
            action: #selector(openSystemPermissions)
        )
        permissionsButton.bezelStyle = .rounded

        let automaticSubjectLabel = NSTextField(labelWithString: "科目自动分类")
        automaticSubjectLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let automaticSubjectHint = NSTextField(wrappingLabelWithString: "整理时自动识别医学综合、政治、英语，并写入对应独立题本。英语优先根据题干语言及固定章节识别；中文题重点识别政治与医学特征，模糊题交由已配置接口判断。仍无法可靠判断的图片会保留在待人工校对图片文件夹，不会误入其他科目。")
        automaticSubjectHint.textColor = .secondaryLabelColor
        automaticSubjectHint.font = .systemFont(ofSize: 11)

        let recognitionLabel = NSTextField(labelWithString: "截图识别方式")
        recognitionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        recognitionHint.textColor = .secondaryLabelColor
        recognitionHint.font = .systemFont(ofSize: 11)

        let apiTitle = NSTextField(labelWithString: "题目分析 API")
        apiTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let apiHint = NSTextField(wrappingLabelWithString: "接口地址、模型、访问密钥和连接测试已移到独立页面。整理时只上传题目文字，不上传截图。")
        apiHint.textColor = .secondaryLabelColor
        apiHint.font = .systemFont(ofSize: 11)
        let apiButton = NSButton(title: "打开 API 设置…", target: self, action: #selector(openAPISettings))
        apiButton.bezelStyle = .rounded

        let outputsTitle = NSTextField(labelWithString: "整理输出")
        outputsTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let outputs = NSTextField(wrappingLabelWithString: "• 医学综合、政治、英语三个独立题本.xlsx（始终生成）\n• 各科错题本状态随作答更新；Word 文档由下方开关控制")
        outputs.textColor = .secondaryLabelColor

        dailyCheckbox.target = self
        dailyCheckbox.action = #selector(dailySettingChanged)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 2

        let saveButton = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let organizeButton = NSButton(title: "立即整理", target: self, action: #selector(organizeNow))
        organizeButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [organizeButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [
            heading, intro,
            sectionSeparator(),
            automaticSubjectLabel, automaticSubjectHint,
            sectionSeparator(),
            shortcutLabel, shortcutPopup, targetHint, permissionsButton,
            sectionSeparator(),
            recognitionLabel, recognitionPopup, recognitionHint,
            sectionSeparator(),
            apiTitle, apiHint, apiButton,
            sectionSeparator(),
            captureRow, outputRow,
            sectionSeparator(),
            dailyCheckbox, outputsTitle, outputs, generateWordCheckbox,
            statusLabel, buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        shortcutPopup.widthAnchor.constraint(equalToConstant: 330).isActive = true
        recognitionPopup.widthAnchor.constraint(equalToConstant: 330).isActive = true
        captureRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        outputRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        targetHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        automaticSubjectHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        recognitionHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        apiHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.setHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
    }

    private func folderRow(label: String, field: NSTextField, action: Selector) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.widthAnchor.constraint(equalToConstant: 105).isActive = true
        field.placeholderString = "请选择文件夹"
        let button = NSButton(title: "选择…", target: self, action: action)
        button.bezelStyle = .rounded
        let row = NSStackView(views: [title, field, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func labeledFieldRow(label: String, field: NSTextField) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let row = NSStackView(views: [title, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func sectionSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func chooseFolder(for field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: field.stringValue, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        field.stringValue = url.path
    }

    @objc private func chooseCaptureFolder() { chooseFolder(for: capturePathField) }
    @objc private func chooseOutputFolder() { chooseFolder(for: outputPathField) }

    @objc private func dailySettingChanged() {
        if dailyCheckbox.state == .on {
            showStatus("保存后将注册本机每日 15:00 定时任务。")
        }
    }

    @objc private func recognitionModeChanged() {
        updateRecognitionHint()
    }

    @objc private func contentServiceSettingChanged() {
        updateContentServiceFields()
    }

    @objc private func openAPISettings() {
        onOpenAPISettings?()
    }

    @objc private func openSystemPermissions() {
        onOpenSystemPermissions?()
    }

    private func updateRecognitionHint() {
        let mode = RecognitionMode.allCases[safe: recognitionPopup.indexOfSelectedItem] ?? .fentiQuestionBank
        recognitionHint.stringValue = mode.detail
    }

    private func updateContentServiceFields() {
        let enabled = contentServiceCheckbox.state == .on
        contentServiceEndpointField.isEnabled = enabled
        contentServiceModelField.isEnabled = enabled
        contentServiceAccessKeyField.isEnabled = enabled
        contentServiceTestButton.isEnabled = enabled
    }

    @objc private func testContentService() {
        guard let endpoint = URL(string: contentServiceEndpointField.stringValue),
              !contentServiceAccessKeyField.stringValue.isEmpty else {
            showStatus("请先填写接口地址和访问密钥。", isError: true)
            return
        }
        contentServiceTestButton.isEnabled = false
        showStatus("正在用内置基础题测试接口，不会提交真实题本……")
        let key = contentServiceAccessKeyField.stringValue
        let model = contentServiceModelField.stringValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let service = QuestionContentService(endpoint: endpoint, accessKey: key, model: model)
                let result = try service.analyze(
                    QuestionContentInput(
                        stableID: "connection-test",
                        question: "全面依法治国的总目标是（）。",
                        options: [
                            "A. 建设中国特色社会主义法治体系，建设社会主义法治国家",
                            "B. 只完善行政法规",
                            "C. 只加强道德建设",
                            "D. 只推进司法改革"
                        ],
                        knownAnswer: "A",
                        existingExplanation: "全面依法治国的总目标是建设中国特色社会主义法治体系、建设社会主义法治国家。",
                        requiresSolution: false,
                        subjectHint: "政治"
                    )
                )
                guard result.subject == .politics,
                      result.curriculumSection == "第三部分、新时代中国特色社会主义思想概论",
                      result.curriculumChapter == "全面依法治国" else {
                    throw QuestionContentServiceError.invalidResponse
                }
                DispatchQueue.main.async {
                    self?.showStatus("接口测试成功：政治 / \(result.curriculumChapter)")
                    self?.updateContentServiceFields()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showStatus("接口测试失败：\(error.localizedDescription)", isError: true)
                    self?.updateContentServiceFields()
                }
            }
        }
    }

    @objc private func saveSettings() {
        let shortcut = CaptureShortcut.allCases[safe: shortcutPopup.indexOfSelectedItem] ?? .rightShift
        let recognitionMode = RecognitionMode.allCases[safe: recognitionPopup.indexOfSelectedItem] ?? .fentiQuestionBank
        let settings = AppSettings(
            captureFolderPath: capturePathField.stringValue,
            outputFolderPath: outputPathField.stringValue,
            captureShortcut: shortcut,
            recognitionMode: recognitionMode,
            contentServiceEnabled: contentServiceCheckbox.state == .on,
            contentServiceEndpoint: contentServiceEndpointField.stringValue,
            contentServiceModel: contentServiceModelField.stringValue,
            contentServiceAccessKey: contentServiceAccessKeyField.stringValue,
            generateWordDocuments: generateWordCheckbox.state == .on,
            dailyOrganizeEnabled: dailyCheckbox.state == .on
        )
        guard let onSave else { return }
        switch onSave(settings) {
        case .success(let message):
            apply(settings.normalized())
            showStatus(message)
        case .failure(let error):
            showStatus(error.localizedDescription, isError: true)
        }
    }

    @objc private func organizeNow() {
        showStatus("正在识别、整理并刷新题本工作簿……")
        onOrganize?()
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
