import Foundation
import QuestionBankCore

enum CaptureShortcut: String, CaseIterable {
    case rightShift
    case controlOptionShift2
    case controlOptionShiftS
    case optionShiftS

    var title: String {
        switch self {
        case .rightShift: return "单独轻点右 Shift（推荐）"
        case .controlOptionShift2: return "Control + Option + Shift + 2"
        case .controlOptionShiftS: return "Control + Option + Shift + S"
        case .optionShiftS: return "Option + Shift + S"
        }
    }

    var menuTitle: String {
        switch self {
        case .rightShift: return "轻点右⇧"
        case .controlOptionShift2: return "⌃⌥⇧2"
        case .controlOptionShiftS: return "⌃⌥⇧S"
        case .optionShiftS: return "⌥⇧S"
        }
    }
}

enum RecognitionMode: String, CaseIterable {
    case fentiQuestionBank
    case general

    var title: String {
        switch self {
        case .fentiQuestionBank: return "焚题库专项优化（推荐）"
        case .general: return "通用识别"
        }
    }

    var detail: String {
        switch self {
        case .fentiQuestionBank:
            return "按焚题库页面区域识别，并清除导航、答题卡、异常选项前缀及重复题干。"
        case .general:
            return "保留更完整的窗口区域，只使用通用题干、选项和答案解析规则。"
        }
    }
}

struct AppSettings {
    private enum Key {
        static let captureFolderPath = "captureFolderPath"
        static let outputFolderPath = "outputFolderPath"
        static let captureShortcut = "captureShortcut"
        static let recognitionMode = "recognitionMode"
        static let contentServiceEnabled = "contentServiceEnabled"
        static let contentServiceEndpoint = "contentServiceEndpoint"
        static let contentServiceModel = "contentServiceModel"
        static let generateWordDocuments = "generateWordDocuments"
        static let dailyOrganizeEnabled = "dailyOrganizeEnabled"
        static let initialized = "settingsInitializedV3"
        static let questionBookTerminologyMigrated = "questionBookTerminologyMigratedV1"
    }

    var captureFolderPath: String
    var outputFolderPath: String
    var captureShortcut: CaptureShortcut
    var recognitionMode: RecognitionMode
    var contentServiceEnabled: Bool
    var contentServiceEndpoint: String
    var contentServiceModel: String
    var contentServiceAccessKey: String
    var generateWordDocuments: Bool
    var dailyOrganizeEnabled: Bool

    static var defaults: AppSettings {
        let capture = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Pictures/错题截图", isDirectory: true)
            .standardizedFileURL.path
        return AppSettings(
            captureFolderPath: capture,
            outputFolderPath: URL(fileURLWithPath: capture)
                .appendingPathComponent("题本", isDirectory: true).path,
            captureShortcut: .rightShift,
            recognitionMode: .fentiQuestionBank,
            contentServiceEnabled: false,
            contentServiceEndpoint: "",
            contentServiceModel: "",
            contentServiceAccessKey: "",
            generateWordDocuments: false,
            dailyOrganizeEnabled: true
        )
    }

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        let fallback = AppSettings.defaults
        let shared = SharedContentServiceConfigurationStore.load()
        guard defaults.bool(forKey: Key.initialized) else {
            var value = fallback
            value.contentServiceEnabled = shared.enabled
            value.contentServiceEndpoint = shared.endpoint
            value.contentServiceModel = shared.model
            value.contentServiceAccessKey = shared.accessKey
            value.outputFolderPath = shared.knowledgeDocumentFolderPath
            return value.normalized()
        }
        let storedCapture = defaults.string(forKey: Key.captureFolderPath) ?? ""
        let storedOutput = defaults.string(forKey: Key.outputFolderPath) ?? ""
        let captureFolderPath = storedCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback.captureFolderPath : storedCapture
        var outputFolderPath = storedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback.outputFolderPath : storedOutput
        if !defaults.bool(forKey: Key.questionBookTerminologyMigrated) {
            let legacyDefaultPath = URL(fileURLWithPath: captureFolderPath, isDirectory: true)
                .appendingPathComponent("错题本", isDirectory: true)
                .standardizedFileURL.path
            let wasLegacyDefault = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
                .standardizedFileURL.path == legacyDefaultPath
            outputFolderPath = migrateLegacyQuestionBookLocation(
                captureFolderPath: captureFolderPath,
                outputFolderPath: outputFolderPath
            )
            defaults.set(outputFolderPath, forKey: Key.outputFolderPath)
            defaults.set(
                !wasLegacyDefault || outputFolderPath != legacyDefaultPath,
                forKey: Key.questionBookTerminologyMigrated
            )
        }
        if !shared.knowledgeDocumentFolderPath.isEmpty {
            outputFolderPath = shared.knowledgeDocumentFolderPath
        }
        return AppSettings(
            captureFolderPath: captureFolderPath,
            outputFolderPath: outputFolderPath,
            captureShortcut: CaptureShortcut(rawValue: defaults.string(forKey: Key.captureShortcut) ?? "") ?? .rightShift,
            recognitionMode: RecognitionMode(rawValue: defaults.string(forKey: Key.recognitionMode) ?? "") ?? .fentiQuestionBank,
            contentServiceEnabled: shared.enabled,
            contentServiceEndpoint: shared.endpoint,
            contentServiceModel: shared.model,
            contentServiceAccessKey: shared.accessKey,
            generateWordDocuments: defaults.bool(forKey: Key.generateWordDocuments),
            dailyOrganizeEnabled: defaults.object(forKey: Key.dailyOrganizeEnabled) as? Bool ?? true
        ).normalized()
    }

    func save() throws {
        let value = normalized()
        try value.ensureFoldersExist()
        let defaults = UserDefaults.standard
        defaults.set(value.captureFolderPath, forKey: Key.captureFolderPath)
        defaults.set(value.outputFolderPath, forKey: Key.outputFolderPath)
        defaults.set(value.captureShortcut.rawValue, forKey: Key.captureShortcut)
        defaults.set(value.recognitionMode.rawValue, forKey: Key.recognitionMode)
        defaults.set(value.contentServiceEnabled, forKey: Key.contentServiceEnabled)
        defaults.set(value.contentServiceEndpoint, forKey: Key.contentServiceEndpoint)
        defaults.set(value.contentServiceModel, forKey: Key.contentServiceModel)
        try SharedContentServiceConfigurationStore.save(
            SharedContentServiceConfiguration(
                enabled: value.contentServiceEnabled,
                endpoint: value.contentServiceEndpoint,
                model: value.contentServiceModel,
                accessKey: value.contentServiceAccessKey,
                knowledgeDocumentFolderPath: value.outputFolderPath
            )
        )
        defaults.set(value.generateWordDocuments, forKey: Key.generateWordDocuments)
        defaults.set(value.dailyOrganizeEnabled, forKey: Key.dailyOrganizeEnabled)
        defaults.set(true, forKey: Key.initialized)
    }

    func normalized() -> AppSettings {
        var value = self
        value.captureFolderPath = Self.normalizePath(captureFolderPath)
        value.outputFolderPath = Self.normalizePath(outputFolderPath)
        value.contentServiceEndpoint = contentServiceEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        value.contentServiceModel = contentServiceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        value.contentServiceAccessKey = contentServiceAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    func ensureFoldersExist() throws {
        guard !captureFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !outputFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "AppSettings", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "截图和文档保存位置不能为空。"])
        }
        try FileManager.default.createDirectory(at: captureFolderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputFolderURL, withIntermediateDirectories: true)
        if contentServiceEnabled {
            guard let url = URL(string: contentServiceEndpoint),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || (scheme == "http" && Self.isLocalEndpoint(url))
            else {
                throw NSError(
                    domain: "AppSettings",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "启用题目分析 API 时必须填写 HTTPS 接口地址；本机接口可使用 HTTP。"]
                )
            }
            guard !contentServiceAccessKey.isEmpty else {
                throw NSError(
                    domain: "AppSettings",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "启用题目分析 API 时必须填写访问密钥。"]
                )
            }
        }
    }

    var captureFolderURL: URL { URL(fileURLWithPath: captureFolderPath, isDirectory: true).standardizedFileURL }
    var outputFolderURL: URL { URL(fileURLWithPath: outputFolderPath, isDirectory: true).standardizedFileURL }

    private static func normalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func migrateLegacyQuestionBookLocation(
        captureFolderPath: String,
        outputFolderPath: String,
        fileManager: FileManager = .default
    ) -> String {
        let capture = URL(fileURLWithPath: captureFolderPath, isDirectory: true).standardizedFileURL
        let current = URL(fileURLWithPath: outputFolderPath, isDirectory: true).standardizedFileURL
        let legacy = capture.appendingPathComponent("错题本", isDirectory: true).standardizedFileURL
        guard current.path == legacy.path else { return current.path }

        let questionBook = capture.appendingPathComponent("题本", isDirectory: true).standardizedFileURL
        do {
            if fileManager.fileExists(atPath: legacy.path) {
                guard !fileManager.fileExists(atPath: questionBook.path) else { return current.path }
                try fileManager.moveItem(at: legacy, to: questionBook)
            } else {
                try fileManager.createDirectory(at: questionBook, withIntermediateDirectories: true)
            }
        } catch {
            return current.path
        }
        try? renameLegacyGeneratedFiles(in: questionBook, fileManager: fileManager)
        return questionBook.path
    }

    private static func renameLegacyGeneratedFiles(in folder: URL, fileManager: FileManager) throws {
        let replacements = [
            "医学综合错题题库.xlsx": "医学综合题本.xlsx",
            "医学综合错题本_纯题.docx": "医学综合题本_纯题.docx",
            "医学综合错题本_答案与解析.docx": "医学综合题本_答案与解析.docx"
        ]
        for (legacyName, questionBookName) in replacements {
            let source = folder.appendingPathComponent(legacyName, isDirectory: false)
            let destination = folder.appendingPathComponent(questionBookName, isDirectory: false)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path)
            else { continue }
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}
