import Foundation

public struct SharedContentServiceConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var endpoint: String
    public var model: String
    public var accessKey: String
    public var knowledgeDocumentFolderPath: String

    public init(
        enabled: Bool = false,
        endpoint: String = "",
        model: String = "",
        accessKey: String = "",
        knowledgeDocumentFolderPath: String = SharedContentServiceConfiguration.defaultDocumentFolderPath
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.model = model
        self.accessKey = accessKey
        self.knowledgeDocumentFolderPath = knowledgeDocumentFolderPath
    }

    public static var defaultDocumentFolderPath: String {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Pictures/错题截图/题本", isDirectory: true)
            .standardizedFileURL.path
    }

    public func normalized() -> SharedContentServiceConfiguration {
        var value = self
        value.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.accessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        value.knowledgeDocumentFolderPath = URL(
            fileURLWithPath: knowledgeDocumentFolderPath.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: true
        ).standardizedFileURL.path
        return value
    }

    public func validate() throws {
        let value = normalized()
        guard !value.knowledgeDocumentFolderPath.isEmpty else {
            throw SharedContentServiceConfigurationError.invalidDocumentFolder
        }
        guard value.enabled else { return }
        guard let url = URL(string: value.endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.isLocalEndpoint(url))
        else { throw SharedContentServiceConfigurationError.invalidEndpoint }
        guard !value.accessKey.isEmpty else {
            throw SharedContentServiceConfigurationError.missingAccessKey
        }
    }

    private static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public enum SharedContentServiceConfigurationError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingAccessKey
    case invalidDocumentFolder

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "启用题目分析 API 时必须填写 HTTPS 接口地址；本机接口可使用 HTTP。"
        case .missingAccessKey:
            return "启用题目分析 API 时必须填写访问密钥。"
        case .invalidDocumentFolder:
            return "知识点 Word 保存位置不能为空。"
        }
    }
}

public enum SharedContentServiceConfigurationStore {
    private struct LegacyCredential: Codable { let accessKey: String }
    private static let directoryName = "错题每日自动化整理"
    private static let fileName = "content-service-settings.json"

    public static func load(fileManager: FileManager = .default) -> SharedContentServiceConfiguration {
        if let data = try? Data(contentsOf: configurationFileURL(fileManager: fileManager)),
           let value = try? JSONDecoder().decode(SharedContentServiceConfiguration.self, from: data) {
            return value.normalized()
        }
        let migrated = legacyConfiguration(fileManager: fileManager)
        try? save(migrated, fileManager: fileManager)
        return migrated
    }

    public static func save(
        _ configuration: SharedContentServiceConfiguration,
        fileManager: FileManager = .default
    ) throws {
        let value = configuration.normalized()
        try value.validate()
        let fileURL = try configurationFileURL(fileManager: fileManager)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: value.knowledgeDocumentFolderPath, isDirectory: true),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public static func configurationFileURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func legacyConfiguration(fileManager: FileManager) -> SharedContentServiceConfiguration {
        let standard = UserDefaults.standard
        let suite = UserDefaults(suiteName: "com.guiming.wrong-question-daily-organizer")
        let fallback = SharedContentServiceConfiguration()
        let value: (String) -> String? = { key in
            let standardValue = standard.string(forKey: key)
            return standardValue?.isEmpty == false ? standardValue : suite?.string(forKey: key)
        }
        let output = value("outputFolderPath")
        let enabled: Bool
        if standard.object(forKey: "contentServiceEnabled") != nil {
            enabled = standard.bool(forKey: "contentServiceEnabled")
        } else {
            enabled = suite?.bool(forKey: "contentServiceEnabled") ?? false
        }
        let credentialURL = (try? configurationFileURL(fileManager: fileManager))?
            .deletingLastPathComponent()
            .appendingPathComponent("content-service-credential.json", isDirectory: false)
        let key = credentialURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(LegacyCredential.self, from: $0).accessKey } ?? ""
        return SharedContentServiceConfiguration(
            enabled: enabled,
            endpoint: value("contentServiceEndpoint") ?? fallback.endpoint,
            model: value("contentServiceModel") ?? fallback.model,
            accessKey: key,
            knowledgeDocumentFolderPath: output?.isEmpty == false ? output! : fallback.knowledgeDocumentFolderPath
        ).normalized()
    }
}
