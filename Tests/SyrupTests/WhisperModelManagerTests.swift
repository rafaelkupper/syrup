import Foundation
import Testing
@testable import Syrup

@MainActor
struct WhisperModelRemovalTests {
    @Test
    func removeModelDeletesFilesAndResetsState() throws {
        let storageDirectory = try makeInstalledModelDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let manager = WhisperModelManager(storageDirectory: storageDirectory)
        #expect(manager.state == .ready)

        manager.removeModel()

        #expect(manager.state == .notDownloaded)
        #expect(FileManager.default.fileExists(atPath: storageDirectory.path(percentEncoded: false)) == false)
    }

    @Test
    func removeModelWithoutFilesIsANoOpReset() {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SyrupWhisperModelTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        let manager = WhisperModelManager(storageDirectory: storageDirectory)
        #expect(manager.state == .notDownloaded)

        manager.removeModel()

        #expect(manager.state == .notDownloaded)
    }

    private func makeInstalledModelDirectory() throws -> URL {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SyrupWhisperModelTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        let modelDirectory = storageDirectory
            .appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: WhisperModelManager.modelVariant, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: modelDirectory.appending(path: "\(name).mlmodelc"),
                withIntermediateDirectories: true
            )
        }
        try Data("{}".utf8).write(to: modelDirectory.appending(path: "tokenizer.json"))
        return storageDirectory
    }
}
