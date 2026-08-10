import AppKit

final class OrganizeProgressWindowController: NSWindowController {
    private let phaseLabel = NSTextField(labelWithString: "准备整理…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "正在读取截图目录。")
    private let progressIndicator = NSProgressIndicator()
    private let failureTextView = NSTextView()
    private let failureScrollView = NSScrollView()
    private let copyButton = NSButton(title: "复制失败原因", target: nil, action: nil)
    private let closeButton = NSButton(title: "后台继续", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "题本整理进度"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildInterface()
    }

    func begin() {
        phaseLabel.stringValue = "准备整理…"
        detailLabel.stringValue = "正在读取截图目录。"
        detailLabel.textColor = .secondaryLabelColor
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        failureTextView.string = ""
        failureScrollView.isHidden = true
        copyButton.isHidden = true
        copyButton.isEnabled = false
        closeButton.title = "后台继续"
    }

    func update(_ value: OrganizerProgressUpdate) {
        phaseLabel.stringValue = value.phase
        detailLabel.stringValue = value.detail
        detailLabel.textColor = .secondaryLabelColor
        if value.total > 0 {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.minValue = 0
            progressIndicator.maxValue = Double(value.total)
            progressIndicator.doubleValue = Double(min(value.completed, value.total))
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        }
    }

    func complete(_ report: OrganizerReport) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 1
        phaseLabel.stringValue = report.contentFailedCount == 0 ? "题本整理完成" : "题本已整理，部分 API 分析失败"
        detailLabel.stringValue = "API 新完成 \(report.contentCompletedCount) 题、复用 \(report.contentReusedCount) 题；已封存 \(report.archivedImageCount) 份原始采集内容，连续 3 次失败 \(report.contentFailedCount) 题。"
        detailLabel.textColor = report.contentFailedCount == 0 ? .secondaryLabelColor : .systemRed
        if !report.copyableFailureText.isEmpty {
            failureTextView.string = report.copyableFailureText
            failureScrollView.isHidden = false
            copyButton.isHidden = false
            copyButton.isEnabled = true
        }
        closeButton.title = "关闭"
    }

    func fail(_ error: Error) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        phaseLabel.stringValue = "整理失败"
        detailLabel.stringValue = error.localizedDescription
        detailLabel.textColor = .systemRed
        failureTextView.string = error.localizedDescription
        failureScrollView.isHidden = false
        copyButton.isHidden = false
        copyButton.isEnabled = true
        closeButton.title = "关闭"
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        phaseLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        detailLabel.maximumNumberOfLines = 3
        progressIndicator.style = .bar
        progressIndicator.controlSize = .large

        failureTextView.isEditable = false
        failureTextView.isSelectable = true
        failureTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        failureTextView.textContainerInset = NSSize(width: 10, height: 10)
        failureScrollView.documentView = failureTextView
        failureScrollView.hasVerticalScroller = true
        failureScrollView.borderType = .bezelBorder
        failureScrollView.isHidden = true

        copyButton.target = self
        copyButton.action = #selector(copyFailureReason)
        copyButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeWindow)

        let buttonRow = NSStackView(views: [copyButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let stack = NSStackView(views: [phaseLabel, detailLabel, progressIndicator, failureScrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        failureScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        failureScrollView.heightAnchor.constraint(equalToConstant: 235).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
    }

    @objc private func copyFailureReason() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failureTextView.string, forType: .string)
        detailLabel.stringValue = "失败原因已复制到剪贴板。"
    }

    @objc private func closeWindow() { close() }
}
