import AppKit
import Combine
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let isRunActive: () -> Bool
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    private var updaterCanCheck = false
    private var automaticChecksEnabled = false
    @ObservationIgnored private var deferredInstall: (() -> Void)?
    var updateAvailable = false

    init(isRunActive: @escaping () -> Bool) {
        self.isRunActive = isRunActive
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in self?.updaterCanCheck = value }
            .store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in self?.automaticChecksEnabled = value }
            .store(in: &subscriptions)
        if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           !feed.isEmpty, !key.isEmpty {
            controller.startUpdater()
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { automaticChecksEnabled }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// When Sparkle last checked, for the General tab. Nil before the first check.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    var canCheckForUpdates: Bool {
        !isRunActive() && updaterCanCheck
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func resumeDeferredInstallation() {
        guard !isRunActive(), let install = deferredInstall else { return }
        deferredInstall = nil
        install()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isRunActive() { throw UpdateError.runActive }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isRunActive() else { return false }
        deferredInstall = installHandler
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                    forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updateAvailable = true
        NSApp.setActivationPolicy(.regular)
        if !state.userInitiated { NSApp.dockTile.badgeLabel = "Update" }
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAvailable = false
        NSApp.dockTile.badgeLabel = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private enum UpdateError: LocalizedError {
        case runActive
        var errorDescription: String? { "Updates wait until dictation finishes." }
    }
}
