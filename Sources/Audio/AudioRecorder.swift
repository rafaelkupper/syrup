import AVFoundation
import AudioToolbox
import CoreAudio
import Dispatch

enum AudioRecordingError: Error, Equatable {
    case microphoneAccessDenied
    case builtInMicrophoneUnavailableWithClosedLid
    case microphoneStartFailed
    case audioBufferOverflow
}

@MainActor
protocol AudioRecording: AnyObject {
    var onFailure: (@MainActor (any Error) -> Void)? { get set }
    func start() async throws -> AudioBufferSequence
    func stop()
    func finish() async throws
}

extension AudioRecording {
    var onFailure: (@MainActor (any Error) -> Void)? { get { nil } set {} }
    func finish() async throws { stop() }
}

protocol AudioCaptureSessioning: AnyObject, Sendable {
    var onFailure: (@Sendable (any Error) -> Void)? { get set }
    func start(selectedDeviceUID: String?) throws
    func stop()
    func finish() throws
}

extension AudioCaptureSessioning {
    var onFailure: (@Sendable (any Error) -> Void)? { get { nil } set {} }
    func finish() throws { stop() }
}

typealias MicrophonePermissionRequester = @MainActor () async -> Bool
typealias AudioCaptureSessionFactory = @MainActor (
    AVAudioFormat,
    AudioBufferSequence.Continuation
) -> any AudioCaptureSessioning

@MainActor
final class AudioRecorder: AudioRecording {
    var onFailure: (@MainActor (any Error) -> Void)?
    private let settings: AppSettings
    private let deviceCatalog: any AudioInputDeviceCataloging
    private let lidStateReader: any LidStateReading
    private let microphonePermissionRequester: MicrophonePermissionRequester
    private let captureSessionFactory: AudioCaptureSessionFactory
    private var generation = 0
    private var captureSession: (any AudioCaptureSessioning)?
    private var continuation: AudioBufferSequence.Continuation?

    init(
        settings: AppSettings,
        deviceCatalog: any AudioInputDeviceCataloging = CoreAudioInputDeviceCatalog(),
        lidStateReader: any LidStateReading = IOKitLidStateReader(),
        microphonePermissionRequester: @escaping MicrophonePermissionRequester = {
            await AVAudioApplication.requestRecordPermission()
        },
        captureSessionFactory: @escaping AudioCaptureSessionFactory = { format, continuation in
            AudioQueueCaptureSession(
                format: format,
                continuation: continuation
            )
        }
    ) {
        self.settings = settings
        self.deviceCatalog = deviceCatalog
        self.lidStateReader = lidStateReader
        self.microphonePermissionRequester = microphonePermissionRequester
        self.captureSessionFactory = captureSessionFactory
    }

    func start() async throws -> AudioBufferSequence {
        stop()
        let generation = generation
        try Task.checkCancellation()

        guard await microphonePermissionRequester() else {
            throw AudioRecordingError.microphoneAccessDenied
        }

        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        return try startCapture()
    }

    func stop() {
        generation += 1
        captureSession?.stop()
        captureSession = nil
        continuation?.finish()
        continuation = nil
    }

    func finish() async throws {
        let session = captureSession
        let output = continuation
        captureSession = nil
        continuation = nil
        defer { output?.finish() }
        try await Task.detached(priority: .userInitiated) { try session?.finish() }.value
        try Task.checkCancellation()
    }

    private func startCapture() throws -> AudioBufferSequence {
        let selectedDeviceUID = try Self.resolvedSelectedDeviceUID(
            settings: settings,
            deviceCatalog: deviceCatalog,
            lidStateReader: lidStateReader
        )
        let format = try Self.recordingFormat(
            selectedDeviceUID: selectedDeviceUID,
            deviceCatalog: deviceCatalog
        )
        let stream = AudioBufferStream.make()
        let continuation = stream.continuation
        let captureSession = captureSessionFactory(format, continuation)
        let captureGeneration = generation
        captureSession.onFailure = { [weak self] error in
            continuation.finish(throwing: error)
            Task { @MainActor in
                guard let self, self.generation == captureGeneration else { return }
                self.onFailure?(error)
            }
        }

        do {
            try captureSession.start(selectedDeviceUID: selectedDeviceUID)
        } catch {
            captureSession.stop()
            continuation.finish()
            throw AudioRecordingError.microphoneStartFailed
        }

        self.captureSession = captureSession
        self.continuation = continuation
        return stream.stream
    }

    static func resolvedSelectedDeviceUID(
        settings: AppSettings,
        deviceCatalog: any AudioInputDeviceCataloging,
        lidStateReader: any LidStateReading = IOKitLidStateReader()
    ) throws -> String? {
        try InputResolution.resolve(
            devices: deviceCatalog.inputDevices(),
            savedUID: settings.selectedMicrophoneID,
            defaultUID: deviceCatalog.defaultInputDevice()?.id,
            lidState: lidStateReader.lidState(),
            avoidBluetoothMicrophone: settings.avoidBluetoothMicrophone
        )
    }

    static func recordingFormat(
        selectedDeviceUID: String?,
        deviceCatalog: any AudioInputDeviceCataloging
    ) throws -> AVAudioFormat {
        let device = selectedDeviceUID.flatMap { deviceCatalog.inputDevice(for: $0) }
            ?? deviceCatalog.defaultInputDevice()
        let sampleRate = device?.sampleRate ?? 48_000
        let channelCount = min(max(device?.channelCount ?? 1, 1), 2)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else {
            throw AudioRecordingError.microphoneStartFailed
        }
        return format
    }
}

final class AudioQueueCaptureSession: AudioCaptureSessioning, @unchecked Sendable {
    // Installed before start; never mutated while callbacks are running.
    var onFailure: (@Sendable (any Error) -> Void)?
    private static let bufferFrameCount: AVAudioFrameCount = 4096
    private static let bufferCount = 3

    private let format: AVAudioFormat
    private let continuation: AudioBufferSequence.Continuation
    private let callbackQueue = DispatchQueue(label: "org.syrup.Syrup.audioQueue")
    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var stopped = false
    private var draining = false
    private var overflowed = false

    init(
        format: AVAudioFormat,
        continuation: AudioBufferSequence.Continuation
    ) {
        self.format = format
        self.continuation = continuation
    }

    func start(selectedDeviceUID: String?) throws {
        var streamDescription = format.streamDescription.pointee
        var audioQueue: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(
            &audioQueue,
            &streamDescription,
            0,
            callbackQueue
        ) { [weak self] queue, buffer, _, _, _ in
            self?.handleInput(queue: queue, buffer: buffer)
        }
        guard status == noErr, let audioQueue else {
            throw AudioRecordingError.microphoneStartFailed
        }

        queue = audioQueue

        do {
            try setCurrentDevice(selectedDeviceUID, on: audioQueue)
            try enqueueInitialBuffers(on: audioQueue)
            try startQueue(audioQueue)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let audioQueue: AudioQueueRef?
        lock.lock()
        stopped = true
        audioQueue = queue
        queue = nil
        lock.unlock()

        guard let audioQueue else {
            return
        }

        AudioQueueStop(audioQueue, true)
        // Callbacks run on `callbackQueue`; waiting for it means none is still reading a buffer when
        // the queue and its buffers are disposed. Neither caller runs on that queue.
        callbackQueue.sync {}
        AudioQueueDispose(audioQueue, true)
    }

    /// Final callbacks from AudioQueueStop are accepted while draining, but never enqueue more input.
    /// Cancellation uses stop() instead.
    func finish() throws {
        let audioQueue = lock.withLock { () -> AudioQueueRef? in
            draining = true
            return queue
        }
        guard let audioQueue else { return }
        AudioQueueStop(audioQueue, true)
        // A final callback the stop dispatched may not have run yet. Running it here, before stop()
        // marks the session stopped, keeps the last buffer instead of dropping it.
        callbackQueue.sync {}
        stop()
        if lock.withLock({ overflowed }) {
            throw AudioRecordingError.audioBufferOverflow
        }
    }

    private func setCurrentDevice(_ selectedDeviceUID: String?, on queue: AudioQueueRef) throws {
        guard let selectedDeviceUID else {
            return
        }

        let currentDevice = selectedDeviceUID as CFString
        var currentDevicePointer = Unmanaged.passUnretained(currentDevice).toOpaque()
        let status = AudioQueueSetProperty(
            queue,
            kAudioQueueProperty_CurrentDevice,
            &currentDevicePointer,
            UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
        )
        guard status == noErr else {
            throw AudioRecordingError.microphoneStartFailed
        }
    }

    private func enqueueInitialBuffers(on queue: AudioQueueRef) throws {
        let bufferByteSize = Self.bufferFrameCount * format.streamDescription.pointee.mBytesPerFrame

        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            let allocateStatus = AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer)
            guard allocateStatus == noErr, let buffer else {
                throw AudioRecordingError.microphoneStartFailed
            }

            let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            guard enqueueStatus == noErr else {
                throw AudioRecordingError.microphoneStartFailed
            }
        }
    }

    private func startQueue(_ queue: AudioQueueRef) throws {
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            throw AudioRecordingError.microphoneStartFailed
        }
    }

    private func handleInput(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        guard isRunning(queue: queue) else {
            return
        }

        if let pcmBuffer = Self.makePCMBuffer(
            audioData: buffer.pointee.mAudioData,
            byteSize: buffer.pointee.mAudioDataByteSize,
            format: format
        ) {
            if AudioBufferStream.yield(pcmBuffer, to: continuation) == false {
                let firstOverflow = lock.withLock {
                    let first = overflowed == false
                    overflowed = true
                    return first
                }
                if firstOverflow { onFailure?(AudioRecordingError.audioBufferOverflow) }
            }
        }

        reenqueueIfRunning(queue: queue, buffer: buffer)
    }

    private func isRunning(queue: AudioQueueRef) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped == false && self.queue == queue
    }

    private func reenqueueIfRunning(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        lock.lock()
        defer { lock.unlock() }

        guard stopped == false, draining == false, overflowed == false, self.queue == queue else {
            return
        }

        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    static func makePCMBuffer(
        audioData: UnsafeMutableRawPointer?,
        byteSize: UInt32,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let audioData,
              byteSize > 0
        else {
            return nil
        }

        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else {
            return nil
        }

        let frameLength = byteSize / bytesPerFrame
        guard frameLength > 0,
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameLength)
              )
        else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameLength)
        let destinationBuffer = pcmBuffer.mutableAudioBufferList.pointee.mBuffers
        guard let destination = destinationBuffer.mData else {
            return nil
        }

        // Whole frames only: the buffer holds `frameLength` frames, and a trailing partial frame would
        // write past it.
        let copiedBytes = frameLength * bytesPerFrame
        memcpy(destination, audioData, Int(copiedBytes))
        pcmBuffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = copiedBytes
        return pcmBuffer
    }
}
