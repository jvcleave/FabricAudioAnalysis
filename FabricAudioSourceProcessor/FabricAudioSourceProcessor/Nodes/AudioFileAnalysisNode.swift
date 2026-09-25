import AudioSourceProcessorCore
import Fabric
import Foundation
import Metal
import Satin
import SwiftUI

private struct AudioFileAnalysisNodeError: LocalizedError
{
    let message: String
    var errorDescription: String? { message }
}

public final class AudioFileAnalysisNode: Node
{
    public override class var name: String { "Audio File Analysis" }
    public override class var nodeType: Node.NodeType { .Parameter(parameterType: .IO) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }
    public override class var nodeDescription: String
    {
        "Analyzes an audio file and publishes time-addressed levels, frequency bands, onsets, and envelopes."
    }

    public private(set) var fileSettings: AudioFileAnalysisSettings
    private let analysisStore: AudioFileAnalysisStore
    private weak var settingsModel: AudioFileAnalysisSettingsModel?
    private var lastPublishedState: PublishedState?

    private enum CodingKeys: String, CodingKey
    {
        case fileSettings
    }

    private struct PublishedState: Equatable
    {
        let generation: Int
        let frameIndex: Int?
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) +
        [
            ("inputTime", ParameterPort(parameter: FloatParameter("Time", 0, .inputfield, "Playback time in seconds; graph time is used when unconnected"))),
            ("inputLoop", ParameterPort(parameter: BoolParameter("Loop", true, .toggle, "Wrap file time at the end"))),
            ("inputPlaybackRate", ParameterPort(parameter: FloatParameter("Playback Rate", 1, .inputfield, "Graph-time speed when Time is unconnected"))),
            ("inputFileURL", ParameterPort(parameter: StringParameter("File URL", "", .filepicker, "Optional local file URL or absolute path; overrides the file selected in Settings"))),
        ] +
        AudioAnalysisPortLayout.outputs(for: .file) +
        [
            ("outputReady", NodePort<Bool>(name: "Ready", kind: .Outlet, description: "True when the selected file has completed analysis")),
            ("outputCurrentFrame", NodePort<Int>(name: "Current Frame", kind: .Outlet, description: "Zero-based selected analysis frame")),
            ("outputFrameCount", NodePort<Int>(name: "Frame Count", kind: .Outlet, description: "Number of analyzed frames")),
            ("outputFrameRate", NodePort<Float>(name: "Frame Rate", kind: .Outlet, description: "Analysis frames per second")),
            ("outputDuration", NodePort<Float>(name: "Duration", kind: .Outlet, description: "Source duration in seconds")),
            ("outputAverageBPM", NodePort<Float>(name: "Average BPM", kind: .Outlet, description: "Whole-file tempo estimate")),
        ]
    }

    public var inputTime: ParameterPort<Float> { port(named: "inputTime") }
    public var inputLoop: ParameterPort<Bool> { port(named: "inputLoop") }
    public var inputPlaybackRate: ParameterPort<Float> { port(named: "inputPlaybackRate") }
    public var inputFileURL: ParameterPort<String> { port(named: "inputFileURL") }
    public var outputReady: NodePort<Bool> { port(named: "outputReady") }
    public var outputCurrentFrame: NodePort<Int> { port(named: "outputCurrentFrame") }
    public var outputFrameCount: NodePort<Int> { port(named: "outputFrameCount") }
    public var outputFrameRate: NodePort<Float> { port(named: "outputFrameRate") }
    public var outputDuration: NodePort<Float> { port(named: "outputDuration") }
    public var outputAverageBPM: NodePort<Float> { port(named: "outputAverageBPM") }
    public var outputWaveformHistory: NodePort<ContiguousArray<Float>> { port(named: "outputWaveformHistory") }

    public required init(context: Context)
    {
        fileSettings = AudioFileAnalysisSettings()
        analysisStore = AudioFileAnalysisStore(settings: fileSettings)
        super.init(context: context)
    }

    public init(context: Context, settings: AudioFileAnalysisSettings)
    {
        fileSettings = settings
        analysisStore = AudioFileAnalysisStore(settings: settings)
        super.init(context: context)
    }

    public required init(from decoder: any Decoder) throws
    {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileSettings = try container.decodeIfPresent(
            AudioFileAnalysisSettings.self,
            forKey: .fileSettings
        ) ?? AudioFileAnalysisSettings()
        analysisStore = AudioFileAnalysisStore(settings: fileSettings)
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws
    {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileSettings, forKey: .fileSettings)
    }

    public func setFileSettings(_ settings: AudioFileAnalysisSettings)
    {
        guard fileSettings != settings else { return }
        fileSettings = settings
        analysisStore.replaceSettings(settings)
        markDirty()
    }

    public override func providesSettingsView() -> Bool { true }

    public override func settingsView() -> AnyView
    {
        MainActor.assumeIsolated
        {
            let model = settingsModel ?? AudioFileAnalysisSettingsModel(
                settings: fileSettings,
                updateSettings: { [weak self] settings in
                    self?.setFileSettings(settings)
                }
            )
            settingsModel = model
            return AnyView(AudioFileAnalysisSettingsView(model: model))
        }
    }

    public override var settingsSize: SettingsViewSize
    {
        .Custom(size: CGSize(width: 420, height: 220))
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        analysisStore.cancelPendingWork()
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        analysisStore.replaceInputFileURL(inputFileURL.value)
        analysisStore.beginProcessingIfNeeded()
        let state = analysisStore.currentState()
        guard let analysis = state.analysis else
        {
            let unavailable = PublishedState(generation: state.generation, frameIndex: nil)
            if lastPublishedState != unavailable
            {
                AudioAnalysisPortLayout.publish(nil, from: self)
                outputReady.send(false)
                outputCurrentFrame.send(0)
                outputFrameCount.send(0)
                outputFrameRate.send(0)
                outputDuration.send(0)
                outputAverageBPM.send(0)
                outputWaveformHistory.send(AudioWaveformRow.flattenedHistory([]))
                lastPublishedState = unavailable
            }
            if let errorDescription = state.errorDescription
            {
                throw AudioFileAnalysisNodeError(message: errorDescription)
            }
            return
        }

        let requestedTime: Float
        if inputTime.connectedOutlets.isEmpty
        {
            requestedTime = Float(executionInfo.timing.time)
                * (inputPlaybackRate.value ?? 1)
        }
        else
        {
            requestedTime = inputTime.value ?? 0
        }
        guard let snapshot = analysis.frame(
            at: requestedTime,
            loop: inputLoop.value ?? true
        ) else
        {
            return
        }
        let selected = PublishedState(
            generation: state.generation,
            frameIndex: snapshot.frameIndex
        )
        guard lastPublishedState != selected else { return }

        AudioAnalysisPortLayout.publish(snapshot, from: self)
        outputReady.send(true)
        outputCurrentFrame.send(snapshot.frameIndex)
        outputFrameCount.send(analysis.frameCount)
        outputFrameRate.send(analysis.framesPerSecond)
        outputDuration.send(analysis.durationSeconds)
        outputAverageBPM.send(analysis.averageBPM)
        outputWaveformHistory.send(
            analysis.waveformHistory(endingAt: snapshot.frameIndex)
        )
        lastPublishedState = selected
    }
}
