import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MedicalCurriculumSection: Codable, Equatable, Sendable {
    public let name: String
    public let chapters: [String]

    public init(name: String, chapters: [String]) {
        self.name = name
        self.chapters = chapters
    }
}

public enum MedicalCurriculumTaxonomy {
    public static let version = 1

    public static let sections: [MedicalCurriculumSection] = [
        MedicalCurriculumSection(
            name: "第一部分、人体解剖学",
            chapters: [
                "骨学", "关节学", "肌学", "消化系统", "呼吸系统", "泌尿系统",
                "男性生殖系统", "女性生殖系统", "脉管系统", "感觉器官", "周围神经系统", "中枢神经系统"
            ]
        ),
        MedicalCurriculumSection(
            name: "第二部分、生理学",
            chapters: [
                "绪论", "细胞的基本功能", "血液", "血液循环", "呼吸", "消化和吸收",
                "能量代谢和体温", "尿的生成和排出", "感觉器官的功能", "神经系统的功能", "内分泌", "生殖"
            ]
        ),
        MedicalCurriculumSection(
            name: "第三部分、内科学基础（诊断学）",
            chapters: ["问诊", "临床常见症状", "体格检查", "实验室及其他辅助检查", "内科常用的诊断技术"]
        ),
        MedicalCurriculumSection(
            name: "第四部分、外科学（外科总论）",
            chapters: [
                "水、电解质代谢和酸碱平衡失调", "外科休克", "外科感染", "围手术期处理", "输血",
                "多器官功能不全", "外科营养", "创伤和烧伤", "肿瘤", "复苏"
            ]
        )
    ]

    public static func contains(section: String, chapter: String) -> Bool {
        sections.first(where: { $0.name == section })?.chapters.contains(chapter) == true
    }

    public static var promptText: String {
        sections.map { section in
            "\(section.name)：\(section.chapters.joined(separator: "、"))"
        }.joined(separator: "\n")
    }
}

public struct MedicalCategorySelection: Codable, Equatable, Sendable {
    public var section: String
    public var chapter: String

    public init(section: String, chapter: String) {
        self.section = section
        self.chapter = chapter
    }
}

public struct StudyKnowledgeCard: Codable, Equatable, Sendable {
    public var title: String
    public var memoryText: String
    public var pitfalls: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case memoryText = "memory_text"
        case pitfalls
    }

    public init(title: String, memoryText: String, pitfalls: [String] = []) {
        self.title = title
        self.memoryText = memoryText
        self.pitfalls = pitfalls
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        memoryText = try values.decode(String.self, forKey: .memoryText)
        pitfalls = try values.decodeIfPresent([String].self, forKey: .pitfalls) ?? []
    }
}

public struct QuestionContentResult: Codable, Equatable, Sendable {
    public var subject: StudySubject
    public var curriculumSection: String
    public var curriculumChapter: String
    public var questionType: String
    public var knowledgeCards: [StudyKnowledgeCard]
    public var resolvedAnswer: String?
    public var resolvedExplanation: String?

    enum CodingKeys: String, CodingKey {
        case subject
        case curriculumSection = "curriculum_section"
        case curriculumChapter = "curriculum_chapter"
        case medicalCategory = "medical_category"
        case questionType = "question_type"
        case knowledgeCards = "knowledge_cards"
        case resolvedAnswer = "resolved_answer"
        case resolvedExplanation = "resolved_explanation"
    }

    public init(
        subject: StudySubject,
        curriculumSection: String,
        curriculumChapter: String,
        questionType: String,
        knowledgeCards: [StudyKnowledgeCard],
        resolvedAnswer: String? = nil,
        resolvedExplanation: String? = nil
    ) {
        self.subject = subject
        self.curriculumSection = curriculumSection
        self.curriculumChapter = curriculumChapter
        self.questionType = questionType
        self.knowledgeCards = knowledgeCards
        self.resolvedAnswer = resolvedAnswer
        self.resolvedExplanation = resolvedExplanation
    }

    public init(
        medicalCategory: MedicalCategorySelection,
        questionType: String,
        knowledgeCards: [StudyKnowledgeCard],
        resolvedAnswer: String? = nil,
        resolvedExplanation: String? = nil
    ) {
        self.subject = .medicalComprehensive
        self.curriculumSection = medicalCategory.section
        self.curriculumChapter = medicalCategory.chapter
        self.questionType = questionType
        self.knowledgeCards = knowledgeCards
        self.resolvedAnswer = resolvedAnswer
        self.resolvedExplanation = resolvedExplanation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let label = try values.decodeIfPresent(String.self, forKey: .subject) {
            guard let decodedSubject = StudySubject.allCases.first(where: {
                $0.rawValue == label || $0.displayName == label
            }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .subject,
                    in: values,
                    debugDescription: "Unsupported subject"
                )
            }
            subject = decodedSubject
        } else {
            subject = .medicalComprehensive
        }
        if let section = try values.decodeIfPresent(String.self, forKey: .curriculumSection),
           let chapter = try values.decodeIfPresent(String.self, forKey: .curriculumChapter) {
            curriculumSection = section
            curriculumChapter = chapter
        } else {
            let legacy = try values.decode(MedicalCategorySelection.self, forKey: .medicalCategory)
            curriculumSection = legacy.section
            curriculumChapter = legacy.chapter
            subject = .medicalComprehensive
        }
        questionType = try values.decode(String.self, forKey: .questionType)
        knowledgeCards = try values.decode([StudyKnowledgeCard].self, forKey: .knowledgeCards)
        resolvedAnswer = try values.decodeIfPresent(String.self, forKey: .resolvedAnswer)
        resolvedExplanation = try values.decodeIfPresent(String.self, forKey: .resolvedExplanation)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(subject.displayName, forKey: .subject)
        try values.encode(curriculumSection, forKey: .curriculumSection)
        try values.encode(curriculumChapter, forKey: .curriculumChapter)
        if subject == .medicalComprehensive {
            try values.encode(
                MedicalCategorySelection(section: curriculumSection, chapter: curriculumChapter),
                forKey: .medicalCategory
            )
        }
        try values.encode(questionType, forKey: .questionType)
        try values.encode(knowledgeCards, forKey: .knowledgeCards)
        try values.encodeIfPresent(resolvedAnswer, forKey: .resolvedAnswer)
        try values.encodeIfPresent(resolvedExplanation, forKey: .resolvedExplanation)
    }

    public var medicalCategory: MedicalCategorySelection {
        MedicalCategorySelection(section: curriculumSection, chapter: curriculumChapter)
    }
}

public struct QuestionContentInput: Codable, Equatable, Sendable {
    public var stableID: String
    public var question: String
    public var options: [String]
    public var knownAnswer: String?
    public var existingExplanation: String?
    public var requiresSolution: Bool
    public var subjectHint: String?
    public var forceCompleteExplanation: Bool

    enum CodingKeys: String, CodingKey {
        case stableID = "stable_id"
        case question
        case options
        case knownAnswer = "known_answer"
        case existingExplanation = "existing_explanation"
        case requiresSolution = "requires_solution"
        case subjectHint = "subject_hint"
        case forceCompleteExplanation = "force_complete_explanation"
    }

    public init(
        stableID: String,
        question: String,
        options: [String],
        knownAnswer: String?,
        existingExplanation: String?,
        requiresSolution: Bool,
        subjectHint: String? = nil,
        forceCompleteExplanation: Bool = false
    ) {
        self.stableID = stableID
        self.question = question
        self.options = options
        self.knownAnswer = knownAnswer
        self.existingExplanation = existingExplanation
        self.requiresSolution = requiresSolution
        self.subjectHint = subjectHint
        self.forceCompleteExplanation = forceCompleteExplanation
    }
}

public enum QuestionContentServiceError: LocalizedError, Equatable {
    case invalidEndpoint
    case transport(String)
    case httpStatus(Int)
    case emptyResponse
    case invalidResponse
    case invalidCategory(subject: String, section: String, chapter: String)
    case invalidQuestionType
    case emptyKnowledgeCards

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "题目分析接口地址无效。"
        case .transport(let message): return "题目分析接口连接失败：\(message)"
        case .httpStatus(let status): return "题目分析接口返回 HTTP \(status)。"
        case .emptyResponse: return "题目分析接口没有返回内容。"
        case .invalidResponse: return "题目分析接口返回的 JSON 结构不符合约定。"
        case .invalidCategory(let subject, let section, let chapter):
            return "题目分析接口返回了分类表之外的分类：\(subject) / \(section) / \(chapter)。"
        case .invalidQuestionType: return "题目分析接口返回了不支持的题型。"
        case .emptyKnowledgeCards: return "题目分析接口没有返回可背诵知识点。"
        }
    }
}

public final class QuestionContentService: @unchecked Sendable {
    private let endpoint: URL
    private let accessKey: String
    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    public convenience init(endpoint: URL, accessKey: String, model: String, timeout: TimeInterval = 45) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.init(
            endpoint: endpoint,
            accessKey: accessKey,
            model: model,
            timeout: timeout,
            session: URLSession(configuration: configuration)
        )
    }

    init(endpoint: URL, accessKey: String, model: String, timeout: TimeInterval, session: URLSession) {
        self.endpoint = endpoint
        self.accessKey = accessKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    public func analyze(_ input: QuestionContentInput) throws -> QuestionContentResult {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.isLocalEndpoint(endpoint))
        else { throw QuestionContentServiceError.invalidEndpoint }

        let bodyData = try Self.makeRequestBody(input: input, model: model)

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !accessKey.isEmpty {
            request.setValue("Bearer \(accessKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var receivedData: Data?
        var receivedResponse: URLResponse?
        var receivedError: Error?
        session.dataTask(with: request) { data, response, error in
            lock.lock()
            receivedData = data
            receivedResponse = response
            receivedError = error
            lock.unlock()
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + timeout + 2) == .success else {
            throw QuestionContentServiceError.transport("请求超时")
        }
        lock.lock()
        let data = receivedData
        let response = receivedResponse
        let error = receivedError
        lock.unlock()
        if let error { throw QuestionContentServiceError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw QuestionContentServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuestionContentServiceError.httpStatus(http.statusCode)
        }
        guard let data, !data.isEmpty else { throw QuestionContentServiceError.emptyResponse }
        return try Self.decodeAndValidate(data)
    }

    static func makeRequestBody(input: QuestionContentInput, model: String) throws -> Data {
        let inputData = try JSONEncoder().encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": inputJSON]
            ],
            "max_tokens": 8_000,
            "response_format": ["type": "json_object"]
        ]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            body["model"] = normalizedModel
            if normalizedModel.hasPrefix("deepseek-v4-") {
                body["thinking"] = ["type": "enabled"]
                body["reasoning_effort"] = "high"
            } else {
                body["temperature"] = 0.1
            }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func inputHash(_ input: QuestionContentInput) -> String {
        struct HashPayload: Codable {
            let question: String
            let options: [String]
            let knownAnswer: String?
            let existingExplanation: String?
            let requiresSolution: Bool
            let subjectHint: String?
        }
        let payload = HashPayload(
            question: input.question,
            options: input.options,
            knownAnswer: input.knownAnswer,
            existingExplanation: input.existingExplanation,
            requiresSolution: input.requiresSolution,
            subjectHint: input.subjectHint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(payload)) ?? Data()
        data.append(Data("|taxonomy:\(MedicalCurriculumTaxonomy.version)|knowledge-contract:4".utf8))
        if input.forceCompleteExplanation {
            data.append(Data("|force-complete-explanation:1".utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func decodeAndValidate(_ data: Data) throws -> QuestionContentResult {
        let decoder = JSONDecoder()
        var candidateData = data

        if (try? decoder.decode(QuestionContentResult.self, from: candidateData)) == nil {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = extractTextContent(from: root)
            else { throw QuestionContentServiceError.invalidResponse }
            let cleaned = stripJSONFence(content)
            guard let nested = cleaned.data(using: .utf8) else {
                throw QuestionContentServiceError.invalidResponse
            }
            candidateData = nested
        }

        guard var result = try? decoder.decode(QuestionContentResult.self, from: candidateData) else {
            throw QuestionContentServiceError.invalidResponse
        }
        result = normalized(result)
        let categoryIsValid: Bool
        switch result.subject {
        case .medicalComprehensive:
            categoryIsValid = MedicalCurriculumTaxonomy.contains(
                section: result.curriculumSection,
                chapter: result.curriculumChapter
            )
        case .politics:
            categoryIsValid = PoliticalCurriculumTaxonomy.contains(
                section: result.curriculumSection,
                chapter: result.curriculumChapter
            )
        case .english:
            categoryIsValid = EnglishCurriculumTaxonomy.contains(
                section: result.curriculumSection,
                chapter: result.curriculumChapter
            )
        }
        guard categoryIsValid else {
            throw QuestionContentServiceError.invalidCategory(
                subject: result.subject.displayName,
                section: result.curriculumSection,
                chapter: result.curriculumChapter
            )
        }
        guard ["单选题", "多选题", "判断题", "论述题"].contains(result.questionType) else {
            throw QuestionContentServiceError.invalidQuestionType
        }
        if result.questionType == "论述题", result.subject != .politics {
            throw QuestionContentServiceError.invalidQuestionType
        }
        guard !result.knowledgeCards.isEmpty else {
            throw QuestionContentServiceError.emptyKnowledgeCards
        }
        return result
    }

    private static var systemPrompt: String {
        """
        你是成人高考专升本题目整理接口。只返回一个 JSON 对象，不要 Markdown、标题、说明或代码围栏。

        科目只能选择“医学综合”“政治”“英语”。分类只能从对应科目的固定范围中各选一个一级部分和对应章节：
        【医学综合】
        \(MedicalCurriculumTaxonomy.promptText)
        【政治】
        \(PoliticalCurriculumTaxonomy.promptText)
        【英语】
        \(EnglishCurriculumTaxonomy.promptText)

        返回结构：
        {"subject":"医学综合|政治|英语","curriculum_section":"对应科目的固定一级部分","curriculum_chapter":"对应科目的固定章节","question_type":"单选题|多选题|判断题|论述题","knowledge_cards":[{"title":"可背诵知识点标题","memory_text":"直接陈述应记住的完整事实","pitfalls":["容易混淆但有学习价值的辨析"]}],"resolved_answer":null,"resolved_explanation":null}

        规则：
        1. 每题提炼 1 至 3 个知识卡。memory_text 必须是可脱离题目直接背诵的完整知识说明，通常使用 2 至 5 个陈述句；按内容需要写清定义、适用条件、机制或因果链、关键数值、典型表现以及容易混淆的边界，信息量应接近一段可靠解析，而不是只给一句结论。
        2. 不输出题号、截图信息、错误次数、学习建议、鼓励语、置信度、免责声明或生成过程。
        3. 已有答案和解析时以它们为主要依据，不改写已知正确答案；resolved_answer 和 resolved_explanation 返回 null。
        4. requires_solution 为 true 时，独立解题；客观题的 resolved_answer 返回选项字母，resolved_explanation 返回简明、可核对的基础解析。论述题的 resolved_answer 返回 null，resolved_explanation 只能给出参考作答内容；如果输入里没有原题评分标准，不得生成分值、权重或伪称它们来自原解析，后续评分应等待真实评分标准。
        5. subject_hint 只是本地初步判断，可用于参考但不能替代题目内容；必须返回你最终判断的科目。
        6. 不确定时仍必须选择最接近的固定分类，但不得编造不存在的科目或分类名称。
        7. 只有政治主观题可标记为“论述题”。论述题没有选项；保留已有参考答案或解析，不自行生成或改写分值权重。
        8. force_complete_explanation 为 true 时，这是一次性解析修复：即使 known_answer 已存在，也必须在 resolved_explanation 返回完整、可独立阅读的解析。客观题需说明正确项依据及主要错误项为什么不成立；只写答案、照抄选项或返回 null 均不合格。内容只服务于本题学习，不添加寒暄、免责声明或无关延伸。
        """
    }

    private static func extractTextContent(from root: [String: Any]) -> String? {
        if let text = root["output_text"] as? String { return text }
        if let result = root["result"] as? String { return result }
        if let choices = root["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let data = root["data"] as? [String: Any],
           let content = data["content"] as? String {
            return content
        }
        return nil
    }

    private static func stripJSONFence(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") { text.removeFirst(7) }
        else if text.hasPrefix("```") { text.removeFirst(3) }
        if text.hasSuffix("```") { text.removeLast(3) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: QuestionContentResult) -> QuestionContentResult {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cards = value.knowledgeCards.prefix(3).compactMap { card -> StudyKnowledgeCard? in
            let title = trim(card.title)
            let memory = trim(card.memoryText)
            guard !title.isEmpty, !memory.isEmpty else { return nil }
            let pitfalls = card.pitfalls.map(trim).filter { !$0.isEmpty }
            return StudyKnowledgeCard(title: title, memoryText: memory, pitfalls: Array(pitfalls.prefix(3)))
        }
        var result = QuestionContentResult(
            subject: value.subject,
            curriculumSection: trim(value.curriculumSection),
            curriculumChapter: trim(value.curriculumChapter),
            questionType: trim(value.questionType),
            knowledgeCards: cards,
            resolvedAnswer: value.resolvedAnswer.map(trim).flatMap { $0.isEmpty ? nil : $0 },
            resolvedExplanation: value.resolvedExplanation.map(trim).flatMap { $0.isEmpty ? nil : $0 }
        )
        if let canonical = canonicalCategory(
            subject: result.subject,
            section: result.curriculumSection,
            chapter: result.curriculumChapter
        ) {
            result.curriculumSection = canonical.section
            result.curriculumChapter = canonical.chapter
        }
        return result
    }

    private static func canonicalCategory(
        subject: StudySubject,
        section: String,
        chapter: String
    ) -> (section: String, chapter: String)? {
        let sections: [MedicalCurriculumSection]
        switch subject {
        case .medicalComprehensive:
            sections = MedicalCurriculumTaxonomy.sections
        case .politics:
            sections = PoliticalCurriculumTaxonomy.sections
        case .english:
            sections = [MedicalCurriculumSection(name: "英语", chapters: EnglishCurriculumTaxonomy.sections)]
        }
        guard let canonicalSection = sections.first(where: {
            categoryComparisonKey($0.name, removingPartPrefix: true) ==
                categoryComparisonKey(section, removingPartPrefix: true)
        }), let canonicalChapter = canonicalSection.chapters.first(where: {
            categoryComparisonKey($0, removingPartPrefix: false) ==
                categoryComparisonKey(chapter, removingPartPrefix: false)
        }) else { return nil }
        return (canonicalSection.name, canonicalChapter)
    }

    private static func categoryComparisonKey(_ value: String, removingPartPrefix: Bool) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if removingPartPrefix, text.hasPrefix("第"), let range = text.range(of: "部分") {
            text = String(text[range.upperBound...])
        }
        let scalars = text.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
