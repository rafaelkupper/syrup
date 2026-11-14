import Foundation
import OSLog

/// Glossary learning used to keep dictation audio under `Recordings/` and a 626 MB comparison model
/// under `WhisperModels/`, both in Syrup's Application Support folder, behind the
/// `glossaryLearningEnabled` setting. The flow is gone. At each launch this deletes what it left, and
/// nothing else; a folder it cannot delete stays listed by `remainingFolders`, which Privacy shows.
enum RetiredGlossaryLearning {
    static let folders = ["Recordings", "WhisperModels"]
    static let settingKey = "glossaryLearningEnabled"
    private static let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "GlossaryLearning")

    /// Deletes both folders and the setting, and returns the folders still on disk.
    @discardableResult
    static func removeLeftovers(
        inSupportFolder supportFolder: URL? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [URL] {
        let supportFolder = supportFolder ?? defaultSupportFolder(fileManager: fileManager)
        for folder in remainingFolders(inSupportFolder: supportFolder, fileManager: fileManager) {
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                // Shown in Privacy, and tried again at the next launch.
                logger.error("retired_learning_cleanup_failed code=\((error as NSError).code, privacy: .public)")
            }
        }
        userDefaults.removeObject(forKey: settingKey)
        return remainingFolders(inSupportFolder: supportFolder, fileManager: fileManager)
    }

    /// The folders the flow left that are still on disk.
    static func remainingFolders(inSupportFolder supportFolder: URL? = nil, fileManager: FileManager = .default) -> [URL] {
        let supportFolder = supportFolder ?? defaultSupportFolder(fileManager: fileManager)
        return folders
            .map { supportFolder.appending(path: $0, directoryHint: .isDirectory) }
            .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    static func defaultSupportFolder(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appending(path: "Syrup", directoryHint: .isDirectory)
    }
}
