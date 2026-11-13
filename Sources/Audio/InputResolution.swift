import IOKit

enum LidState: Sendable, CaseIterable {
    case open
    case closed
    case unknown
}

protocol LidStateReading: Sendable {
    func lidState() -> LidState
}

struct IOKitLidStateReader: LidStateReading {
    func lidState() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return .unknown }
        defer { IOObjectRelease(service) }
        guard let closed = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else { return .unknown }
        return closed ? .closed : .open
    }
}

enum InputResolution {
    static func resolve(
        devices: [AudioInputDevice],
        savedUID: String,
        defaultUID: String?,
        lidState: LidState,
        avoidBluetoothMicrophone: Bool = true
    ) throws -> String? {
        var selectedUID = devices.first { $0.id == savedUID }?.id
        if savedUID.isEmpty, avoidBluetoothMicrophone,
           devices.first(where: { $0.id == defaultUID })?.isBluetooth == true {
            let builtIn = devices.first {
                $0.id == AudioInputDevice.builtInMicrophoneID && $0.channelCount > 0 && lidState != .closed
            }
            let alternative = devices.first {
                $0.isRealInput && !$0.isBluetooth
                    && (lidState != .closed || $0.id != AudioInputDevice.builtInMicrophoneID)
            }
            selectedUID = builtIn?.id ?? alternative?.id ?? defaultUID
        }
        guard lidState == .closed,
              (selectedUID ?? defaultUID) == AudioInputDevice.builtInMicrophoneID else {
            return selectedUID
        }
        guard let replacement = devices.first(where: {
            $0.id != AudioInputDevice.builtInMicrophoneID && $0.channelCount > 0
        }) else {
            throw AudioRecordingError.builtInMicrophoneUnavailableWithClosedLid
        }
        return replacement.id
    }
}
