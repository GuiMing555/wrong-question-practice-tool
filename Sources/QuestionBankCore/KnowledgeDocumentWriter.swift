import Foundation

public struct QuestionKnowledgeRecord: Equatable, Sendable {
    public let questionID: String
    public let subject: StudySubject
    public let curriculumSection: String
    public let curriculumChapter: String
    public let knowledgeCards: [StudyKnowledgeCard]
    public let wrongAttempts: Int
    public let responseReceivedAt: Date

    public init(
        questionID: String,
        subject: StudySubject,
        curriculumSection: String,
        curriculumChapter: String,
        knowledgeCards: [StudyKnowledgeCard],
        wrongAttempts: Int,
        responseReceivedAt: Date
    ) {
        self.questionID = questionID
        self.subject = subject
        self.curriculumSection = curriculumSection
        self.curriculumChapter = curriculumChapter
        self.knowledgeCards = knowledgeCards
        self.wrongAttempts = wrongAttempts
        self.responseReceivedAt = responseReceivedAt
    }
}

public struct QuestionAnalysisCandidate: Equatable, Sendable {
    public let questionID: String
    public let input: QuestionContentInput

    public init(questionID: String, input: QuestionContentInput) {
        self.questionID = questionID
        self.input = input
    }
}

public enum KnowledgeDocumentKind: Equatable, Sendable {
    case dailyNew(date: Date)
    case allKnowledge(updatedAt: Date)
    case currentWrong(updatedAt: Date)
}

public enum KnowledgeDocumentWriter {
    private struct MergedCard {
        var subject: StudySubject
        var section: String
        var chapter: String
        var title: String
        var memoryText: String
        var pitfalls: [String]
        var maximumWrongAttempts: Int
    }

    public static func write(
        records: [QuestionKnowledgeRecord],
        kind: KnowledgeDocumentKind,
        to output: URL,
        fileManager: FileManager = .default
    ) throws {
        let cards = mergedCards(records)
        let html = documentHTML(cards: cards, kind: kind)
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryHTML = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).html")
        let temporaryDocx = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).docx")
        let normalizedDocx = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-normalized.docx")
        defer {
            try? fileManager.removeItem(at: temporaryHTML)
            try? fileManager.removeItem(at: temporaryDocx)
            try? fileManager.removeItem(at: normalizedDocx)
        }
        try Data(html.utf8).write(to: temporaryHTML, options: .atomic)
        try runProcess(
            executable: "/usr/bin/textutil",
            arguments: ["-convert", "docx", "-format", "html", "-output", temporaryDocx.path, temporaryHTML.path]
        )
        guard fileManager.fileExists(atPath: temporaryDocx.path) else {
            throw KnowledgeDocumentWriterError.conversionFailed("textutil 未生成文件")
        }
        try normalizeCJKDocument(source: temporaryDocx, output: normalizedDocx, fileManager: fileManager)
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        try fileManager.moveItem(at: normalizedDocx, to: output)
    }

    static func documentHTML(
        records: [QuestionKnowledgeRecord],
        kind: KnowledgeDocumentKind
    ) -> String {
        documentHTML(cards: mergedCards(records), kind: kind)
    }

    private static func mergedCards(_ records: [QuestionKnowledgeRecord]) -> [MergedCard] {
        var values: [String: MergedCard] = [:]
        for record in records {
            for card in record.knowledgeCards {
                let titleKey = normalizedKey(card.title)
                guard !titleKey.isEmpty else { continue }
                let key = record.subject.rawValue + "|" + titleKey
                if var existing = values[key] {
                    existing.maximumWrongAttempts = max(existing.maximumWrongAttempts, record.wrongAttempts)
                    if card.memoryText.count > existing.memoryText.count {
                        existing.memoryText = card.memoryText
                        existing.section = record.curriculumSection
                        existing.chapter = record.curriculumChapter
                    }
                    for pitfall in card.pitfalls where !existing.pitfalls.contains(pitfall) {
                        existing.pitfalls.append(pitfall)
                    }
                    values[key] = existing
                } else {
                    values[key] = MergedCard(
                        subject: record.subject,
                        section: record.curriculumSection,
                        chapter: record.curriculumChapter,
                        title: card.title,
                        memoryText: card.memoryText,
                        pitfalls: card.pitfalls,
                        maximumWrongAttempts: record.wrongAttempts
                    )
                }
            }
        }
        return values.values.sorted { left, right in
            let leftKey = categoryOrder(subject: left.subject, section: left.section, chapter: left.chapter)
            let rightKey = categoryOrder(subject: right.subject, section: right.section, chapter: right.chapter)
            if leftKey != rightKey { return leftKey.lexicographicallyPrecedes(rightKey) }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private static func documentHTML(cards: [MergedCard], kind: KnowledgeDocumentKind) -> String {
        let title: String
        let subtitle: String
        let emptyText: String
        let isWrongBook: Bool
        switch kind {
        case .dailyNew(let date):
            title = "\(shortDate(date))新增知识点"
            subtitle = "当日 API 新增内容 · 已按科目与章节去重"
            emptyText = "今日没有新增的有效知识点。"
            isWrongBook = false
        case .allKnowledge(let updatedAt):
            title = "\(shortDate(updatedAt))更新·全部知识点"
            subtitle = "当前题本全部有效 API 知识点 · 已按科目与章节去重"
            emptyText = "当前题本没有可整理的知识点。"
            isWrongBook = false
        case .currentWrong(let updatedAt):
            title = "\(shortDate(updatedAt))更新·错题知识点"
            subtitle = "当前错题本实时重建 · 移出错题本后自动移除"
            emptyText = "当前错题本没有可整理的知识点。"
            isWrongBook = true
        }
        var body = "<header><div class='kicker'>成人高考专升本 · 背诵手册</div><h1>\(escape(title))</h1><p class='subtitle'>\(escape(subtitle))</p><p class='count'>共 \(cards.count) 个去重知识点</p></header>"
        if cards.isEmpty {
            body += "<section class='empty'>\(escape(emptyText))</section>"
        } else {
            for subject in StudySubject.allCases {
                let subjectCards = cards.filter { $0.subject == subject }
                guard !subjectCards.isEmpty else { continue }
                body += "<section class='subject'><h2>\(escape(subject.displayName))</h2>"
                for section in orderedSections(subject: subject, cards: subjectCards) {
                    let sectionCards = subjectCards.filter { $0.section == section }
                    guard !sectionCards.isEmpty else { continue }
                    body += "<h3>\(escape(section))</h3>"
                    for chapter in orderedChapters(subject: subject, section: section, cards: sectionCards) {
                        let chapterCards = sectionCards.filter { $0.chapter == chapter }
                        guard !chapterCards.isEmpty else { continue }
                        body += "<h4 class='chapter'>\(escape(chapter))</h4>"
                        for card in chapterCards {
                            let emphasized = isWrongBook && card.maximumWrongAttempts > 3
                            body += "<article class='card\(emphasized ? " high-frequency" : "")'>"
                            body += "<h5>\(escape(card.title))</h5><p>\(escape(card.memoryText))</p>"
                            if !card.pitfalls.isEmpty {
                                body += "<div class='pitfalls'><b>易错辨析</b><ul>"
                                body += card.pitfalls.map { "<li>\(escape($0))</li>" }.joined()
                                body += "</ul></div>"
                            }
                            body += "</article>"
                        }
                    }
                }
                body += "</section>"
            }
        }
        return """
        <!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><title>\(escape(title))</title>
        <style>
          @page { size: A4 portrait; margin: 15mm 16mm 15mm 16mm; }
          body { font-family: 'Noto Sans CJK SC','PingFang SC',sans-serif; font-size:10pt; line-height:1.15; color:#222; margin:0; }
          header { border-bottom:2px solid #2E74B5; padding:0 0 8pt; margin:0 0 10pt; }
          .kicker { color:#2E74B5; font-size:8.5pt; letter-spacing:0.7px; margin-bottom:4pt; }
          h1 { color:#2E74B5; font-size:18pt; margin:0 0 4pt; }
          .subtitle { color:#1F4D78; font-size:9.5pt; margin:0 0 2pt; }
          .count { color:#666; font-size:8.5pt; margin:0; }
          h2 { color:#2E74B5; font-size:15pt; margin:12pt 0 6pt; }
          h3 { color:#2E74B5; font-size:12pt; margin:8pt 0 4pt; }
          h4.chapter { color:#1F4D78; font-size:11pt; margin:6pt 0 3pt; border-bottom:1px solid #B4C7DC; padding-bottom:2pt; }
          .card { page-break-inside:avoid; margin:0 0 5pt; padding:4pt 6pt; background:#F5F8FB; border-left:2px solid #2E74B5; }
          .card h5 { color:#1F4D78; font-size:10.5pt; margin:0 0 2pt; }
          .card p { margin:0 0 2pt; }
          .pitfalls { color:#7A3030; font-size:9.5pt; margin-top:3pt; }
          .pitfalls ul { margin:2pt 0 0 14pt; padding:0; }
          .pitfalls li { margin:1pt 0; }
          .high-frequency { border-left-color:#C00000; }
          .high-frequency h5, .high-frequency p, .high-frequency .pitfalls { color:#C00000; }
          .empty { padding:16pt; background:#F4F6F9; color:#555; }
        </style></head><body>\(body)</body></html>
        """
    }

    private static func categoryOrder(subject: StudySubject, section: String, chapter: String) -> [Int] {
        let subjectIndex = StudySubject.allCases.firstIndex(of: subject) ?? Int.max
        switch subject {
        case .medicalComprehensive:
            let sectionIndex = MedicalCurriculumTaxonomy.sections.firstIndex { $0.name == section } ?? Int.max
            let chapterIndex = MedicalCurriculumTaxonomy.sections.first { $0.name == section }?.chapters.firstIndex(of: chapter) ?? Int.max
            return [subjectIndex, sectionIndex, chapterIndex]
        case .politics:
            let sectionIndex = PoliticalCurriculumTaxonomy.sections.firstIndex { $0.name == section } ?? Int.max
            let chapterIndex = PoliticalCurriculumTaxonomy.sections.first { $0.name == section }?.chapters.firstIndex(of: chapter) ?? Int.max
            return [subjectIndex, sectionIndex, chapterIndex]
        case .english:
            return [subjectIndex, 0, EnglishCurriculumTaxonomy.sections.firstIndex(of: chapter) ?? Int.max]
        }
    }

    private static func orderedSections(subject: StudySubject, cards: [MergedCard]) -> [String] {
        let available = Set(cards.map(\.section))
        let canonical: [String]
        switch subject {
        case .medicalComprehensive: canonical = MedicalCurriculumTaxonomy.sections.map(\.name)
        case .politics: canonical = PoliticalCurriculumTaxonomy.sections.map(\.name)
        case .english: canonical = ["英语"]
        }
        return canonical.filter(available.contains) + available.filter { !canonical.contains($0) }.sorted()
    }

    private static func orderedChapters(subject: StudySubject, section: String, cards: [MergedCard]) -> [String] {
        let available = Set(cards.map(\.chapter))
        let canonical: [String]
        switch subject {
        case .medicalComprehensive:
            canonical = MedicalCurriculumTaxonomy.sections.first { $0.name == section }?.chapters ?? []
        case .politics:
            canonical = PoliticalCurriculumTaxonomy.sections.first { $0.name == section }?.chapters ?? []
        case .english:
            canonical = EnglishCurriculumTaxonomy.sections
        }
        return canonical.filter(available.contains) + available.filter { !canonical.contains($0) }.sorted()
    }

    private static func normalizedKey(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains(Int($0.value))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func normalizeCJKDocument(source: URL, output: URL, fileManager: FileManager) throws {
        let working = source.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-docx", isDirectory: true)
        try fileManager.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: working) }
        try runProcess(executable: "/usr/bin/unzip", arguments: ["-q", source.path, "-d", working.path])
        let documentXML = working.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: documentXML, encoding: .utf8)
        xml = xml.replacingOccurrences(of: "<w:rFonts ", with: "<w:rFonts w:eastAsia=\"Noto Sans CJK SC\" ")
        xml = xml.replacingOccurrences(of: "<w:spacing w:val=\"0\"/>", with: "")
        xml = xml.replacingOccurrences(of: #"<w:pgSz\b[^>]*/>"#, with: "", options: .regularExpression)
        xml = xml.replacingOccurrences(of: #"<w:pgMar\b[^>]*/>"#, with: "", options: .regularExpression)
        xml = xml.replacingOccurrences(
            of: "<w:sectPr>",
            with: #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="850" w:right="907" w:bottom="850" w:left="907" w:header="708" w:footer="708" w:gutter="0"/>"#
        )
        try Data(xml.utf8).write(to: documentXML, options: .atomic)
        if let resources = fontResourcesURL(fileManager: fileManager),
           fileManager.fileExists(atPath: resources.appendingPathComponent("font1.odttf").path) {
            try installEmbeddedFonts(resources: resources, working: working, fileManager: fileManager)
        }
        try runProcess(executable: "/usr/bin/zip", arguments: ["-q", "-r", output.path, "."], currentDirectory: working)
    }

    private static func fontResourcesURL(fileManager: FileManager) -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["KNOWLEDGE_DOC_FONT_RESOURCES"],
           !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return Bundle.main.resourceURL?.appendingPathComponent("DocxFonts", isDirectory: true)
    }

    private static func installEmbeddedFonts(resources: URL, working: URL, fileManager: FileManager) throws {
        let fonts = working.appendingPathComponent("word/fonts", isDirectory: true)
        let rels = working.appendingPathComponent("word/_rels", isDirectory: true)
        try fileManager.createDirectory(at: fonts, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rels, withIntermediateDirectories: true)
        for name in ["font1.odttf", "font2.odttf"] {
            try fileManager.copyItem(at: resources.appendingPathComponent(name), to: fonts.appendingPathComponent(name))
        }
        try fileManager.copyItem(at: resources.appendingPathComponent("fontTable.xml"), to: working.appendingPathComponent("word/fontTable.xml"))
        try fileManager.copyItem(at: resources.appendingPathComponent("fontTable.xml.rels"), to: rels.appendingPathComponent("fontTable.xml.rels"))
        let contentTypesURL = working.appendingPathComponent("[Content_Types].xml")
        var contentTypes = try String(contentsOf: contentTypesURL, encoding: .utf8)
        contentTypes = contentTypes.replacingOccurrences(
            of: "</Types>",
            with: "<Default Extension=\"odttf\" ContentType=\"application/vnd.openxmlformats-officedocument.obfuscatedFont\"/><Override PartName=\"/word/fontTable.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml\"/></Types>"
        )
        try Data(contentTypes.utf8).write(to: contentTypesURL, options: .atomic)
        let relationshipURL = rels.appendingPathComponent("document.xml.rels")
        var relationships = try String(contentsOf: relationshipURL, encoding: .utf8)
        relationships = relationships.replacingOccurrences(
            of: "</Relationships>",
            with: "<Relationship Id=\"rIdDocxFontTable\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable\" Target=\"fontTable.xml\"/></Relationships>"
        )
        try Data(relationships.utf8).write(to: relationshipURL, options: .atomic)
    }

    private static func runProcess(executable: String, arguments: [String], currentDirectory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw KnowledgeDocumentWriterError.conversionFailed(message)
        }
    }
}

public enum KnowledgeDocumentWriterError: LocalizedError {
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conversionFailed(let message): return "生成知识点 Word 失败：\(message)"
        }
    }
}
