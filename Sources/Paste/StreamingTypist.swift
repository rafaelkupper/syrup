import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum TypingStep: Equatable, Sendable {
    case text(String)
    case lineBreak

    nonisolated static func plan(_ text: String, maximumUTF16Units: Int = 20) -> [TypingStep] {
        let limit = max(1, maximumUTF16Units)
        var steps: [TypingStep] = []
        var current = ""
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                if current.isEmpty == false {
                    steps.append(.text(current))
                    current = ""
                }
                steps.append(.lineBreak)
            } else {
                let characterText = String(character)
                if current.isEmpty == false,
                   current.utf16.count + characterText.utf16.count > limit {
                    steps.append(.text(current))
                    current = ""
                }
                current.append(character)
            }
        }
        if current.isEmpty == false { steps.append(.text(current)) }
        return steps
    }
}

typealias StreamingTypistSleeper = @Sendable (Duration) async throws -> Void

enum StreamingTypingStopReason: Equatable, Sendable {
    case focusChanged
    case secureInputActive
    case eventCreationFailed
}

enum StreamingTypingStartError: Error, Equatable, Sendable {
    case targetUnavailable
}

@MainActor
protocol StreamingTyping: AnyObject {
    var stopReason: StreamingTypingStopReason? { get }
    var hasPostedText: Bool { get }
    func start() throws
    func append(_ delta: String)
    func addLeadingSpace()
    func setSentenceFit(context: CaretContext, protectedTerms: [String])
    func setKeepsWrapperQuotes(_ keepsWrapperQuotes: Bool)
    func typeText(_ text: String) async throws
    func finish() async
    func cancel()
    func setTargetValidator(_ validator: @escaping TypingTargetValidator)
    var onTextPosted: (() -> Void)? { get set }
}

/// Checks that the editor typing started in still has focus. It may wait on Accessibility off the
/// main actor; the typist posts nothing for a flush until its check returns.
typealias TypingTargetValidator = @MainActor () async -> Bool

extension StreamingTyping {
    func setSentenceFit(context: CaretContext, protectedTerms: [String]) {}
    func setKeepsWrapperQuotes(_ keepsWrapperQuotes: Bool) {}
    func setTargetValidator(_ validator: @escaping TypingTargetValidator) {}
    var onTextPosted: (() -> Void)? { get { nil } set {} }
}

/// Runs the same provider stream without synthesizing input events.
@MainActor
final class PreviewOnlyTypist: StreamingTyping {
    var stopReason: StreamingTypingStopReason? { nil }
    var hasPostedText: Bool { false }
    func start() throws {}
    func append(_ delta: String) {}
    func addLeadingSpace() {}
    func typeText(_ text: String) async throws {}
    func finish() async {}
    func cancel() {}
}

@MainActor
final class StreamingTypist: StreamingTyping {
    private let cadence: Duration
    private let sizeThreshold: Int
    private let trustStatus: () -> Bool
    private let secureInputStatus: () -> Bool
    private let frontmostApplicationID: () -> String?
    private let eventPoster: (TypingStep) -> Bool
    private let sleeper: StreamingTypistSleeper

    var onTextPosted: (() -> Void)?
    private var targetValidator: TypingTargetValidator = { true }
    private var cadenceTask: Task<Void, Never>?
    /// Flushes run one after another, each validating the target before it posts, so text keeps its
    /// order even though validation waits. Cancelling bumps `generation`, and a queued flush then
    /// posts nothing.
    private var flushChain: Task<Void, Never>?
    private var generation = 0
    private var pinnedApplicationID: String?
    private var pendingText = ""
    private var pendingLeadingSpace = false
    private var keepsWrapperQuotes = false
    private var sentenceContext: CaretContext?
    private var protectedTerms: [String] = []
    private var hasStartedTyping = false
    private var isActive = false
    private(set) var stopReason: StreamingTypingStopReason?
    private(set) var hasPostedText = false

    init(
        cadence: Duration = .milliseconds(50),
        sizeThreshold: Int = 200,
        trustStatus: @escaping () -> Bool = { AXIsProcessTrusted() },
        secureInputStatus: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        frontmostApplicationID: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication.map {
                $0.bundleIdentifier ?? "pid:\($0.processIdentifier)"
            }
        },
        eventPoster: @escaping (TypingStep) -> Bool = StreamingTypist.postStep,
        sleeper: @escaping StreamingTypistSleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.cadence = cadence
        self.sizeThreshold = max(1, sizeThreshold)
        self.trustStatus = trustStatus
        self.secureInputStatus = secureInputStatus
        self.frontmostApplicationID = frontmostApplicationID
        self.eventPoster = eventPoster
        self.sleeper = sleeper
    }

    func start() throws {
        guard trustStatus() else {
            throw AutoPasteError.notTrusted
        }
        guard secureInputStatus() == false else {
            throw AutoPasteError.secureInputActive
        }
        guard let frontmostApplicationID = frontmostApplicationID() else {
            throw StreamingTypingStartError.targetUnavailable
        }

        cadenceTask?.cancel()
        cadenceTask = nil
        generation += 1
        flushChain = nil
        pinnedApplicationID = frontmostApplicationID
        pendingText = ""
        pendingLeadingSpace = false
        keepsWrapperQuotes = false
        sentenceContext = nil
        protectedTerms = []
        hasStartedTyping = false
        stopReason = nil
        hasPostedText = false
        isActive = true
    }

    func typeText(_ text: String) async throws {
        try start()
        guard text.isEmpty == false else {
            isActive = false
            return
        }
        let generation = generation
        if await validateTarget(), generation == self.generation, isActive {
            post(text)
        }
        if generation == self.generation { isActive = false }
    }

    func addLeadingSpace() {
        pendingLeadingSpace = true
    }

    func setSentenceFit(context: CaretContext, protectedTerms: [String]) {
        sentenceContext = context
        self.protectedTerms = protectedTerms
    }

    func setKeepsWrapperQuotes(_ keepsWrapperQuotes: Bool) {
        self.keepsWrapperQuotes = keepsWrapperQuotes
    }

    func append(_ delta: String) {
        guard isActive, delta.isEmpty == false else { return }

        pendingText += delta
        if pendingText.count >= sizeThreshold {
            enqueueFlush(force: false)
        }
        scheduleCadenceIfNeeded()
    }

    func finish() async {
        guard isActive else { return }

        cadenceTask?.cancel()
        cadenceTask = nil
        let generation = generation
        await enqueueFlush(force: true).value
        if generation == self.generation { isActive = false }
    }

    func cancel() {
        cadenceTask?.cancel()
        cadenceTask = nil
        generation += 1
        flushChain = nil
        pendingText = ""
        isActive = false
    }

    /// Waits for every flush queued so far. Tests use it to observe posted text deterministically.
    func waitForQueuedFlushes() async {
        await flushChain?.value
    }

    @discardableResult
    private func enqueueFlush(force: Bool) -> Task<Void, Never> {
        let previous = flushChain
        let generation = generation
        let flush = Task { [weak self] in
            await previous?.value
            await self?.flush(force: force, generation: generation)
        }
        flushChain = flush
        return flush
    }

    private func scheduleCadenceIfNeeded() {
        guard isActive,
              cadenceTask == nil,
              pendingText.count > 2 else {
            return
        }

        let cadence = cadence
        let sleeper = sleeper
        cadenceTask = Task { [weak self] in
            do {
                try await sleeper(cadence)
            } catch {
                return
            }
            guard Task.isCancelled == false, let self else { return }
            self.cadenceTask = nil
            await self.enqueueFlush(force: false).value
            self.scheduleCadenceIfNeeded()
        }
    }

    private func flush(force: Bool, generation: Int) async {
        guard isActive, generation == self.generation else { return }
        // The focused-field check is an Accessibility round trip, so it runs once per flush and waits
        // off the main actor. Steps within the flush recheck only the frontmost app and secure input.
        guard await validateTarget() else { return }
        // A cancel or stop while the check waited ends this flush before it posts anything.
        guard isActive, generation == self.generation else { return }

        if force, hasStartedTyping == false {
            let normalized = ModelOutputNormalizer.normalize(pendingText, keepsWrapperQuotes: keepsWrapperQuotes)
            let textToPost = sentenceContext.map { SentenceFit.apply(normalized, context: $0, protectedTerms: protectedTerms) } ?? normalized
            pendingText = ""
            hasStartedTyping = true
            post(textToPost)
            return
        }

        prepareLeadingTextIfNeeded()
        guard hasStartedTyping else { return }

        let textToPost: String
        if force {
            textToPost = finalPendingText()
            pendingText = ""
        } else {
            guard let tailStart = ModelOutputNormalizer.holdbackStart(in: pendingText),
                  tailStart > pendingText.startIndex else {
                return
            }
            let heldStart = sentenceContext?.textFollows == true
                ? min(tailStart, SentenceFit.finalWordStart(in: pendingText)) : tailStart
            textToPost = String(pendingText[..<heldStart])
            pendingText = String(pendingText[heldStart...])
        }

        post(textToPost)
    }

    func setTargetValidator(_ validator: @escaping TypingTargetValidator) {
        targetValidator = validator
    }

    /// The full check before a flush: the pinned app, the focused field, and secure input.
    private func validateTarget() async -> Bool {
        guard checkApplicationAndSecureInput() else { return false }
        let generation = generation
        let isCurrent = await targetValidator()
        guard generation == self.generation, isActive else { return false }
        guard isCurrent else {
            stop(reason: .focusChanged)
            return false
        }
        return checkApplicationAndSecureInput()
    }

    /// The cheap check before each posted step.
    private func checkApplicationAndSecureInput() -> Bool {
        guard frontmostApplicationID() == pinnedApplicationID else {
            stop(reason: .focusChanged)
            return false
        }
        guard secureInputStatus() == false else {
            stop(reason: .secureInputActive)
            return false
        }
        return true
    }

    private func prepareLeadingTextIfNeeded() {
        guard hasStartedTyping == false else { return }

        guard keepsWrapperQuotes || ModelOutputNormalizer.beginsWithPotentialWrapperQuote(pendingText) == false else {
            return
        }

        let nonWhitespaceCharacters = pendingText.lazy.filter {
            $0.isWhitespace == false
        }.count
        guard nonWhitespaceCharacters >= 3 else { return }

        if sentenceContext?.continuesSentence == true {
            guard SentenceFit.firstWordIsComplete(in: pendingText, protectedTerms: protectedTerms) else { return }
            pendingText = SentenceFit.lowercaseFirstWord(pendingText, protectedTerms: protectedTerms)
        }
        pendingText.removeLeadingWhitespace()
        hasStartedTyping = true
    }

    private func finalPendingText() -> String {
        var finalText = pendingText
        finalText.removeTrailingWhitespace()
        return sentenceContext?.textFollows == true ? SentenceFit.removingFinalPeriod(finalText) : finalText
    }

    /// Posts text whose target the caller has just validated.
    private func post(_ text: String) {
        guard !text.isEmpty else { return }
        let prefix = pendingLeadingSpace && text.first?.isWhitespace == false ? " " : ""
        pendingLeadingSpace = false
        for step in TypingStep.plan(prefix + text) {
            guard checkApplicationAndSecureInput() else { return }
            guard eventPoster(step) else {
                stop(reason: .eventCreationFailed)
                return
            }
            if hasPostedText == false { onTextPosted?() }
            hasPostedText = true
        }
    }

    private func stop(reason: StreamingTypingStopReason) {
        cadenceTask?.cancel()
        cadenceTask = nil
        generation += 1
        pendingText = ""
        stopReason = reason
        isActive = false
    }

    nonisolated private static func postStep(_ step: TypingStep) -> Bool {
        guard let (keyDown, keyUp) = events(for: step) else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Flags are always set explicitly. An event made from the session source otherwise carries the
    /// modifiers held down right now, so a Command-S pressed mid-stream would turn typed text into a
    /// shortcut or drop it, and the editor would no longer match the clipboard.
    nonisolated static func events(for step: TypingStep) -> (CGEvent, CGEvent)? {
        let source = CGEventSource(stateID: .combinedSessionState)
        let virtualKey = step == .lineBreak ? CGKeyCode(kVK_Return) : 0
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return nil
        }

        switch step {
        case .lineBreak:
            keyDown.flags = .maskShift
            keyUp.flags = .maskShift
        case .text(let text):
            keyDown.flags = []
            keyUp.flags = []
            let utf16 = Array(text.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }
        return (keyDown, keyUp)
    }
}

private extension String {
    mutating func removeLeadingWhitespace() {
        guard let firstNonWhitespace = firstIndex(where: { $0.isWhitespace == false }) else {
            removeAll()
            return
        }
        removeSubrange(..<firstNonWhitespace)
    }

    mutating func removeTrailingWhitespace() {
        guard let lastNonWhitespace = lastIndex(where: { $0.isWhitespace == false }) else {
            removeAll()
            return
        }
        removeSubrange(index(after: lastNonWhitespace)...)
    }
}
