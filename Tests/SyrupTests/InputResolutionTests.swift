import CoreAudio
import Foundation
import Testing
@testable import Syrup

private let builtIn = "BuiltInMicrophoneDevice"
private let headphones = "BuiltInHeadphoneInputDevice"

struct InputResolutionTests {
    struct Scenario: Sendable {
        let devices: [String]
        let saved: String
        let systemDefault: String?
        let ordinary: String?
        let closed: String?
        var failsClosed = false
    }

    static let scenarios: [Scenario] = [
        .init(devices: [], saved: "", systemDefault: nil, ordinary: nil, closed: nil),
        .init(devices: [], saved: "missing", systemDefault: nil, ordinary: nil, closed: nil),
        .init(devices: [builtIn], saved: builtIn, systemDefault: builtIn, ordinary: builtIn, closed: nil, failsClosed: true),
        .init(devices: [builtIn], saved: "", systemDefault: builtIn, ordinary: nil, closed: nil, failsClosed: true),
        .init(devices: [builtIn], saved: "missing", systemDefault: builtIn, ordinary: nil, closed: nil, failsClosed: true),
        .init(devices: [builtIn, "usb"], saved: builtIn, systemDefault: builtIn, ordinary: builtIn, closed: "usb"),
        .init(devices: [builtIn, "usb"], saved: "", systemDefault: builtIn, ordinary: nil, closed: "usb"),
        .init(devices: [builtIn, "usb"], saved: "missing", systemDefault: builtIn, ordinary: nil, closed: "usb"),
        .init(devices: [builtIn, headphones, "usb"], saved: builtIn, systemDefault: builtIn, ordinary: builtIn, closed: headphones),
        .init(devices: [builtIn, headphones], saved: "", systemDefault: builtIn, ordinary: nil, closed: headphones),
        .init(devices: [builtIn, headphones], saved: headphones, systemDefault: builtIn, ordinary: headphones, closed: headphones),
        .init(devices: [builtIn, "usb"], saved: "usb", systemDefault: builtIn, ordinary: "usb", closed: "usb"),
        .init(devices: [builtIn, "usb"], saved: "", systemDefault: "usb", ordinary: nil, closed: nil),
        .init(devices: [builtIn, "usb"], saved: builtIn, systemDefault: "usb", ordinary: builtIn, closed: "usb"),
        .init(devices: ["usb"], saved: builtIn, systemDefault: "usb", ordinary: nil, closed: nil),
        .init(devices: ["usb"], saved: "usb", systemDefault: nil, ordinary: "usb", closed: "usb"),
        .init(devices: [builtIn], saved: builtIn, systemDefault: nil, ordinary: builtIn, closed: nil, failsClosed: true),
        .init(devices: [builtIn], saved: "", systemDefault: nil, ordinary: nil, closed: nil)
    ]

    @Test(arguments: scenarios, LidState.allCases)
    func resolvesDeviceWithoutChangingOrdinaryFallback(_ scenario: Scenario, _ lid: LidState) throws {
        let devices = scenario.devices.map {
            AudioInputDevice(id: $0, name: $0, sampleRate: 48_000, channelCount: 1)
        }
        if lid == .closed && scenario.failsClosed {
            #expect(throws: AudioRecordingError.builtInMicrophoneUnavailableWithClosedLid) {
                try InputResolution.resolve(devices: devices, savedUID: scenario.saved,
                    defaultUID: scenario.systemDefault, lidState: lid)
            }
        } else {
            let resolved = try InputResolution.resolve(devices: devices, savedUID: scenario.saved,
                defaultUID: scenario.systemDefault, lidState: lid)
            #expect(resolved == (lid == .closed ? scenario.closed : scenario.ordinary))
        }
    }

    @Test
    func zeroChannelDeviceCannotReplaceClosedLidMicrophone() {
        let devices = [
            AudioInputDevice(id: builtIn, name: "Built-in", sampleRate: 48_000, channelCount: 1),
            AudioInputDevice(id: "output-only", name: "Output", sampleRate: 48_000, channelCount: 0)
        ]
        #expect(throws: AudioRecordingError.builtInMicrophoneUnavailableWithClosedLid) {
            try InputResolution.resolve(devices: devices, savedUID: builtIn,
                defaultUID: builtIn, lidState: .closed)
        }
    }
}

struct BluetoothInputResolutionTests {
    struct Scenario: Sendable {
        let devices: [AudioInputDevice]
        let saved: String
        let systemDefault: String?
        let lid: LidState
        let avoid: Bool
        let expected: String?
    }

    static let internalMic = AudioInputDevice(id: AudioInputDevice.builtInMicrophoneID, name: "Built-in", sampleRate: 48_000, channelCount: 1, transportType: kAudioDeviceTransportTypeBuiltIn)
    static let bluetooth = AudioInputDevice(id: "bt", name: "Headset", sampleRate: 16_000, channelCount: 1, transportType: kAudioDeviceTransportTypeBluetooth)
    static let lowEnergy = AudioInputDevice(id: "ble", name: "LE Headset", sampleRate: 16_000, channelCount: 1, transportType: kAudioDeviceTransportTypeBluetoothLE)
    static let usb = AudioInputDevice(id: "usb", name: "USB", sampleRate: 48_000, channelCount: 1, transportType: kAudioDeviceTransportTypeUSB)
    static let virtual = AudioInputDevice(id: "virtual", name: "Virtual", sampleRate: 48_000, channelCount: 1, transportType: kAudioDeviceTransportTypeVirtual)
    static let aggregate = AudioInputDevice(id: "aggregate", name: "Aggregate", sampleRate: 48_000, channelCount: 1, transportType: kAudioDeviceTransportTypeAggregate)
    static let output = AudioInputDevice(id: "output", name: "Output", sampleRate: 48_000, channelCount: 0, transportType: kAudioDeviceTransportTypeUSB)

    static let scenarios: [Scenario] = [
        .init(devices: [bluetooth, usb, internalMic], saved: "", systemDefault: "bt", lid: .open, avoid: true, expected: AudioInputDevice.builtInMicrophoneID),
        .init(devices: [bluetooth, usb, internalMic], saved: "", systemDefault: "bt", lid: .unknown, avoid: true, expected: AudioInputDevice.builtInMicrophoneID),
        .init(devices: [bluetooth, usb, internalMic], saved: "", systemDefault: "bt", lid: .closed, avoid: true, expected: "usb"),
        .init(devices: [bluetooth, internalMic], saved: "", systemDefault: "bt", lid: .closed, avoid: true, expected: "bt"),
        .init(devices: [bluetooth, usb], saved: "", systemDefault: "bt", lid: .open, avoid: true, expected: "usb"),
        .init(devices: [bluetooth, virtual, aggregate, output], saved: "", systemDefault: "bt", lid: .open, avoid: true, expected: "bt"),
        .init(devices: [lowEnergy, internalMic], saved: "", systemDefault: "ble", lid: .open, avoid: true, expected: AudioInputDevice.builtInMicrophoneID),
        .init(devices: [bluetooth, internalMic], saved: "bt", systemDefault: "bt", lid: .closed, avoid: true, expected: "bt"),
        .init(devices: [bluetooth, internalMic], saved: "bt", systemDefault: "bt", lid: .open, avoid: true, expected: "bt"),
        .init(devices: [bluetooth, internalMic], saved: "", systemDefault: "bt", lid: .open, avoid: false, expected: nil),
        .init(devices: [usb, internalMic], saved: "", systemDefault: "usb", lid: .open, avoid: true, expected: nil),
        .init(devices: [bluetooth, internalMic], saved: "missing", systemDefault: "bt", lid: .open, avoid: true, expected: nil),
        .init(devices: [], saved: "", systemDefault: nil, lid: .closed, avoid: true, expected: nil),
    ]

    @Test(arguments: scenarios)
    func defaultsAvoidBluetoothWithoutOverridingSavedChoices(_ scenario: Scenario) throws {
        #expect(try InputResolution.resolve(devices: scenario.devices, savedUID: scenario.saved,
            defaultUID: scenario.systemDefault, lidState: scenario.lid,
            avoidBluetoothMicrophone: scenario.avoid) == scenario.expected)
    }

    @MainActor @Test func settingIsARawDefaultOnBoolean() {
        let suite = "Bluetooth.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(settings.avoidBluetoothMicrophone)
        settings.avoidBluetoothMicrophone = false
        #expect(defaults.object(forKey: "avoidBluetoothMicrophone") as? Bool == false)
        #expect(!AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" }).avoidBluetoothMicrophone)
    }
}
