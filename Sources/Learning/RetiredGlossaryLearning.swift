import Foundation
import OSLog

/// Glossary learning used to keep dictation audio under `Recordings/` and a 626 MB comparison model
/// under `WhisperModels/`, both in Syrup's Application Support folder, behind the
/// `glossaryLearningEnabled` setting. The flow is gone. At each launch this deletes what it left, and
/// nothing else; a folder it cannot delete stays listed by `remainingFolders`, which Privacy shows.
enum RetiredGlossaryLearning {
    static let folders = ["Recordings", "WhisperModels"]
    static let settingKey = "glossaryLearningEnabled"
    /// The cleanup `SyrupApp` starts at launch, so Privacy reads the folders after it, not during it.
    @MainActor static var launchCleanup: Task<[URL], Never>?
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

    /// The folders the flow left that may still be on disk: every one the system does not report as
    /// missing. A folder that cannot be inspected, because a parent cannot be searched, is included,
    /// so Privacy never says nothing is left when it cannot tell.
    static func remainingFolders(inSupportFolder supportFolder: URL? = nil, fileManager: FileManager = .default) -> [URL] {
        let supportFolder = supportFolder ?? defaultSupportFolder(fileManager: fileManager)
        return folders
            // No trailing slash: with one, the system follows a link instead of reporting the link.
            .map { supportFolder.appending(path: $0, directoryHint: .notDirectory) }
            .filter { isMissing($0, fileManager: fileManager) == false }
    }

    /// Not following a symbolic link, so a link left in the folder's place is reported and removed,
    /// never what it points to.
    private static func isMissing(_ url: URL, fileManager: FileManager) -> Bool {
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
            return false
        } catch {
            let error = error as NSError
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            return error.code == NSFileReadNoSuchFileError || posix == Int(ENOENT) || posix == Int(ENOTDIR)
        }
    }

    /// Privacy's description of what is left, naming only the folders still there.
    static func leftoverDescription(for remaining: [URL]) -> String {
        let names = Set(remaining.map(\.lastPathComponent))
        let what = switch (names.contains("Recordings"), names.contains("WhisperModels")) {
        case (true, true): "recordings and a comparison model"
        case (true, false): "recordings"
        default: "a comparison model"
        }
        let pronoun = names.contains("Recordings") ? "They" : "It"
        return "An earlier version kept \(what) on this Mac. \(pronoun) could not be deleted yet; Syrup tries again at each launch."
    }

    static func defaultSupportFolder(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appending(path: "Syrup", directoryHint: .isDirectory)
    }
}
