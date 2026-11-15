import Foundation
import Synchronization

// Compiled only by OwnerBoundaryContractTests, beside the unmodified production owner files.
// These doubles replace external boundaries, including OSLog and Accessibility, without loading
// the app. Keep decisions in ResultActions and OutputVolumeChain, not in these doubles.
@MainActor final class AppSettings {
    var autoPasteEnabled = true
    var smartSpacingEnabled = false
    var matchesSentenceAtCaret = true
    var pinDeliveryTarget = false
    var glossaryList = GlossaryList()
}
struct GlossaryList { var terms: [Term] = [] }
struct Term { let term: String }
enum TranslationProvider { case fixture }
enum PipelineState { case idle; var acceptsNewRun: Bool { true } }
struct DictationRecord {
    enum TransformationSnapshot { case revision }
    enum Outcome { case success, failed }
    let id = UUID()
    var provider: TranslationProvider? = .fixture
    var transcript = "fixture"
    var output: String? = "Hello."
    var transformation = TransformationSnapshot.revision
    var outcome = Outcome.success
    var canUseTranscriptFallback: Bool { false }
    var canCopyFromHistory: Bool { true }
}
@MainActor final class HistoryStore { var records = [DictationRecord()] }
@MainActor protocol PasteboardWriting { func write(_ text: String) throws }
@MainActor final class Clipboard: PasteboardWriting {
    var writes: [String] = []
    func write(_ text: String) { writes.append(text) }
}
@MainActor protocol AutoPasting { var isTrusted: Bool { get } }
@MainActor struct Paster: AutoPasting { let isTrusted = true }
@MainActor final class StatusIndicator {
    func cancelErrorReset() {}
    func showSuccess() {}
    func scheduleErrorReset(for id: UUID) {}
}
@MainActor final class DeliveryCoordinator {
    func notifyNoCapturedTarget() {}
    func pasteCompletedText(
        _ text: String, contextTarget: DeliveryTarget?, usesSpacing: Bool, knownContext: CaretContext?,
        canContinue: @escaping @MainActor () -> Bool, targetIsCurrent: @escaping @MainActor () async -> Bool
    ) async throws -> Bool {
        guard canContinue() else { return false }
        return await targetIsCurrent()
    }
}
struct CaretContext: Sendable {}
enum SentenceFit {
    static func apply(_ text: String, context: CaretContext, protectedTerms: [String]) -> String { text }
}
@MainActor final class DeliveryTarget {
    var sentenceRequests: [Bool] = []
    func caretContext(readsSentence: Bool) async -> CaretContext? {
        sentenceRequests.append(readsSentence)
        return CaretContext()
    }
    func isCurrent() async -> Bool { true }
}
@MainActor final class Host: ResultActionsHost {
    var pipelineState = PipelineState.idle
    func appendRecord(transcript: String, output: String?, transformation: DictationRecord.TransformationSnapshot,
                      outcome: DictationRecord.Outcome, provider: TranslationProvider?) -> UUID { UUID() }
    func presentError(_ error: Error) {}
    func showIdleAfterCopy() {}
    func clearErrorAfterCopy() {}
}

enum OutputVolumeError: Error { case writeFailed(Int32) }
actor OutputDucker {
    func lower() throws { throw OutputVolumeError.writeFailed(123) }
    func restore() throws {}
    func restoreAfterCrash() throws {}
}
struct Logger: Sendable {
    static let errors = Mutex<[String]>([])
    init(subsystem: String, category: String) {}
    func error(_ message: String) { Self.errors.withLock { $0.append(message) } }
}
enum LogPrivacy { case `public` }
extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: String, privacy: LogPrivacy) { appendLiteral(value) }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let clipboard = Clipboard(), target = DeliveryTarget(), host = Host()
        let actions = ResultActions(
            history: HistoryStore(), settings: AppSettings(), pasteboard: clipboard, autoPaster: Paster(),
            delivery: DeliveryCoordinator(), status: StatusIndicator(), captureDeliveryTarget: { _ in target },
            frontmostApplication: { _ in (nil, 42) }
        )
        actions.host = host
        await actions.pasteLastResult()
        let volume = OutputVolumeChain(ducker: OutputDucker())
        volume.lower()
        await volume.pending?.value
        let report: [String: Any] = [
            "sentenceRequests": target.sentenceRequests,
            "clipboard": clipboard.writes,
            "volumeErrors": Logger.errors.withLock { $0 }
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
