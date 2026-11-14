import Foundation
import OSLog
import Synchronization

enum KeychainStoreError: Error, Equatable {
    case readFailed
    case saveFailed
    case deleteFailed
}

/// The API key in a 0600 file under Application Support (legacy name; not the macOS Keychain).
/// Access is serialized by a lock. Every load reads the file, so a corrupted or unreadable key is
/// reported instead of masked by an earlier read.
/// Unchecked because `FileManager` is not `Sendable`; every file access happens inside the lock.
final class KeychainStore: @unchecked Sendable {

    private static let defaultService = "org.syrup.SyrupApp"
    private static let defaultAccount = "apiKey"

    private let service: String
    private let account: String
    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let lock = Mutex(())
    private let logger: Logger

    init(
        service: String = KeychainStore.defaultService,
        account: String = KeychainStore.defaultAccount,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.service = service
        self.account = account
        self.fileManager = fileManager
        let rootDirectory = storageDirectory ?? Self.defaultStorageDirectory(fileManager: fileManager)
        self.directoryURL = rootDirectory.appendingPathComponent(Self.safePathComponent(service), isDirectory: true)
        self.fileURL = directoryURL
            .appendingPathComponent(Self.safePathComponent(account), isDirectory: false)
            .appendingPathExtension("secret")
        self.logger = Logger(subsystem: service, category: "APIKeyStore")
    }

    func save(_ key: String) throws {
        try lock.withLock { _ in try saveLocked(key) }
    }

    func load() throws -> String? {
        try lock.withLock { _ in try loadLocked() }
    }

    func delete() throws {
        try lock.withLock { _ in try deleteLocked() }
    }

    private func saveLocked(_ key: String) throws {
        do {
            try prepareDirectoryLocked()
            try Data(key.utf8).write(to: fileURL, options: .atomic)
            try setPOSIXPermissions(0o600, at: fileURL)
        } catch {
            logFileError("API key save failed", error: error)
            throw KeychainStoreError.saveFailed
        }
    }

    private func loadLocked() throws -> String? {
        do {
            let data = try Data(contentsOf: fileURL)
            guard let key = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.readFailed
            }
            return key
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            logFileError("API key load failed", error: error)
            throw KeychainStoreError.readFailed
        }
    }

    private func deleteLocked() throws {
        do {
            try fileManager.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        } catch {
            logFileError("API key delete failed", error: error)
            throw KeychainStoreError.deleteFailed
        }
    }

    private func prepareDirectoryLocked() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try setPOSIXPermissions(0o700, at: directoryURL.deletingLastPathComponent())
        try setPOSIXPermissions(0o700, at: directoryURL)
    }

    private func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func logFileError(_ message: StaticString, error: Error) {
        let nsError = error as NSError
        logger.error("\(message) with \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory
            .appendingPathComponent("Syrup", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
    }

    private static func safePathComponent(_ text: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: ".-_"))
        let sanitized = text
            .components(separatedBy: allowedCharacters.inverted)
            .filter { $0.isEmpty == false }
            .joined(separator: "_")
        return sanitized.isEmpty ? "default" : sanitized
    }
}
