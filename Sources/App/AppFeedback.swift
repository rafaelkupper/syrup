import AppKit
import UserNotifications

@MainActor
protocol AppFeedbackProviding: AnyObject {
    func playSuccessSound(_ sound: SuccessSound)
    func notifyError(message: String)
    func notifyRecordingAutoStopped(afterSeconds seconds: Int)
    func notifyAutoPasteNotTrusted()
    func notifyAutoPasteSecureInput()
    func notifyStreamingFocusChanged()
    func notifyStreamingSecureInput()
    func notifyTransformationFailed(
        message: String,
        recordID: UUID,
        allowsTranscriptFallback: Bool,
        allowsRetry: Bool
    )
}

@MainActor
protocol AppFeedbackActionHandling: AnyObject {
    func copyTranscriptFallback(recordID: UUID?)
    func retryTranslation(recordID: UUID)
}

@MainActor
final class AppFeedback: NSObject, AppFeedbackProviding, UNUserNotificationCenterDelegate {
    private enum Constants {
        static let transformationFailedCategory = "transformationFailed"
        static let transformationFailedCopyOnlyCategory = "transformationFailedCopyOnly"
        static let transformationFailedRetryOnlyCategory = "transformationFailedRetryOnly"
        static let copyTranscriptAction = "copyTranscript"
        static let retryAction = "retryTransformation"
        static let recordIDKey = "recordID"
    }

    weak var actionHandler: (any AppFeedbackActionHandling)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func playSuccessSound(_ sound: SuccessSound) {
        sound.play()
    }

    func notifyError(message: String) {
        postNotification(message: message, categoryIdentifier: nil, userInfo: [:])
    }

    func notifyRecordingAutoStopped(afterSeconds seconds: Int) {
        postNotification(
            message: "Recording stopped at the \(seconds)s limit - processing what was heard.",
            categoryIdentifier: nil,
            userInfo: [:]
        )
    }

    func notifyAutoPasteNotTrusted() {
        postNotification(
            message: "Copied - grant Accessibility to paste automatically.",
            categoryIdentifier: nil,
            userInfo: [:]
        )
    }

    func notifyAutoPasteSecureInput() {
        postNotification(
            message: "Copied - couldn't paste into a secure field.",
            categoryIdentifier: nil,
            userInfo: [:]
        )
    }

    func notifyStreamingFocusChanged() {
        postNotification(
            message: "Typing stopped when the active app changed - the full result was copied.",
            categoryIdentifier: nil,
            userInfo: [:]
        )
    }

    func notifyStreamingSecureInput() {
        postNotification(
            message: "Typing stopped for secure input - the full result was copied.",
            categoryIdentifier: nil,
            userInfo: [:]
        )
    }

    func notifyTransformationFailed(
        message: String,
        recordID: UUID,
        allowsTranscriptFallback: Bool,
        allowsRetry: Bool
    ) {
        postNotification(
            message: message,
            categoryIdentifier: Self.transformationFailureCategoryIdentifier(
                allowsTranscriptFallback: allowsTranscriptFallback,
                allowsRetry: allowsRetry
            ),
            userInfo: [Constants.recordIDKey: recordID.uuidString]
        )
    }

    static func transformationFailureCategoryIdentifier(
        allowsTranscriptFallback: Bool,
        allowsRetry: Bool
    ) -> String? {
        switch (allowsTranscriptFallback, allowsRetry) {
        case (true, true):
            Constants.transformationFailedCategory
        case (true, false):
            Constants.transformationFailedCopyOnlyCategory
        case (false, true):
            Constants.transformationFailedRetryOnlyCategory
        case (false, false):
            nil
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        let recordIDString = response.notification.request.content.userInfo[Constants.recordIDKey] as? String
        let recordID = recordIDString.flatMap(UUID.init(uuidString:))

        await MainActor.run {
            switch actionIdentifier {
            case Constants.copyTranscriptAction:
                if let recordID { actionHandler?.copyTranscriptFallback(recordID: recordID) }
            case Constants.retryAction:
                if let recordID {
                    actionHandler?.retryTranslation(recordID: recordID)
                }
            default:
                break
            }
        }
    }

    private func postNotification(
        message: String,
        categoryIdentifier: String?,
        userInfo: [AnyHashable: Any]
    ) {
        Task {
            let center = UNUserNotificationCenter.current()
            let isAllowed: Bool
            do {
                registerCategories(center: center)
                isAllowed = try await center.requestAuthorization(options: [.provisional])
            } catch {
                return
            }

            guard isAllowed else { return }

            let content = UNMutableNotificationContent()
            content.title = "Syrup"
            content.body = message
            if let categoryIdentifier {
                content.categoryIdentifier = categoryIdentifier
            }
            content.userInfo = userInfo

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func registerCategories(center: UNUserNotificationCenter) {
        let copyTranscript = UNNotificationAction(
            identifier: Constants.copyTranscriptAction,
            title: "Copy transcript",
            options: []
        )
        let retry = UNNotificationAction(
            identifier: Constants.retryAction,
            title: "Retry",
            options: []
        )
        let categories = [
            UNNotificationCategory(
                identifier: Constants.transformationFailedCategory,
                actions: [copyTranscript, retry],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Constants.transformationFailedCopyOnlyCategory,
                actions: [copyTranscript],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Constants.transformationFailedRetryOnlyCategory,
                actions: [retry],
                intentIdentifiers: [],
                options: []
            ),
        ]
        center.setNotificationCategories(Set(categories))
    }
}
