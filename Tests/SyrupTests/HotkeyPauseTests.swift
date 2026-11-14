import AVFoundation
import Foundation
import KeyboardShortcuts
import Synchronization
import Testing
@testable import Syrup

/// Pausing and resuming shortcuts.
@MainActor
struct HotkeyPauseTests {
    @Test func pauseUnregistersShortcutsAndResumeUsesCurrentWorkflows() {
        let suite = testDomainName("SyrupHotkeyCorrection")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("fixture")), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster())
        let registration = CorrectionHotkeyRegistration()
        let controller = HotkeyController(appState: state, registration: registration)
        let removed = UUID()
        let added = UUID()
        controller.rebuildWorkflowShortcuts(workflowIDs: [removed])
        controller.setCancelShortcutEnabled(true)
        let enableCount = registration.enableCount
        controller.rebuildWorkflowShortcuts(workflowIDs: [removed])
        #expect(registration.enableCount == enableCount)
        controller.setListening(false)
        #expect(registration.enabled.isEmpty)
        controller.rebuildWorkflowShortcuts(workflowIDs: [added])
        #expect(registration.enabled.isEmpty)
        controller.setCancelShortcutEnabled(false)
        controller.setListening(true)
        #expect(registration.enabled == [.dictate, .revise, .pasteLast, .dictateWorkflow(added)])
        #expect(!registration.enabled.contains(.dictateWorkflow(removed)))
    }

    @Test func appPauseKeepsEditedWorkflowShortcutsDetached() {
        let suite = testDomainName("SyrupPauseCorrection")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let state = AppState.fixture(settings: settings,
            transcriberAssetManager: TranscriberAssetManager(prepare: { _ in .installed("fixture") }),
            audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("fixture")),
            transformer: FakeTextTransformer(.success("fixture")), pasteboard: SpyPasteboard(),
            feedback: SpyFeedback(), autoPaster: SpyAutoPaster())
        let registration = CorrectionHotkeyRegistration()
        state.installHotkeys(registration: registration)
        #expect(registration.enabled.contains(.dictate))
        state.isHotkeyPaused = true
        let newID = settings.addWorkflow(from: WorkflowTemplate.templates()[0])
        registration.enabled.insert(.dictate)
        registration.enabled.insert(.dictateWorkflow(newID))
        state.refreshWorkflowHotkeys()
        #expect(registration.enabled.isEmpty)
        state.isHotkeyPaused = false
        #expect(registration.enabled.contains(.dictateWorkflow(newID)))
        #expect(!registration.enabled.contains(.cancelDictation))
    }
}

@MainActor private final class CorrectionHotkeyRegistration: HotkeyRegistering {
    var enabled: Set<KeyboardShortcuts.Name> = []
    var enableCount = 0
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func enable(_ name: KeyboardShortcuts.Name) { enabled.insert(name); enableCount += 1 }
    func disable(_ name: KeyboardShortcuts.Name) { enabled.remove(name) }
}
