import Foundation
import OSLog

enum CaptureDiagnosticLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

enum CaptureDiagnosticLogger {
    private static let unifiedLogger = Logger(
        subsystem: "com.guiming.wrong-question-daily-organizer",
        category: "Capture"
    )
    private static let fileQueue = DispatchQueue(
        label: "com.guiming.wrong-question-daily-organizer.capture-log"
    )

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/错题每日自动化整理", isDirectory: true)
            .appendingPathComponent("capture.log")
    }

    static func record(
        _ level: CaptureDiagnosticLevel,
        event: String,
        fields: [String: String] = [:]
    ) {
        let fieldText = fields.keys.sorted().map { key in
            "\(safe(key))=\(safe(fields[key] ?? ""))"
        }.joined(separator: "\t")
        let message = fieldText.isEmpty ? event : "\(event)\t\(fieldText)"

        switch level {
        case .info:
            unifiedLogger.info("\(message, privacy: .public)")
        case .warning:
            unifiedLogger.warning("\(message, privacy: .public)")
        case .error:
            unifiedLogger.error("\(message, privacy: .public)")
        }

        fileQueue.async {
            do {
                var url = try ensureLogFile()
                if try shouldRotate(url) {
                    let archivedURL = url.appendingPathExtension("1")
                    try? FileManager.default.removeItem(at: archivedURL)
                    try FileManager.default.moveItem(at: url, to: archivedURL)
                    url = try ensureLogFile()
                }
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let line = "\(timestamp)\t\(level.rawValue)\t\(message)\n"
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } catch {
                unifiedLogger.error("capture_log_write_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func flush() {
        fileQueue.sync {}
    }

    @discardableResult
    static func ensureLogFile() throws -> URL {
        let fileManager = FileManager.default
        let url = logURL
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw NSError(
                    domain: "CaptureDiagnosticLogger",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "无法创建采集日志文件。"]
                )
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func shouldRotate(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return size >= 5 * 1_024 * 1_024
    }

    private static func safe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
