import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AudioFileAnalysisSettingsModel
{
    var settings: AudioFileAnalysisSettings
    var selectionError: String?
    @ObservationIgnored private let updateSettings: (AudioFileAnalysisSettings) -> Void

    init(
        settings: AudioFileAnalysisSettings,
        updateSettings: @escaping (AudioFileAnalysisSettings) -> Void
    )
    {
        self.settings = settings
        self.updateSettings = updateSettings
    }

    func chooseFile(_ url: URL)
    {
        let updatedSettings = AudioFileAnalysisSettings(
            fileURL: url,
            analysisFramesPerSecond: settings.analysisFramesPerSecond
        )
        settings = updatedSettings
        selectionError = nil
        updateSettings(updatedSettings)
    }

    func changeFrameRate(_ framesPerSecond: Int)
    {
        let updatedSettings = settings.changingFrameRate(to: framesPerSecond)
        settings = updatedSettings
        selectionError = nil
        updateSettings(updatedSettings)
    }
}

struct AudioFileAnalysisSettingsView: View
{
    @State var model: AudioFileAnalysisSettingsModel
    @State private var isFileImporterPresented = false

    var body: some View
    {
        Form
        {
            LabeledContent("Audio File")
            {
                Text(model.settings.fileName ?? "No file selected")
            }

            Button("Choose Audio File", systemImage: "waveform")
            {
                isFileImporterPresented = true
            }

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

            if let selectionError = model.selectionError
            {
                Text(selectionError)
                    .foregroundStyle(.red)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.audio]
        )
        { result in
            switch result
            {
                case .success(let url):
                    model.chooseFile(url)
                case .failure(let error):
                    model.selectionError = error.localizedDescription
            }
        }
    }
}
