import AudioSourceProcessorCore
import Fabric
import Foundation
import Metal
import Satin

private struct AudioWaveformGeometryError: LocalizedError
{
    let message: String
    var errorDescription: String? { message }
}

/// Turns file or microphone waveform history into real 3D ribbon geometry.
/// Connect Geometry to a Mesh node and choose a Material for its appearance.
public final class AudioWaveformGeometryNode: BaseGeometryNode
{
    public override class var name: String { "Audio Waveform Geometry" }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Processor }
    public override class var nodeTimeMode: Node.TimeMode { .Idle }
    public override class var nodeDescription: String
    {
        "Builds layered 3D ribbon geometry from signed audio waveform history."
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        [
            ("inputHistory", NodePort<ContiguousArray<Float>>(name: "Waveform History", kind: .Inlet, description: "24 oldest-to-newest rows of 192 signed samples from an audio analysis node")),
            ("inputRows", ParameterPort(parameter: IntParameter("History", 24, 1, 24, .inputfield, "Number of newest waveform rows to build"))),
            ("inputWidth", ParameterPort(parameter: FloatParameter("Width", 2, 0.1, 20, .inputfield, "Width across the waveform in world units"))),
            ("inputDepth", ParameterPort(parameter: FloatParameter("Depth", 1.2, 0, 20, .inputfield, "Distance between oldest and newest rows in world units"))),
            ("inputAmplitude", ParameterPort(parameter: FloatParameter("Amplitude", 0.6, 0, 10, .slider, "Vertical waveform displacement in world units"))),
            ("inputThickness", ParameterPort(parameter: FloatParameter("Thickness", 0.01, 0.001, 0.2, .slider, "Ribbon width in world units"))),
        ] + super.registerPorts(context: context)
    }

    public var inputHistory: NodePort<ContiguousArray<Float>> { port(named: "inputHistory") }
    public var inputRows: ParameterPort<Int> { port(named: "inputRows") }
    public var inputWidth: ParameterPort<Float> { port(named: "inputWidth") }
    public var inputDepth: ParameterPort<Float> { port(named: "inputDepth") }
    public var inputAmplitude: ParameterPort<Float> { port(named: "inputAmplitude") }
    public var inputThickness: ParameterPort<Float> { port(named: "inputThickness") }

    public override var geometry: Geometry { ribbonGeometry }

    private lazy var ribbonGeometry = AudioWaveformRibbonGeometry(context: context)

    public override func updateGeometry(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool
    {
        let history = inputHistory.value ?? ContiguousArray<Float>(
            repeating: 0,
            count: AudioWaveformRow.sampleCount * AudioWaveformRow.maximumHistoryRows
        )
        guard history.count == AudioWaveformRow.sampleCount * AudioWaveformRow.maximumHistoryRows,
              history.allSatisfy(\.isFinite)
        else
        {
            throw AudioWaveformGeometryError(
                message: "Waveform History requires 24 rows of 192 finite signed samples."
            )
        }
        let shouldOutput = try super.updateGeometry(
            renderer: renderer,
            executionInfo: executionInfo,
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer
        )
        ribbonGeometry.setWaveform(
            history: history,
            visibleRows: min(max(inputRows.value ?? 24, 1), 24),
            width: min(max(inputWidth.value ?? 2, 0.1), 20),
            depth: min(max(inputDepth.value ?? 1.2, 0), 20),
            amplitude: min(max(inputAmplitude.value ?? 0.6, 0), 10),
            thickness: min(max(inputThickness.value ?? 0.01, 0.001), 0.2)
        )
        return shouldOutput || inputHistory.valueDidChange
            || inputRows.valueDidChange || inputWidth.valueDidChange
            || inputDepth.valueDidChange || inputAmplitude.valueDidChange
            || inputThickness.valueDidChange
    }
}
