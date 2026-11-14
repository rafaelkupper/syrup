import Foundation

struct OutputVolume: Equatable, Sendable {
    let deviceUID: String
    let channels: [UInt32: Float32]
}

protocol OutputVolumeControlling: Sendable {
    func defaultOutputVolume() throws -> OutputVolume?
    func volume(for deviceUID: String) throws -> OutputVolume?
    func setVolume(_ volume: OutputVolume) throws
}

enum OutputVolumeError: Error {
    case readFailed(Int32)
    case writeFailed(Int32)
    case restoreRecordNotSaved
}

actor OutputDucker {
    private static let restoreKey = "outputVolumeRestore"
    /// Devices round the level they are given. This stays below the smallest keyboard volume step (1/64), so a real user change still wins.
    private static let unchangedLevelTolerance: Float32 = 0.015
    private let controller: any OutputVolumeControlling
    private let userDefaults: UserDefaults

    init(
        controller: any OutputVolumeControlling = CoreAudioOutputVolumeController(),
        userDefaults: UserDefaults = .standard
    ) {
        self.controller = controller
        self.userDefaults = userDefaults
    }

    func lower() throws {
        guard restoreRecord() == nil,
              let original = try controller.defaultOutputVolume(),
              original.channels.isEmpty == false else { return }
        let lowered = OutputVolume(deviceUID: original.deviceUID,
            channels: original.channels.mapValues { $0 * 0.3 })
        try save(RestoreRecord(original: original, lowered: lowered))
        do {
            try controller.setVolume(lowered)
        } catch {
            try? restore()
            throw error
        }
    }

    func restore() throws {
        guard let record = restoreRecord() else { return }
        if let current = try controller.volume(for: record.original.deviceUID) {
            let unchanged = record.original.channels.filter { channel, _ in
                guard let level = current.channels[channel], let lowered = record.lowered.channels[channel] else { return false }
                return abs(level - lowered) < Self.unchangedLevelTolerance
            }
            if unchanged.isEmpty == false {
                try controller.setVolume(OutputVolume(deviceUID: record.original.deviceUID, channels: unchanged))
            }
        }
        userDefaults.removeObject(forKey: Self.restoreKey)
        userDefaults.synchronize()
    }

    func restoreAfterCrash() throws {
        try restore()
    }

    private struct RestoreRecord {
        let original: OutputVolume
        let lowered: OutputVolume
    }

    private func save(_ record: RestoreRecord) throws {
        userDefaults.set([
            "deviceUID": record.original.deviceUID,
            "original": Dictionary(uniqueKeysWithValues: record.original.channels.map { (String($0.key), $0.value) }),
            "lowered": Dictionary(uniqueKeysWithValues: record.lowered.channels.map { (String($0.key), $0.value) })
        ], forKey: Self.restoreKey)
        guard userDefaults.synchronize() else {
            userDefaults.removeObject(forKey: Self.restoreKey)
            throw OutputVolumeError.restoreRecordNotSaved
        }
    }

    private func restoreRecord() -> RestoreRecord? {
        guard let raw = userDefaults.dictionary(forKey: Self.restoreKey) else { return nil }
        guard let uid = raw["deviceUID"] as? String, uid.isEmpty == false,
              let original = Self.channels(raw["original"]),
              let lowered = Self.channels(raw["lowered"]),
              original.keys.sorted() == lowered.keys.sorted() else {
            userDefaults.removeObject(forKey: Self.restoreKey)
            return nil
        }
        return RestoreRecord(original: OutputVolume(deviceUID: uid, channels: original),
            lowered: OutputVolume(deviceUID: uid, channels: lowered))
    }

    private static func channels(_ raw: Any?) -> [UInt32: Float32]? {
        guard let values = raw as? [String: NSNumber], values.isEmpty == false else { return nil }
        var channels: [UInt32: Float32] = [:]
        for (key, value) in values {
            guard let channel = UInt32(key), value.floatValue.isFinite,
                  (0...1).contains(value.floatValue) else { return nil }
            channels[channel] = value.floatValue
        }
        return channels
    }
}
