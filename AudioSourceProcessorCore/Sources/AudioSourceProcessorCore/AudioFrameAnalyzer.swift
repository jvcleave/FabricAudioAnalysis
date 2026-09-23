import Accelerate
import Foundation

public enum AudioFrameAnalyzerError: LocalizedError
{
    case invalidSampleRate
    case emptySamples
    case fftSetupUnavailable

    public var errorDescription: String?
    {
        switch self
        {
            case .invalidSampleRate:
                return "Audio sample rate must be finite and greater than zero."
            case .emptySamples:
                return "An audio analysis frame must contain samples."
            case .fftSetupUnavailable:
                return "The audio FFT analyzer could not be created."
        }
    }
}

/// Stateful 2048-point FFT analyzer adapted from AudioSourceProcessorExample
/// commit 4db4e252f88339e7f7833fa37a42230779b4a904. One instance belongs
/// to one ordered source stream because spectral flux uses the previous frame.
/// Callers serialize access; this class is not shared across processing queues.
public final class AudioFrameAnalyzer
{
    public static let fftSize = 2048

    private let fftSetup: FFTSetup
    private let window: [Float]
    private let highFrequencyRamp: [Float]
    private var previousLogMagnitudes: [Float]
    private var fftSamples: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]

    public init() throws
    {
        let logarithmicSize = vDSP_Length(11)
        guard let fftSetup = vDSP_create_fftsetup(logarithmicSize, FFTRadix(kFFTRadix2)) else
        {
            throw AudioFrameAnalyzerError.fftSetupUnavailable
        }
        self.fftSetup = fftSetup
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.fftSize,
            isHalfWindow: false
        )
        highFrequencyRamp = (0 ..< Self.fftSize / 2).map
        {
            Float($0) / Float(Self.fftSize / 2)
        }
        previousLogMagnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
        fftSamples = [Float](repeating: 0, count: Self.fftSize)
        real = [Float](repeating: 0, count: Self.fftSize / 2)
        imaginary = [Float](repeating: 0, count: Self.fftSize / 2)
        magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
    }

    deinit
    {
        vDSP_destroy_fftsetup(fftSetup)
    }

    public func reset()
    {
        for magnitudeIndex in previousLogMagnitudes.indices
        {
            previousLogMagnitudes[magnitudeIndex] = 0
        }
    }

    /// Analyze one mono frame. RMS uses the complete supplied hop; spectral
    /// measurements use the first 2048 samples, zero-padded when necessary.
    public func analyze(samples: [Float], sampleRate: Float) throws -> AudioFrameMeasurements
    {
        guard sampleRate.isFinite, sampleRate > 0 else
        {
            throw AudioFrameAnalyzerError.invalidSampleRate
        }
        guard !samples.isEmpty else
        {
            throw AudioFrameAnalyzerError.emptySamples
        }

        var squaredSampleSum: Double = 0
        for sampleIndex in samples.indices
        {
            let safeSample = samples[sampleIndex].isFinite ? samples[sampleIndex] : 0
            squaredSampleSum += Double(safeSample) * Double(safeSample)
            if sampleIndex < Self.fftSize
            {
                fftSamples[sampleIndex] = safeSample * window[sampleIndex]
            }
        }
        for sampleIndex in min(samples.count, Self.fftSize) ..< Self.fftSize
        {
            fftSamples[sampleIndex] = 0
        }
        let rms = Float(sqrt(squaredSampleSum / Double(samples.count)))
        let loudnessDB = rms > 1e-7 ? 20 * log10f(rms) : -140

        let halfSize = Self.fftSize / 2
        let setup = fftSetup

        real.withUnsafeMutableBufferPointer
        { realPointer in
            imaginary.withUnsafeMutableBufferPointer
            { imaginaryPointer in
                fftSamples.withUnsafeMutableBufferPointer
                { samplePointer in
                    guard let realAddress = realPointer.baseAddress,
                          let imaginaryAddress = imaginaryPointer.baseAddress,
                          let sampleAddress = samplePointer.baseAddress
                    else
                    {
                        preconditionFailure("The fixed-size FFT work buffers must be nonempty.")
                    }
                    var splitComplex = DSPSplitComplex(
                        realp: realAddress,
                        imagp: imaginaryAddress
                    )
                    sampleAddress.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfSize
                    )
                    { complexPointer in
                        vDSP_ctoz(
                            complexPointer,
                            2,
                            &splitComplex,
                            1,
                            vDSP_Length(halfSize)
                        )
                    }
                    vDSP_fft_zrip(
                        setup,
                        &splitComplex,
                        1,
                        vDSP_Length(11),
                        FFTDirection(FFT_FORWARD)
                    )
                    vDSP_zvmags(
                        &splitComplex,
                        1,
                        &magnitudes,
                        1,
                        vDSP_Length(halfSize)
                    )
                }
            }
        }

        var bandSums = [Float](repeating: 0, count: 5)
        var bandCounts = [Int](repeating: 0, count: 5)
        var weightedFrequencySum: Float = 0
        var magnitudeSum: Float = 0
        let topFrequency = min(20_000, sampleRate / 2)

        for magnitudeIndex in 1 ..< magnitudes.count
        {
            let frequency = Float(magnitudeIndex) * sampleRate / Float(Self.fftSize)
            let magnitude = max(0, magnitudes[magnitudeIndex])
            weightedFrequencySum += frequency * magnitude
            magnitudeSum += magnitude

            let bandIndex: Int?
            switch frequency
            {
                case 20 ..< 60: bandIndex = 0
                case 60 ..< 250: bandIndex = 1
                case 250 ..< 500: bandIndex = 2
                case 500 ..< 2_000: bandIndex = 3
                case let highFrequency where highFrequency >= 2_000 && highFrequency <= topFrequency:
                    bandIndex = 4
                default: bandIndex = nil
            }
            if let bandIndex
            {
                bandSums[bandIndex] += magnitude
                bandCounts[bandIndex] += 1
            }
        }

        for bandIndex in bandSums.indices where bandCounts[bandIndex] > 0
        {
            bandSums[bandIndex] /= Float(bandCounts[bandIndex])
        }

        var spectralFlux: Float = 0
        for magnitudeIndex in magnitudes.indices
        {
            let currentLogMagnitude = logf(1 + magnitudes[magnitudeIndex])
            spectralFlux += max(0, currentLogMagnitude - previousLogMagnitudes[magnitudeIndex])
                * highFrequencyRamp[magnitudeIndex]
            previousLogMagnitudes[magnitudeIndex] = currentLogMagnitude
        }

        return AudioFrameMeasurements(
            rms: rms,
            loudnessDB: loudnessDB,
            bandEnergies: AudioFrequencyBands(
                subBass: bandSums[0],
                bass: bandSums[1],
                lowMid: bandSums[2],
                mid: bandSums[3],
                high: bandSums[4]
            ),
            spectralFlux: spectralFlux,
            spectralCentroidHz: magnitudeSum > 0
                ? weightedFrequencySum / magnitudeSum
                : 0
        )
    }
}
