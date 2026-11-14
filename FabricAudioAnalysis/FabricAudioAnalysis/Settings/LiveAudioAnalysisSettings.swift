import Fabric

public struct LiveAudioAnalysisSettings: NodeSettings
{
    public let analysisFramesPerSecond: Int

    public init(analysisFramesPerSecond: Int = 30)
    {
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }
}
