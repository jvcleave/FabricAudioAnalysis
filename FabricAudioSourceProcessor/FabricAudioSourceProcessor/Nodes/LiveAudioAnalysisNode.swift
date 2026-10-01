import AudioSourceProcessorCore
import Fabric
import Foundation
import Metal
import Satin
import SwiftUI

private struct LiveAudioAnalysisNodeError: LocalizedError
{
    let message: String
    var errorDescription: String? { message }
}

public final class LiveAudioAnalysisNode: Node
{
    public override class var name: String { "Live Audio Analysis" }
    public override class var nodeType: Node.NodeType { .Parameter(parameterType: .IO) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeTimeMode: Node.TimeMode { .Idle }
    public override class var nodeDescription: String
    {
        "Analyzes the default microphone while the graph runs and publishes rolling levels, frequency bands, onsets, and envelopes."
    }

    public private(set) var liveSettings: LiveAudioAnalysisSettings
    private let analysisStore: LiveAudioAnalysisStore
    private weak var settingsModel: LiveAudioAnalysisSettingsModel?
    private var lastPublishedState: PublishedState?

    private enum CodingKeys: String, CodingKey
    {
        case liveSettings
    }

    private struct PublishedState: Equatable
    {
        let generation: Int
        let revision: Int
        let onset: Bool
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) +
        [
            ("inputEnabled", ParameterPort(parameter: BoolParameter("Enabled", true, .toggle, "Capture while the graph executes"))),
        ] +
        AudioAnalysisPortLayout.outputs() +
        [
            ("outputRunning", NodePort<Bool>(name: "Running", kind: .Outlet, description: "True while microphone capture is active")),
            ("outputSampleRate", NodePort<Float>(name: "Sample Rate", kind: .Outlet, description: "Microphone sample rate in hertz")),
        ]
    }

    public var inputEnabled: ParameterPort<Bool> { port(named: "inputEnabled") }
    public var outputRunning: NodePort<Bool> { port(named: "outputRunning") }
    public var outputSampleRate: NodePort<Float> { port(named: "outputSampleRate") }
    public var outputWaveformHistory: NodePort<ContiguousArray<Float>> { port(named: "outputWaveformHistory") }

    public required init(context: Context)
    {
        liveSettings = LiveAudioAnalysisSettings()
        analysisStore = LiveAudioAnalysisStore(settings: liveSettings)
        super.init(context: context)
    }

    public init(context: Context, settings: LiveAudioAnalysisSettings)
    {
        liveSettings = settings
        analysisStore = LiveAudioAnalysisStore(settings: settings)
        super.init(context: context)
    }

    public required init(from decoder: any Decoder) throws
    {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liveSettings = try container.decodeIfPresent(
            LiveAudioAnalysisSettings.self,
            forKey: .liveSettings
        ) ?? LiveAudioAnalysisSettings()
        analysisStore = LiveAudioAnalysisStore(settings: liveSettings)
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws
    {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(liveSettings, forKey: .liveSettings)
    }

    public func setLiveSettings(_ settings: LiveAudioAnalysisSettings)
    {
        guard liveSettings != settings else { return }
        liveSettings = settings
        analysisStore.replaceSettings(settings)
        markDirty()
    }

    public override func providesSettingsView() -> Bool { true }

    public override func settingsView() -> AnyView
    {
        MainActor.assumeIsolated
        {
            let model = settingsModel ?? LiveAudioAnalysisSettingsModel(
                settings: liveSettings,
                updateSettings: { [weak self] settings in
                    self?.setLiveSettings(settings)
                }
            )
            settingsModel = model
            return AnyView(LiveAudioAnalysisSettingsView(model: model))
        }
    }

    public override var settingsSize: SettingsViewSize
    {
        .Custom(size: CGSize(width: 420, height: 180))
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        analysisStore.stop()
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        analysisStore.setEnabled(inputEnabled.value ?? true)
        analysisStore.beginCaptureIfNeeded()
        let state = analysisStore.takeStateForGraphPass()
        let publication = PublishedState(
            generation: state.generation,
            revision: state.revision,
            onset: state.snapshot?.onset ?? false
        )
        if lastPublishedState != publication
        {
            AudioAnalysisPortLayout.publish(state.snapshot, from: self)
            outputRunning.send(state.isRunning)
            outputSampleRate.send(state.sampleRate)
            outputWaveformHistory.send(
                AudioWaveformRow.flattenedHistory(state.waveformRows[...])
            )
            lastPublishedState = publication
        }
        if let errorDescription = state.errorDescription
        {
            throw LiveAudioAnalysisNodeError(message: errorDescription)
        }
    }
}
