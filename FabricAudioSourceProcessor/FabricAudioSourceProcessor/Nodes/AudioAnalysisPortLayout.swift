import AudioSourceProcessorCore
import Fabric

/// Stable outlet keys for live microphone analysis.
enum AudioAnalysisPortLayout
{
    static func outputs() -> [(name: String, port: Fabric.Port)]
    {
        [
            ("outputRMS", NodePort<Float>(name: "RMS", kind: .Outlet, description: "Raw root-mean-square audio amplitude")),
            ("outputRMSNormalized", NodePort<Float>(name: "RMS Normalized", kind: .Outlet, description: "RMS normalized to the rolling 180-frame maximum, 0 to 1")),
            ("outputLoudnessDB", NodePort<Float>(name: "Loudness dB", kind: .Outlet, description: "Audio loudness in decibels")),
            ("outputLoudnessNormalized", NodePort<Float>(name: "Loudness Normalized", kind: .Outlet, description: "Loudness mapped from -60 to 0 dB into 0 to 1")),
            ("outputOnset", NodePort<Bool>(name: "Onset", kind: .Outlet, description: "Pulses once when newly captured frames contain an onset")),
            ("outputSubBass", NodePort<Float>(name: "Sub Bass", kind: .Outlet, description: "Energy from 20 to 60 Hz, normalized to the rolling 180-frame maximum")),
            ("outputBass", NodePort<Float>(name: "Bass", kind: .Outlet, description: "Energy from 60 to 250 Hz, normalized to the rolling 180-frame maximum")),
            ("outputLowMid", NodePort<Float>(name: "Low Mid", kind: .Outlet, description: "Energy from 250 to 500 Hz, normalized to the rolling 180-frame maximum")),
            ("outputMid", NodePort<Float>(name: "Mid", kind: .Outlet, description: "Energy from 500 to 2000 Hz, normalized to the rolling 180-frame maximum")),
            ("outputHigh", NodePort<Float>(name: "High", kind: .Outlet, description: "Energy from 2000 Hz to Nyquist or 20000 Hz, normalized to the rolling 180-frame maximum")),
            ("outputSpectralFlux", NodePort<Float>(name: "Spectral Flux", kind: .Outlet, description: "Positive spectral change normalized to the rolling 180-frame maximum, 0 to 1")),
            ("outputSpectralCentroid", NodePort<Float>(name: "Spectral Centroid", kind: .Outlet, description: "Spectral center of mass in hertz")),
            ("outputPeakRMS", NodePort<Float>(name: "Peak RMS", kind: .Outlet, description: "Peak-held normalized RMS, 0 to 1")),
            ("outputPeakFlux", NodePort<Float>(name: "Peak Flux", kind: .Outlet, description: "Peak-held normalized spectral flux, 0 to 1")),
            ("outputFastEnvelope", NodePort<Float>(name: "Fast Envelope", kind: .Outlet, description: "Fast-release normalized RMS envelope, 0 to 1")),
            ("outputMediumEnvelope", NodePort<Float>(name: "Medium Envelope", kind: .Outlet, description: "Medium-release normalized RMS envelope, 0 to 1")),
            ("outputSlowEnvelope", NodePort<Float>(name: "Slow Envelope", kind: .Outlet, description: "Slow-release normalized RMS envelope, 0 to 1")),
            ("outputWaveformHistory", NodePort<ContiguousArray<Float>>(name: "Waveform History", kind: .Outlet, description: "24 oldest-to-newest rows of 192 signed waveform samples")),
        ]
    }

    static func publish(_ snapshot: AudioAnalysisSnapshot?, from node: Node)
    {
        let measurements = snapshot?.measurements
        let bands = snapshot?.bandsNormalized

        let rms: NodePort<Float> = node.port(named: "outputRMS")
        rms.send(measurements?.rms ?? 0)
        let rmsNormalized: NodePort<Float> = node.port(named: "outputRMSNormalized")
        rmsNormalized.send(snapshot?.rmsNormalized ?? 0)
        let loudnessDB: NodePort<Float> = node.port(named: "outputLoudnessDB")
        loudnessDB.send(measurements?.loudnessDB ?? -140)
        let loudnessNormalized: NodePort<Float> = node.port(named: "outputLoudnessNormalized")
        loudnessNormalized.send(snapshot?.loudnessNormalized ?? 0)
        let onset: NodePort<Bool> = node.port(named: "outputOnset")
        onset.send(snapshot?.onset ?? false)
        let subBass: NodePort<Float> = node.port(named: "outputSubBass")
        subBass.send(bands?.subBass ?? 0)
        let bass: NodePort<Float> = node.port(named: "outputBass")
        bass.send(bands?.bass ?? 0)
        let lowMid: NodePort<Float> = node.port(named: "outputLowMid")
        lowMid.send(bands?.lowMid ?? 0)
        let mid: NodePort<Float> = node.port(named: "outputMid")
        mid.send(bands?.mid ?? 0)
        let high: NodePort<Float> = node.port(named: "outputHigh")
        high.send(bands?.high ?? 0)
        let spectralFlux: NodePort<Float> = node.port(named: "outputSpectralFlux")
        spectralFlux.send(snapshot?.spectralFluxNormalized ?? 0)
        let spectralCentroid: NodePort<Float> = node.port(named: "outputSpectralCentroid")
        spectralCentroid.send(measurements?.spectralCentroidHz ?? 0)
        let peakRMS: NodePort<Float> = node.port(named: "outputPeakRMS")
        peakRMS.send(snapshot?.peakHeldRMS ?? 0)
        let peakFlux: NodePort<Float> = node.port(named: "outputPeakFlux")
        peakFlux.send(snapshot?.peakHeldFlux ?? 0)
        let fastEnvelope: NodePort<Float> = node.port(named: "outputFastEnvelope")
        fastEnvelope.send(snapshot?.fastEnvelope ?? 0)
        let mediumEnvelope: NodePort<Float> = node.port(named: "outputMediumEnvelope")
        mediumEnvelope.send(snapshot?.mediumEnvelope ?? 0)
        let slowEnvelope: NodePort<Float> = node.port(named: "outputSlowEnvelope")
        slowEnvelope.send(snapshot?.slowEnvelope ?? 0)
    }
}
