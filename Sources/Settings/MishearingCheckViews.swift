import AppKit
import SwiftUI

// The Glossary tab's system-voice check: a button and a short status on each term row, and a
// section under the table that checks every term and lists what to add. Table rows keep one
// height, so suggestions live in the section rather than under each field. Results stay in
// `MishearingSuggestionModel`, in memory only.

/// Checks one term. Sits in the terms table beside Delete.
struct MishearingCheckButton: View {
    let suggestions: MishearingSuggestionModel
    let term: GlossaryTerm

    var body: some View {
        Button {
            Task { await suggestions.probe(termID: term.id) }
        } label: {
            Image(systemName: "waveform.badge.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(suggestions.canProbe == false)
        .help("Check how dictation hears “\(term.term)”")
        .accessibilityLabel("Check how dictation hears \(term.term)")
    }
}

/// A term's latest check, at the end of its Sounds like cell. Its own view, so a finished
/// check redraws only this badge, not the table row someone may be typing in.
struct MishearingTermStatus: View {
    let suggestions: MishearingSuggestionModel
    let termID: UUID

    var body: some View {
        if let status = MishearingCheckCopy.status(for: suggestions.state(for: termID)) {
            MishearingStatusBadge(status: status)
        }
    }
}

struct MishearingStatusBadge: View {
    let status: MishearingCheckCopy.Status

    var body: some View {
        let text = MishearingCheckCopy.text(for: status)
        HStack(spacing: 4) {
            switch status {
            case .checking:
                ProgressView()
                    .controlSize(.mini)
            case .heard:
                Image(systemName: "text.badge.plus")
            case .noNewSuggestions:
                EmptyView()
            case .heardCorrectly:
                Image(systemName: "checkmark")
            case .notChecked:
                Image(systemName: "minus.circle")
            case .failed:
                Image(systemName: "exclamationmark.circle")
            }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
        .fixedSize()
        .help(MishearingCheckCopy.detail(for: status) ?? text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MishearingCheckCopy.detail(for: status).map { "\(text). \($0)" } ?? text)
    }

    private var color: AnyShapeStyle {
        switch status {
        case .heard:
            AnyShapeStyle(.tint)
        case .heardCorrectly:
            AnyShapeStyle(.green)
        case .failed:
            AnyShapeStyle(.orange)
        case .checking, .noNewSuggestions, .notChecked:
            AnyShapeStyle(.secondary)
        }
    }
}

/// One heard form. Clicking its name adds it; the x hides it. Everyday words stay gray and ask first.
struct HeardFormChip: View {
    let form: String
    let term: String
    let isEveryday: Bool
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onAdd) {
                HStack(spacing: 4) {
                    Image(systemName: isEveryday ? "exclamationmark.triangle" : "plus")
                        .font(.caption.weight(.semibold))
                    Text(form)
                }
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isEveryday ? MishearingCheckCopy.everydayHelp() : "Add to Sounds like")
            .accessibilityLabel(MishearingCheckCopy.addLabel(form: form, term: term, isEveryday: isEveryday))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.leading, 4)
                    .padding(.trailing, 9)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel(MishearingCheckCopy.dismissLabel(form: form))
        }
        .font(.callout)
        .foregroundStyle(isEveryday ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .background(
            isEveryday ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.opacity(0.14)),
            in: Capsule()
        )
    }
}

/// Check every term, show progress, list what was heard, and say once what it is worth.
struct MishearingCheckSection: View {
    let suggestions: MishearingSuggestionModel
    let settings: AppSettings
    let navigation: SettingsNavigation
    let onAccept: (String, GlossaryTerm) -> Void

    var body: some View {
        let checked = settings.glossaryList.terms.map { (term: $0, state: suggestions.state(for: $0.id)) }
        let states = checked.map(\.state)
        let summary = suggestions.isRunning ? nil : MishearingCheckCopy.summary(of: states)
        Section {
            LabeledContent {
                control
            } label: {
                Text("How dictation hears your terms")
                Text(MishearingCheckCopy.description(
                    localeIDs: suggestions.localeIDs,
                    isForegroundActive: suggestions.isForegroundActive
                ))
                if let summary {
                    Text(summary)
                }
            }

            ForEach(checked, id: \.term.id) { entry in
                switch entry.state {
                case .results(let result) where result.heardForms.isEmpty == false:
                    suggestionRow(entry.term, result: result)
                case .failed(let failure):
                    failureRow(entry.term, failure: failure)
                default:
                    EmptyView()
                }
            }

            ForEach(Array(MishearingCheckCopy.issues(in: states).enumerated()), id: \.offset) { _, issue in
                issueRow(issue)
            }
        } header: {
            Text("Check with a system voice")
        } footer: {
            Text("A system voice isn't your voice, so suggestions are hints to review. Checks run on this Mac, and nothing is kept until you add a suggestion.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var control: some View {
        if suggestions.isRunning {
            let progress = suggestions.progress
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 120)
                    .accessibilityLabel("Checking terms")
                    .accessibilityValue("\(progress.done) of \(progress.total)")
                Text(MishearingCheckCopy.progressText(progress))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Button("Stop") {
                    suggestions.cancel()
                }
            }
        } else {
            Button("Check All") {
                Task { await suggestions.probeAll() }
            }
            .disabled(suggestions.canProbe == false)
        }
    }

    private func suggestionRow(_ term: GlossaryTerm, result: MishearingProbeResult) -> some View {
        let chips = ForEach(result.heardForms, id: \.self) { form in
            HeardFormChip(
                form: form,
                term: term.term,
                isEveryday: result.isEveryday(form),
                onAdd: { onAccept(form, term) },
                onDismiss: { suggestions.dismiss(form, for: term.id) }
            )
        }
        return LabeledContent {
            // Long forms stack instead of squeezing the term's name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips }
                VStack(alignment: .trailing, spacing: 4) { chips }
            }
        } label: {
            Text(term.term)
            Text("Heard as")
        }
    }

    private func failureRow(_ term: GlossaryTerm, failure: MishearingProbeFailure) -> some View {
        LabeledContent {
            Button("Try Again") {
                Task { await suggestions.probe(termID: term.id) }
            }
            .disabled(suggestions.canProbe == false)
            .accessibilityLabel("Check \(term.term) again")
        } label: {
            Text(term.term)
            Text(MishearingCheckCopy.failureText(failure))
        }
    }

    private func issueRow(_ issue: MishearingProbeLocaleIssue) -> some View {
        LabeledContent {
            fixButton(for: issue)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(MishearingCheckCopy.issueText(issue))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func fixButton(for issue: MishearingProbeLocaleIssue) -> some View {
        switch MishearingCheckCopy.fix(for: issue) {
        case .openSpokenContent:
            Button("Open Accessibility…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .openWorkflow(let localeID):
            if let workflow = workflow(dictating: localeID) {
                Button("Open Workflow") {
                    navigation.openWorkflow(workflow.id)
                }
                .help("Open \(workflow.name)")
            }
        case .openPrivacy:
            Button("Open Privacy") {
                navigation.selectedTab = .privacy
            }
        case .none:
            EmptyView()
        }
    }

    private func workflow(dictating localeID: String) -> Workflow? {
        let wanted = Locale(identifier: localeID).identifier(.bcp47).lowercased()
        let list = settings.workflowList
        return ([list.activeWorkflow] + list.workflows).first {
            $0.input == .voice && Locale(identifier: $0.dictationLocaleID).identifier(.bcp47).lowercased() == wanted
        }
    }
}

/// Asks before adding everyday words as a hint. NSAlert gives "Cancel" the Escape key and
/// leaves Return unassigned, so adding is never the default.
@MainActor
func confirmEverydayHint(form: String, term: String) -> Bool {
    NSApp.activate()
    return everydayHintAlert(form: form, term: term).runModal() == .alertSecondButtonReturn
}

@MainActor
func everydayHintAlert(form: String, term: String) -> NSAlert {
    let copy = MishearingCheckCopy.everydayConfirmation(form: form, term: term)
    let alert = NSAlert()
    alert.messageText = copy.message
    alert.informativeText = copy.detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Add Anyway")
    return alert
}
