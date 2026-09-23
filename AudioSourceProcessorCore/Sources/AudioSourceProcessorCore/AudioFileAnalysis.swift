import Foundation

/// Compact whole-file measurements. Frame samples are discarded during decoding.
public struct AudioFileAnalysis: Sendable
{
    public let sampleRate: Float
    public let durationSeconds: Float
    public let framesPerSecond: Float
    public let averageBPM: Float
    public let frames: [AudioAnalysisSnapshot]

    public var frameCount: Int { frames.count }

    public init(
        sampleRate: Float,
        durationSeconds: Float,
        framesPerSecond: Float,
        averageBPM: Float,
        frames: [AudioAnalysisSnapshot]
    )
    {
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.framesPerSecond = framesPerSecond
        self.averageBPM = averageBPM
        self.frames = frames
    }

    /// Graph-time lookup is independent of processing order, so backward
    /// scrubbing produces the same measurements as forward playback.
    public func frame(at timeSeconds: Float, loop: Bool) -> AudioAnalysisSnapshot?
    {
        guard !frames.isEmpty else { return nil }
        let safeTime = timeSeconds.isFinite ? timeSeconds : 0
        let selectedTime: Float
        if loop, durationSeconds > 0
        {
            let wrappedTime = safeTime.truncatingRemainder(dividingBy: durationSeconds)
            selectedTime = wrappedTime < 0 ? wrappedTime + durationSeconds : wrappedTime
        }
        else
        {
            selectedTime = min(max(0, safeTime), durationSeconds)
        }

        let frameIndex = min(Int(selectedTime * framesPerSecond), frames.count - 1)
        return frames[frameIndex]
    }
}
