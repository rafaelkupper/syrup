import Foundation
import Testing
@testable import Syrup

/// The removed glossary-learning flow's files go at launch, and nothing beside them does. The files
/// follow what earlier builds wrote: `<id>.wav` and `<id>.json` in a 0700 `Recordings/` with 0600
/// files, and WhisperKit's hub layout plus a `.partial` staging folder under `WhisperModels/`.
struct RetiredGlossaryLearningTests {
    private let fileManager = FileManager.default

    private func supportFolder() -> URL {
        fileManager.temporaryDirectory.appending(path: testDomainName("RetiredLearning"), directoryHint: .isDirectory)
    }

    private func write(_ relative: String, in support: URL, permissions: Int? = nil) throws {
        let file = support.appending(path: relative)
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        if let permissions { try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path(percentEncoded: false)) }
    }

    private func exists(_ relative: String, in support: URL) -> Bool {
        fileManager.fileExists(atPath: support.appending(path: relative).path(percentEncoded: false))
    }

    private func writeLeftovers(in support: URL) throws {
        let id = UUID().uuidString
        try write("Recordings/\(id).wav", in: support, permissions: 0o600)
        try write("Recordings/\(id).json", in: support, permissions: 0o600)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.appending(path: "Recordings").path(percentEncoded: false))
        try write("WhisperModels/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB/TextDecoder.mlmodelc/weights/weight.bin", in: support)
        try write("WhisperModels/models/openai/whisper-large-v3/tokenizer.json", in: support)
        try write("WhisperModels/.partial/models/openai/whisper-large-v3/config.json", in: support)
    }

    @Test func launchRemovesTheRecordingsAndComparisonModelAndNothingElse() throws {
        let support = supportFolder()
        defer { try? fileManager.removeItem(at: support) }
        try writeLeftovers(in: support)
        let kept = ["History/history.json", "SpeechModels/parakeet-ultra/w.bin", "Secrets/org.syrup.SyrupApp/apiKey.secret", "usage-stats.json"]
        for relative in kept { try write(relative, in: support) }
        let suite = testDomainName("RetiredLearning")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "glossaryLearningEnabled")
        defaults.set(true, forKey: "persistHistory")

        let remaining = RetiredGlossaryLearning.removeLeftovers(inSupportFolder: support, userDefaults: defaults)

        #expect(remaining.isEmpty)
        #expect(exists("Recordings", in: support) == false)
        #expect(exists("WhisperModels", in: support) == false)
        for relative in kept { #expect(exists(relative, in: support), "\(relative) must survive") }
        #expect(defaults.object(forKey: "glossaryLearningEnabled") == nil)
        #expect(defaults.bool(forKey: "persistHistory"))
    }

    /// Analysis deleted each recording after use, so the model is often all that is left; and a
    /// Mac may have recordings without the model. Either goes alone.
    @Test(arguments: ["Recordings", "WhisperModels"])
    func eitherFolderAloneIsRemoved(present: String) throws {
        let support = supportFolder()
        defer { try? fileManager.removeItem(at: support) }
        try writeLeftovers(in: support)
        let absent = RetiredGlossaryLearning.folders.filter { $0 != present }
        for name in absent { try fileManager.removeItem(at: support.appending(path: name)) }
        let suite = testDomainName("RetiredLearning")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        RetiredGlossaryLearning.removeLeftovers(inSupportFolder: support, userDefaults: defaults)

        #expect(exists(present, in: support) == false)
    }

    /// A folder that cannot be deleted is reported, for Privacy to show, and a later launch deletes it.
    @Test func aFolderThatCannotBeDeletedGoesAtTheNextLaunch() throws {
        let support = supportFolder()
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path(percentEncoded: false))
            try? fileManager.removeItem(at: support)
        }
        try writeLeftovers(in: support)
        let suite = testDomainName("RetiredLearning")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: support.path(percentEncoded: false))

        let reported = RetiredGlossaryLearning.removeLeftovers(inSupportFolder: support, userDefaults: defaults)
        #expect(reported.map(\.lastPathComponent) == ["Recordings", "WhisperModels"])
        #expect(RetiredGlossaryLearning.remainingFolders(inSupportFolder: support) == reported)
        #expect(exists("Recordings", in: support))

        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path(percentEncoded: false))
        #expect(RetiredGlossaryLearning.removeLeftovers(inSupportFolder: support, userDefaults: defaults).isEmpty)
        #expect(RetiredGlossaryLearning.remainingFolders(inSupportFolder: support).isEmpty)
        #expect(exists("Recordings", in: support) == false)
        #expect(exists("WhisperModels", in: support) == false)
    }

    /// A support folder that cannot be searched hides whether the folders exist. They are reported, so
    /// Privacy never says nothing is left when it cannot tell.
    @Test func foldersThatCannotBeInspectedAreReported() throws {
        let support = supportFolder()
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path(percentEncoded: false))
            try? fileManager.removeItem(at: support)
        }
        try writeLeftovers(in: support)
        let suite = testDomainName("RetiredLearning")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: support.path(percentEncoded: false))

        #expect(RetiredGlossaryLearning.remainingFolders(inSupportFolder: support).map(\.lastPathComponent) == ["Recordings", "WhisperModels"])
        #expect(RetiredGlossaryLearning.removeLeftovers(inSupportFolder: support, userDefaults: defaults).count == 2)

        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path(percentEncoded: false))
        #expect(exists("Recordings", in: support), "Nothing was deleted while the folder could not be searched")
    }

    /// A symbolic link in a folder's place, even one pointing nowhere, is removed; what it points to
    /// is never touched.
    @Test func aLinkInAFoldersPlaceIsRemovedAndItsTargetKept() throws {
        let support = supportFolder()
        let outside = supportFolder()
        defer {
            try? fileManager.removeItem(at: support)
            try? fileManager.removeItem(at: outside)
        }
        try write("kept.wav", in: outside)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: support.appending(path: "Recordings"), withDestinationURL: outside)
        try fileManager.createSymbolicLink(at: support.appending(path: "WhisperModels"), withDestinationURL: outside.appending(path: "missing"))
        let suite = testDomainName("RetiredLearning")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(RetiredGlossaryLearning.removeLeftovers(inSupportFolder: support, userDefaults: defaults).isEmpty)

        #expect((try? fileManager.destinationOfSymbolicLink(atPath: support.appending(path: "Recordings").path(percentEncoded: false))) == nil)
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: support.appending(path: "WhisperModels").path(percentEncoded: false))) == nil)
        #expect(exists("kept.wav", in: outside))
    }

    @Test func launchWithNothingLeftOverChangesNothing() throws {
        let support = supportFolder()
        defer { try? fileManager.removeItem(at: support) }
        let suite = testDomainName("RetiredLearning")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        RetiredGlossaryLearning.removeLeftovers(inSupportFolder: support, userDefaults: defaults)

        #expect(fileManager.fileExists(atPath: support.path(percentEncoded: false)) == false)
    }
}
