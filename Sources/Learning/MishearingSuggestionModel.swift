import Foundation
import Observation

@MainActor
@Observable
final class MishearingSuggestionModel {
    enum TermState: Equatable, Sendable {
        case idle
        case running
        case results(MishearingProbeResult)
        case recognizedCorrectly(MishearingProbeResult)
        case unavailable([MishearingProbeLocaleIssue])
        case failed(MishearingProbeFailure)
    }

    struct Progress: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    private(set) var states: [UUID: TermState] = [:]
    private(set) var progress = Progress(done: 0, total: 0)
    private(set) var isRunning = false
    private(set) var isForegroundActive = false
    var canProbe: Bool { !isRunning && !isForegroundActive && !localeIDs.isEmpty }

    var localeIDs: [String] {
        let list = settings.workflowList
        let ordered = [list.activeWorkflow] + list.workflows.filter { $0.id != list.activeWorkflowID }
        var seen: Set<String> = []
        return Array(ordered.filter { $0.input == .voice }.map {
            Locale(identifier: $0.dictationLocaleID).identifier(.bcp47)
        }.filter { seen.insert($0.lowercased()).inserted }.prefix(3))
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: any MishearingProbing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var probedTerms: [UUID: String] = [:]
    @ObservationIgnored private var dismissed: [UUID: Set<String>] = [:]

    init(settings: AppSettings, engine: any MishearingProbing) {
        self.settings = settings
        self.engine = engine
    }

    func state(for termID: UUID) -> TermState {
        // Read the observed state first, so a view asking about a term that was never checked
        // still updates when a check of that term starts.
        let state = states[termID] ?? .idle
        guard let term = settings.glossaryList.terms.first(where: { $0.id == termID }),
              probedTerms[termID] == term.term else { return .idle }
        return state
    }

    func probe(termID: UUID) async {
        guard let term = settings.glossaryList.terms.first(where: { $0.id == termID }) else { return }
        await run([term])
    }

    func probeAll() async { await run(settings.glossaryList.terms) }

    func cancel() {
        task?.cancel()
    }

    func setForegroundActive(_ active: Bool) {
        isForegroundActive = active
        if active { cancel() }
    }

    @discardableResult
    func accept(_ form: String, for termID: UUID) -> Bool {
        guard let term = settings.glossaryList.terms.first(where: { $0.id == termID }),
              probedTerms[termID] == term.term,
              case .results(let result) = state(for: termID),
              let offered = result.heardForms.first(where: { MishearingForms.key($0) == MishearingForms.key(form) }),
              !term.mishearings.contains(where: { MishearingForms.key($0) == MishearingForms.key(offered) }) else { return false }
        settings.updateGlossaryTerm(id: termID, term: term.term, mishearings: term.mishearings + [offered])
        remove(offered, for: termID)
        return true
    }

    func dismiss(_ form: String, for termID: UUID) {
        guard case .results(let result) = state(for: termID),
              result.heardForms.contains(where: { MishearingForms.key($0) == MishearingForms.key(form) }) else { return }
        dismissed[termID, default: []].insert(MishearingForms.key(form))
        remove(form, for: termID)
    }

    private func remove(_ form: String, for termID: UUID) {
        guard case .results(var result) = states[termID] else { return }
        result.heardForms.removeAll { MishearingForms.key($0) == MishearingForms.key(form) }
        result.everydayForms.removeAll { MishearingForms.key($0) == MishearingForms.key(form) }
        states[termID] = .results(result)
    }

    private func run(_ terms: [GlossaryTerm]) async {
        guard canProbe, !terms.isEmpty else { return }
        let locales = localeIDs
        let vocabulary = AppSettings.composedSpeechVocabulary(
            glossary: settings.glossaryList, includeCommonTechTerms: settings.includeCommonTechTerms
        )
        isRunning = true
        progress = Progress(done: 0, total: terms.count)
        let work = Task { await process(terms, locales: locales, vocabulary: vocabulary) }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
        task = nil
        isRunning = false
    }

    private func process(_ terms: [GlossaryTerm], locales: [String], vocabulary: [String]) async {
        for term in terms {
            guard !Task.isCancelled else { break }
            guard settings.glossaryList.terms.contains(where: { $0.id == term.id && $0.term == term.term }) else {
                progress = Progress(done: progress.done + 1, total: progress.total)
                continue
            }
            if probedTerms[term.id] != term.term {
                dismissed[term.id] = nil
                states[term.id] = nil
            }
            probedTerms[term.id] = term.term
            let previous = states[term.id] ?? .idle
            states[term.id] = .running
            do {
                var result = try await engine.probe(term: term, localeIDs: locales, vocabulary: vocabulary)
                try Task.checkCancellation()
                guard let current = settings.glossaryList.terms.first(where: { $0.id == term.id }),
                      current.term == term.term else {
                    states[term.id] = nil
                    progress = Progress(done: progress.done + 1, total: progress.total)
                    continue
                }
                result.heardForms = MishearingForms.suggestions(result.heardForms, term: current).filter {
                    !(dismissed[term.id] ?? []).contains(MishearingForms.key($0))
                }
                if result.sampleCount == 0 {
                    states[term.id] = result.failedSampleCount == 0 && result.discardedSampleCount == 0
                        ? .unavailable(result.unavailableLocales) : .failed(.noUsableSamples)
                } else {
                    states[term.id] = result.recognizedCorrectly ? .recognizedCorrectly(result) : .results(result)
                }
            } catch is CancellationError {
                states[term.id] = previous
                break
            } catch {
                if Task.isCancelled { states[term.id] = previous; break }
                states[term.id] = .failed((error as? MishearingProbeFailure) ?? .recognitionFailed)
            }
            progress = Progress(done: progress.done + 1, total: progress.total)
        }
    }
}
