import CoreAudio
import Foundation

struct AudioInputDevice: Equatable, Identifiable, Sendable {
    static let builtInMicrophoneID = "BuiltInMicrophoneDevice"

    /// The microphone a new install starts with: the built-in one when this Mac has it.
    static func defaultSelectionID() -> String {
        CoreAudioInputDeviceCatalog().inputDevice(for: builtInMicrophoneID)?.id ?? ""
    }

    let id: String
    let name: String
    let sampleRate: Double
    let channelCount: UInt32
    var transportType: UInt32 = kAudioDeviceTransportTypeUnknown

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isRealInput: Bool {
        channelCount > 0 && transportType != kAudioDeviceTransportTypeVirtual
            && transportType != kAudioDeviceTransportTypeAggregate
    }
}

protocol AudioInputDeviceCataloging: Sendable {
    func inputDevices() -> [AudioInputDevice]
    func inputDevice(for uid: String) -> AudioInputDevice?
    func defaultInputDevice() -> AudioInputDevice?
}

struct CoreAudioInputDeviceCatalog: AudioInputDeviceCataloging {
    func inputDevices() -> [AudioInputDevice] {
        Self.audioDeviceIDs()
            .compactMap(Self.inputDevice(for:))
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func inputDevice(for uid: String) -> AudioInputDevice? {
        guard let deviceID = Self.deviceID(for: uid) else {
            return nil
        }

        return Self.inputDevice(for: deviceID)
    }

    func defaultInputDevice() -> AudioInputDevice? {
        guard let deviceID = Self.defaultInputDeviceID() else {
            return nil
        }

        return Self.inputDevice(for: deviceID)
    }

    private static func deviceID(for uid: String) -> AudioDeviceID? {
        Self.audioDeviceIDs()
            .first { deviceID in
                Self.inputChannelCount(deviceID) > 0
                    && Self.stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID) == uid
            }
    }

    private static func inputDevice(for deviceID: AudioDeviceID) -> AudioInputDevice? {
        let channelCount = inputChannelCount(deviceID)
        guard channelCount > 0,
              let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
              uid.isEmpty == false
        else {
            return nil
        }

        let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID)
            ?? "Microphone"
        let sampleRate = doubleProperty(kAudioDevicePropertyNominalSampleRate, deviceID: deviceID)
            ?? 48_000

        return AudioInputDevice(
            id: uid,
            name: name,
            sampleRate: sampleRate,
            channelCount: channelCount,
            transportType: transportType(deviceID)
        )
    }

    private static func audioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: deviceCount)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard dataStatus == noErr else {
            return []
        }
        return deviceIDs
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else {
            return 0
        }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferList
        )
        guard dataStatus == noErr else {
            return 0
        }

        let audioBufferList = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(UInt32(0)) { count, buffer in
            count + buffer.mNumberChannels
        }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        guard status == noErr else {
            return nil
        }
        return value as String?
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(kAudioDeviceTransportTypeUnknown)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return value
    }

    private static func doubleProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = Float64()
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            return nil
        }
        return value
    }
}
