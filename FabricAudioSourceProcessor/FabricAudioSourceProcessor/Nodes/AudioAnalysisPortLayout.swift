import Fabric

/// Stable shared outlet keys for file and microphone analysis nodes.
enum AudioAnalysisPortLayout
{
    static func outputs() -> [(name: String, port: Fabric.Port)]
    {
        [
            ("outputRMS", NodePort<Float>(name: "RMS", kind: .Outlet, description: "Raw root-mean-square audio amplitude")),
            ("outputRMSNormalized", NodePort<Float>(name: "RMS Normalized", kind: .Outlet, description: "RMS normalized to the source's analysis window, 0 to 1")),
            ("outputLoudnessDB", NodePort<Float>(name: "Loudness dB", kind: .Outlet, description: "Audio loudness in decibels")),
            ("outputLoudnessNormalized", NodePort<Float>(name: "Loudness Normalized", kind: .Outlet, description: "Loudness mapped from -60 to 0 dB into 0 to 1")),
            ("outputOnset", NodePort<Bool>(name: "Onset", kind: .Outlet, description: "Whether the published analysis frame has an onset")),
            ("outputSubBass", NodePort<Float>(name: "Sub Bass", kind: .Outlet, description: "Normalized energy from 20 to 60 Hz")),
            ("outputBass", NodePort<Float>(name: "Bass", kind: .Outlet, description: "Normalized energy from 60 to 250 Hz")),
            ("outputLowMid", NodePort<Float>(name: "Low Mid", kind: .Outlet, description: "Normalized energy from 250 to 500 Hz")),
            ("outputMid", NodePort<Float>(name: "Mid", kind: .Outlet, description: "Normalized energy from 500 to 2000 Hz")),
            ("outputHigh", NodePort<Float>(name: "High", kind: .Outlet, description: "Normalized energy from 2000 Hz to Nyquist or 20000 Hz")),
            ("outputSpectralFlux", NodePort<Float>(name: "Spectral Flux", kind: .Outlet, description: "Normalized positive spectral change, 0 to 1")),
            ("outputSpectralCentroid", NodePort<Float>(name: "Spectral Centroid", kind: .Outlet, description: "Spectral center of mass in hertz")),
            ("outputPeakRMS", NodePort<Float>(name: "Peak RMS", kind: .Outlet, description: "Peak-held normalized RMS, 0 to 1")),
            ("outputPeakFlux", NodePort<Float>(name: "Peak Flux", kind: .Outlet, description: "Peak-held normalized spectral flux, 0 to 1")),
            ("outputFastEnvelope", NodePort<Float>(name: "Fast Envelope", kind: .Outlet, description: "Fast-release normalized RMS envelope, 0 to 1")),
            ("outputMediumEnvelope", NodePort<Float>(name: "Medium Envelope", kind: .Outlet, description: "Medium-release normalized RMS envelope, 0 to 1")),
            ("outputSlowEnvelope", NodePort<Float>(name: "Slow Envelope", kind: .Outlet, description: "Slow-release normalized RMS envelope, 0 to 1")),
        ]
    }
}
