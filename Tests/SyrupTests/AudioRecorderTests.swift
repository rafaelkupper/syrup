import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Syrup

struct AudioRecorderTests {
    @Test
    @MainActor
    func selectedDeviceResolutionTreatsEmptySelectionAsSystemDefault() throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.selectedMicrophoneID = ""
        let catalog = FakeAudioInputDeviceCatalog()

        let resolvedDeviceUID = try AudioRecorder.resolvedSelectedDeviceUID(
            settings: settings,
            deviceCatalog: catalog
        )

        #expect(resolvedDeviceUID == nil)
    }

    @Test
    @MainActor
    func selectedDeviceResolutionUsesCatalogMatch() throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.selectedMicrophoneID = "built-in"
        let catalog = FakeAudioInputDeviceCatalog(devices: [
            AudioInputDevice(id: "built-in", name: "Built-in", sampleRate: 44_100, channelCount: 1)
        ])

        let resolvedDeviceUID = try AudioRecorder.resolvedSelectedDeviceUID(
            settings: settings,
            deviceCatalog: catalog
        )

        #expect(resolvedDeviceUID == "built-in")
    }

    @Test
    @MainActor
    func selectedDeviceResolutionFallsBackWhenDeviceIsMissing() throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.selectedMicrophoneID = "missing"
        let catalog = FakeAudioInputDeviceCatalog()

        let resolvedDeviceUID = try AudioRecorder.resolvedSelectedDeviceUID(
            settings: settings,
            deviceCatalog: catalog
        )

        #expect(resolvedDeviceUID == nil)
    }

    @Test
    @MainActor
    func recordingFormatUsesSelectedDeviceFormat() throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.selectedMicrophoneID = "built-in"
        let catalog = FakeAudioInputDeviceCatalog(devices: [
            AudioInputDevice(id: "built-in", name: "Built-in", sampleRate: 44_100, channelCount: 2)
        ])

        let format = try AudioRecorder.recordingFormat(
            selectedDeviceUID: try AudioRecorder.resolvedSelectedDeviceUID(settings: settings, deviceCatalog: catalog),
            deviceCatalog: catalog
        )

        #expect(format.sampleRate == 44_100)
        #expect(format.channelCount == 2)
        #expect(format.isInterleaved)
        #expect(format.commonFormat == .pcmFormatFloat32)
    }

    @Test
    @MainActor
    func recordingFormatFallsBackToDefaultInputWhenSelectionIsMissing() throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.selectedMicrophoneID = "missing"
        let catalog = FakeAudioInputDeviceCatalog(
            devices: [
                AudioInputDevice(id: "built-in", name: "Built-in", sampleRate: 44_100, channelCount: 1)
            ],
            defaultDevice: AudioInputDevice(
                id: "default",
                name: "Default",
                sampleRate: 48_000,
                channelCount: 1
            )
        )

        let format = try AudioRecorder.recordingFormat(
            selectedDeviceUID: try AudioRecorder.resolvedSelectedDeviceUID(settings: settings, deviceCatalog: catalog),
            deviceCatalog: catalog
        )

        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 1)
    }

    @Test
    @MainActor
    func startDoesNotRetryFailedCaptureSessionStart() async throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let session = FakeAudioCaptureSession(startError: AudioRecordingError.microphoneStartFailed)
        let recorder = AudioRecorder(
            settings: settings,
            deviceCatalog: FakeAudioInputDeviceCatalog(),
            microphonePermissionRequester: { true },
            captureSessionFactory: { _, _ in session }
        )

        await #expect(throws: AudioRecordingError.microphoneStartFailed) {
            try await recorder.start()
        }

        #expect(session.startCallCount == 1)
        #expect(session.stopCallCount == 1)
    }

    @Test
    @MainActor
    func deniedMicrophonePermissionDoesNotCreateCaptureSession() async throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        var factoryCallCount = 0
        let recorder = AudioRecorder(
            settings: settings,
            deviceCatalog: FakeAudioInputDeviceCatalog(),
            microphonePermissionRequester: { false },
            captureSessionFactory: { _, _ in
                factoryCallCount += 1
                return FakeAudioCaptureSession()
            }
        )

        await #expect(throws: AudioRecordingError.microphoneAccessDenied) {
            try await recorder.start()
        }

        #expect(factoryCallCount == 0)
    }

    @Test
    func audioQueueBytesAreCopiedIntoPCMBuffer() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        var samples: [Float] = [0.25, -0.5, 0.75, 1.0]

        let pcmBuffer = try samples.withUnsafeMutableBytes { bytes in
            try #require(AudioQueueCaptureSession.makePCMBuffer(
                audioData: bytes.baseAddress,
                byteSize: UInt32(bytes.count),
                format: format
            ))
        }

        #expect(pcmBuffer.frameLength == 4)
        let audioBuffer = pcmBuffer.audioBufferList.pointee.mBuffers
        let copiedSamples = try #require(audioBuffer.mData?.assumingMemoryBound(to: Float.self))
        #expect(Array(UnsafeBufferPointer(start: copiedSamples, count: 4)) == samples)
    }

    @Test @MainActor
    func normalFinishPreservesFinalCallbackWhileCancelDiscardsIt() async throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let recorder = AudioRecorder(settings: settings, deviceCatalog: FakeAudioInputDeviceCatalog(),
            microphonePermissionRequester: { true }, captureSessionFactory: { format, continuation in
                FinalCallbackCapture(format: format, continuation: continuation)
            })
        let audio = try await recorder.start()
        try await recorder.finish()
        var frames: [AVAudioFrameCount] = []
        for try await buffer in audio { frames.append(buffer.frameLength) }
        #expect(frames == [7])

        let cancelledAudio = try await recorder.start()
        recorder.stop()
        var cancelledFrames = 0
        for try await _ in cancelledAudio { cancelledFrames += 1 }
        #expect(cancelledFrames == 0)
    }

    @Test @MainActor
    func closedLidUsesReplacementFormatWithoutChangingPreference() async throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.selectedMicrophoneID = AudioInputDevice.builtInMicrophoneID
        let catalog = FakeAudioInputDeviceCatalog(devices: [
            AudioInputDevice(id: AudioInputDevice.builtInMicrophoneID, name: "Built-in", sampleRate: 48_000, channelCount: 1),
            AudioInputDevice(id: "BuiltInHeadphoneInputDevice", name: "Headset", sampleRate: 44_100, channelCount: 2)
        ])
        let session = FakeAudioCaptureSession()
        var capturedFormat: AVAudioFormat?
        let recorder = AudioRecorder(settings: settings, deviceCatalog: catalog,
            lidStateReader: FixedLidStateReader(state: .closed), microphonePermissionRequester: { true },
            captureSessionFactory: { format, _ in
                capturedFormat = format
                return session
            })
        _ = try await recorder.start()
        defer { recorder.stop() }
        #expect(session.selectedDeviceUID == "BuiltInHeadphoneInputDevice")
        #expect(capturedFormat?.sampleRate == 44_100)
        #expect(capturedFormat?.channelCount == 2)
        #expect(settings.selectedMicrophoneID == AudioInputDevice.builtInMicrophoneID)
        #expect(UserDefaults(suiteName: suiteName)?.string(forKey: "selectedMicrophoneID") == AudioInputDevice.builtInMicrophoneID)
    }

    @Test @MainActor
    func closedLidFailureNeverCreatesCaptureSession() async throws {
        let (settings, suiteName) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.selectedMicrophoneID = ""
        var createdSession = false
        let recorder = AudioRecorder(settings: settings, deviceCatalog: FakeAudioInputDeviceCatalog(devices: [
            AudioInputDevice(id: AudioInputDevice.builtInMicrophoneID, name: "Built-in", sampleRate: 48_000, channelCount: 1)
        ]), lidStateReader: FixedLidStateReader(state: .closed), microphonePermissionRequester: { true },
        captureSessionFactory: { _, _ in
            createdSession = true
            return FakeAudioCaptureSession()
        })
        await #expect(throws: AudioRecordingError.builtInMicrophoneUnavailableWithClosedLid) {
            _ = try await recorder.start()
        }
        #expect(createdSession == false)
    }

    @MainActor
    private func makeSettings() throws -> (AppSettings, String) {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(userDefaults: userDefaults), suiteName)
    }
}

private struct FakeAudioInputDeviceCatalog: AudioInputDeviceCataloging {
    let devices: [AudioInputDevice]
    var defaultDevice: AudioInputDevice?

    init(
        devices: [AudioInputDevice] = [
            AudioInputDevice(id: "built-in", name: "Built-in", sampleRate: 44_100, channelCount: 1)
        ],
        defaultDevice: AudioInputDevice? = nil
    ) {
        self.devices = devices
        self.defaultDevice = defaultDevice
    }

    func inputDevices() -> [AudioInputDevice] {
        devices
    }

    func inputDevice(for uid: String) -> AudioInputDevice? {
        devices.first { $0.id == uid }
    }

    func defaultInputDevice() -> AudioInputDevice? {
        defaultDevice ?? devices.first
    }
}

private final class FakeAudioCaptureSession: AudioCaptureSessioning, @unchecked Sendable {
    private let startError: (any Error)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var selectedDeviceUID: String?

    init(startError: (any Error)? = nil) {
        self.startError = startError
    }

    func start(selectedDeviceUID: String?) throws {
        startCallCount += 1
        self.selectedDeviceUID = selectedDeviceUID
        if let startError {
            throw startError
        }
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class FinalCallbackCapture: AudioCaptureSessioning, @unchecked Sendable {
    let format: AVAudioFormat
    let continuation: AudioBufferSequence.Continuation
    init(format: AVAudioFormat, continuation: AudioBufferSequence.Continuation) {
        self.format = format
        self.continuation = continuation
    }
    func start(selectedDeviceUID: String?) throws {}
    func stop() {}
    func finish() throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 7))
        buffer.frameLength = 7
        continuation.yield(buffer)
    }
}

private struct FixedLidStateReader: LidStateReading {
    let state: LidState
    func lidState() -> LidState { state }
}
