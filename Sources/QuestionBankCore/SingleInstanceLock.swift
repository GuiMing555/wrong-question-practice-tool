import Darwin
import Foundation

public enum SingleInstanceLockError: LocalizedError {
    case cannotOpen(path: String, code: Int32)
    case cannotLock(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code):
            return "无法创建单实例验证文件：\(path)（错误码 \(code)）"
        case let .cannotLock(path, code):
            return "无法锁定单实例验证文件：\(path)（错误码 \(code)）"
        }
    }
}

public final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    /// Returns `nil` when another process already owns the same lock.
    public static func acquire(identifier: String) throws -> SingleInstanceLock? {
        let safeIdentifier = identifier.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "-"
        }
        let filename = String(safeIdentifier) + ".single-instance.lock"
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SingleInstanceLockError.cannotOpen(path: lockURL.path, code: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return nil
            }
            throw SingleInstanceLockError.cannotLock(path: lockURL.path, code: lockError)
        }
        return SingleInstanceLock(fileDescriptor: descriptor)
    }
}
