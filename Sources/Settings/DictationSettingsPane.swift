import AppKit
import KeyboardShortcuts
import SwiftUI

/// How you start a dictation and how Syrup listens.
struct DictationSettingsPane: View {
    @Bindable var settings: AppSettings
    let shortcutChangeHandler: () -> Void
    let deviceCatalog: any AudioInputDeviceCataloging = CoreAudioInputDeviceCatalog()
    @State private var microphones: [AudioInputDevice] = []

    var body: some View {
        Form {
            shortcutsSection
            microphoneSection
            whileSpeakingSection
            limitsSection
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshMicrophones)
        .onChange(of: settings.dictateWithFnKey) { shortcutChangeHandler() }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        Section {
            LabeledContent {
                KeyboardShortcuts.Recorder(for: .dictate) { _ in shortcutChangeHandler() }
            } label: {
                Text("Dictate")
                Text("Runs the workflow set for the app in front, or \(settings.activeWorkflow.name)")
            }

            LabeledContent {
                KeyboardShortcuts.Recorder(for: .revise) { _ in shortcutChangeHandler() }
            } label: {
                Text("Revise last result")
                Text("Say one change, like “shorter” or “more formal”")
            }

            LabeledContent("Paste last result") {
                KeyboardShortcuts.Recorder(for: .pasteLast) { _ in shortcutChangeHandler() }
            }

            LabeledContent {
                Picker("Shortcuts work by", selection: $settings.hotkeyMode) {
                    Text("Holding").tag(HotkeyMode.hold)
                    Text("Pressing twice").tag(HotkeyMode.toggle)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("Shortcuts work by")
                Text(settings.hotkeyMode == .hold ? "Hold to record, release to finish" : "Press once to start, again to finish")
            }

            LabeledContent {
                Toggle("Also use the Fn key", isOn: $settings.dictateWithFnKey)
                    .labelsHidden()
            } label: {
                Text("Also use the Fn key")
                Text(settings.hotkeyMode == .hold
                     ? "Hold Fn to talk, or double-tap to start and again to stop"
                     : "Double-tap Fn to start, and tap once to stop")
            }

            if settings.dictateWithFnKey {
                DisclosureGroup("Fn does something else too?") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("In Keyboard Settings, set “Press globe key to” to Do Nothing and turn off Press Fn Twice for Dictation, or macOS reacts too. Some third-party keyboards never send Fn to macOS, so Fn can't work on them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Keyboard Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Each workflow can also have its own shortcut, set in Workflows.")
                .font(.caption)
        }
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        Section("Microphone") {
            LabeledContent {
                HStack(spacing: 8) {
                    Picker("Input", selection: $settings.selectedMicrophoneID) {
                        Text("System default")
                            .tag("")
                        if selectedMicrophoneIsMissing {
                            Text("Missing microphone")
                                .tag(settings.selectedMicrophoneID)
                        }
                        ForEach(microphones) { microphone in
                            Text(microphone.name)
                                .tag(microphone.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Button {
                        refreshMicrophones()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh microphones")
                    .accessibilityLabel("Refresh microphones")
                }
            } label: {
                Text("Input")
            }

            LabeledContent {
                Toggle("Avoid Bluetooth microphones", isOn: $settings.avoidBluetoothMicrophone)
                    .labelsHidden()
            } label: {
                Text("Avoid Bluetooth microphones")
                Text("With System default, uses the built-in or another non-Bluetooth mic when there is one. A Bluetooth mic picked above is kept.")
            }
        }
    }

    // MARK: - While you speak

    private var whileSpeakingSection: some View {
        Section("While you speak") {
            LabeledContent {
                Toggle("Lower other audio", isOn: $settings.lowerOtherAudioWhileRecording)
                    .labelsHidden()
            } label: {
                Text("Lower other audio")
                Text("Turns the Mac down to 30%, then restores it")
            }

            LabeledContent {
                Toggle("Show the recording wave", isOn: $settings.showRecordingCue)
                    .labelsHidden()
            } label: {
                Text("Show the recording wave")
                Text("At the bottom of the screen")
            }

            LabeledContent {
                Toggle("Show words as they're heard", isOn: $settings.showLiveTranscript)
                    .labelsHidden()
            } label: {
                Text("Show words as they're heard")
                Text("A preview only. The result doesn't change.")
            }
            .padding(.leading, 20)
            .disabled(settings.showRecordingCue == false)
        }
    }

    // MARK: - Limits

    private var limitsSection: some View {
        Section("Limits") {
            LabeledContent {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 1) {
                        Slider(
                            value: durationDetentBinding,
                            in: 0...Double(RecordingDurationDetents.seconds.count - 1),
                            step: 1
                        )
                        .labelsHidden()
                        .accessibilityLabel("Stop recording after")
                        .accessibilityValue(RecordingDurationDetents.label(for: settings.maximumRecordingDurationSeconds))

                        GeometryReader { geometry in
                            ForEach(RecordingDurationDetents.scaleMarks) { mark in
                                Text(mark.label)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .position(x: geometry.size.width * mark.fraction, y: 6)
                            }
                        }
                        .frame(height: 12)
                        .accessibilityHidden(true)
                    }
                    .frame(width: 240)

                    Text(RecordingDurationDetents.label(for: settings.maximumRecordingDurationSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            } label: {
                Text("Stop recording after")
            }

            LabeledContent {
                Toggle("Prefer faster recognition", isOn: $settings.preferFastTranscription)
                    .labelsHidden()
            } label: {
                Text("Prefer faster recognition")
                Text("Uses less context, so it can be less accurate")
            }
        }
    }

    private var durationDetentBinding: Binding<Double> {
        Binding {
            Double(RecordingDurationDetents.nearestIndex(to: settings.maximumRecordingDurationSeconds))
        } set: { value in
            let index = min(max(Int(value.rounded()), 0), RecordingDurationDetents.seconds.count - 1)
            settings.maximumRecordingDurationSeconds = RecordingDurationDetents.seconds[index]
        }
    }

    private var selectedMicrophoneIsMissing: Bool {
        settings.selectedMicrophoneID.isEmpty == false
            && microphones.contains { $0.id == settings.selectedMicrophoneID } == false
    }

    private func refreshMicrophones() {
        microphones = deviceCatalog.inputDevices()
    }
}
