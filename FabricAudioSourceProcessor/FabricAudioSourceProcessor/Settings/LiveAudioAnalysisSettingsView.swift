import Observation
import SwiftUI

@MainActor
@Observable
final class LiveAudioAnalysisSettingsModel
{
    var settings: LiveAudioAnalysisSettings
    @ObservationIgnored private let updateSettings: (LiveAudioAnalysisSettings) -> Void

    init(
        settings: LiveAudioAnalysisSettings,
        updateSettings: @escaping (LiveAudioAnalysisSettings) -> Void
    )
    {
        self.settings = settings
        self.updateSettings = updateSettings
    }

    func changeFrameRate(_ framesPerSecond: Int)
    {
        let updatedSettings = LiveAudioAnalysisSettings(
            analysisFramesPerSecond: framesPerSecond
        )
        settings = updatedSettings
        updateSettings(updatedSettings)
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
