import Foundation

/// At launch, deletes any recordings left from a time learning was on, when it is off now. A failed
/// cleanup never turns the opt-in on: the person did not change it, so it just retries at the next
/// launch. Changing the setting goes through `PrivacyOptIns.setGlossaryLearning`.
@MainActor
func deleteLeftoverRecordingsIfLearningIsOff(
    settings: AppSettings,
    recordingArchive: (any RecordingArchiving)?
) async {
    guard settings.glossaryLearningEnabled == false, let recordingArchive else { return }
    try? await recordingArchive.deleteAll()
}
