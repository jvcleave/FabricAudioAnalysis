import AudioSourceProcessorCore
import Foundation

/// Separates background decoding from the render-thread port publication.
final class AudioFileAnalysisStore: @unchecked Sendable
{
    struct State
    {
        let generation: Int
        let analysis: AudioFileAnalysis?
        let errorDescription: String?
    }

    private let lock = NSLock()
    private var settings: AudioFileAnalysisSettings
    private var inputFileURLString: String?
    private var generation = 0
    private var analysis: AudioFileAnalysis?
    private var errorDescription: String?
    private var processingTask: Task<Void, Never>?

    init(settings: AudioFileAnalysisSettings)
    {
        self.settings = settings
    }

    deinit
    {
        processingTask?.cancel()
    }

    func replaceSettings(_ newSettings: AudioFileAnalysisSettings)
    {
        lock.lock()
        defer { lock.unlock() }
        guard settings != newSettings else { return }
        settings = newSettings
        invalidateLocked()
    }

    func replaceInputFileURL(_ value: String?)
    {
        let normalizedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = normalizedValue?.isEmpty == false ? normalizedValue : nil
        lock.lock()
        defer { lock.unlock() }
        guard inputFileURLString != newValue else { return }
        inputFileURLString = newValue
        invalidateLocked()
    }

    func cancelPendingWork()
    {
        lock.lock()
        defer { lock.unlock() }
        guard processingTask != nil, analysis == nil else { return }
        invalidateLocked()
    }

    func currentState() -> State
    {
        lock.lock()
        defer { lock.unlock() }
        return State(
            generation: generation,
            analysis: analysis,
            errorDescription: errorDescription
        )
    }

    func beginProcessingIfNeeded()
    {
        lock.lock()
        defer { lock.unlock() }
        guard processingTask == nil,
              analysis == nil,
              errorDescription == nil,
              (inputFileURLString != nil || settings.fileURLString != nil || settings.bookmarkData != nil)
        else
        {
            return
        }

        let requestSettings = settings
        let requestInputFileURLString = inputFileURLString
        let requestGeneration = generation
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do
            {
                let fileURL = if let requestInputFileURLString
                {
                    AudioFileSourceURL.resolve(requestInputFileURLString)
                }
                else
                {
                    try requestSettings.resolvedFileURL()
                }
                guard let fileURL else
                {
                    throw AudioFileAnalysisSettingsError.invalidFileURL
                }
                let result = try await AudioFileProcessor().process(
                    url: fileURL,
                    framesPerSecond: Double(requestSettings.analysisFramesPerSecond)
                )
                self?.complete(requestGeneration, result: .success(result))
            }
            catch is CancellationError
            {
                // A newer generation owns the node now.
            }
            catch
            {
                self?.complete(requestGeneration, result: .failure(error))
            }
        }
    }

    private func invalidateLocked()
    {
        processingTask?.cancel()
        processingTask = nil
        generation += 1
        analysis = nil
        errorDescription = nil
    }

    private func complete(
        _ requestGeneration: Int,
        result: Result<AudioFileAnalysis, any Error>
    )
    {
        lock.lock()
        defer { lock.unlock() }
        guard generation == requestGeneration else { return }
        processingTask = nil
        switch result
        {
            case .success(let completedAnalysis):
                analysis = completedAnalysis
                errorDescription = nil
            case .failure(let error):
                analysis = nil
                errorDescription = error.localizedDescription
        }
    }
}
