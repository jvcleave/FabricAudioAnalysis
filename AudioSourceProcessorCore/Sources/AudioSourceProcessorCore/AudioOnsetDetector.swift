import Foundation

/// Streaming flux threshold adapted from AudioSourceProcessorExample commit
/// 4db4e252f88339e7f7833fa37a42230779b4a904. File analysis may replace
/// these provisional decisions with its centered, whole-source onset pass.
public final class AudioOnsetDetector
{
    private let historyLimit = 17
    private let minimumFrameGap = 2
    private var fluxHistory: [Float] = []
    private var lastOnsetFrameIndex: Int?

    public init() {}

    public func reset()
    {
        fluxHistory.removeAll(keepingCapacity: true)
        lastOnsetFrameIndex = nil
    }

    public func detect(spectralFlux: Float, frameIndex: Int) -> Bool
    {
        let safeFlux = spectralFlux.isFinite ? max(0, spectralFlux) : 0
        fluxHistory.append(safeFlux)
        if fluxHistory.count > historyLimit
        {
            fluxHistory.removeFirst()
        }
        guard fluxHistory.count > 3 else { return false }

        let previousValues = fluxHistory.dropLast()
        let previousAverage = previousValues.reduce(0, +) / Float(previousValues.count)
        guard let previousFlux = previousValues.last,
              safeFlux > previousAverage * 1.2,
              safeFlux > previousFlux
        else
        {
            return false
        }

        if let lastOnsetFrameIndex,
           frameIndex - lastOnsetFrameIndex < minimumFrameGap
        {
            return false
        }

        lastOnsetFrameIndex = frameIndex
        return true
    }
}
