import Foundation

public struct ScreenshotBatchArchiveReport: Equatable, Sendable {
    public let archiveURL: URL
    public let archivedImageCount: Int

    public init(archiveURL: URL, archivedImageCount: Int) {
        self.archiveURL = archiveURL
        self.archivedImageCount = archivedImageCount
    }
}

public final class ScreenshotBatchArchiver {
    public static let archiveFolderName = "已整理截图归档"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func archive(
        imageURLs: [URL],
        captureRoot: URL,
        archivedAt: Date = Date()
    ) throws -> ScreenshotBatchArchiveReport? {
        guard !imageURLs.isEmpty else { return nil }

        let root = captureRoot.standardizedFileURL
        let rootPrefix = root.path + "/"
        let sources = try imageURLs.map { source -> (url: URL, relativePath: String) in
            let normalized = source.standardizedFileURL
            guard normalized.path.hasPrefix(rootPrefix),
                  fileManager.fileExists(atPath: normalized.path)
            else {
                throw archiveError("待封存内容不在采集目录内或已经不存在：\(source.lastPathComponent)")
            }
            let relative = String(normalized.path.dropFirst(rootPrefix.count))
            guard !relative.isEmpty,
                  !relative.hasPrefix(Self.archiveFolderName + "/")
            else { throw archiveError("不能重复封存归档目录中的图片。") }
            return (normalized, relative)
        }
        var payloadSources = sources
        for source in sources {
            guard !PageSnapshotSidecar.isStandaloneSnapshotURL(source.url) else { continue }
            let sidecar = PageSnapshotSidecar.url(for: source.url).standardizedFileURL
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            let relative = String(sidecar.path.dropFirst(rootPrefix.count))
            payloadSources.append((sidecar, relative))
        }

        let archiveFolder = root.appendingPathComponent(Self.archiveFolderName, isDirectory: true)
        try fileManager.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        let workFolder = archiveFolder.appendingPathComponent(".正在封存-\(UUID().uuidString)", isDirectory: true)
        let payloadFolder = workFolder.appendingPathComponent("原始采集内容", isDirectory: true)
        let temporaryArchive = workFolder.appendingPathComponent("批次.zip")
        defer { try? fileManager.removeItem(at: workFolder) }
        try fileManager.createDirectory(at: payloadFolder, withIntermediateDirectories: true)

        for source in payloadSources {
            let destination = payloadFolder.appendingPathComponent(source.relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source.url, to: destination)
        }

        try run(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", payloadFolder.path, temporaryArchive.path],
            failurePrefix: "创建采集内容压缩包失败"
        )
        try run(
            executable: "/usr/bin/unzip",
            arguments: ["-tqq", temporaryArchive.path],
            failurePrefix: "采集内容压缩包完整性校验失败"
        )

        let finalArchive = uniqueArchiveURL(
            in: archiveFolder,
            archivedAt: archivedAt,
            imageCount: sources.count
        )
        try fileManager.moveItem(at: temporaryArchive, to: finalArchive)

        var removalFailures: [String] = []
        for source in payloadSources {
            do { try fileManager.removeItem(at: source.url) }
            catch { removalFailures.append("\(source.url.lastPathComponent)：\(error.localizedDescription)") }
        }
        guard removalFailures.isEmpty else {
            throw archiveError(
                "压缩包已安全生成，但有 \(removalFailures.count) 份原始采集内容未能移出待处理目录：\n" +
                    removalFailures.prefix(10).joined(separator: "\n")
            )
        }

        return ScreenshotBatchArchiveReport(
            archiveURL: finalArchive,
            archivedImageCount: sources.count
        )
    }

    private func uniqueArchiveURL(in folder: URL, archivedAt: Date, imageCount: Int) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let base = "\(formatter.string(from: archivedAt))_原始采集内容_\(imageCount)份"
        var candidate = folder.appendingPathComponent(base + ".zip")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_\(suffix).zip")
            suffix += 1
        }
        return candidate
    }

    private func run(executable: String, arguments: [String], failurePrefix: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw archiveError(detail.isEmpty ? failurePrefix : "\(failurePrefix)：\(detail)")
        }
    }

    private func archiveError(_ message: String) -> NSError {
        NSError(
            domain: "ScreenshotBatchArchiver",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
