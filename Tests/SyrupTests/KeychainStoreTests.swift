import Foundation
import Testing
@testable import Syrup

@Suite(.serialized)
struct KeychainStoreTests {
    @Test
    func saveLoadUpdateAndDeleteRoundTripUsesLocalSecretFile() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(testDomainName("SyrupTests"), isDirectory: true)
        let store = KeychainStore(
            service: "org.syrup.SyrupTests",
            storageDirectory: storageDirectory
        )
        try store.delete()
        defer {
            try? store.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        #expect(try store.load() == nil)

        try store.save("stored-value-one")
        #expect(try store.load() == "stored-value-one")
        try #expect(secretFilePermissions(under: storageDirectory) == 0o600)
        try #expect(secretDirectoryPermissions(under: storageDirectory) == 0o700)
        try #expect(secretRootDirectoryPermissions(under: storageDirectory) == 0o700)

        try store.save("stored-value-two")
        #expect(try store.load() == "stored-value-two")
        try #expect(secretFilePermissions(under: storageDirectory) == 0o600)
        try #expect(secretDirectoryPermissions(under: storageDirectory) == 0o700)
        try #expect(secretRootDirectoryPermissions(under: storageDirectory) == 0o700)

        try store.delete()
        #expect(try store.load() == nil)
    }

    private func secretFilePermissions(under storageDirectory: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: secretFileURL(under: storageDirectory).path
        )
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func secretDirectoryPermissions(under storageDirectory: URL) throws -> Int {
        let secretDirectory = try secretFileURL(under: storageDirectory).deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: secretDirectory.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func secretRootDirectoryPermissions(under storageDirectory: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: storageDirectory.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func secretFileURL(under storageDirectory: URL) throws -> URL {
        let enumerator = try #require(FileManager.default.enumerator(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ))
        let secretFiles = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "secret" }
        return try #require(secretFiles.first)
    }
}
