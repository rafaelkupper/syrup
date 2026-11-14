import Foundation
import Observation
import os
import Testing
@testable import Syrup

@MainActor
struct MishearingSuggestionModelTests {
    @Test func idleAndLocaleOrderReflectCurrentVoiceWorkflows() {
        withSettings { settings in
            let workflows = [workflow("en-US"), workflow("fr-FR", input: .selection), workflow("pt_BR"),
                             workflow("en_US"), workflow("de-DE"), workflow("it-IT")]
            settings.workflowList = WorkflowList(workflows: workflows, activeWorkflowID: workflows[2].id)
            let model = MishearingSuggestionModel(settings: settings, engine: ModelTestProbe())
            #expect(model.localeIDs == ["pt-BR", "en-US", "de-DE"])
            #expect(model.state(for: UUID()) == .idle)
            settings.workflowList = WorkflowList(workflows: [workflow("en-US", input: .selection)])
            #expect(model.localeIDs.isEmpty)
            #expect(!model.canProbe)
        }
    }

    @Test func sequentialProgressStatesAndSharedVocabulary() async {
        await withSettings { settings, _ in
            let terms = [GlossaryTerm(term: "Grafana"), GlossaryTerm(term: "Nginx")]
            settings.glossaryList = GlossaryList(terms: terms)
            settings.includeCommonTechTerms = true
            let engine = ModelTestProbe()
            engine.suspends = true
            let model = MishearingSuggestionModel(settings: settings, engine: engine)
            let task = Task { await model.probeAll() }
            await engine.waitForCall(1)
            #expect(model.isRunning)
            #expect(model.progress == .init(done: 0, total: 2))
            #expect(model.state(for: terms[0].id) == .running)
            await model.probeAll()
            #expect(engine.calls.count == 1)
            engine.finishNext(.success(result(forms: ["Graph ana"])))
            await engine.waitForCall(2)
            #expect(model.progress == .init(done: 1, total: 2))
            #expect(model.state(for: terms[0].id) == .results(result(forms: ["Graph ana"])))
            engine.finishNext(.success(result(forms: [], exact: 1)))
            await task.value
            #expect(model.state(for: terms[1].id) == .recognizedCorrectly(result(forms: [], exact: 1)))
            #expect(model.progress == .init(done: 2, total: 2))
            #expect(!model.isRunning)
            #expect(engine.calls.map(\.term) == terms)
            #expect(engine.calls[0].vocabulary == AppSettings.composedSpeechVocabulary(
                glossary: settings.glossaryList, includeCommonTechTerms: true))
        }
    }

    @Test func viewsReadingAnUncheckedTermHearItsFirstCheck() async {
        await withSettings { settings, _ in
            let term = GlossaryTerm(term: "Grafana")
            settings.glossaryList = GlossaryList(terms: [term])
            let engine = ModelTestProbe()
            engine.suspends = true
            let model = MishearingSuggestionModel(settings: settings, engine: engine)
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = model.state(for: term.id)
            } onChange: {
                changed.withLock { $0 = true }
            }
            let task = Task { await model.probe(termID: term.id) }
            await engine.waitForCall(1)
            #expect(changed.withLock { $0 })
            engine.finishNext(.success(result(forms: [])))
            await task.value
        }
    }

    @Test func acceptancePersistsThroughSettingsAndDismissalOnlyLivesInMemory() async {
        await withSettings { settings, defaults in
            let term = GlossaryTerm(term: "Grafana", mishearings: ["Known"])
            settings.glossaryList = GlossaryList(terms: [term])
            let engine = ModelTestProbe()
            engine.nextResult = result(forms: ["Graph ana", "Gráfana"])
            let model = MishearingSuggestionModel(settings: settings, engine: engine)
            await model.probe(termID: term.id)
            model.dismiss("Graph ana", for: term.id)
            #expect(settings.glossaryList.terms[0].mishearings == ["Known"])
            await model.probe(termID: term.id)
            #expect(model.state(for: term.id) == .results(result(forms: ["Gráfana"])))
            #expect(!model.accept("fabricated", for: term.id))
            #expect(model.accept("Gráfana", for: term.id))
            #expect(!model.accept("Gráfana", for: term.id))
            #expect(settings.glossaryList.terms[0].mishearings == ["Known", "Gráfana"])
            let reloaded = AppSettings(userDefaults: defaults)
            #expect(reloaded.glossaryList == settings.glossaryList)
            let fresh = MishearingSuggestionModel(settings: settings, engine: engine)
            #expect(fresh.state(for: term.id) == .idle)
            await fresh.probe(termID: term.id)
            #expect(fresh.state(for: term.id) == .results(result(forms: ["Graph ana"])))
        }
    }

    @Test(arguments: [false, true])
    func cancellationRestoresStateAndForegroundBlocksStarts(_ foreground: Bool) async {
        await withSettings { settings, _ in
            let terms = [GlossaryTerm(term: "Grafana"), GlossaryTerm(term: "Nginx")]
            settings.glossaryList = GlossaryList(terms: terms)
            let engine = ModelTestProbe()
            engine.suspends = true
            let model = MishearingSuggestionModel(settings: settings, engine: engine)
            let task = Task { await model.probeAll() }
            await engine.waitForCall(1)
            if foreground { model.setForegroundActive(true) } else { model.cancel() }
            // Simulate a framework that completes after cancellation instead of throwing.
            engine.finishNext(.success(result(forms: ["Late result"])))
            await task.value
            #expect(!model.isRunning)
            #expect(model.state(for: terms[0].id) == .idle)
            #expect(model.state(for: terms[1].id) == .idle)
            #expect(model.progress == .init(done: 0, total: 2))
            if foreground {
                await model.probe(termID: terms[1].id)
                #expect(engine.calls.count == 1)
                model.setForegroundActive(false)
                #expect(model.canProbe)
            }
        }
    }

    @Test func callerCancellationReachesOwnedTask() async {
        await withSettings { settings, _ in
            let term = GlossaryTerm(term: "Grafana")
            settings.glossaryList = GlossaryList(terms: [term])
            let engine = ModelTestProbe()
            engine.suspends = true
            let model = MishearingSuggestionModel(settings: settings, engine: engine)
            let task = Task { await model.probe(termID: term.id) }
            await engine.waitForCall(1)
            task.cancel()
            engine.finishNext(.success(result(forms: ["Late"])))
            await task.value
            #expect(model.state(for: term.id) == .idle)
            #expect(!model.isRunning)
        }
    }

    @Test func unavailableFailedAndDiscardedStates() async {
        await withSettings { settings, _ in
            let term = GlossaryTerm(term: "Grafana")
            settings.glossaryList = GlossaryList(terms: [term])
            let engine = ModelTestProbe()
            let model = MishearingSuggestionModel(settings: settings, engine: engine)
            let issues = [MishearingProbeLocaleIssue(localeID: "en-US", reason: .noVoice)]
            engine.nextResult = MishearingProbeResult(heardForms: [], sampleCount: 0, exactMatchCount: 0,
                discardedSampleCount: 0, failedSampleCount: 0, unavailableLocales: issues)
            await model.probeAll()
            #expect(model.state(for: term.id) == .unavailable(issues))
            engine.nextResult = MishearingProbeResult(heardForms: [], sampleCount: 0, exactMatchCount: 0,
                discardedSampleCount: 1, failedSampleCount: 0, unavailableLocales: [])
            await model.probeAll()
            #expect(model.state(for: term.id) == .failed(.noUsableSamples))
            engine.error = .timedOut
            await model.probeAll()
            #expect(model.state(for: term.id) == .failed(.timedOut))
        }
    }

    @Test func editsDuringProbeDiscardStaleResultsAndAcceptanceMergesCurrentHints() async {
        await withSettings { settings, _ in
            let term = GlossaryTerm(term: "Grafana")
            settings.glossaryList = GlossaryList(terms: [term])
            let engine = ModelTestProbe()
            engine.suspends = true
            let model = MishearingSuggestionModel(settings: settings, engine: engine)
            let task = Task { await model.probeAll() }
            await engine.waitForCall(1)
            settings.updateGlossaryTerm(id: term.id, term: "Renamed", mishearings: [])
            engine.finishNext(.success(result(forms: ["Old"])))
            await task.value
            #expect(model.state(for: term.id) == .idle)
            #expect(!model.accept("Old", for: term.id))
            engine.suspends = false
            engine.nextResult = result(forms: ["New"])
            await model.probeAll()
            settings.updateGlossaryTerm(id: term.id, term: "Renamed", mishearings: ["Manual"])
            #expect(model.accept("New", for: term.id))
            #expect(settings.glossaryList.terms[0].mishearings == ["Manual", "New"])
            settings.deleteGlossaryTerm(id: term.id)
            #expect(model.state(for: term.id) == .idle)
        }
    }

    private func withSettings(_ body: (AppSettings) -> Void) {
        let name = testDomainName("MishearingSuggestionTests")
        let defaults = TestDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(AppSettings(userDefaults: defaults))
    }

    private func withSettings(_ body: @MainActor (AppSettings, UserDefaults) async -> Void) async {
        let name = testDomainName("MishearingSuggestionTests")
        let defaults = TestDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        await body(AppSettings(userDefaults: defaults), defaults)
    }
}

private func result(forms: [String], exact: Int = 0) -> MishearingProbeResult {
    .init(heardForms: forms, sampleCount: 1, exactMatchCount: exact,
          discardedSampleCount: 0, failedSampleCount: 0, unavailableLocales: [])
}

private func workflow(_ locale: String, input: WorkflowInput = .voice) -> Workflow {
    .init(id: UUID(), name: "Test", kind: .custom(instruction: "Test", enforceOutputContract: false),
          dictationLocaleID: locale, translationProvider: nil, input: input)
}

@MainActor private final class ModelTestProbe: MishearingProbing {
    struct Call { let term: GlossaryTerm; let vocabulary: [String] }
    var calls: [Call] = []
    var suspends = false
    var nextResult = result(forms: [])
    var error: MishearingProbeFailure?
    private var pending: CheckedContinuation<MishearingProbeResult, any Error>?
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func probe(term: GlossaryTerm, localeIDs: [String], vocabulary: [String]) async throws -> MishearingProbeResult {
        calls.append(Call(term: term, vocabulary: vocabulary))
        if let error { throw error }
        if suspends {
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                notifyWaiters()
            }
        }
        notifyWaiters()
        return nextResult
    }

    func waitForCall(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    private func notifyWaiters() {
        let ready = callWaiters.filter { $0.0 <= calls.count }
        callWaiters.removeAll { $0.0 <= calls.count }
        ready.forEach { $0.1.resume() }
    }

    func finishNext(_ result: Result<MishearingProbeResult, any Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
