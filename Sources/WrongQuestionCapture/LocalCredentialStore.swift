import Foundation

enum LocalCredentialStore {
    private struct StoredCredential: Codable {
        let version: Int
        let accessKey: String
    }

    private static let directoryName = "错题每日自动化整理"
    private static let fileName = "content-service-credential.json"

    static func loadAccessKey() -> String {
        do {
            let data = try Data(contentsOf: credentialFileURL())
            return try JSONDecoder().decode(StoredCredential.self, from: data).accessKey
        } catch {
            return ""
        }
    }

    static func saveAccessKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default
        let fileURL = try credentialFileURL(fileManager: fileManager)
        if trimmed.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let data = try JSONEncoder().encode(StoredCredential(version: 1, accessKey: trimmed))
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func credentialFileURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
