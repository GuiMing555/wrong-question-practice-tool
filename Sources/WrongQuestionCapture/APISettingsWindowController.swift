import AppKit
import QuestionBankCore

final class APISettingsWindowController: NSWindowController {
    var onSave: ((AppSettings) -> Result<String, Error>)?

    private var settings: AppSettings
    private let enabledCheckbox = NSButton(checkboxWithTitle: "启用题目分析 API", target: nil, action: nil)
    private let endpointField = NSTextField()
    private let modelField = NSTextField()
    private let accessKeyField = NSSecureTextField()
    private let testButton = NSButton(title: "测试接口", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存 API 设置", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "题目分析 API 设置"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        apply(settings)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ settings: AppSettings) {
        self.settings = settings
        enabledCheckbox.state = settings.contentServiceEnabled ? .on : .off
        endpointField.stringValue = settings.contentServiceEndpoint
        modelField.stringValue = settings.contentServiceModel
        accessKeyField.stringValue = settings.contentServiceAccessKey
        updateFields()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "题目分析 API")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(
            wrappingLabelWithString: "启用后，整理程序会逐题提交题干、选项、答案和解析文字，用于科目分类、章节归纳和知识卡整理；截图图片不会上传。"
        )
        intro.textColor = .secondaryLabelColor

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged)
        endpointField.placeholderString = "https://服务地址/接口路径"
        modelField.placeholderString = "模型标识（接口不需要时可留空）"
        accessKeyField.placeholderString = "访问密钥"

        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let hint = NSTextField(
            wrappingLabelWithString: "单题失败会自动重试，连续 3 次失败后停止，并在整理进度窗口返回可复制的具体原因。访问密钥保存在仅当前账户可读写的本地文件中，不调用钥匙串。"
        )
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 3

        let buttons = NSStackView(views: [testButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [
            heading, intro, separator(), enabledCheckbox,
            fieldRow("接口地址", endpointField),
            fieldRow("模型标识", modelField),
            fieldRow("访问密钥", accessKeyField),
            hint, statusLabel, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        for view in [intro, hint, statusLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
    }

    private func fieldRow(_ title: String, _ field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.widthAnchor.constraint(equalToConstant: 624).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    @objc private func enabledChanged() { updateFields() }

    private func updateFields() {
        let enabled = enabledCheckbox.state == .on
        endpointField.isEnabled = enabled
        modelField.isEnabled = enabled
        accessKeyField.isEnabled = enabled
        testButton.isEnabled = enabled
    }

    @objc private func testConnection() {
        guard let endpoint = URL(string: endpointField.stringValue),
              !accessKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showStatus("请先填写接口地址和访问密钥。", isError: true)
            return
        }
        testButton.isEnabled = false
        showStatus("正在用内置基础题测试接口，不会提交真实题本……")
        let key = accessKeyField.stringValue
        let model = modelField.stringValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try QuestionContentService(
                    endpoint: endpoint,
                    accessKey: key,
                    model: model
                ).analyze(
                    QuestionContentInput(
                        stableID: "connection-test",
                        question: "全面依法治国的总目标是（）。",
                        options: [
                            "A. 建设中国特色社会主义法治体系，建设社会主义法治国家",
                            "B. 只完善行政法规", "C. 只加强道德建设", "D. 只推进司法改革"
                        ],
                        knownAnswer: "A",
                        existingExplanation: "全面依法治国的总目标是建设中国特色社会主义法治体系、建设社会主义法治国家。",
                        requiresSolution: false,
                        subjectHint: "政治"
                    )
                )
                guard result.subject == .politics else { throw QuestionContentServiceError.invalidResponse }
                DispatchQueue.main.async {
                    self?.showStatus("接口测试成功：政治 / \(result.curriculumChapter)")
                    self?.updateFields()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showStatus("接口测试失败：\(error.localizedDescription)", isError: true)
                    self?.updateFields()
                }
            }
        }
    }

    @objc private func save() {
        var proposed = settings
        proposed.contentServiceEnabled = enabledCheckbox.state == .on
        proposed.contentServiceEndpoint = endpointField.stringValue
        proposed.contentServiceModel = modelField.stringValue
        proposed.contentServiceAccessKey = accessKeyField.stringValue
        guard let onSave else { return }
        switch onSave(proposed) {
        case .success(let message):
            apply(proposed.normalized())
            showStatus(message)
        case .failure(let error):
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func showStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }
}
