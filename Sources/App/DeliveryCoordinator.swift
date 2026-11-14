import AppKit
import Foundation

/// A result fitted to the sentence at the cursor. `text` is what the clipboard and editor receive;
/// `context` is the cursor read that produced it, reused so smart spacing does not read again.
struct FittedText {
    let text: String
    let context: CaretContext?
}

/// How finished text reaches the editor once it is on the clipboard: sentence fit, the delay before
/// pasting, smart spacing, typed or Command-V delivery, and the notices when delivery stops early.
/// `AppState` decides when a run delivers; this type decides how.
@MainActor
final class DeliveryCoordinator {
    private let autoPaster: any AutoPasting
    private let feedback: any AppFeedbackProviding
    private let metrics: any PipelineMetricsRecording
    private let streamingTypistFactory: () -> any StreamingTyping
    private let autoPasteDelayNanoseconds: UInt64
    private let autoPasteSleeper: AutoPasteSleeper
    private let captureDeliveryTarget: @MainActor (pid_t?) async -> DeliveryTarget?
    private let frontmostApplication: @MainActor (Bool) -> (bundleID: String?, processID: pid_t?)
    private var didNotifyAutoPasteNotTrusted = false

    init(
        autoPaster: any AutoPasting,
        feedback: any AppFeedbackProviding,
        metrics: any PipelineMetricsRecording,
        streamingTypistFactory: @escaping () -> any StreamingTyping,
        autoPasteDelayNanoseconds: UInt64,
        autoPasteSleeper: @escaping AutoPasteSleeper,
        captureDeliveryTarget: @escaping @MainActor (pid_t?) async -> DeliveryTarget?,
        frontmostApplication: @escaping @MainActor (Bool) -> (bundleID: String?, processID: pid_t?)
    ) {
        self.autoPaster = autoPaster
        self.feedback = feedback
        self.metrics = metrics
        self.streamingTypistFactory = streamingTypistFactory
        self.autoPasteDelayNanoseconds = autoPasteDelayNanoseconds
        self.autoPasteSleeper = autoPasteSleeper
        self.captureDeliveryTarget = captureDeliveryTarget
        self.frontmostApplication = frontmostApplication
    }

    /// A pinned run delivers only while the editor captured at the trigger still has focus.
    func targetIsCurrent(_ run: PipelineRun) async -> Bool {
        guard run.pinsDeliveryTarget, let target = run.deliveryTarget else { return run.pinsDeliveryTarget == false }
        return await target.isCurrent()
    }

    /// Match the sentence at the cursor. The clipboard and any paste carry the fitted text, and history
    /// keeps the exact result so Copy Last and Paste Last can fit it again elsewhere. The cursor is read
    /// once, just before the clipboard write: at the pinned editor while it is still current, otherwise
    /// in the app in front, where a manual Command-V would land.
    func sentenceFit(for text: String, run: PipelineRun, knownContext: CaretContext? = nil) async -> FittedText {
        guard run.matchesSentenceAtCaret, autoPaster.isTrusted else { return FittedText(text: text, context: nil) }
        var context = knownContext
        if context == nil {
            let target: DeliveryTarget?
            if let pinned = run.deliveryTarget, await pinned.isCurrent() {
                target = pinned
            } else if let processID = frontmostApplication(false).processID,
                      processID != ProcessInfo.processInfo.processIdentifier {
                target = await captureDeliveryTarget(processID)
            } else {
                target = nil
            }
            context = await target?.caretContext(readsSentence: true)
        }
        guard let context else { return FittedText(text: text, context: nil) }
        return FittedText(text: SentenceFit.apply(text, context: context, protectedTerms: run.protectedTerms), context: context)
    }

    /// Pastes a run's committed result into its editor when auto-paste is on.
    func autoPaste(
        _ text: String, run: PipelineRun, knownContext: CaretContext?,
        isCurrentRun: @escaping @MainActor () -> Bool
    ) async throws {
        guard isCurrentRun(), run.autoPasteEnabled else { return }
        guard await targetIsCurrent(run), isCurrentRun() else {
            if isCurrentRun() { feedback.notifyError(message: "The editor changed - the full result was copied.") }
            return
        }
        metrics.begin(.autoPaste, runID: run.id)
        defer { metrics.end(.autoPaste, runID: run.id) }
        try await pasteCompletedText(
            text, contextTarget: run.smartSpacingEnabled ? run.deliveryTarget : nil,
            usesSpacing: run.smartSpacingEnabled, knownContext: knownContext,
            canContinue: isCurrentRun,
            targetIsCurrent: { [weak self, weak run] in
                guard let self, let run else { return false }
                return await self.targetIsCurrent(run)
            }
        )
    }

    /// Pastes text that is already on the clipboard, already fitted when caret fit is on. Smart spacing
    /// reuses a cursor context read for the fit, or reads its one unit here.
    func pasteCompletedText(
        _ text: String, contextTarget: DeliveryTarget?,
        usesSpacing: Bool, knownContext: CaretContext?,
        canContinue: @escaping @MainActor () -> Bool,
        targetIsCurrent: @escaping TypingTargetValidator
    ) async throws {
        try await autoPasteSleeper(autoPasteDelayNanoseconds)
        guard canContinue(), Task.isCancelled == false else { throw CancellationError() }
        let targetIsCurrentBeforePaste = await targetIsCurrent()
        guard canContinue(), Task.isCancelled == false else { throw CancellationError() }
        guard targetIsCurrentBeforePaste else {
            feedback.notifyError(message: "The editor changed - the full result was copied.")
            return
        }
        let spaces = usesSpacing && text.first?.isWhitespace == false
        var context = knownContext
        if spaces, context == nil, let contextTarget, autoPaster.isTrusted {
            context = await contextTarget.caretContext(readsSentence: false)
            guard canContinue(), !Task.isCancelled else { throw CancellationError() }
            let stillCurrent = await targetIsCurrent()
            guard canContinue(), !Task.isCancelled else { throw CancellationError() }
            guard stillCurrent else {
                feedback.notifyError(message: "The editor changed - the full result was copied.")
                return
            }
        }
        let prefix = spaces && context?.precedingWordCharacter == true ? " " : ""
        do {
            let strategy = autoPaster.strategy
            if strategy == .typeText || !prefix.isEmpty {
                let typist = streamingTypistFactory()
                typist.setTargetValidator { canContinue() ? await targetIsCurrent() : false }
                try await typist.typeText(strategy == .typeText ? prefix + text : prefix)
                notifyIfStopped(typist.stopReason, focusMessage: "The editor changed - the full result was copied.",
                                secureInput: { feedback.notifyAutoPasteSecureInput() })
                if typist.stopReason != nil { return }
            }
            if case .commandV(let keyCode) = strategy { try autoPaster.paste(keyCode: keyCode) }
        } catch AutoPasteError.notTrusted {
            if didNotifyAutoPasteNotTrusted == false {
                didNotifyAutoPasteNotTrusted = true
                feedback.notifyAutoPasteNotTrusted()
            }
        } catch AutoPasteError.secureInputActive {
            feedback.notifyAutoPasteSecureInput()
        } catch {
            feedback.notifyError(message: "Typing stopped - the full result was copied.")
        }
    }

    /// Tells the person why streamed typing stopped before the end; the full result is on the clipboard.
    func notifyStreamingStopped(_ reason: StreamingTypingStopReason) {
        switch reason {
        case .focusChanged: feedback.notifyStreamingFocusChanged()
        case .secureInputActive: feedback.notifyStreamingSecureInput()
        case .eventCreationFailed: feedback.notifyError(message: "Typing stopped - the full result was copied.")
        }
    }

    private func notifyIfStopped(
        _ reason: StreamingTypingStopReason?, focusMessage: String, secureInput: () -> Void
    ) {
        switch reason {
        case .focusChanged: feedback.notifyError(message: focusMessage)
        case .secureInputActive: secureInput()
        case .eventCreationFailed: feedback.notifyError(message: "Typing stopped - the full result was copied.")
        case nil: break
        }
    }
}
