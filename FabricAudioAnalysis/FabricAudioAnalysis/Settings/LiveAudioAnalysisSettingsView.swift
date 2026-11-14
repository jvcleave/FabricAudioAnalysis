import Observation
import SwiftUI

@MainActor
@Observable
final class LiveAudioAnalysisSettingsModel
{
    private(set) var settings: LiveAudioAnalysisSettings
    @ObservationIgnored private weak var node: LiveAudioAnalysisNode?

    init(node: LiveAudioAnalysisNode)
    {
        self.node = node
        self.settings = node.liveSettings
    }

    func changeFrameRate(_ framesPerSecond: Int)
    {
        node?.setLiveSettings(LiveAudioAnalysisSettings(analysisFramesPerSecond: framesPerSecond))
        refreshFromNode()
    }

    func refreshFromNode()
    {
        guard let liveSettings = node?.liveSettings, liveSettings != settings else { return }
        settings = liveSettings
    }
}

struct LiveAudioAnalysisSettingsView: View
{
    @State var model: LiveAudioAnalysisSettingsModel

    var body: some View
    {
        Form
        {
            Text("Uses the system default microphone while the graph runs and Enabled is true.")

            Stepper(
                value: Binding(
                    get: { model.settings.analysisFramesPerSecond },
                    set: { model.changeFrameRate($0) }
                ),
                in: 1 ... 120
            )
            {
                Text("Analysis FPS: \(model.settings.analysisFramesPerSecond)")
            }
        }
    }
}
