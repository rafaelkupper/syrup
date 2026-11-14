import SwiftUI

/// Download, progress, ready state, and delete for one speech model.
struct SpeechModelControls: View {
    @Bindable var model: SpeechModelManager

    var body: some View {
        switch model.state {
        case .unsupported:
            Text("Requires Apple silicon")
                .foregroundStyle(.secondary)
        case .notDownloaded:
            Button("Download (\(model.engine.downloadSize ?? ""))") {
                model.download()
            }
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(width: 160)
                .accessibilityLabel("Downloading \(model.engine.displayName)")
                .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
        case .downloaded, .ready:
            HStack(spacing: 8) {
                Text(model.state == .ready ? "Ready" : "Downloaded")
                    .foregroundStyle(.secondary)
                Button("Delete", role: .destructive) {
                    model.remove()
                }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .foregroundStyle(.red)
                Button("Retry") {
                    model.retry()
                }
                Button("Delete", role: .destructive) {
                    model.remove()
                }
            }
        }
    }
}

struct SpeechModelsSection: View {
    let speechModels: SpeechModelCatalog
    let workflows: [Workflow]

    var body: some View {
        Section {
            ForEach(SpeechEngine.allCases) { engine in
                row(engine)
            }
        } header: {
            HStack {
                Text("Speech recognition")
                Spacer()
                Text("Runs on this Mac. Each workflow picks one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Bars come from synthetic English and Portuguese clips (English only for English-only models), so results with your voice may differ. Speed is the wait after you stop talking.")
                .font(.caption)
        }
    }

    private func row(_ engine: SpeechEngine) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(engine.displayName)
                    TagBadge(text: engine.languageSummary, color: .secondary)
                    if engine.isStreaming {
                        TagBadge(text: "Live text", color: .accentColor)
                    }
                }
                Text(engine.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ScoreBar(title: "Accuracy", score: engine.measuredScores.accuracy)
                    ScoreBar(title: "Speed", score: engine.measuredScores.speed)
                }
                if let usedBy = usedBy(engine) {
                    Text(usedBy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let model = speechModels.manager(for: engine) {
                SpeechModelControls(model: model)
            } else {
                Text("Built in")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Which voice workflows use a model, so you can tell whether deleting it changes anything.
    private func usedBy(_ engine: SpeechEngine) -> String? {
        let names = workflows.filter { $0.input == .voice && $0.speechEngine == engine }.map(\.name)
        guard names.isEmpty == false else { return nil }
        return "Used by " + names.formatted(.list(type: .and))
    }
}

/// Five steps, with the number exposed to VoiceOver and the label always visible.
private struct ScoreBar: View {
    let title: String
    let score: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if score == 0 {
                Text("Not measured yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                steps
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(score == 0 ? "Not measured yet" : "\(score) of 5")
    }

    private var steps: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(step <= score ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: 12, height: 5)
            }
        }
    }
}
