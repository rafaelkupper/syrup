import Speech

enum SpeechPermissionRequester {
    typealias Completion = @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    typealias Request = @Sendable (@escaping Completion) -> Void

    nonisolated static func requestAuthorization(
        using request: Request = { completion in
            SFSpeechRecognizer.requestAuthorization { status in
                completion(status)
            }
        }
    ) async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            request { status in
                continuation.resume(returning: status)
            }
        }
    }
}
