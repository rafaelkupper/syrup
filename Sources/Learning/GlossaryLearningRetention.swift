import Foundation

/// Deletes pending recordings whenever learning is (or already was) off.
/// `revertsSettingOnFailure` is only correct for the interactive toggle: it
/// keeps the UI honest when the opt-out couldn't be honored. At startup the
/// setting was never changed by the user, so a failed cleanup must never flip
/// a privacy opt-in on — it just retries on the next launch.
@MainActor
func applyGlossaryLearningRetentionChange(
    isEnabled: Bool,
    settings: AppSettings,
    recordingArchive: (any RecordingArchiving)?,
    revertsSettingOnFailure: Bool
) async {
    guard isEnabled == false, let recordingArchive else { return }

    do {
        try await recordingArchive.deleteAll()
    } catch {
        if revertsSettingOnFailure {
            settings.glossaryLearningEnabled = true
        }
    }
}
