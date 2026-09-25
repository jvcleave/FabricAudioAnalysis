import AVFoundation
import Fabric
import Foundation
import Metal
import Satin
import SwiftUI

private struct AudioFilePlaybackError: LocalizedError
{
    let message: String
    var errorDescription: String? { message }
}

/// Plays a selected file and publishes AVPlayer's clock for downstream analysis.
public final class AudioFilePlaybackNode: Node
{
    public override class var name: String { "Audio File Playback" }
    public override class var nodeType: Node.NodeType { .Parameter(parameterType: .IO) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Consumer }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }
    public override class var nodeDescription: String
    {
        "Plays a local audio file and provides its current playback time."
    }

    public private(set) var fileSettings: AudioFilePlaybackSettings
    private weak var settingsModel: AudioFilePlaybackSettingsModel?
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var endObserver: NSObjectProtocol?
    private let endLock = NSLock()
    private var reachedEnd = false
    private var needsLoad = true

    private enum CodingKeys: String, CodingKey
    {
        case fileSettings
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) +
        [
            ("inputFileURL", ParameterPort(parameter: StringParameter("File URL", "", .filepicker, "Optional file URL or absolute path; overrides the file selected in Settings"))),
            ("inputPlaying", ParameterPort(parameter: BoolParameter("Playing", true, .toggle, "Play or pause the selected audio file"))),
            ("inputLoop", ParameterPort(parameter: BoolParameter("Loop", true, .toggle, "Restart playback when the file ends"))),
            ("inputVolume", ParameterPort(parameter: FloatParameter("Volume", 1, 0, 1, .slider, "Audio output volume, 0 to 1"))),
            ("inputSeekTime", ParameterPort(parameter: FloatParameter("Seek Time", -1, .inputfield, "Set a nonnegative time in seconds to seek; -1 leaves playback alone"))),
            ("outputCurrentTime", NodePort<Float>(name: "Current Time", kind: .Outlet, description: "Current player time in seconds; connect to Audio File Analysis Time")),
            ("outputDuration", NodePort<Float>(name: "Duration", kind: .Outlet, description: "Audio file duration in seconds")),
            ("outputPlaying", NodePort<Bool>(name: "Is Playing", kind: .Outlet, description: "True while the player is advancing")),
            ("outputReady", NodePort<Bool>(name: "Ready", kind: .Outlet, description: "True when the player item is ready")),
            ("outputFinished", NodePort<Bool>(name: "Finished", kind: .Outlet, description: "One graph-pass pulse when the player reaches the end")),
            ("outputFileURL", NodePort<String>(name: "File URL", kind: .Outlet, description: "Selected local file URL; connect to Audio File Analysis File URL")),
            ("outputVolume", NodePort<Float>(name: "Volume", kind: .Outlet, description: "Effective player volume from the Volume input, clamped to 0 to 1")),
        ]
    }

    public var inputFileURL: ParameterPort<String> { port(named: "inputFileURL") }
    public var inputPlaying: ParameterPort<Bool> { port(named: "inputPlaying") }
    public var inputLoop: ParameterPort<Bool> { port(named: "inputLoop") }
    public var inputVolume: ParameterPort<Float> { port(named: "inputVolume") }
    public var inputSeekTime: ParameterPort<Float> { port(named: "inputSeekTime") }
    public var outputCurrentTime: NodePort<Float> { port(named: "outputCurrentTime") }
    public var outputDuration: NodePort<Float> { port(named: "outputDuration") }
    public var outputPlaying: NodePort<Bool> { port(named: "outputPlaying") }
    public var outputReady: NodePort<Bool> { port(named: "outputReady") }
    public var outputFinished: NodePort<Bool> { port(named: "outputFinished") }
    public var outputFileURL: NodePort<String> { port(named: "outputFileURL") }
    public var outputVolume: NodePort<Float> { port(named: "outputVolume") }

    public required init(context: Context)
    {
        fileSettings = AudioFilePlaybackSettings()
        super.init(context: context)
    }

    public init(context: Context, settings: AudioFilePlaybackSettings)
    {
        fileSettings = settings
        super.init(context: context)
    }

    public required init(from decoder: any Decoder) throws
    {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileSettings = try container.decodeIfPresent(
            AudioFilePlaybackSettings.self,
            forKey: .fileSettings
        ) ?? AudioFilePlaybackSettings()
        try super.init(from: decoder)
    }

    deinit
    {
        releasePlayer()
    }

    public override func encode(to encoder: Encoder) throws
    {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileSettings, forKey: .fileSettings)
    }

    public func setFileSettings(_ settings: AudioFilePlaybackSettings)
    {
        guard fileSettings != settings else { return }
        releasePlayer()
        fileSettings = settings
        needsLoad = true
        markDirty()
    }

    public override func providesSettingsView() -> Bool { true }

    public override func settingsView() -> AnyView
    {
        MainActor.assumeIsolated
        {
            let model = settingsModel ?? AudioFilePlaybackSettingsModel(
                settings: fileSettings,
                updateSettings: { [weak self] settings in
                    self?.setFileSettings(settings)
                }
            )
            settingsModel = model
            return AnyView(AudioFilePlaybackSettingsView(model: model))
        }
    }

    public override var settingsSize: SettingsViewSize
    {
        .Custom(size: CGSize(width: 420, height: 130))
    }

    public override func startExecution(renderer: GraphRenderer) throws
    {
        needsLoad = true
        try super.startExecution(renderer: renderer)
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        releasePlayer()
        needsLoad = true
        publishEmptyState()
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        let volume = effectiveVolume()
        outputVolume.send(volume)
        if needsLoad || inputFileURL.valueDidChange
        {
            needsLoad = false
            try loadSelectedFile(volume: volume)
        }
        guard let player, let playerItem else
        {
            publishEmptyState()
            return
        }

        if playerItem.status == .failed
        {
            throw AudioFilePlaybackError(
                message: playerItem.error?.localizedDescription ?? "The audio file could not be played."
            )
        }
        if inputVolume.valueDidChange
        {
            player.volume = volume
        }
        if inputPlaying.valueDidChange
        {
            applyPlayingInput()
        }
        if inputSeekTime.valueDidChange,
           let requestedTime = inputSeekTime.value,
           requestedTime.isFinite, requestedTime >= 0
        {
            let target = CMTime(seconds: Double(requestedTime), preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        let didFinish = takeEndSignal()
        if didFinish
        {
            if inputLoop.value ?? true
            {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if inputPlaying.value ?? true { player.play() }
            }
            else
            {
                player.pause()
            }
        }

        let duration = playerItem.duration.seconds
        let currentTime = player.currentTime().seconds
        outputDuration.send(duration.isFinite && duration > 0 ? Float(duration) : 0)
        outputCurrentTime.send(currentTime.isFinite && currentTime >= 0 ? Float(currentTime) : 0)
        outputPlaying.send(player.rate > 0)
        outputReady.send(playerItem.status == .readyToPlay)
        outputFinished.send(didFinish, force: didFinish)
    }

    private func loadSelectedFile(volume: Float) throws
    {
        releasePlayer()
        let suppliedPath = (inputFileURL.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = try suppliedPath.isEmpty
            ? fileSettings.resolvedFileURL()
            : AudioFileSourceURL.resolve(suppliedPath)
        guard let fileURL, fileURL.isFileURL else
        {
            throw AudioFilePlaybackError(message: "Choose a local audio file for playback.")
        }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else
        {
            releasePlayer()
            throw AudioFilePlaybackError(message: "Audio file is unavailable: \(fileURL.lastPathComponent)")
        }
        let item = AVPlayerItem(url: fileURL)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = volume
        newPlayer.actionAtItemEnd = .pause
        playerItem = item
        player = newPlayer
        outputFileURL.send(fileURL.absoluteString)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: nil
        ) { [weak self] _ in
            self?.markEnd()
        }
        applyPlayingInput()
    }

    private func effectiveVolume() -> Float
    {
        let requestedVolume = inputVolume.value ?? 1
        guard requestedVolume.isFinite else { return 1 }
        return min(max(requestedVolume, 0), 1)
    }

    private func applyPlayingInput()
    {
        guard let player else { return }
        if inputPlaying.value ?? true
        {
            if let duration = playerItem?.duration.seconds,
               duration.isFinite,
               player.currentTime().seconds >= duration
            {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        }
        else
        {
            player.pause()
        }
    }

    private func markEnd()
    {
        endLock.lock()
        reachedEnd = true
        endLock.unlock()
    }

    private func takeEndSignal() -> Bool
    {
        endLock.lock()
        defer { endLock.unlock() }
        let result = reachedEnd
        reachedEnd = false
        return result
    }

    private func publishEmptyState()
    {
        outputCurrentTime.send(0)
        outputDuration.send(0)
        outputPlaying.send(false)
        outputReady.send(false)
        outputFinished.send(false)
        outputFileURL.send("")
    }

    private func releasePlayer()
    {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        if let endObserver
        {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        _ = takeEndSignal()
    }
}
