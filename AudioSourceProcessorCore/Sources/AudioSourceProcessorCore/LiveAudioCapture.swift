@preconcurrency import AVFoundation
import Foundation

public enum LiveAudioCaptureError: LocalizedError
{
    case invalidFrameRate
    case permissionDenied
    case missingInputDevice
    case unsupportedInputFormat

    public var errorDescription: String?
    {
        switch self
        {
            case .invalidFrameRate:
                return "Live analysis frame rate must be between 1 and 120 FPS."
            case .permissionDenied:
                return "Microphone access was denied. Allow Fabric to use the microphone in System Settings."
            case .missingInputDevice:
                return "The default microphone is unavailable."
            case .unsupportedInputFormat:
                return "The default microphone did not provide noninterleaved floating-point PCM."
        }
    }
}

/// One capture session belongs to one graph execution generation. It keeps
/// AVAudioEngine off Fabric's render call and never retains PCM in snapshots.
public final class LiveAudioCapture
{
    private let engine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var sampleRing: LiveAudioSampleRing?
    private var sampleRate: Float = 0
    private var hopSize = 0
    private var hasInputTap = false

    public init() {}

    deinit
    {
        stop()
    }

    public func start(framesPerSecond: Int) async throws -> Float
    {
        guard (1 ... 120).contains(framesPerSecond) else
        {
            throw LiveAudioCaptureError.invalidFrameRate
        }

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let hasPermission: Bool
        switch authorizationStatus
        {
            case .authorized:
                hasPermission = true
            case .notDetermined:
                hasPermission = await AVCaptureDevice.requestAccess(for: .audio)
            case .denied, .restricted:
                hasPermission = false
            @unknown default:
                hasPermission = false
        }
        try Task.checkCancellation()
        guard hasPermission else
        {
            throw LiveAudioCaptureError.permissionDenied
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0
        else
        {
            throw LiveAudioCaptureError.missingInputDevice
        }
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved
        else
        {
            throw LiveAudioCaptureError.unsupportedInputFormat
        }

        sampleRate = Float(format.sampleRate)
        hopSize = max(1, Int(format.sampleRate / Double(framesPerSecond)))
        let sampleRing = LiveAudioSampleRing(capacity: max(32_768, Int(format.sampleRate)))
        self.sampleRing = sampleRing
        self.inputNode = inputNode

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        )
        { buffer, _ in
            sampleRing.append(buffer)
        }
        hasInputTap = true

        do
        {
            engine.prepare()
            try engine.start()
            return sampleRate
        }
        catch
        {
            stop()
            throw error
        }
    }

    /// A single task drains the bounded ring. The audio callback schedules no
    /// work, and this loop checks cancellation between small processing batches.
    public func run(
        onSnapshot: @escaping @Sendable (AudioAnalysisSnapshot) -> Void
    ) async throws
    {
        guard let sampleRing,
              sampleRate > 0,
              hopSize > 0
        else
        {
            throw LiveAudioCaptureError.missingInputDevice
        }
        let processor = try LiveAudioFrameProcessor()
        var pendingSamples: [Float] = []
        var consumedSampleCount = 0
        let requiredSamples = max(hopSize, AudioFrameAnalyzer.fftSize)

        while true
        {
            try Task.checkCancellation()
            pendingSamples.append(contentsOf: sampleRing.take(upTo: 8192))

            while pendingSamples.count - consumedSampleCount >= requiredSamples
            {
                let frameSamples = Array(
                    pendingSamples[consumedSampleCount ..< consumedSampleCount + requiredSamples]
                )
                let snapshot = try processor.process(
                    samples: frameSamples,
                    rmsSampleCount: hopSize,
                    sampleRate: sampleRate
                )
                onSnapshot(snapshot)
                consumedSampleCount += hopSize
                if consumedSampleCount >= 8192
                {
                    pendingSamples.removeFirst(consumedSampleCount)
                    consumedSampleCount = 0
                }
                try Task.checkCancellation()
            }

            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func stop()
    {
        if hasInputTap
        {
            inputNode?.removeTap(onBus: 0)
            hasInputTap = false
        }
        if engine.isRunning
        {
            engine.stop()
        }
        sampleRing = nil
        inputNode = nil
        sampleRate = 0
        hopSize = 0
    }
}

/// The tap writes directly into preallocated memory and drops samples when
/// the consumer falls behind. It never blocks the audio callback on a lock.
final class LiveAudioSampleRing: @unchecked Sendable
{
    private let lock = NSLock()
    private var samples: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableCount = 0

    init(capacity: Int)
    {
        precondition(capacity > 0)
        samples = [Float](repeating: 0, count: capacity)
    }

    func append(_ buffer: AVAudioPCMBuffer)
    {
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return }

        for frameIndex in 0 ..< frameCount
        {
            var mixedSample: Float = 0
            for channelIndex in 0 ..< channelCount
            {
                mixedSample += channels[channelIndex][frameIndex]
            }
            samples[writeIndex] = mixedSample / Float(channelCount)
            writeIndex = (writeIndex + 1) % samples.count
            if availableCount == samples.count
            {
                readIndex = (readIndex + 1) % samples.count
            }
            else
            {
                availableCount += 1
            }
        }
    }

    func take(upTo maximumCount: Int) -> [Float]
    {
        lock.lock()
        defer { lock.unlock() }
        let count = min(maximumCount, availableCount)
        var result: [Float] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count
        {
            result.append(samples[readIndex])
            readIndex = (readIndex + 1) % samples.count
        }
        availableCount -= count
        return result
    }
}
