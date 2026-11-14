import AVFoundation
import Foundation
import KeyboardShortcuts
import Synchronization
import Testing
@testable import Syrup

/// Connection tests and saved credentials for the OpenAI-compatible provider.
@MainActor
struct ProviderCredentialTests {
    @Test func oldConnectionSuccessCannotReplaceNewFailure() async {
        let model = EndpointConnectionTest()
        let gate = ConnectionTestGate()
        let old = model.begin()
        let task = Task { await model.run(old) { await gate.wait() } }
        await gate.waitUntilStarted()
        let current = model.begin()
        await model.run(current) { throw TranslationError.apiKeyRejected }
        gate.resume()
        await task.value
        #expect(model.status == .failure("API key rejected"))
    }

    @Test func unreadableSavedKeyDoesNotFallBackToEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupKeyReadCorrection"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeychainStore(service: "fixture", storageDirectory: directory)
        try store.save("fixture-value")
        try Data([0xff]).write(to: directory.appending(path: "fixture/apiKey.secret"))
        await #expect(throws: KeychainStoreError.readFailed) {
            _ = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
                baseURLString: "https://original.invalid/v1", modelName: "fixture", keychainStore: store,
                environment: ["OPENAI_COMPATIBLE_URL": "https://fallback.invalid/v1",
                    "OPENAI_COMPATIBLE_MODEL": "fixture", "OPENAI_COMPATIBLE_API_KEY": "fixture-value"])
        }
    }

    @Test func changedEndpointIgnoresOldSuccessAndFailure() async {
        let model = EndpointConnectionTest()
        let old = model.begin()
        model.invalidate()
        var startedStaleRequest = false
        await model.run(old) { startedStaleRequest = true }
        #expect(!startedStaleRequest)
        #expect(model.status == .idle)
        let request = model.begin()
        await model.run(request) {
            model.invalidate()
            throw TranslationError.apiKeyRejected
        }
        #expect(model.status == .idle)
        let latest = model.begin()
        await model.run(latest) {}
        #expect(model.status == .success)
        model.invalidate()
        #expect(model.status == .idle)
    }

    @Test func failedCredentialDeletionMustNotLookSuccessful() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupCredentialAudit"))
        let secretDirectory = directory.appending(path: "audit")
        let secret = secretDirectory.appending(path: "apiKey.secret")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secretDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = KeychainStore(service: "audit", storageDirectory: directory)
        try store.save("fixture-value")
        #expect(try store.load() == "fixture-value")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secretDirectory.path)
        #expect(throws: KeychainStoreError.deleteFailed) { try store.delete() }
        #expect(throws: KeychainStoreError.readFailed) { _ = try store.load() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secretDirectory.path)
        let remainsOnDisk = FileManager.default.fileExists(atPath: secret.path)
        #expect(remainsOnDisk)
    }

    @Test func providerConfigurationIsFrozenBeforeTransformation() async throws {
        let settings = fixtureSettings()
        settings.baseURL = "https://snapshot.invalid/v1"
        settings.modelName = "original-model"
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupSnapshot"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SnapshotURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = AppSettingsTransformerProvider(settings: settings,
            keychainStore: KeychainStore(storageDirectory: directory), session: session, environment: [:])
        let snapshot = provider.snapshot(for: .openAICompatible)
        settings.baseURL = "https://changed.invalid/v1"
        settings.modelName = "changed-model"
        let transformer = await snapshot.transformer(instruction: "fixture")
        let output = try await transformer.transform("fixture", instruction: "fixture")
        #expect(output == "snapshot.invalid original-model")
    }

    private func fixtureSettings() -> AppSettings {
        let defaults = TestDefaults(suiteName: testDomainName("SyrupReviewTests"))!
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = false
        settings.playSounds = false
        return settings
    }
}

@MainActor private final class ConnectionTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private final class SnapshotURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text = "\(request.url!.host!) \(body?["model"] as? String ?? "missing")"
        let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
