import AVFoundation
import Observation
import Speech
import UserNotifications

@MainActor
@Observable
final class PermissionStatusModel {
    enum Status: Equatable {
        case granted
        case denied
        case restricted
        case notRequested
        case unknown

        var needsAttention: Bool {
            switch self {
            case .granted, .unknown:
                false
            case .denied, .restricted, .notRequested:
                true
            }
        }
    }

    private(set) var microphone: Status = .unknown
    private(set) var speech: Status = .unknown
    private(set) var notifications: Status = .unknown
    private(set) var accessibility: Status = .unknown

    var attentionCount: Int {
        [microphone, speech, notifications, accessibility]
            .filter(\.needsAttention)
            .count
    }

    func refresh(autoPaster: any AutoPasting) {
        microphone = switch AVAudioApplication.shared.recordPermission {
        case .granted:
            .granted
        case .denied:
            .denied
        case .undetermined:
            .notRequested
        @unknown default:
            .unknown
        }

        speech = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            .granted
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notRequested
        @unknown default:
            .unknown
        }

        accessibility = autoPaster.isTrusted ? .granted : .notRequested

        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notifications = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                .granted
            case .denied:
                .denied
            case .notDetermined:
                .notRequested
            @unknown default:
                .unknown
            }
        }
    }
}
