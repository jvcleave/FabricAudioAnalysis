import Fabric
import Metal
import Satin

private enum WaveformIteratorError: Error
{
    case verificationFailed(String)
}

private final class IteratedWaveform: Node
{
    static let samples: [Float] = [-1, -0.5, 0, 0.5, 1]

    override class var name: String { "Iterated Waveform" }
    override class var nodeType: Node.NodeType { .Utility }
    override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    override class var nodeTimeMode: Node.TimeMode { .None }
    override class var nodeDescription: String { "Supplies a distinct waveform on each Iterator pass" }

    override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) + [("output", NodePort<ContiguousArray<Float>>(name: "Waveform", kind: .Outlet))]
    }

    var output: NodePort<ContiguousArray<Float>> { port(named: "output") }

    override func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                          renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws
    {
        guard let iteration = executionInfo.iterationInfo?.currentIteration,
              Self.samples.indices.contains(iteration) else
        {
            throw WaveformIteratorError.verificationFailed("Missing Iterator index")
        }
        output.send(ContiguousArray(repeating: Self.samples[iteration], count: 192))
    }
}

private final class IteratedImageReceiver: Node
{
    override class var name: String { "Iterated Image Receiver" }
    override class var nodeType: Node.NodeType { .Utility }
    override class var nodeExecutionMode: Node.ExecutionMode { .Consumer }
    override class var nodeTimeMode: Node.TimeMode { .None }
    override class var nodeDescription: String { "Keeps each Iterator image for Metal readback" }

    override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) + [("input", NodePort<FabricImage>(name: "Image", kind: .Inlet))]
    }

    var input: NodePort<FabricImage> { port(named: "input") }
    private(set) var images: [FabricImage] = []

    override func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                          renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws
    {
        guard let image = input.value else { throw WaveformIteratorError.verificationFailed("Missing Iterator image") }
        images.append(image)
    }
}

func verifyWaveformIterator(_ waveformClass: Node.Type, context: Context, retainedReferences: Bool) throws
{
    let graph = Graph(context: context)
    let iterator = IteratorNode(context: context)
    let source = IteratedWaveform(context: context)
    let trail = waveformClass.init(context: context)
    let receiver = IteratedImageReceiver(context: context)
    let samples = IteratedWaveform.samples
    iterator.inputIteratonCount.value = samples.count
    let height = 128
    let inputWidth: ParameterPort<Int> = trail.port(named: "inputWidth")
    let inputHeight: ParameterPort<Int> = trail.port(named: "inputHeight")
    let inputGlow: ParameterPort<Float> = trail.port(named: "inputGlow")
    let inputThickness: ParameterPort<Float> = trail.port(named: "inputThickness")
    inputWidth.value = 64
    inputHeight.value = height
    inputGlow.value = 0
    inputThickness.value = 0.012
    let inputWaveform: NodePort<ContiguousArray<Float>> = trail.port(named: "inputWaveform")
    let outputImage: NodePort<FabricImage> = trail.port(named: "outputImage")
    for node in [source, trail, receiver] { iterator.subGraph.addNode(node) }
    guard iterator.subGraph.connect(source.output, to: inputWaveform) != nil,
          iterator.subGraph.connect(outputImage, to: receiver.input) != nil else
    {
        throw WaveformIteratorError.verificationFailed("Could not connect the waveform Iterator")
    }
    graph.addNode(iterator)
    let renderer = GraphRenderer(context: context, graph: graph)
    try renderer.startExecution()
    defer { renderer.teardown() }
    let commandBuffer = retainedReferences
        ? renderer.makeCommandBuffer()
        : renderer.commandQueue.makeCommandBufferWithUnretainedReferences()
    guard let commands = commandBuffer else
    {
        throw WaveformIteratorError.verificationFailed("Could not create Iterator command buffer")
    }
    try renderer.execute(graph: graph, executionInfo: renderer.currentExecutionInfo,
                         renderPassDescriptor: MTLRenderPassDescriptor(), commandBuffer: commands)

    let images = receiver.images
    let imageVersions = Set(images.map(\.id)).count
    guard images.count == samples.count, imageVersions == samples.count else
    {
        throw WaveformIteratorError.verificationFailed("Expected five Iterator images, got \(imageVersions) distinct versions across \(images.count) passes")
    }
    let pixelStride = 256
    guard let pixels = context.device.makeBuffer(length: images.count * pixelStride, options: .storageModeShared),
          let blit = commands.makeBlitCommandEncoder() else
    {
        throw WaveformIteratorError.verificationFailed("Could not prepare Iterator pixel readback")
    }
    for (iteration, image) in images.enumerated()
    {
        let lineY = Int((0.64 - samples[iteration] * 0.25) * Float(height))
        blit.copy(from: image.texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 12, y: lineY, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: pixels, destinationOffset: iteration * pixelStride,
                  destinationBytesPerRow: pixelStride, destinationBytesPerImage: pixelStride)
    }
    blit.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    guard commands.status == .completed else
    {
        throw WaveformIteratorError.verificationFailed(commands.error?.localizedDescription ?? "Iterator GPU execution failed")
    }
    for iteration in images.indices
    {
        let blue = pixels.contents().load(fromByteOffset: iteration * pixelStride + 2 * MemoryLayout<UInt16>.stride, as: UInt16.self)
        guard Float16(bitPattern: blue) > 0.9 else
        {
            throw WaveformIteratorError.verificationFailed("Iterator pass \(iteration + 1) missed its expected waveform line")
        }
    }
    print("Verified five distinct Waveform Trail images and their waveform pixels on one Iterator command buffer (retained references: \(retainedReferences))")
}
