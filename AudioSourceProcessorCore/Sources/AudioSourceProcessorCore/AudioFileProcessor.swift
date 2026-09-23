import AVFoundation
import Foundation

public enum AudioFileProcessorError: LocalizedError
{
    case invalidFrameRate
    case invalidSampleRate
    case missingPCMBuffer
    case missingFloatChannels
    case emptyFile

    public var errorDescription: String?
    {
        switch self
        {
            case .invalidFrameRate:
                return "Analysis frame rate must be finite and between 1 and 120 FPS."
            case .invalidSampleRate:
                return "The audio file has an invalid sample rate or no channels."
            case .missingPCMBuffer:
                return "An audio decoding buffer could not be created."
            case .missingFloatChannels:
                return "The audio file could not be decoded as noninterleaved floating-point PCM."
            case .emptyFile:
                return "The selected audio file contains no samples."
        }
    }
}

/// Reads bounded PCM chunks and retains measurements instead of source samples.
/// Adapted from AudioSourceProcessorExample commit
/// 4db4e252f88339e7f7833fa37a42230779b4a904.
public final class AudioFileProcessor
{
    public init() {}

    /// Run from a background task. The file read and FFT work are synchronous;
    /// cancellation is checked between bounded decoding chunks.
    public func process(url: URL, framesPerSecond requestedFrameRate: Double) async throws -> AudioFileAnalysis
    {
        guard requestedFrameRate.isFinite, (1 ... 120).contains(requestedFrameRate) else
        {
            throw AudioFileProcessorError.invalidFrameRate
        }

        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        let sampleRate = Float(format.sampleRate)
        let channelCount = Int(format.channelCount)
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else
        {
            throw AudioFileProcessorError.invalidSampleRate
        }
        guard !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else
        {
            throw AudioFileProcessorError.missingPCMBuffer
        }

        let hopSize = max(1, Int(sampleRate / Float(requestedFrameRate)))
        var accumulator = try AudioFileFrameAccumulator(
            sampleRate: sampleRate,
            hopSize: hopSize
        )
        var totalSamples = 0

        while file.framePosition < file.length
        {
            try Task.checkCancellation()
            let remainingFrameCount = file.length - file.framePosition
            let framesToRead = AVAudioFrameCount(min(
                AVAudioFramePosition(buffer.frameCapacity),
                remainingFrameCount
            ))
            try file.read(into: buffer, frameCount: framesToRead)
            let decodedCount = Int(buffer.frameLength)
            guard decodedCount > 0 else { break }
            guard let channels = buffer.floatChannelData else
            {
                throw AudioFileProcessorError.missingFloatChannels
            }

            var monoSamples = [Float](repeating: 0, count: decodedCount)
            for channelIndex in 0 ..< channelCount
            {
                let channel = channels[channelIndex]
                for sampleIndex in 0 ..< decodedCount
                {
                    monoSamples[sampleIndex] += channel[sampleIndex]
                }
            }
            if channelCount > 1
            {
                let reciprocalChannelCount = 1 / Float(channelCount)
                for sampleIndex in monoSamples.indices
                {
                    monoSamples[sampleIndex] *= reciprocalChannelCount
                }
            }

            totalSamples += decodedCount
            try accumulator.append(monoSamples)
        }

        guard totalSamples > 0 else
        {
            throw AudioFileProcessorError.emptyFile
        }
        try accumulator.finish()
        return AudioFileSnapshotBuilder.build(
            measurements: accumulator.measurements,
            waveformRows: accumulator.waveformRows,
            sampleRate: sampleRate,
            totalSamples: totalSamples,
            hopSize: hopSize
        )
    }
}

private struct AudioFileFrameAccumulator
{
    let sampleRate: Float
    let hopSize: Int
    let analyzer: AudioFrameAnalyzer
    private(set) var measurements: [AudioFrameMeasurements] = []
    private(set) var waveformRows: [AudioWaveformRow] = []
    private var pendingSamples: [Float] = []
    private var consumedSampleCount = 0

    init(sampleRate: Float, hopSize: Int) throws
    {
        self.sampleRate = sampleRate
        self.hopSize = hopSize
        analyzer = try AudioFrameAnalyzer()
    }

    mutating func append(_ samples: [Float]) throws
    {
        pendingSamples.append(contentsOf: samples)
        try consumeAvailableFrames(atEnd: false)
    }

    mutating func finish() throws
    {
        try consumeAvailableFrames(atEnd: true)
    }

    private mutating func consumeAvailableFrames(atEnd: Bool) throws
    {
        let requiredSamples = max(hopSize, AudioFrameAnalyzer.fftSize)
        while true
        {
            let availableSamples = pendingSamples.count - consumedSampleCount
            guard availableSamples > 0,
                  atEnd || availableSamples >= requiredSamples
            else
            {
                break
            }

            let rmsSampleCount = min(hopSize, availableSamples)
            let analysisSampleCount = min(
                max(rmsSampleCount, AudioFrameAnalyzer.fftSize),
                availableSamples
            )
            let frameSamples = Array(
                pendingSamples[consumedSampleCount ..< consumedSampleCount + analysisSampleCount]
            )
            measurements.append(try analyzer.analyze(
                samples: frameSamples,
                sampleRate: sampleRate,
                rmsSampleCount: rmsSampleCount
            ))
            waveformRows.append(AudioWaveformRow(
                frameSamples.prefix(rmsSampleCount)
            ))
            consumedSampleCount += rmsSampleCount

            if consumedSampleCount >= 8192
            {
                pendingSamples.removeFirst(consumedSampleCount)
                consumedSampleCount = 0
            }
        }
    }
}

private enum AudioFileSnapshotBuilder
{
    static func build(
        measurements: [AudioFrameMeasurements],
        waveformRows: [AudioWaveformRow],
        sampleRate: Float,
        totalSamples: Int,
        hopSize: Int
    ) -> AudioFileAnalysis
    {
        let frameRate = sampleRate / Float(hopSize)
        let duration = Float(totalSamples) / sampleRate
        let onsetFrames = detectOnsets(in: measurements, frameRate: frameRate)
        let onsetSet = Set(onsetFrames)
        let averageBPM = tempo(for: onsetFrames, frameRate: frameRate)

        var maximumRMS: Float = 0
        var maximumFlux: Float = 0
        var maximumSubBass: Float = 0
        var maximumBass: Float = 0
        var maximumLowMid: Float = 0
        var maximumMid: Float = 0
        var maximumHigh: Float = 0
        for measurement in measurements
        {
            maximumRMS = max(maximumRMS, measurement.rms)
            maximumFlux = max(maximumFlux, measurement.spectralFlux)
            maximumSubBass = max(maximumSubBass, measurement.bandEnergies.subBass)
            maximumBass = max(maximumBass, measurement.bandEnergies.bass)
            maximumLowMid = max(maximumLowMid, measurement.bandEnergies.lowMid)
            maximumMid = max(maximumMid, measurement.bandEnergies.mid)
            maximumHigh = max(maximumHigh, measurement.bandEnergies.high)
        }

        var frames: [AudioAnalysisSnapshot] = []
        frames.reserveCapacity(measurements.count)
        var peakRMS: Float = 0
        var peakFlux: Float = 0
        var fastEnvelope: Float = 0
        var mediumEnvelope: Float = 0
        var slowEnvelope: Float = 0

        for (frameIndex, measurement) in measurements.enumerated()
        {
            let rmsNormalized = normalize(measurement.rms, maximum: maximumRMS)
            let fluxNormalized = normalize(measurement.spectralFlux, maximum: maximumFlux)
            let bandEnergies = measurement.bandEnergies
            let normalizedBands = AudioFrequencyBands(
                subBass: normalize(bandEnergies.subBass, maximum: maximumSubBass),
                bass: normalize(bandEnergies.bass, maximum: maximumBass),
                lowMid: normalize(bandEnergies.lowMid, maximum: maximumLowMid),
                mid: normalize(bandEnergies.mid, maximum: maximumMid),
                high: normalize(bandEnergies.high, maximum: maximumHigh)
            )
            let loudnessNormalized = min(max((measurement.loudnessDB + 60) / 60, 0), 1)
            peakRMS = max(rmsNormalized, peakRMS * 0.88)
            peakFlux = max(fluxNormalized, peakFlux * 0.88)
            fastEnvelope = max(rmsNormalized, fastEnvelope * 0.45)
            mediumEnvelope = max(rmsNormalized, mediumEnvelope * 0.82)
            slowEnvelope = max(rmsNormalized, slowEnvelope * 0.96)

            frames.append(AudioAnalysisSnapshot(
                frameIndex: frameIndex,
                timeSeconds: Float(frameIndex * hopSize) / sampleRate,
                measurements: measurement,
                rmsNormalized: rmsNormalized,
                loudnessNormalized: loudnessNormalized,
                bandsNormalized: normalizedBands,
                spectralFluxNormalized: fluxNormalized,
                onset: onsetSet.contains(frameIndex),
                peakHeldRMS: peakRMS,
                peakHeldFlux: peakFlux,
                fastEnvelope: fastEnvelope,
                mediumEnvelope: mediumEnvelope,
                slowEnvelope: slowEnvelope
            ))
        }

        return AudioFileAnalysis(
            sampleRate: sampleRate,
            durationSeconds: duration,
            framesPerSecond: frameRate,
            averageBPM: averageBPM,
            frames: frames,
            waveformRows: waveformRows
        )
    }

    private static func normalize(_ value: Float, maximum: Float) -> Float
    {
        guard maximum > 0 else { return 0 }
        return min(max(value / maximum, 0), 1)
    }

    /// Centered adaptive peak picking from the reference file processor.
    private static func detectOnsets(
        in measurements: [AudioFrameMeasurements],
        frameRate: Float
    ) -> [Int]
    {
        guard measurements.count > 2 else { return [] }
        let descriptors = measurements.map(\.spectralFlux)
        guard let minimum = descriptors.min(),
              let maximum = descriptors.max(),
              maximum > minimum
        else
        {
            return []
        }

        // A short burst can create two FFT flux peaks as the analysis window
        // crosses its leading edge. Treat peaks within 100 ms as one onset.
        let minimumGap = max(3, Int(ceil(0.1 * frameRate)))
        var lastOnsetFrame = -minimumGap
        var onsetFrames: [Int] = []
        for frameIndex in 1 ..< descriptors.count - 1
        {
            let start = max(0, frameIndex - 8)
            let end = min(descriptors.count, frameIndex + 9)
            let nearby = descriptors[start ..< end]
            let nearbyAverage = (nearby.reduce(0, +) - descriptors[frameIndex])
                / Float(max(nearby.count - 1, 1))
            let flux = descriptors[frameIndex]
            guard flux > max(1e-6, nearbyAverage * 1.2),
                  flux > descriptors[frameIndex - 1],
                  flux > descriptors[frameIndex + 1],
                  frameIndex - lastOnsetFrame >= minimumGap
            else
            {
                continue
            }
            onsetFrames.append(frameIndex)
            lastOnsetFrame = frameIndex
        }
        return onsetFrames
    }

    private static func tempo(for onsetFrames: [Int], frameRate: Float) -> Float
    {
        guard onsetFrames.count > 1 else { return 0 }
        let intervals = zip(onsetFrames, onsetFrames.dropFirst())
            .map { Float($1 - $0) / frameRate }
            .filter { $0.isFinite && $0 >= 0.2 }
            .sorted()
        guard !intervals.isEmpty else { return 0 }

        var beatsPerMinute = 60 / intervals[intervals.count / 2]
        while beatsPerMinute > 180 { beatsPerMinute *= 0.5 }
        while beatsPerMinute < 60 { beatsPerMinute *= 2 }
        return beatsPerMinute.isFinite ? beatsPerMinute : 0
    }
}
