import Foundation
import Observation

/// What `ResultActions` needs from the pipeline: its state, history records that carry the active
/// run's details, and the state changes a copy makes. `AppState` is the one host.
@MainActor
protocol ResultActionsHost: AnyObject {
    var pipelineState: PipelineState { get }
    @discardableResult
    func appendRecord(
        transcript: String,
        output: String?,
        transformation: DictationRecord.TransformationSnapshot,
        outcome: DictationRecord.Outcome,
        provider: TranslationProvider?
    ) -> UUID
    /// Shows an error and notifies the person.
    func presentError(_ error: Error)
    /// An explicit copy succeeded: the pipeline shows idle.
    func showIdleAfterCopy()
    /// Paste Last copied: an error still on screen no longer applies. Any other state stays.
    func clearErrorAfterCopy()
}

/// Copying and pasting finished results while no run owns the pipeline: Copy last result, Paste last
/// result, Copy result again after a failed clipboard write, Copy transcript instead, and copying a
/// history row. Owns the result kept for Copy result again and the newest Paste Last request.
/// The run's own delivery, and its single commit point, stay in `AppState+Delivery.swift`.
@MainActor
@Observable
final class ResultActions {
    /// A finished result whose clipboard write failed, kept so Copy Result can deliver it later.
    /// `output` is the exact result that history keeps; `delivered` is the sentence-fitted text.
    struct PendingClipboardResult {
        let output: String
        let delivered: String
        let transcript: String
        let transformation: DictationRecord.TransformationSnapshot
        let provider: TranslationProvider
    }

    /// Set by the commit point when the clipboard refused a finished result, cleared when it took one.
    var pendingClipboardResult: PendingClipboardResult?
    /// The newest Paste Last request. A newer request or a new run replaces it, and the older one stops.
    private var pendingPasteID: UUID?

    @ObservationIgnored weak var host: (any ResultActionsHost)?
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let pasteboard: any PasteboardWriting
    @ObservationIgnored private let autoPaster: any AutoPasting
    @ObservationIgnored private let delivery: DeliveryCoordinator
    @ObservationIgnored private let status: StatusIndicator
    @ObservationIgnored private let captureDeliveryTarget: @MainActor (pid_t?) async -> DeliveryTarget?
    @ObservationIgnored private let frontmostApplication: @MainActor (Bool) -> (bundleID: String?, processID: pid_t?)

    init(
        history: HistoryStore,
        settings: AppSettings,
        pasteboard: any PasteboardWriting,
        autoPaster: any AutoPasting,
        delivery: DeliveryCoordinator,
        status: StatusIndicator,
        captureDeliveryTarget: @escaping @MainActor (pid_t?) async -> DeliveryTarget?,
        frontmostApplication: @escaping @MainActor (Bool) -> (bundleID: String?, processID: pid_t?)
    ) {
        self.history = history
        self.settings = settings
        self.pasteboard = pasteboard
        self.autoPaster = autoPaster
        self.delivery = delivery
        self.status = status
        self.captureDeliveryTarget = captureDeliveryTarget
        self.frontmostApplication = frontmostApplication
    }

    private var acceptsNewRun: Bool {
        host?.pipelineState.acceptsNewRun == true
    }

    // MARK: - Results in history

    var lastResult: String? {
        history.records.first { record in
            guard record.output != nil else { return false }
            if case .success = record.outcome { return true }
            if case .failed = record.outcome,
               case .revision = record.transformation {
                return true
            }
            return false
        }?.output
    }

    var lastSuccessfulResult: String? {
        history.records.first { record in
            guard record.output != nil else { return false }
            if case .success = record.outcome { return true }
            return false
        }?.output ?? lastResult
    }

    var transcriptFallback: String? {
        guard let record = history.records.first,
              record.canUseTranscriptFallback else {
            return nil
        }
        return record.transcript
    }

    var canCopyTranscriptFallback: Bool {
        transcriptFallback != nil && acceptsNewRun
    }

    var canCopyLastResult: Bool {
        lastSuccessfulResult != nil && acceptsNewRun
    }

    var canCopyPendingResult: Bool {
        pendingClipboardResult != nil && acceptsNewRun
    }

    // MARK: - Copy actions

    func copyPendingResult() {
        guard canCopyPendingResult, let result = pendingClipboardResult else { return }
        copyToClipboard(result.delivered) {
            host?.appendRecord(
                transcript: result.transcript,
                output: result.output,
                transformation: result.transformation,
                outcome: .success,
                provider: result.provider
            )
            pendingClipboardResult = nil
        }
    }

    func copyTranscriptFallback(recordID: UUID? = nil) {
        guard acceptsNewRun,
              let record = recordID.flatMap({ id in history.records.first { $0.id == id } }) ?? (recordID == nil ? history.records.first : nil),
              record.canUseTranscriptFallback else {
            return
        }

        copyToClipboard(record.transcript) {
            host?.appendRecord(
                transcript: record.transcript,
                output: record.transcript,
                transformation: record.transformation,
                outcome: .success,
                provider: record.provider
            )
        }
    }

    func copyHistoryRecord(recordID: UUID) {
        guard acceptsNewRun,
              let record = history.records.first(where: { $0.id == recordID }),
              record.canCopyFromHistory else {
            return
        }
        copyToClipboard(record.output ?? record.transcript)
    }

    func copyLastResult() {
        guard canCopyLastResult, let text = lastSuccessfulResult else { return }
        copyToClipboard(text)
    }

    /// The one path for explicit copy actions: write, record, and confirm, or show why it failed.
    private func copyToClipboard(_ text: String, afterWrite: () -> Void = {}) {
        do {
            try pasteboard.write(text)
            afterWrite()
            status.cancelErrorReset()
            host?.showIdleAfterCopy()
            status.showSuccess()
        } catch {
            host?.presentError(error)
            status.scheduleErrorReset(for: UUID())
        }
    }

    // MARK: - Paste Last

    /// Stops a Paste Last still waiting, because a run is starting.
    func cancelPendingPaste() {
        pendingPasteID = nil
    }

    /// Pastes the last result where automatic paste would. Accessibility serves only opt-in automatic
    /// paste, so with automatic paste off this copies the result, like Copy Last.
    func pasteLastResult() async {
        guard settings.autoPasteEnabled else {
            copyLastResult()
            return
        }
        guard canCopyLastResult, let text = lastSuccessfulResult else { return }
        let pasteID = UUID()
        pendingPasteID = pasteID
        defer { if pendingPasteID == pasteID { pendingPasteID = nil } }
        let pinsTarget = settings.pinDeliveryTarget
        let usesSpacing = settings.autoPasteEnabled && settings.smartSpacingEnabled
        let fitsSentence = settings.matchesSentenceAtCaret && autoPaster.isTrusted
        let target = (pinsTarget || usesSpacing || fitsSentence) ? await captureDeliveryTarget(frontmostApplication(false).processID) : nil
        guard pendingPasteID == pasteID, canCopyLastResult, !Task.isCancelled else { return }
        var context: CaretContext?
        if fitsSentence, let target {
            context = await target.caretContext(readsSentence: true)
            guard pendingPasteID == pasteID, canCopyLastResult, !Task.isCancelled else { return }
        }
        let delivered = context.map {
            SentenceFit.apply(text, context: $0, protectedTerms: settings.glossaryList.terms.map(\.term))
        } ?? text
        do {
            try pasteboard.write(delivered)
            // The copy succeeded, so an error still on screen no longer applies, as with Copy Last.
            status.cancelErrorReset()
            host?.clearErrorAfterCopy()
            // Whenever it copied without pasting, the copied flash shows, every time: the notice for
            // missing Accessibility appears only once per launch.
            if pinsTarget, target == nil {
                delivery.notifyNoCapturedTarget()
                status.showSuccess()
                return
            }
            let pasted = try await delivery.pasteCompletedText(delivered, contextTarget: usesSpacing ? target : nil,
                                                               usesSpacing: usesSpacing, knownContext: context, canContinue: { [weak self] in
                self?.pendingPasteID == pasteID && self?.canCopyLastResult == true
            }, targetIsCurrent: {
                guard pinsTarget else { return true }
                return await target?.isCurrent() == true
            })
            if pasted == false { status.showSuccess() }
        } catch is CancellationError {
        } catch {
            host?.presentError(error)
            status.scheduleErrorReset(for: UUID())
        }
    }
}
