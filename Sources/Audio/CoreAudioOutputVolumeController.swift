import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioOutputVolumeController: OutputVolumeControlling {
    func defaultOutputVolume() throws -> OutputVolume? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw OutputVolumeError.readFailed(status) }
        guard device != kAudioObjectUnknown else { return nil }
        var uidAddress = self.address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, $0)
        }
        guard uidStatus == noErr else { throw OutputVolumeError.readFailed(uidStatus) }
        guard let uid else { return nil }
        return try volume(device: device, uid: uid as String)
    }

    func volume(for deviceUID: String) throws -> OutputVolume? {
        guard let device = try deviceID(for: deviceUID) else { return nil }
        return try volume(device: device, uid: deviceUID)
    }

    func setVolume(_ volume: OutputVolume) throws {
        guard let device = try deviceID(for: volume.deviceUID) else { return }
        for (channel, level) in volume.channels.sorted(by: { $0.key < $1.key }) {
            var address = volumeAddress(channel: channel)
            var value = level
            let status = AudioObjectSetPropertyData(device, &address, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &value)
            guard status == noErr else { throw OutputVolumeError.writeFailed(status) }
        }
    }

    private func volume(device: AudioDeviceID, uid: String) throws -> OutputVolume? {
        var mainAddress = volumeAddress(channel: 0)
        let channels: [UInt32]
        if try isSettable(device, address: &mainAddress) {
            channels = [0]
        } else {
            let count = try outputChannelCount(device)
            guard count > 0 else { return nil }
            channels = Array(1...count)
        }
        var values: [UInt32: Float32] = [:]
        for channel in channels {
            var address = volumeAddress(channel: channel)
            guard try isSettable(device, address: &address) else { continue }
            var value = Float32()
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            guard status == noErr else { throw OutputVolumeError.readFailed(status) }
            values[channel] = value
        }
        return values.isEmpty ? nil : OutputVolume(deviceUID: uid, channels: values)
    }

    private func isSettable(_ device: AudioDeviceID, address: inout AudioObjectPropertyAddress) throws -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        guard status == noErr else { throw OutputVolumeError.readFailed(status) }
        return settable.boolValue
    }

    private func deviceID(for uid: String) throws -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID()
        var uid = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        guard status == noErr else { throw OutputVolumeError.readFailed(status) }
        return device == kAudioObjectUnknown ? nil : device
    }

    private func outputChannelCount(_ device: AudioDeviceID) throws -> UInt32 {
        var address = address(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw OutputVolumeError.readFailed(sizeStatus) }
        guard size > 0 else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, data)
        guard status == noErr else { throw OutputVolumeError.readFailed(status) }
        return UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + $1.mNumberChannels }
    }

    private func volumeAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        address(channel == 0 ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume : kAudioDevicePropertyVolumeScalar,
            element: channel)
    }

    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
