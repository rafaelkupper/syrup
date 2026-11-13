import SwiftUI

/// The two things that do the work: speech recognition on this Mac, and the writing provider.
struct ModelsSettingsPane: View {
    @Bindable var settings: AppSettings
    let speechModels: SpeechModelCatalog
    let keychainStore: KeychainStore

    var body: some View {
        Form {
            SpeechModelsSection(speechModels: speechModels, workflows: settings.workflowList.workflows)
            ProviderSections(settings: settings, keychainStore: keychainStore)
            EarlyTransformationSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}
