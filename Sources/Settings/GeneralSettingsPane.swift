import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    let updates: UpdateController
    @State private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Toggle(
                        "Open Syrup at login",
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                } label: {
                    Text("Open Syrup at login")
                    if let errorMessage = launchAtLogin.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                LabeledContent {
                    Toggle(
                        "Check for updates automatically",
                        isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates },
                            set: { updates.automaticallyChecksForUpdates = $0 }
                        )
                    )
                    .labelsHidden()
                } label: {
                    Text("Check for updates automatically")
                }

                LabeledContent {
                    Button(updates.updateAvailable ? "Update Available…" : "Check Now") {
                        updates.checkForUpdates()
                    }
                    .disabled(updates.canCheckForUpdates == false)
                } label: {
                    Text(Self.versionLabel)
                    Text(lastCheckText)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates wait until a dictation finishes.")
                    .font(.caption)
            }

            Section("Setup") {
                LabeledContent {
                    Button("Show Welcome Again") {
                        openWindow(id: OnboardingWindow.id)
                        NSApp.activate()
                    }
                } label: {
                    Text("Welcome guide")
                    Text("Goes through permissions, language, and AI provider again. Keeps your current settings.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private var lastCheckText: String {
        if updates.updateAvailable { return "A new version is ready to install" }
        guard let date = updates.lastUpdateCheckDate else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Syrup \(version) (\(build))"
    }
}
