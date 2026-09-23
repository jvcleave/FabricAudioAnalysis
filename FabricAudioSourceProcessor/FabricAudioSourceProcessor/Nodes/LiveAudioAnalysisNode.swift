import Fabric
import Metal
import Satin

/// Registration shell. Microphone capture arrives in the next milestone.
public final class LiveAudioAnalysisNode: Node
{
    public override class var name: String { "Live Audio Analysis" }
    public override class var nodeType: Node.NodeType { .Parameter(parameterType: .IO) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeTimeMode: Node.TimeMode { .Idle }
    public override class var nodeDescription: String
    {
        "Development shell for default-microphone analysis. Live capture is not yet implemented."
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) +
        [
            ("inputEnabled", ParameterPort(parameter: BoolParameter("Enabled", true, .toggle, "Capture while the graph executes"))),
        ] +
        AudioAnalysisPortLayout.outputs(for: .microphone) +
        [
            ("outputRunning", NodePort<Bool>(name: "Running", kind: .Outlet, description: "True while microphone capture is active")),
            ("outputSampleRate", NodePort<Float>(name: "Sample Rate", kind: .Outlet, description: "Microphone sample rate in hertz")),
        ]
    }

    public var inputEnabled: ParameterPort<Bool> { port(named: "inputEnabled") }
    public var outputRunning: NodePort<Bool> { port(named: "outputRunning") }

    private var publishedUnavailableState = false

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        guard !publishedUnavailableState else { return }
        outputRunning.send(false)
        publishedUnavailableState = true
    }
}
