import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct EssayCriterionGrade: Codable, Equatable, Sendable {
    public var title: String
    public var passed: Bool
    public var awardedScore: Int
    public var maximumScore: Int
    public var comment: String

    enum CodingKeys: String, CodingKey {
        case title
        case passed
        case awardedScore = "awarded_score"
        case maximumScore = "maximum_score"
        case comment
    }
}

public struct EssayGradingResult: Codable, Equatable, Sendable {
    public var score: Int
    public var maximumScore: Int
    public var passed: Bool
    public var gradingBasisFound: Bool
    public var criteria: [EssayCriterionGrade]
    public var summary: String

    enum CodingKeys: String, CodingKey {
        case score
        case maximumScore = "maximum_score"
        case passed
        case gradingBasisFound = "grading_basis_found"
        case criteria
        case summary
    }
}

public struct EssayGradingInput: Codable, Equatable, Sendable {
    public var question: String
    public var referenceExplanation: String
    public var answer: String

    enum CodingKeys: String, CodingKey {
        case question
        case referenceExplanation = "reference_explanation"
        case answer
    }

    public init(
        question: String,
        referenceExplanation: String,
        answer: String
    ) {
        self.question = question
        self.referenceExplanation = referenceExplanation
        self.answer = answer
    }
}

public enum EssayGradingServiceError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidInput(String)
    case transport(String)
    case httpStatus(Int)
    case missingGradingBasis
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "论述题评分接口地址无效。"
        case .invalidInput(let message): return message
        case .transport(let message): return "论述题评分接口连接失败：\(message)"
        case .httpStatus(let status): return "论述题评分接口返回 HTTP \(status)。"
        case .missingGradingBasis: return "原解析中没有识别到明确的考点分值，本次作答尚未保存。"
        case .invalidResponse: return "论述题评分接口返回的评分结构无效，本次作答尚未保存。"
        }
    }
}

public final class EssayGradingService: @unchecked Sendable {
    private let endpoint: URL
    private let accessKey: String
    private let model: String
    private let session: URLSession

    public init(
        endpoint: URL,
        accessKey: String,
        model: String,
        timeout: TimeInterval = 90,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.accessKey = accessKey
        self.model = model
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func grade(_ input: EssayGradingInput) throws -> EssayGradingResult {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.isLocalEndpoint(endpoint))
        else { throw EssayGradingServiceError.invalidEndpoint }
        guard !input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.referenceExplanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw EssayGradingServiceError.invalidInput("论述题缺少题干、参考解析、评分标准或作答内容。") }
        let expectedMaximumScores = Self.explicitScoreWeights(in: input.referenceExplanation)
        guard !expectedMaximumScores.isEmpty else {
            throw EssayGradingServiceError.missingGradingBasis
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !accessKey.isEmpty { request.setValue("Bearer \(accessKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try Self.requestBody(input: input, model: model)

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
        semaphore.wait()
        if let receivedError { throw EssayGradingServiceError.transport(receivedError.localizedDescription) }
        if let response = receivedResponse as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw EssayGradingServiceError.httpStatus(response.statusCode)
        }
        guard let data = receivedData else { throw EssayGradingServiceError.invalidResponse }
        return try Self.decodeAndValidate(data, expectedMaximumScores: expectedMaximumScores)
    }

    static func requestBody(input: EssayGradingInput, model: String) throws -> Data {
        let inputData = try JSONEncoder().encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": inputJSON]
            ],
            "max_tokens": 6_000,
            "response_format": ["type": "json_object"]
        ]
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedModel.isEmpty { body["model"] = normalizedModel }
        if normalizedModel.hasPrefix("deepseek-v4-") {
            body["thinking"] = ["type": "enabled"]
            body["reasoning_effort"] = "high"
        } else {
            body["temperature"] = 0.1
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func decodeAndValidate(
        _ data: Data,
        expectedMaximumScores: [Int]? = nil
    ) throws -> EssayGradingResult {
        let decoder = JSONDecoder()
        var candidate = data
        if (try? decoder.decode(EssayGradingResult.self, from: candidate)) == nil {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = extractTextContent(root),
                  let nested = stripJSONFence(text).data(using: .utf8)
            else { throw EssayGradingServiceError.invalidResponse }
            candidate = nested
        }
        guard var result = try? decoder.decode(EssayGradingResult.self, from: candidate)
        else { throw EssayGradingServiceError.invalidResponse }
        guard result.gradingBasisFound else { throw EssayGradingServiceError.missingGradingBasis }
        guard
              result.maximumScore > 0,
              (0...result.maximumScore).contains(result.score),
              !result.criteria.isEmpty
        else { throw EssayGradingServiceError.invalidResponse }

        guard result.criteria.allSatisfy({
                  $0.maximumScore > 0 && $0.awardedScore >= 0 && $0.awardedScore <= $0.maximumScore &&
                      !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !$0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      (!$0.passed || Double($0.awardedScore) / Double($0.maximumScore) >= 0.6)
              }),
              result.criteria.reduce(0, { $0 + $1.maximumScore }) == result.maximumScore,
              result.criteria.reduce(0, { $0 + $1.awardedScore }) == result.score,
              (!result.passed || Double(result.score) / Double(result.maximumScore) >= 0.6)
        else { throw EssayGradingServiceError.invalidResponse }
        if let expectedMaximumScores {
            guard !expectedMaximumScores.isEmpty,
                  result.criteria.map(\.maximumScore) == expectedMaximumScores,
                  expectedMaximumScores.reduce(0, +) == result.maximumScore
            else { throw EssayGradingServiceError.invalidResponse }
        }
        result.summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.summary.isEmpty else { throw EssayGradingServiceError.invalidResponse }
        return result
    }

    /// Extracts the score attached to every explicitly numbered scoring point.
    /// If the source uses an unnumbered list, every non-total “N分” marker is retained.
    static func explicitScoreWeights(in explanation: String) -> [Int] {
        let normalized = explanation
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let source = normalized as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let numeral = #"(?:[0-9]{1,3}|[一二三四五六七八九十]{1,3})"#
        let pointPattern = #"(?m)(?:^|\n)\s*(?:[（(]\s*"# + numeral + #"\s*[）)]|"# + numeral + #"\s*[、.．])|[（(]\s*"# + numeral + #"\s*[）)]"#
        let pointRegex = try? NSRegularExpression(pattern: pointPattern)
        let markers = pointRegex?.matches(in: normalized, range: fullRange) ?? []

        let ranges: [NSRange]
        if markers.isEmpty {
            ranges = [fullRange]
        } else {
            ranges = markers.enumerated().map { index, marker in
                let end = index + 1 < markers.count ? markers[index + 1].range.location : fullRange.length
                return NSRange(location: marker.range.location, length: max(0, end - marker.range.location))
            }
        }

        let scoreRegex = try? NSRegularExpression(
            pattern: #"([0-9]{1,3}|[一二三四五六七八九十]{1,3})\s*分"#
        )
        var weights: [Int] = []
        for range in ranges {
            for match in scoreRegex?.matches(in: normalized, range: range) ?? [] {
                let contextStart = max(range.location, match.range.location - 12)
                let context = source.substring(
                    with: NSRange(location: contextStart, length: match.range.location - contextStart)
                )
                if ["本题", "总分", "满分", "合计", "共计"].contains(where: context.contains) {
                    continue
                }
                let rawValue = source.substring(with: match.range(at: 1))
                if let value = scoreValue(rawValue), value > 0 {
                    weights.append(value)
                }
            }
        }
        return weights
    }

    private static func scoreValue(_ rawValue: String) -> Int? {
        if let value = Int(rawValue) { return value }
        let values: [Character: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if rawValue == "十" { return 10 }
        let characters = Array(rawValue)
        if let tenIndex = characters.firstIndex(of: "十") {
            let tens = tenIndex == characters.startIndex ? 1 : (values[characters[tenIndex - 1]] ?? 0)
            let nextIndex = characters.index(after: tenIndex)
            let ones = nextIndex < characters.endIndex ? (values[characters[nextIndex]] ?? 0) : 0
            return tens * 10 + ones
        }
        return characters.count == 1 ? values[characters[0]] : nil
    }

    private static let systemPrompt = """
    你是成人高考专升本政治论述题阅卷接口。请在内部充分思考后，只返回一个 JSON 对象，不要输出思考过程、Markdown 或代码围栏。

    你会收到题干、含评分标准的参考答案或解析，以及考生自由作答。必须以原解析明确标出的考点和分值为最高依据，按现实阅卷中的同义表达、准确含义和论证完整度评分，不能只因为出现孤立关键词就给分，也不能因为措辞与参考答案不同就扣除本应获得的分数。

    返回结构：
    {"score":整数,"maximum_score":解析中本题总分,"passed":true或false,"grading_basis_found":true或false,"criteria":[{"title":"解析中的考点","passed":true或false,"awarded_score":整数,"maximum_score":解析中该点分值,"comment":"一句可核对的判定依据"}],"summary":"总评"}

    规则：
    1. 只提取并使用 reference_explanation 中明确存在的考点与分值，按原文出现顺序逐项返回；严禁自行生成、补齐、合并、拆分或重新分配权重。maximum_score 必须等于原解析各评分点之和。
    2. 根据答案是否准确表达该考点及必要关系给 0 分、部分分或满分；各 criterion.maximum_score 之和必须等于 maximum_score，各 awarded_score 之和必须等于 score。
    3. 每个评分点 awarded_score 达到该点 maximum_score 的 60% 时，该点 passed=true，否则为 false。
    4. 得分率达到 60% 且没有严重原理性错误时 passed=true；否则为 false。
    5. comment 只说明答案体现了什么或缺少什么，不泄露隐藏思考过程。
    6. 如果原解析没有可识别的明确分值标准，grading_basis_found=false，criteria 返回空数组，score 和 maximum_score 均返回 0；不得临时编造评分权重。
    """

    private static func extractTextContent(_ root: [String: Any]) -> String? {
        if let text = root["output_text"] as? String { return text }
        if let result = root["result"] as? String { return result }
        if let choices = root["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            return message["content"] as? String
        }
        return (root["data"] as? [String: Any])?["content"] as? String
    }

    private static func stripJSONFence(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") { text.removeFirst(7) }
        else if text.hasPrefix("```") { text.removeFirst(3) }
        if text.hasSuffix("```") { text.removeLast(3) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
