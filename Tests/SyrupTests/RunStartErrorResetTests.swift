import Foundation
import Testing
@testable import Syrup

@MainActor
struct RunStartErrorResetTests {
    @Test func delayedErrorClearReportsWhetherARunOwnsThePipeline() async {
        let state = AppState.fixture(settings: makeTestSettings(), transcriber: FakeTranscriber(.suspended))
        #expect(state.clearErrorAfterDelay())
        state.triggerPressed()
        #expect(state.pipelineState == .recording)
        #expect(state.clearErrorAfterDelay() == false)
        #expect(state.pipelineState == .recording)
        state.cancelRequested()
        await state.waitForPendingWork()
        #expect(state.clearErrorAfterDelay())
    }

    @Test func emptySelectedTextErrorClearsAfterItsDelay() async throws {
        let reset = ManualResetSleeper()
        let settings = makeTestSettings()
        let template = try #require(WorkflowTemplate.templates().first { $0.id == "summarize-selection" })
        settings.addWorkflow(from: template)
        let state = AppState.fixture(
            settings: settings, transformer: FakeTextTransformer(.success("unused")),
            errorResetSleeper: { try await reset.sleep(nanoseconds: $0) },
            selectionReader: FakeSelectionReader(.empty)
        )
        state.triggerPressed()
        await state.waitForPendingWork()
        #expect(state.pipelineState.isError)
        #expect(state.activeRunID == nil)
        let resetStarted = await eventually { await reset.observedCallCount() == 1 }
        guard resetStarted else { return }
        await reset.resumeCall(0)
        await eventually { state.pipelineState == .idle }
    }
}
