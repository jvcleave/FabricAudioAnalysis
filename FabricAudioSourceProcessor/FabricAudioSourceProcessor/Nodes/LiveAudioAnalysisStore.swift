import AudioSourceProcessorCore
import Foundation

/// Owns one capture generation and hands the newest completed frame to Fabric.
/// The lock protects only small status values and immutable snapshots.
final class LiveAudioAnalysisStore: @unchecked Sendable
{
    struct State
    {
        let generation: Int
        let revision: Int
        let isRunning: Bool
        let sampleRate: Float
        let snapshot: AudioAnalysisSnapshot?
        let errorDescription: String?
    }

    private let lock = NSLock()
    private var settings: LiveAudioAnalysisSettings
    private var isEnabled = true
    private var generation = 0
    private var revision = 0
    private var isRunning = false
    private var sampleRate: Float = 0
    private var latestSnapshot: AudioAnalysisSnapshot?
    private var hasPendingOnset = false
    private var errorDescription: String?
    private var captureTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?

    init(settings: LiveAudioAnalysisSettings)
    {
        self.settings = settings
    }

    deinit
    {
        captureTask?.cancel()
        pendingStopTask?.cancel()
    }

    func replaceSettings(_ newSettings: LiveAudioAnalysisSettings)
    {
        lock.lock()
        defer { lock.unlock() }
        guard settings != newSettings else { return }
        settings = newSettings
        resetCapture()
    }

    func setEnabled(_ enabled: Bool)
    {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        resetCapture()
    }

    func stop()
    {
        lock.lock()
        defer { lock.unlock() }
        resetCapture()
    }

    func beginCaptureIfNeeded()
    {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled,
              captureTask == nil,
              errorDescription == nil
        else
        {
            return
        }

        let requestGeneration = generation
        let framesPerSecond = settings.analysisFramesPerSecond
        let storeReference = WeakLiveAudioAnalysisStore(self)
        let previousCaptureTask = pendingStopTask
        pendingStopTask = nil
        captureTask = Task.detached(priority: .userInitiated) {
            if let previousCaptureTask
            {
                await previousCaptureTask.value
            }
            guard !Task.isCancelled else { return }
            let capture = LiveAudioCapture()
            do
            {
                let sampleRate = try await capture.start(
                    framesPerSecond: framesPerSecond
                )
                storeReference.value?.markRunning(requestGeneration, sampleRate: sampleRate)
                try await capture.run
                { snapshot in
                    storeReference.value?.receive(requestGeneration, snapshot: snapshot)
                }
            }
            catch is CancellationError
            {
                // The graph stopped or a newer generation replaced this one.
            }
            catch
            {
                storeReference.value?.recordFailure(requestGeneration, error: error)
            }
            capture.stop()
            storeReference.value?.markStopped(requestGeneration)
        }
    }

    /// Consuming the pending onset ensures a pulse survives coalesced capture
    /// frames and clears on the next graph pass even without a new frame.
    func takeStateForGraphPass() -> State
    {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = latestSnapshot?.replacingOnset(with: hasPendingOnset)
        hasPendingOnset = false
        return State(
            generation: generation,
            revision: revision,
            isRunning: isRunning,
            sampleRate: sampleRate,
            snapshot: snapshot,
            errorDescription: errorDescription
        )
    }

    private func resetCapture()
    {
        if let captureTask
        {
            captureTask.cancel()
            pendingStopTask = captureTask
        }
        captureTask = nil
        generation += 1
        revision += 1
        isRunning = false
        sampleRate = 0
        latestSnapshot = nil
        hasPendingOnset = false
        errorDescription = nil
    }

    private func markRunning(_ requestGeneration: Int, sampleRate: Float)
    {
        lock.lock()
        defer { lock.unlock() }
        guard generation == requestGeneration else { return }
        isRunning = true
        self.sampleRate = sampleRate
        revision += 1
    }

    private func receive(_ requestGeneration: Int, snapshot: AudioAnalysisSnapshot)
    {
        lock.lock()
        defer { lock.unlock() }
        guard generation == requestGeneration else { return }
        latestSnapshot = snapshot
        hasPendingOnset = hasPendingOnset || snapshot.onset
        revision += 1
    }

    private func recordFailure(_ requestGeneration: Int, error: any Error)
    {
        lock.lock()
        defer { lock.unlock() }
        guard generation == requestGeneration else { return }
        errorDescription = error.localizedDescription
        revision += 1
    }

    private func markStopped(_ requestGeneration: Int)
    {
        lock.lock()
        defer { lock.unlock() }
        guard generation == requestGeneration else { return }
        captureTask = nil
        isRunning = false
        sampleRate = 0
        latestSnapshot = nil
        hasPendingOnset = false
        revision += 1
    }
}

private final class WeakLiveAudioAnalysisStore: @unchecked Sendable
{
    weak var value: LiveAudioAnalysisStore?

    init(_ value: LiveAudioAnalysisStore)
    {
        self.value = value
    }
}
