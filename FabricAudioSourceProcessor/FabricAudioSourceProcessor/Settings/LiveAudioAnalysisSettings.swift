import Foundation

public struct LiveAudioAnalysisSettings: Codable, Equatable, Sendable
{
    public let analysisFramesPerSecond: Int

    public init(analysisFramesPerSecond: Int = 30)
    {
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }
}
