import Foundation

/// Stateful rolling normalization for an ordered microphone stream. Adapted
/// from AudioSourceProcessorExample commit
/// 4db4e252f88339e7f7833fa37a42230779b4a904.
public final class LiveAudioFrameProcessor
{
    public static let normalizationFrameCount = 180

    private let analyzer: AudioFrameAnalyzer
    private let onsetDetector = AudioOnsetDetector()
    private var recentMeasurements: [AudioFrameMeasurements] = []
    private var frameIndex = 0
    private var cumulativeSampleCount = 0
    private var peakRMS: Float = 0
    private var peakFlux: Float = 0
    private var fastEnvelope: Float = 0
    private var mediumEnvelope: Float = 0
    private var slowEnvelope: Float = 0

    public init() throws
    {
        analyzer = try AudioFrameAnalyzer()
        recentMeasurements.reserveCapacity(Self.normalizationFrameCount)
    }

    public func reset()
    {
        analyzer.reset()
        onsetDetector.reset()
        recentMeasurements.removeAll(keepingCapacity: true)
        frameIndex = 0
        cumulativeSampleCount = 0
        peakRMS = 0
        peakFlux = 0
        fastEnvelope = 0
        mediumEnvelope = 0
        slowEnvelope = 0
    }

    public func process(
        samples: [Float],
        rmsSampleCount: Int,
        sampleRate: Float
    ) throws -> AudioAnalysisSnapshot
    {
        let measurements = try analyzer.analyze(
            samples: samples,
            sampleRate: sampleRate,
            rmsSampleCount: rmsSampleCount
        )
        recentMeasurements.append(measurements)
        if recentMeasurements.count > Self.normalizationFrameCount
        {
            recentMeasurements.removeFirst()
        }

        var maximumRMS: Float = 0
        var maximumFlux: Float = 0
        var maximumSubBass: Float = 0
        var maximumBass: Float = 0
        var maximumLowMid: Float = 0
        var maximumMid: Float = 0
        var maximumHigh: Float = 0
        for recent in recentMeasurements
        {
            maximumRMS = max(maximumRMS, recent.rms)
            maximumFlux = max(maximumFlux, recent.spectralFlux)
            maximumSubBass = max(maximumSubBass, recent.bandEnergies.subBass)
            maximumBass = max(maximumBass, recent.bandEnergies.bass)
            maximumLowMid = max(maximumLowMid, recent.bandEnergies.lowMid)
            maximumMid = max(maximumMid, recent.bandEnergies.mid)
            maximumHigh = max(maximumHigh, recent.bandEnergies.high)
        }

        let rmsNormalized = normalize(measurements.rms, maximum: maximumRMS)
        let fluxNormalized = normalize(measurements.spectralFlux, maximum: maximumFlux)
        let bands = measurements.bandEnergies
        let normalizedBands = AudioFrequencyBands(
            subBass: normalize(bands.subBass, maximum: maximumSubBass),
            bass: normalize(bands.bass, maximum: maximumBass),
            lowMid: normalize(bands.lowMid, maximum: maximumLowMid),
            mid: normalize(bands.mid, maximum: maximumMid),
            high: normalize(bands.high, maximum: maximumHigh)
        )
        peakRMS = max(rmsNormalized, peakRMS * 0.88)
        peakFlux = max(fluxNormalized, peakFlux * 0.88)
        fastEnvelope = max(rmsNormalized, fastEnvelope * 0.45)
        mediumEnvelope = max(rmsNormalized, mediumEnvelope * 0.82)
        slowEnvelope = max(rmsNormalized, slowEnvelope * 0.96)

        let snapshot = AudioAnalysisSnapshot(
            frameIndex: frameIndex,
            timeSeconds: Float(cumulativeSampleCount) / sampleRate,
            measurements: measurements,
            rmsNormalized: rmsNormalized,
            loudnessNormalized: min(max((measurements.loudnessDB + 60) / 60, 0), 1),
            bandsNormalized: normalizedBands,
            spectralFluxNormalized: fluxNormalized,
            onset: onsetDetector.detect(
                spectralFlux: measurements.spectralFlux,
                frameIndex: frameIndex
            ),
            peakHeldRMS: peakRMS,
            peakHeldFlux: peakFlux,
            fastEnvelope: fastEnvelope,
            mediumEnvelope: mediumEnvelope,
            slowEnvelope: slowEnvelope
        )
        frameIndex += 1
        cumulativeSampleCount += rmsSampleCount
        return snapshot
    }

    private func normalize(_ value: Float, maximum: Float) -> Float
    {
        guard maximum > 0 else { return 0 }
        return min(max(value / maximum, 0), 1)
    }
}
