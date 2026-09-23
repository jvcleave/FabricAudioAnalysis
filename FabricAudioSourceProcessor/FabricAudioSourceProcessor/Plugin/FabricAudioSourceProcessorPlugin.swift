import AudioSourceProcessorCore
import Fabric
import Foundation

/// Entry point discovered by Fabric when the development bundle loads.
public final class FabricAudioSourceProcessorPlugin: NSObject, FabricPlugin
{
    public static func pluginDidLoad(bundle: Bundle)
    {
        // Resolve the linked core package without starting analysis or capture.
        _ = AudioFrameAnalyzer.fftSize
    }

    public static func pluginWillUnload() {}

    public static func additionalNodeClasses() -> [Node.Type]
    {
        [AudioFileAnalysisNode.self, LiveAudioAnalysisNode.self, Audio3DWaveformNode.self]
    }
}
