import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Waits until `condition` holds. Between checks it yields, and every so often sleeps briefly so
/// work on detached tasks and other actors can progress. It fails the test after `timeout` of real
/// time, rather than after a fixed number of yields that may or may not cover the work under test.
@MainActor
@discardableResult
func eventually(
    _ comment: Comment? = nil,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var checks = 0
    while condition() == false {
        guard clock.now < deadline else {
            Issue.record(comment ?? "Condition was not met in time", sourceLocation: sourceLocation)
            return false
        }
        checks += 1
        if checks.isMultiple(of: 50) {
            try? await Task.sleep(for: .milliseconds(1))
        } else {
            await Task.yield()
        }
    }
    return true
}

/// The same wait for conditions that need `await`, such as reading an actor's state.
@MainActor
@discardableResult
func eventually(
    _ comment: Comment? = nil,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var checks = 0
    while await condition() == false {
        guard clock.now < deadline else {
            Issue.record(comment ?? "Condition was not met in time", sourceLocation: sourceLocation)
            return false
        }
        checks += 1
        if checks.isMultiple(of: 50) {
            try? await Task.sleep(for: .milliseconds(1))
        } else {
            await Task.yield()
        }
    }
    return true
}

/// Waits for a run to finish, successfully or with an error. A run that never finishes fails the
/// test and is cancelled so it cannot leak into the next one.
@MainActor
func settleRun(
    _ state: AppState,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let finished = await eventually("The run did not finish", timeout: timeout, sourceLocation: sourceLocation) {
        state.pipelineState == .idle || state.pipelineState.isError
    }
    if finished == false { state.cancelRequested() }
}

// MARK: - Shared fakes for pipeline tests


enum FakeFailure: Error, Equatable, Sendable {
    case recorder
    case transcriber
    case transformer
    case speechPermission
    case languageModelInstalling
}

final class FakeRecorder: AudioRecording {
    var startCallCount = 0
    var stopCallCount = 0
    var startError: (any Error)?
    var finishesStreamOnStop = true
    private var continuation: AudioBufferSequence.Continuation?

    func start() async throws -> AudioBufferSequence {
        startCallCount += 1

        if let startError {
            throw startError
        }

        let stream = AudioBufferSequence.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func stop() {
        stopCallCount += 1
        if finishesStreamOnStop {
            continuation?.finish()
            continuation = nil
        }
    }
}

@MainActor
final class FastForwardClock: RecordingClock {
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant {
        instant += .seconds(1)
        return instant
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
    }
}

actor FakeTranscriber: Transcriber {
    enum Behavior: Sendable {
        case success(String)
        case failure(FakeFailure)
        case suspended
    }

    private let behavior: Behavior
    private var pending: CheckedContinuation<String, any Error>?
    private var callWaiter: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private(set) var localeIdentifier: String?
    private(set) var vocabulary: [String] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        let locale = request.locale
        let vocabulary = request.vocabulary
        let onPartialTranscript = request.onPartialTranscript
        callCount += 1
        localeIdentifier = locale.identifier
        self.vocabulary = vocabulary
        callWaiter?.resume()
        callWaiter = nil

        switch behavior {
        case .success(let transcript):
            onPartialTranscript?(transcript)
            return transcript
        case .failure(let error):
            if error == .speechPermission {
                throw TranscriptionError.speechRecognitionAccessDenied
            }
            if error == .languageModelInstalling {
                throw TranscriptionError.languageModelInstalling("Portuguese (Brazil)")
            }
            throw error
        case .suspended:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                }
            } onCancel: {
                Task { await self.cancelPending() }
            }
        }
    }

    func waitForCall() async {
        if callCount > 0 {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiter = continuation
        }
    }

    func waitForCancellation() async {
        if cancellationCount > 0 {
            return
        }

        await withCheckedContinuation { continuation in
            cancellationWaiter = continuation
        }
    }

    func succeed(_ transcript: String) {
        pending?.resume(returning: transcript)
        pending = nil
    }

    func fail(_ error: FakeFailure) {
        pending?.resume(throwing: error)
        pending = nil
    }

    private func cancelPending() {
        pending?.resume(throwing: CancellationError())
        pending = nil
        cancellationCount += 1
        cancellationWaiter?.resume()
        cancellationWaiter = nil
    }
}

actor FakeTextTransformer: TextTransformer {
    enum Behavior: Sendable {
        case success(String)
        case failure(FakeFailure)
        case suspended
    }

    private let behavior: Behavior
    private var pending: CheckedContinuation<String, any Error>?
    private var callWaiter: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private(set) var receivedText: String?
    private(set) var receivedInstruction: String?

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        callCount += 1
        receivedText = text
        receivedInstruction = instruction
        callWaiter?.resume()
        callWaiter = nil

        switch behavior {
        case .success(let transformedText):
            return transformedText
        case .failure(let error):
            throw error
        case .suspended:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                }
            } onCancel: {
                Task { await self.cancelPending() }
            }
        }
    }

    func waitForCall() async {
        if callCount > 0 {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiter = continuation
        }
    }

    func waitForCancellation() async {
        if cancellationCount > 0 {
            return
        }

        await withCheckedContinuation { continuation in
            cancellationWaiter = continuation
        }
    }

    func succeed(_ transformedText: String) {
        pending?.resume(returning: transformedText)
        pending = nil
    }

    private func cancelPending() {
        pending?.resume(throwing: CancellationError())
        pending = nil
        cancellationCount += 1
        cancellationWaiter?.resume()
        cancellationWaiter = nil
    }
}

actor QueuedTranscriber: Transcriber {
    private var transcripts: [String]
    private(set) var localeIdentifiers: [String] = []
    private(set) var vocabularies: [[String]] = []

    init(_ transcripts: [String]) {
        self.transcripts = transcripts
    }

    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        let locale = request.locale
        let vocabulary = request.vocabulary
        localeIdentifiers.append(locale.identifier)
        vocabularies.append(vocabulary)
        guard transcripts.isEmpty == false else {
            return ""
        }
        return transcripts.removeFirst()
    }
}

actor QueuedTextTransformer: TextTransformer {
    private var translations: [String]
    private(set) var receivedTexts: [String] = []
    private(set) var receivedInstructions: [String] = []

    init(_ translations: [String]) {
        self.translations = translations
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        receivedTexts.append(text)
        receivedInstructions.append(instruction)
        guard translations.isEmpty == false else {
            return ""
        }
        return translations.removeFirst()
    }
}

actor SuspendedTextTransformerProvider: TransformerSource {
    private let providedTextTransformer: any TextTransformer
    private var pending: CheckedContinuation<any TextTransformer, Never>?
    private var callWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(transformer: any TextTransformer) {
        self.providedTextTransformer = transformer
    }

    func transformer(
        for provider: TranslationProvider,
        instruction: String
    ) async -> any TextTransformer {
        callCount += 1
        callWaiter?.resume()
        callWaiter = nil

        return await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    func waitForCall() async {
        if callCount > 0 {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiter = continuation
        }
    }

    func resume() {
        pending?.resume(returning: providedTextTransformer)
        pending = nil
    }
}

struct StaticErrorTextTransformer: TextTransformer {
    let error: any Error & Sendable

    func transform(_ text: String, instruction: String) async throws -> String {
        throw error
    }
}

struct FakeStreamingTextTransformer: StreamingTextTransformer {
    let atomicOutput: String
    let deltas: [String]
    let terminalError: FakeFailure?
    let providedStream: AsyncThrowingStream<String, any Error>?

    init(
        atomicOutput: String = "Atomic result",
        deltas: [String],
        terminalError: FakeFailure? = nil
    ) {
        self.atomicOutput = atomicOutput
        self.deltas = deltas
        self.terminalError = terminalError
        self.providedStream = nil
    }

    init(
        atomicOutput: String = "Atomic result",
        stream: AsyncThrowingStream<String, any Error>
    ) {
        self.atomicOutput = atomicOutput
        self.deltas = []
        self.terminalError = nil
        self.providedStream = stream
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        atomicOutput
    }

    func transformStream(
        _ text: String,
        instruction: String
    ) -> AsyncThrowingStream<String, any Error> {
        if let providedStream {
            return providedStream
        }

        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            if let terminalError {
                continuation.finish(throwing: terminalError)
            } else {
                continuation.finish()
            }
        }
    }
}

@MainActor
final class SpyPasteboard: PasteboardWriting {
    private(set) var writes: [String] = []

    func write(_ string: String) throws {
        writes.append(string)
    }
}

@MainActor
final class FailingPasteboard: PasteboardWriting {
    func write(_ string: String) throws {
        throw ClipboardError.writeFailed
    }
}

actor SpyRecordingArchive: RecordingArchiving {
    struct Commit: Equatable, Sendable {
        let id: UUID
        let localeID: String
        let appleTranscript: String
    }

    struct Snapshot: Sendable {
        let begunEntryIDs: [UUID]
        let commits: [Commit]
        let discardedEntryIDs: [UUID]
        let deletedEntryIDs: [UUID]
        let deleteAllCount: Int
    }

    private(set) var begunEntryIDs: [UUID] = []
    private(set) var commits: [Commit] = []
    private(set) var discardedEntryIDs: [UUID] = []
    private(set) var deletedEntryIDs: [UUID] = []
    private(set) var deleteAllCount = 0
    private let deleteAllError: RecordingArchiveError?

    init(deleteAllError: RecordingArchiveError? = nil) {
        self.deleteAllError = deleteAllError
    }

    func beginEntry(id: UUID) async throws -> URL {
        begunEntryIDs.append(id)
        return FileManager.default.temporaryDirectory
            .appending(path: "SyrupSpyRecordingArchive.\(id.uuidString).wav")
    }

    func commitEntry(id: UUID, localeID: String, appleTranscript: String) async {
        commits.append(Commit(
            id: id,
            localeID: localeID,
            appleTranscript: appleTranscript
        ))
    }

    func discardEntry(id: UUID) async -> Bool {
        discardedEntryIDs.append(id)
        return true
    }

    func unresolvedDeletions() async -> Set<UUID> { [] }

    func pendingEntryCounts() async -> AsyncStream<Int> {
        let count = await pendingEntries().count
        return AsyncStream { $0.yield(count); $0.finish() }
    }

    func pendingEntries() async -> [RecordingSidecar] {
        []
    }

    func audioFileURL(id: UUID) async -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SyrupSpyRecordingArchive.\(id.uuidString).wav")
    }

    func recordAttempt(id: UUID) async -> Int {
        1
    }

    func deleteEntry(id: UUID) async -> Bool {
        deletedEntryIDs.append(id)
        return true
    }

    func deleteAll() async throws {
        deleteAllCount += 1
        if let deleteAllError {
            throw deleteAllError
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            begunEntryIDs: begunEntryIDs,
            commits: commits,
            discardedEntryIDs: discardedEntryIDs,
            deletedEntryIDs: deletedEntryIDs,
            deleteAllCount: deleteAllCount
        )
    }
}

@MainActor
final class SpyAutoPaster: AutoPasting {
    var isTrusted: Bool
    var pasteError: (any Error)?
    var strategy: PasteStrategy = .commandV(9)
    private(set) var requestTrustCount = 0
    private(set) var pasteCount = 0

    init(isTrusted: Bool = true, pasteError: (any Error)? = nil) {
        self.isTrusted = isTrusted
        self.pasteError = pasteError
    }

    func requestTrust() {
        requestTrustCount += 1
    }

    func paste(keyCode: UInt16) throws {
        pasteCount += 1
        if let pasteError {
            throw pasteError
        }
    }
}

@MainActor
final class SpyStreamingTypist: StreamingTyping {
    var startError: AutoPasteError?
    var stopAfterFirstAppend: StreamingTypingStopReason?
    var postsTextOnAppend = false
    var onTextPosted: (() -> Void)?
    private(set) var startCount = 0
    private(set) var appendedDeltas: [String] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var stopReason: StreamingTypingStopReason?
    private(set) var hasPostedText = false

    func start() throws {
        startCount += 1
        hasPostedText = false
        if let startError {
            throw startError
        }
    }

    func typeText(_ text: String) throws {
        try start()
        append(text)
        finish()
    }

    func addLeadingSpace() {
        append(" ")
    }

    func append(_ delta: String) {
        guard stopReason == nil else { return }
        appendedDeltas.append(delta)
        if postsTextOnAppend, delta.isEmpty == false {
            if hasPostedText == false { onTextPosted?() }
            hasPostedText = true
        }
        if appendedDeltas.count == 1, let stopAfterFirstAppend {
            stopReason = stopAfterFirstAppend
        }
    }

    func finish() {
        finishCount += 1
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
final class SpyFeedback: AppFeedbackProviding {
    private(set) var successSoundCount = 0
    private(set) var successSounds: [SuccessSound] = []
    private(set) var errorMessages: [String] = []
    private(set) var autoStoppedDurations: [Int] = []
    private(set) var autoPasteNotTrustedCount = 0
    private(set) var autoPasteSecureInputCount = 0
    private(set) var streamingFocusChangedCount = 0
    private(set) var streamingSecureInputCount = 0
    private(set) var transformationFailures: [(
        message: String,
        recordID: UUID,
        allowsTranscriptFallback: Bool,
        allowsRetry: Bool
    )] = []

    func playSuccessSound(_ sound: SuccessSound) {
        successSoundCount += 1
        successSounds.append(sound)
    }

    func notifyError(message: String) {
        errorMessages.append(message)
    }

    func notifyRecordingAutoStopped(afterSeconds seconds: Int) {
        autoStoppedDurations.append(seconds)
    }

    func notifyAutoPasteNotTrusted() {
        autoPasteNotTrustedCount += 1
    }

    func notifyAutoPasteSecureInput() {
        autoPasteSecureInputCount += 1
    }

    func notifyStreamingFocusChanged() {
        streamingFocusChangedCount += 1
    }

    func notifyStreamingSecureInput() {
        streamingSecureInputCount += 1
    }

    func notifyTransformationFailed(
        message: String,
        recordID: UUID,
        allowsTranscriptFallback: Bool,
        allowsRetry: Bool
    ) {
        transformationFailures.append((
            message,
            recordID,
            allowsTranscriptFallback,
            allowsRetry
        ))
    }
}

@MainActor
final class FakeSelectionReader: SelectionReading {
    var result: SelectionCapture
    private(set) var captureCallCount = 0

    init(_ result: SelectionCapture) {
        self.result = result
    }

    func captureForRun(processID: pid_t?) async -> RunSelectionCapture {
        captureCallCount += 1
        return RunSelectionCapture(selection: result)
    }
}

@MainActor
final class SpyPipelineMetrics: PipelineMetricsRecording {
    private(set) var begunStages: [PipelineMetricStage] = []
    private(set) var endedStages: [PipelineMetricStage] = []
    private(set) var discardedRunIDs: [UUID] = []
    private(set) var deliveryModes: [PipelineDeliveryMode] = []

    func begin(_ stage: PipelineMetricStage, runID: UUID) {
        begunStages.append(stage)
    }

    func end(_ stage: PipelineMetricStage, runID: UUID) {
        endedStages.append(stage)
    }

    private(set) var recordedDurations: [(PipelineMetricStage, Duration)] = []
    func recordDuration(_ stage: PipelineMetricStage, duration: Duration, runID: UUID) {
        recordedDurations.append((stage, duration))
    }
    private(set) var quietDurations: [Duration] = []
    private(set) var pauseOutcomes: [(PauseTransformationOutcome, Int)] = []

    func recordQuietBeforeRelease(_ duration: Duration, runID: UUID) { quietDurations.append(duration) }
    func recordPauseTransformation(_ outcome: PauseTransformationOutcome, attemptCount: Int, runID: UUID) {
        pauseOutcomes.append((outcome, attemptCount))
    }

    func discard(runID: UUID) {
        discardedRunIDs.append(runID)
    }

    func recordDeliveryMode(_ mode: PipelineDeliveryMode, runID: UUID) {
        deliveryModes.append(mode)
    }
}

actor ManualResetSleeper {
    private var nextID = 0
    private var callCount = 0
    private var cancellationCount = 0
    private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = nextID
                nextID += 1
                callCount += 1
                continuations[id] = continuation
                resumeSatisfiedCallWaiters()
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitForCallCount(_ expectedCount: Int) async {
        if callCount >= expectedCount {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiters.append((expectedCount, continuation))
        }
    }

    func waitForCancellationCount(_ expectedCount: Int) async {
        if cancellationCount >= expectedCount {
            return
        }

        await withCheckedContinuation { continuation in
            cancellationWaiters.append((expectedCount, continuation))
        }
    }

    func observedCallCount() -> Int {
        callCount
    }

    func resumeCall(_ id: Int, throwing error: any Error) {
        continuations.removeValue(forKey: id)?.resume(throwing: error)
    }

    func resumeCall(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume()
    }

    func resumeAll(throwing error: any Error) {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }

    private func recordCancellation() {
        cancellationCount += 1
        resumeSatisfiedCancellationWaiters()
    }

    private func resumeSatisfiedCallWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callWaiters {
            if callCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callWaiters = remaining
    }

    private func resumeSatisfiedCancellationWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in cancellationWaiters {
            if cancellationCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        cancellationWaiters = remaining
    }
}

extension AppState {
    /// An `AppState` whose every service is a fake unless the test passes one. Labels and order
    /// match the production initializer, plus `transformer:` for a fixed transformer.
    static func fixture(
        settings: AppSettings,
        transcriberAssetManager: TranscriberAssetManager = TranscriberAssetManager(),
        history: HistoryStore? = nil,
        keychainStore: KeychainStore? = nil,
        audioRecorder: (any AudioRecording)? = nil,
        transcriber: (any Transcriber)? = nil,
        speechModels: [SpeechEngine: InstalledSpeechModel] = [:],
        usageStats: UsageStatsStore = UsageStatsStore(),
        transformer: (any TextTransformer)? = nil,
        transformerProvider: (any TransformerSnapshotting)? = nil,
        pasteboard: any PasteboardWriting = SpyPasteboard(),
        feedback: any AppFeedbackProviding = SpyFeedback(),
        metrics: any PipelineMetricsRecording = SpyPipelineMetrics(),
        autoPaster: any AutoPasting = SpyAutoPaster(isTrusted: false),
        streamingTypistFactory: @escaping () -> any StreamingTyping = { SpyStreamingTypist() },
        errorResetDelayNanoseconds: UInt64 = 4_000_000_000,
        errorResetSleeper: @escaping ErrorResetSleeper = { try await Task.sleep(nanoseconds: $0) },
        feedbackFlashDurationNanoseconds: UInt64 = 1_000_000_000,
        feedbackFlashSleeper: @escaping FeedbackFlashSleeper = { try await Task.sleep(nanoseconds: $0) },
        maximumRecordingDurationNanoseconds: UInt64? = nil,
        recordingDurationSleeper: @escaping RecordingDurationSleeper = { try await Task.sleep(nanoseconds: $0) },
        autoPasteDelayNanoseconds: UInt64 = 50_000_000,
        autoPasteSleeper: @escaping AutoPasteSleeper = { try await Task.sleep(nanoseconds: $0) },
        recordingClock: any RecordingClock = ContinuousRecordingClock(),
        processActivity: any ProcessActivityControlling = ProcessInfo.processInfo,
        installHotkeys: Bool = false,
        selectionReader: any SelectionReading = FakeSelectionReader(.empty),
        recordingCue: (any RecordingCuePresenting)? = nil,
        recordingArchive: (any RecordingArchiving)? = nil,
        outputDucker: OutputDucker? = nil,
        frontmostApplication: @escaping @MainActor (Bool) -> (bundleID: String?, processID: pid_t?) = { _ in (nil, nil) },
        captureDeliveryTarget: @escaping @MainActor (pid_t?) async -> DeliveryTarget? = { _ in nil }
    ) -> AppState {
        AppState(
            settings: settings,
            transcriberAssetManager: transcriberAssetManager,
            history: history ?? HistoryStore(),
            keychainStore: keychainStore ?? KeychainStore(
                storageDirectory: FileManager.default.temporaryDirectory.appending(path: "SyrupTestSecrets-\(UUID().uuidString)")
            ),
            audioRecorder: audioRecorder ?? FakeRecorder(),
            transcriber: transcriber ?? FakeTranscriber(.success("")),
            speechModels: speechModels,
            usageStats: usageStats,
            transformerProvider: transformerProvider
                ?? StaticTransformerProvider(transformer: transformer ?? FakeTextTransformer(.success(""))),
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            autoPaster: autoPaster,
            streamingTypistFactory: streamingTypistFactory,
            selectionReader: selectionReader,
            processActivity: processActivity,
            recordingCue: recordingCue,
            recordingArchive: recordingArchive,
            outputDucker: outputDucker,
            frontmostApplication: frontmostApplication,
            captureDeliveryTarget: captureDeliveryTarget,
            errorResetDelayNanoseconds: errorResetDelayNanoseconds,
            errorResetSleeper: errorResetSleeper,
            feedbackFlashDurationNanoseconds: feedbackFlashDurationNanoseconds,
            feedbackFlashSleeper: feedbackFlashSleeper,
            maximumRecordingDurationNanoseconds: maximumRecordingDurationNanoseconds,
            recordingDurationSleeper: recordingDurationSleeper,
            autoPasteDelayNanoseconds: autoPasteDelayNanoseconds,
            autoPasteSleeper: autoPasteSleeper,
            recordingClock: recordingClock,
            installHotkeys: installHotkeys
        )
    }
}
