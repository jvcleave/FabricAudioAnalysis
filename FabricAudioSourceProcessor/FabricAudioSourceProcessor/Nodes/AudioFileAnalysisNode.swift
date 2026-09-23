import Fabric
import Metal
import Satin

/// Registration shell. File selection and analysis arrive in the next milestone.
public final class AudioFileAnalysisNode: Node
{
    public override class var name: String { "Audio File Analysis" }
    public override class var nodeType: Node.NodeType { .Parameter(parameterType: .IO) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }
    public override class var nodeDescription: String
    {
        "Development shell for time-addressed audio-file analysis. Select and analyze a file in the next milestone."
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) +
        [
            ("inputTime", ParameterPort(parameter: FloatParameter("Time", 0, .inputfield, "Playback time in seconds; graph time is used when unconnected"))),
            ("inputLoop", ParameterPort(parameter: BoolParameter("Loop", true, .toggle, "Wrap file time at the end"))),
            ("inputPlaybackRate", ParameterPort(parameter: FloatParameter("Playback Rate", 1, .inputfield, "Graph-time speed when Time is unconnected"))),
        ] +
        AudioAnalysisPortLayout.outputs() +
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
    public var outputReady: NodePort<Bool> { port(named: "outputReady") }

    private var publishedUnavailableState = false

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        guard !publishedUnavailableState else { return }
        outputReady.send(false)
        publishedUnavailableState = true
    }
}
