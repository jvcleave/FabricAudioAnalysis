import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AudioFilePlaybackSettingsModel
{
    var settings: AudioFilePlaybackSettings
    var selectionError: String?
    @ObservationIgnored private let updateSettings: (AudioFilePlaybackSettings) -> Void

    init(
        settings: AudioFilePlaybackSettings,
        updateSettings: @escaping (AudioFilePlaybackSettings) -> Void
    )
    {
        self.settings = settings
        self.updateSettings = updateSettings
    }

    func chooseFile(_ url: URL)
    {
        let updatedSettings = AudioFilePlaybackSettings(fileURL: url)
        settings = updatedSettings
        selectionError = nil
        updateSettings(updatedSettings)
    }
}

struct AudioFilePlaybackSettingsView: View
{
    @State var model: AudioFilePlaybackSettingsModel
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
