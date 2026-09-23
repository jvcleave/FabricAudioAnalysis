import Foundation

/// Frequency-band energy averaged over FFT bins. These are raw values; a source
/// chooses its own normalization window before publishing graph values.
public struct AudioFrequencyBands: Codable, Equatable, Sendable
{
    public let subBass: Float
    public let bass: Float
    public let lowMid: Float
    public let mid: Float
    public let high: Float

    public init(
        subBass: Float = 0,
        bass: Float = 0,
        lowMid: Float = 0,
        mid: Float = 0,
        high: Float = 0
    )
    {
        self.subBass = subBass
        self.bass = bass
        self.lowMid = lowMid
        self.mid = mid
        self.high = high
    }
}

/// Source-independent measurements for one analysis frame.
public struct AudioFrameMeasurements: Codable, Equatable, Sendable
{
    public let rms: Float
    public let loudnessDB: Float
    public let bandEnergies: AudioFrequencyBands
    public let spectralFlux: Float
    public let spectralCentroidHz: Float

    public init(
        rms: Float,
        loudnessDB: Float,
        bandEnergies: AudioFrequencyBands,
        spectralFlux: Float,
        spectralCentroidHz: Float
    )
    {
        self.rms = rms
        self.loudnessDB = loudnessDB
        self.bandEnergies = bandEnergies
        self.spectralFlux = spectralFlux
        self.spectralCentroidHz = spectralCentroidHz
    }
}

/// Compact result shared by the file and microphone adapters. It intentionally
/// contains no PCM samples, AVFoundation objects, or Fabric types.
public struct AudioAnalysisSnapshot: Codable, Equatable, Sendable
{
    public let frameIndex: Int
    public let timeSeconds: Float
    public let measurements: AudioFrameMeasurements
    public let rmsNormalized: Float
    public let loudnessNormalized: Float
    public let bandsNormalized: AudioFrequencyBands
    public let spectralFluxNormalized: Float
    public let onset: Bool
    public let peakHeldRMS: Float
    public let peakHeldFlux: Float
    public let fastEnvelope: Float
    public let mediumEnvelope: Float
    public let slowEnvelope: Float

    public init(
        frameIndex: Int,
        timeSeconds: Float,
        measurements: AudioFrameMeasurements,
        rmsNormalized: Float,
        loudnessNormalized: Float,
        bandsNormalized: AudioFrequencyBands,
        spectralFluxNormalized: Float,
        onset: Bool,
        peakHeldRMS: Float,
        peakHeldFlux: Float,
        fastEnvelope: Float,
        mediumEnvelope: Float,
        slowEnvelope: Float
    )
    {
        self.frameIndex = frameIndex
        self.timeSeconds = timeSeconds
        self.measurements = measurements
        self.rmsNormalized = rmsNormalized
        self.loudnessNormalized = loudnessNormalized
        self.bandsNormalized = bandsNormalized
        self.spectralFluxNormalized = spectralFluxNormalized
        self.onset = onset
        self.peakHeldRMS = peakHeldRMS
        self.peakHeldFlux = peakHeldFlux
        self.fastEnvelope = fastEnvelope
        self.mediumEnvelope = mediumEnvelope
        self.slowEnvelope = slowEnvelope
    }
}
