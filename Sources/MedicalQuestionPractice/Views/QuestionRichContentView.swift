import AppKit
import SwiftUI

struct QuestionRichContentView: View {
    let content: String
    var textFont: Font = .body
    var showsStrikethrough = false

    private var segments: [QuestionContentSegment] {
        QuestionContentSegment.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let value):
                    Text(value)
                        .font(textFont)
                        .strikethrough(showsStrikethrough, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let relativePath, let label):
                    if let image = CivilServiceAssetLoader.image(relativePath: relativePath) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(maxWidth: 760, maxHeight: 520, alignment: .leading)
                            .overlay {
                                if showsStrikethrough {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.9))
                                        .frame(height: 1.5)
                                }
                            }
                            .accessibilityLabel(label.isEmpty ? "题目图片" : label)
                    } else {
                        Label("图片无法读取：\(relativePath)", systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum QuestionContentSegment {
    case text(String)
    case image(relativePath: String, label: String)

    static func parse(_ content: String) -> [QuestionContentSegment] {
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(civil-asset://([^)]+)\)"#
        ) else { return [.text(content)] }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        guard !matches.isEmpty else { return [.text(content)] }

        var output: [QuestionContentSegment] = []
        var cursor = content.startIndex
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: content),
                  let labelRange = Range(match.range(at: 1), in: content),
                  let pathRange = Range(match.range(at: 2), in: content)
            else { continue }
            let prefix = String(content[cursor..<fullRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { output.append(.text(prefix)) }
            output.append(
                .image(
                    relativePath: String(content[pathRange]).removingPercentEncoding ?? String(content[pathRange]),
                    label: String(content[labelRange])
                )
            )
            cursor = fullRange.upperBound
        }
        let suffix = String(content[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty { output.append(.text(suffix)) }
        return output.isEmpty ? [.text(content)] : output
    }
}

private enum CivilServiceAssetLoader {
    static func image(relativePath: String) -> NSImage? {
        let normalized = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("CivilServiceQuestionBank", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(normalized, isDirectory: false)
        if let bundled, let image = NSImage(contentsOf: bundled) { return image }

        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(
                "extracted/gongkao-question-bank-2026-08-08/cleaned-four-column-20260808/assets",
                isDirectory: true
            )
            .appendingPathComponent(normalized, isDirectory: false)
        return NSImage(contentsOf: development)
    }
}
