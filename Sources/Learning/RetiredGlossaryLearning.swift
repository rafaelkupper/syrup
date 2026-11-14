import Foundation
import OSLog

/// Glossary learning used to keep dictation audio under `Recordings/` and a 626 MB comparison model
/// under `WhisperModels/`, both in Syrup's Application Support folder, behind the
/// `glossaryLearningEnabled` setting. The flow is gone; at launch this deletes what it left, and
/// nothing else, so no audio stays on the Mac.
enum RetiredGlossaryLearning {
    static let folders = ["Recordings", "WhisperModels"]
    static let settingKey = "glossaryLearningEnabled"
    private static let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "GlossaryLearning")

    static func removeLeftovers(
        inSupportFolder supportFolder: URL = defaultSupportFolder(),
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        for name in folders {
            let folder = supportFolder.appending(path: name, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: folder.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                // Tried again at the next launch.
                logger.error("retired_learning_cleanup_failed code=\((error as NSError).code, privacy: .public)")
            }
        }
        userDefaults.removeObject(forKey: settingKey)
    }

    static func defaultSupportFolder() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Syrup", directoryHint: .isDirectory)
    }
}
