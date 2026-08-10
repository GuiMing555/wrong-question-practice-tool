import Foundation

public enum PageSnapshotSidecar {
    public static let pathExtension = "snapshot.txt"
    public static let standaloneSuffix = ".snapshot.txt"
    public static let maximumBytes = 2_000_000

    public static func url(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension(pathExtension)
    }

    public static func write(_ text: String, nextTo imageURL: URL) throws -> URL {
        let output = url(for: imageURL)
        try writeStandalone(text, to: output)
        return output
    }

    public static func writeStandalone(_ text: String, to outputURL: URL) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let data = normalized.data(using: .utf8) else {
            throw NSError(
                domain: "PageSnapshotSidecar",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "浏览器页面快照没有可保存的文字。"]
            )
        }
        guard data.count <= maximumBytes else {
            throw NSError(
                domain: "PageSnapshotSidecar",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "浏览器页面快照超过 2 MB，已拒绝保存。"]
            )
        }
        try data.write(to: outputURL, options: .atomic)
    }

    public static func isStandaloneSnapshotURL(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(standaloneSuffix)
    }

    public static func readStandalone(
        from snapshotURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard isStandaloneSnapshotURL(snapshotURL) else { return nil }
        return readTextFile(snapshotURL, fileManager: fileManager)
    }

    public static func read(nextTo imageURL: URL, fileManager: FileManager = .default) -> String? {
        let sidecar = url(for: imageURL)
        return readTextFile(sidecar, fileManager: fileManager)
    }

    private static func readTextFile(_ url: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
