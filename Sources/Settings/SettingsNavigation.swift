import Foundation
import Observation

@MainActor
@Observable
final class SettingsNavigation {
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case home
        case workflows
        case dictation
        case delivery
        case models
        case glossary
        case privacy
        case general

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home:
                "Home"
            case .workflows:
                "Workflows"
            case .dictation:
                "Dictation"
            case .delivery:
                "Delivery"
            case .models:
                "Models"
            case .glossary:
                "Glossary"
            case .privacy:
                "Privacy"
            case .general:
                "General"
            }
        }

        var systemImage: String {
            switch self {
            case .home:
                "house"
            case .workflows:
                "wand.and.sparkles"
            case .dictation:
                "mic"
            case .delivery:
                "square.and.arrow.down"
            case .models:
                "cpu"
            case .glossary:
                "text.book.closed"
            case .privacy:
                "checkmark.shield"
            case .general:
                "gearshape"
            }
        }
    }

    var selectedTab: Tab = .home
    /// The workflow shown in the Workflows tab. Nil shows the active workflow.
    var selectedWorkflowID: UUID?
    var glossaryDraftTerm = ""
    private(set) var glossaryFocusRequest = 0
    /// Recent results that finished after this were not seen in Home yet.
    var recentSeenAt = Date.distantPast

    func openWorkflow(_ id: UUID) {
        selectedWorkflowID = id
        selectedTab = .workflows
    }

    func openGlossary(draftTerm: String) {
        glossaryDraftTerm = draftTerm
        selectedTab = .glossary
        glossaryFocusRequest += 1
    }
}
