import Foundation
import FoundationModels

struct AppleOnDeviceTransformer: StreamingTextTransformer {
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    private let preparedInstruction: String?
    private let session: LanguageModelSession?
    private let availabilityProvider: @Sendable () -> SystemLanguageModel.Availability
    private let responseProvider: (@Sendable (String, String) async throws -> String)?

    init(
        instruction: String? = nil,
        shouldPrewarm: Bool = false,
        availabilityProvider: @escaping @Sendable () -> SystemLanguageModel.Availability = {
            SystemLanguageModel.default.availability
        },
        responseProvider: (@Sendable (String, String) async throws -> String)? = nil
    ) {
        self.preparedInstruction = instruction
        self.availabilityProvider = availabilityProvider
        self.responseProvider = responseProvider
        if let instruction, instruction.isEmpty == false {
            let session = LanguageModelSession(model: Self.model, instructions: instruction)
            if shouldPrewarm {
                session.prewarm()
            }
            self.session = session
        } else {
            self.session = nil
        }
    }

    private func session(for instruction: String) -> LanguageModelSession {
        if preparedInstruction == instruction, let session { return session }
        return LanguageModelSession(model: Self.model, instructions: instruction)
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        let availability = availabilityProvider()
        guard case .available = availability else {
            throw TranslationError.onDeviceUnavailable(Self.availabilityMessage(availability: availability))
        }

        do {
            let content: String
            if let responseProvider {
                content = try await responseProvider(text, instruction)
            } else {
                let response = try await session(for: instruction).respond(
                    to: text,
                    options: GenerationOptions(temperature: 0.3)
                )
                content = response.content
            }
            let normalizedOutput = ModelOutputNormalizer.normalize(
                content,
                keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
            )
            guard normalizedOutput.isEmpty == false else {
                throw TranslationError.emptyResponse
            }
            return normalizedOutput
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.translationError(for: error)
        }
    }

    func transformStream(
        _ text: String,
        instruction: String
    ) -> AsyncThrowingStream<String, any Error> {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let availability = availabilityProvider()
        guard case .available = availability else {
            continuation.finish(throwing: TranslationError.onDeviceUnavailable(
                Self.availabilityMessage(availability: availability)
            ))
            return stream
        }

        let session = session(for: instruction)
        let task = Task {
            do {
                var adapter = CumulativeSnapshotDeltaAdapter()
                for try await snapshot in session.streamResponse(
                    to: text,
                    options: GenerationOptions(temperature: 0.3)
                ) {
                    try Task.checkCancellation()
                    switch adapter.append(snapshot.content) {
                    case .delta(let delta):
                        if delta.isEmpty == false {
                            continuation.yield(delta)
                        }
                    case .requiresAtomicFallback:
                        throw StreamingTransformError.requiresAtomicFallback
                    }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch let error as LanguageModelSession.GenerationError {
                continuation.finish(throwing: Self.translationError(for: error))
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    func transformAfterStreamingFallback(
        _ text: String,
        instruction: String
    ) async throws -> String {
        let cleanTransformer = AppleOnDeviceTransformer(
            availabilityProvider: availabilityProvider,
            responseProvider: responseProvider
        )
        return try await cleanTransformer.transform(text, instruction: instruction)
    }

    static func availabilityMessage(
        availability: SystemLanguageModel.Availability = SystemLanguageModel.default.availability
    ) -> String {
        switch availability {
        case .available:
            "Ready"
        case .unavailable(.deviceNotEligible):
            "This Mac can't run Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence isn't enabled on this Mac"
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading"
        @unknown default:
            "The on-device model is unavailable"
        }
    }

    static func translationError(for error: LanguageModelSession.GenerationError) -> TranslationError {
        switch error {
        case .guardrailViolation(_), .refusal(_, _):
            .onDeviceGuardrail
        case .exceededContextWindowSize(_):
            .onDeviceContextExceeded
        case .assetsUnavailable(_):
            .onDeviceUnavailable("The on-device model is still downloading")
        default:
            .invalidResponse
        }
    }
}
