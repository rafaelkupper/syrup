import Foundation
import Synchronization
import Testing
@testable import Syrup

@MainActor
struct SmartSpacingTests {
    @Test(arguments: [("a", true), ("é", true), ("中", true), ("_", true), ("7", true),
                      ("\u{301}", false), (" ", false), ("\n", false), (".", false),
                      ("🙂", false), ("abc", false), ("", false)])
    func classifiesOnlyOnePrecedingUnit(text: String, expected: Bool) {
        #expect(DeliveryTarget.isWordCharacter(text) == expected)
    }

    nonisolated static let atomicCases = [PasteStrategy.commandV(9), .typeText].flatMap { strategy in
        [true, false].flatMap { enabled in [true, false].map { (enabled, $0, strategy) } }
    }

    @Test(arguments: atomicCases)
    func atomicDeliveryKeepsClipboardExact(enabled: Bool, precedingWord: Bool, strategy: PasteStrategy) async {
        let suite = "Spacing.\(UUID())", reads = Mutex(0)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(!settings.smartSpacingEnabled)
        settings.smartSpacingEnabled = enabled
        settings.autoPasteEnabled = true
        let clipboard = SpyPasteboard(), typist = SpyStreamingTypist(), paster = SpyAutoPaster()
        paster.strategy = strategy
        let target = DeliveryTarget(checkCurrent: { true }, spacingProbe: {
            reads.withLock { $0 += 1 }
            return precedingWord
        })
        let state = AppState(settings: settings, audioRecorder: FakeRecorder(),
                             transcriber: FakeTranscriber(.success("hello")),
                             transformer: FakeTextTransformer(.success("result")),
                             pasteboard: clipboard, feedback: SpyFeedback(), autoPaster: paster,
                             streamingTypistFactory: { typist }, maximumRecordingDurationNanoseconds: 0,
                             autoPasteDelayNanoseconds: 0, recordingClock: FastForwardClock(),
                             captureDeliveryTarget: { _ in target })
        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)
        #expect(clipboard.writes == ["result"])
        #expect(reads.withLock { $0 } == (enabled ? 1 : 0))
        if strategy == .typeText {
            #expect(typist.appendedDeltas == [(enabled && precedingWord ? " " : "") + "result"])
        } else {
            #expect(paster.pasteCount == 1)
            #expect(typist.appendedDeltas == (enabled && precedingWord ? [" "] : []))
        }
    }

    @Test(arguments: [true, false])
    func streamingPrefixesOnceAndCopyOnlyNeverReads(autoPaste: Bool) async {
        let suite = "Spacing.\(UUID())", reads = Mutex(0)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.smartSpacingEnabled = true
        settings.autoPasteEnabled = autoPaste
        settings.streamingDeliveryEnabled = true
        let clipboard = SpyPasteboard(), typist = SpyStreamingTypist()
        typist.postsTextOnAppend = true
        let state = AppState(settings: settings, audioRecorder: FakeRecorder(),
                             transcriber: FakeTranscriber(.success("hello")),
                             transformer: FakeStreamingTextTransformer(atomicOutput: "result more", deltas: ["result", " more"]),
                             pasteboard: clipboard, feedback: SpyFeedback(), autoPaster: SpyAutoPaster(),
                             streamingTypistFactory: { typist }, maximumRecordingDurationNanoseconds: 0,
                             autoPasteDelayNanoseconds: 0, recordingClock: FastForwardClock(),
                             captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }, spacingProbe: {
                                 reads.withLock { $0 += 1 }; return true
                             }) })
        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)
        #expect(clipboard.writes == ["result more"])
        #expect(reads.withLock { $0 } == (autoPaste ? 1 : 0))
        #expect(typist.appendedDeltas == (autoPaste ? [" ", "result", " more"] : []))
    }

    @Test func aSlowReadTimesOutWithoutHoldingDelivery() async {
        let gate = ManualResetSleeper()
        let target = DeliveryTarget(checkCurrent: { true }, spacingProbe: {
            try? await gate.sleep(nanoseconds: 0)
            return true
        })
        let result = await target.needsLeadingSpace()
        await gate.resumeAll(throwing: CancellationError())
        #expect(!result)
    }

    private func settle(_ state: AppState) async {
        await settleRun(state)
    }
}
