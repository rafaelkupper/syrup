import Foundation
import FoundationModels
import Testing
@testable import Syrup

struct AppleOnDeviceTransformerTests {
    @Test(arguments: [false, true])
    func atomicResponsePreservesOnlyRequestedQuotes(formatting: Bool) async throws {
        let transformer = AppleOnDeviceTransformer(
            availabilityProvider: { .available },
            responseProvider: { input, _ in
                #expect(input == "Entre aspas bom dia.")
                return #"  "good morning"  "#
            }
        )
        let output = try await transformer.transform(
            "Entre aspas bom dia.",
            instruction: formatting ? PromptBuilder.spokenFormattingInstruction : "Translate to English."
        )
        #expect(output == (formatting ? #""good morning""# : "good morning"))
    }

    @Test
    func unavailableModelThrowsTypedErrorWithoutSessionUse() async {
        let transformer = AppleOnDeviceTransformer(
            availabilityProvider: {
                .unavailable(.deviceNotEligible)
            }
        )

        await #expect(throws: TranslationError.onDeviceUnavailable("This Mac can't run Apple Intelligence")) {
            _ = try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func availabilityMessagesAreUserFacing() {
        #expect(AppleOnDeviceTransformer.availabilityMessage(availability: .available) == "Ready")
        #expect(AppleOnDeviceTransformer.availabilityMessage(availability: .unavailable(.appleIntelligenceNotEnabled)) == "Apple Intelligence isn't enabled on this Mac")
        #expect(AppleOnDeviceTransformer.availabilityMessage(availability: .unavailable(.modelNotReady)) == "The on-device model is still downloading")
    }

    /// Runs the real on-device model, so it depends on this Mac and its model. Opt in with
    /// `SYRUP_ON_DEVICE_REAL=1`, like the other real suites.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYRUP_ON_DEVICE_REAL"] == "1"
        && AppleOnDeviceTransformer.availabilityMessage() == "Ready"))
    func availableModelSmokeTransformsShortPhrase() async throws {
        let transformer = AppleOnDeviceTransformer()

        let output = try await transformer.transform(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        )

        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
}
