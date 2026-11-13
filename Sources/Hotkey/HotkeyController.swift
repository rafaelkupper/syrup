import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self(
        "dictate",
        default: .init(.backtick, modifiers: [.option])
    )

    static let revise = Self(
        "revise",
        default: .init(.backtick, modifiers: [.option, .shift])
    )

    static let pasteLast = Self("pasteLast")

    static let cancelDictation = Self(
        "cancelDictation",
        default: .init(.escape)
    )

    static func dictateWorkflow(_ id: UUID) -> Self {
        Self("dictateWorkflow-\(id.uuidString)")
    }
}

@MainActor
protocol HotkeyRegistering {
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void)
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void)
    func enable(_ name: KeyboardShortcuts.Name)
    func disable(_ name: KeyboardShortcuts.Name)
}

final class SystemHotkeyRegistration: HotkeyRegistering {
    private var keyDownActions: [KeyboardShortcuts.Name: () -> Void] = [:]
    private var keyUpActions: [KeyboardShortcuts.Name: () -> Void] = [:]

    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        keyDownActions[name] = action
    }
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        keyUpActions[name] = action
    }
    func enable(_ name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.removeHandler(for: name)
        if let action = keyDownActions[name] { KeyboardShortcuts.onKeyDown(for: name, action: action) }
        if let action = keyUpActions[name] { KeyboardShortcuts.onKeyUp(for: name, action: action) }
    }
    func disable(_ name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.removeHandler(for: name)
    }
}

@MainActor
final class HotkeyController {
    private static let fnToggleMaximumTap: TimeInterval = 0.5
    private var isCancelShortcutEnabled = false
    private var isListening = false
    private let registration: any HotkeyRegistering
    private var registeredWorkflowIDs: Set<UUID> = []
    private weak var appState: AppState?
    private let fnKeyMonitor: FnKeyMonitor
    private let isTypingInSyrup: () -> Bool
    private var isFnKeyEnabled = false
    private var fnStartedRun = false
    /// A double-tap in hold mode keeps recording after Fn is released, until the next double-tap.
    private var isFnLatched = false {
        didSet { appState?.isFnRecordingLatched = isFnLatched }
    }
    /// The first tap of a possible double-tap landed while nothing was running.
    private var isFnDoubleTapArmed = false

    init(
        appState: AppState,
        registration: any HotkeyRegistering = SystemHotkeyRegistration(),
        fnKeyMonitor: FnKeyMonitor = FnKeyMonitor(),
        isTypingInSyrup: @escaping () -> Bool = { NSApp.isActive && NSApp.keyWindow?.firstResponder is NSText }
    ) {
        self.appState = appState
        self.registration = registration
        self.fnKeyMonitor = fnKeyMonitor
        self.isTypingInSyrup = isTypingInSyrup

        fnKeyMonitor.onEvent = { [weak self] event in
            self?.handleFnKey(event)
        }

        registration.onKeyDown(for: .dictate) { [weak appState] in
            Task { @MainActor in
                appState?.triggerPressed()
            }
        }

        registration.onKeyUp(for: .dictate) { [weak appState] in
            Task { @MainActor in
                appState?.triggerReleased()
            }
        }

        registration.onKeyDown(for: .revise) { [weak appState] in
            Task { @MainActor in
                appState?.revisionTriggerPressed()
            }
        }

        registration.onKeyUp(for: .revise) { [weak appState] in
            Task { @MainActor in
                appState?.revisionTriggerReleased()
            }
        }

        registration.onKeyDown(for: .pasteLast) { [weak appState] in
            Task { @MainActor in await appState?.pasteLastResult() }
        }

        registration.onKeyDown(for: .cancelDictation) { [weak appState] in
            Task { @MainActor in
                appState?.cancelRequested()
            }
        }

        registration.disable(.cancelDictation)
        setListening(appState.isHotkeyPaused == false)
    }

    func rebuildWorkflowShortcuts(workflowIDs: [UUID]) {
        let nextIDs = Set(workflowIDs)
        let removedIDs = registeredWorkflowIDs.subtracting(nextIDs)
        let addedIDs = nextIDs.subtracting(registeredWorkflowIDs)

        for id in removedIDs {
            registration.disable(.dictateWorkflow(id))
        }

        for id in addedIDs {
            let name = KeyboardShortcuts.Name.dictateWorkflow(id)
            registration.onKeyDown(for: name) { [weak self] in
                Task { @MainActor in
                    guard self?.registeredWorkflowIDs.contains(id) == true else { return }
                    self?.handleWorkflowPress(id)
                }
            }
            registration.onKeyUp(for: name) { [weak self] in
                Task { @MainActor in
                    guard self?.registeredWorkflowIDs.contains(id) == true else { return }
                    self?.handleWorkflowRelease(id)
                }
            }
            if isListening { registration.enable(name) } else { registration.disable(name) }
        }

        registeredWorkflowIDs = nextIDs
        setListening(isListening)
    }

    private func handleWorkflowPress(_ id: UUID) {
        appState?.triggerPressed(workflowID: id)
    }

    private func handleWorkflowRelease(_ id: UUID) {
        appState?.triggerReleased(workflowID: id)
    }

    func setListening(_ listening: Bool) {
        if listening, isListening { return }
        isListening = listening
        let names: [KeyboardShortcuts.Name] = [.dictate, .revise, .pasteLast]
            + registeredWorkflowIDs.map { .dictateWorkflow($0) }
        for name in names {
            if listening { registration.enable(name) } else { registration.disable(name) }
        }
        if listening && isCancelShortcutEnabled {
            registration.enable(.cancelDictation)
        } else {
            registration.disable(.cancelDictation)
        }
        updateFnKeyMonitor()
    }

    func setFnKeyEnabled(_ isEnabled: Bool) {
        isFnKeyEnabled = isEnabled
        updateFnKeyMonitor()
    }

    private func updateFnKeyMonitor() {
        if isFnKeyEnabled, isListening {
            fnKeyMonitor.start()
        } else {
            fnKeyMonitor.stop()
            fnStartedRun = false
            isFnDoubleTapArmed = false
            if isFnLatched {
                // Nothing could stop this run with Fn any more, so it must not keep the microphone open.
                isFnLatched = false
                appState?.cancelRequested()
            }
        }
    }

    private func handleFnKey(_ event: FnKeyEvent) {
        guard let appState else { return }
        if isFnLatched, appState.pipelineState != .recording {
            isFnLatched = false
        }
        switch event {
        case .pressed:
            // Press to toggle acts on release, because a press could still become Fn+Delete.
            guard appState.settings.hotkeyMode == .hold, isFnLatched == false, isTypingInSyrup() == false,
                  appState.pipelineState == .idle || appState.pipelineState.isError else { return }
            fnStartedRun = true
            appState.triggerPressed()
        case .released(let heldFor, let completesDoubleTap):
            if fnStartedRun {
                fnStartedRun = false
                if completesDoubleTap {
                    isFnLatched = true
                } else {
                    appState.triggerReleased()
                }
            } else if isFnLatched {
                if completesDoubleTap {
                    isFnLatched = false
                    appState.triggerReleased()
                }
            } else if appState.settings.hotkeyMode == .toggle {
                handleFnToggleTap(appState, heldFor: heldFor, completesDoubleTap: completesDoubleTap)
            }
        case .combined:
            if fnStartedRun {
                fnStartedRun = false
                appState.cancelRequested()
            }
        }
    }

    /// A double-tap starts and a single tap stops, so a stray tap can never start a recording.
    private func handleFnToggleTap(_ appState: AppState, heldFor: TimeInterval, completesDoubleTap: Bool) {
        let wasArmed = isFnDoubleTapArmed
        isFnDoubleTapArmed = false
        switch appState.pipelineState {
        case .recording:
            if heldFor < Self.fnToggleMaximumTap {
                appState.triggerPressed()
            }
        case .idle, .error:
            // Without the arming check, a double-tap meant to stop would start a new recording once the result landed.
            if completesDoubleTap {
                if wasArmed, isTypingInSyrup() == false {
                    appState.triggerPressed()
                }
            } else {
                isFnDoubleTapArmed = heldFor < FnKeyGesture.maximumTap
            }
        case .transcribing, .translating:
            // A stray tap must not cancel a result that is on its way.
            break
        }
    }

    func setCancelShortcutEnabled(_ isEnabled: Bool) {
        guard isEnabled != isCancelShortcutEnabled else { return }

        isCancelShortcutEnabled = isEnabled
        if isEnabled && isListening {
            registration.enable(.cancelDictation)
        } else {
            registration.disable(.cancelDictation)
        }
    }
}
