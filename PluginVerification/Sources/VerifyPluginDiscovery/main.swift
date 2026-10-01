import Fabric
import Foundation
import Metal
import Satin
import simd

private enum VerificationError: Error
{
    case missingPlugin(String)
    case missingNode(String)
    case unexpectedNode(String)
    case noMetalDevice
    case noCommandBuffer
    case connectionFailed
    case graphRoundTripFailed
    case boxScaleFailed
}

func verifyBoxScaling(in graph: Graph, context: Context, device: MTLDevice) throws
{
    guard let sourceNode = graph.nodes.first(where: { type(of: $0).name == "Live Audio Analysis" }),
          let meshNode = graph.nodes.compactMap({ $0 as? MeshNode }).first,
          let commandQueue = device.makeCommandQueue(),
          meshNode.inputVisible.value == true,
          meshNode.inputVisible.connectedOutlets.isEmpty
    else
    {
        throw VerificationError.boxScaleFailed
    }
    let microphoneEnabled: ParameterPort<Bool> = sourceNode.port(named: "inputEnabled")
    microphoneEnabled.value = false
    let renderer = GraphRenderer(context: context, graph: graph)
    try renderer.startExecution()
    defer { renderer.teardown() }

    func executeGraphPass() throws
    {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else
        {
            throw VerificationError.noCommandBuffer
        }
        try renderer.execute(
            graph: graph,
            executionInfo: renderer.currentExecutionInfo,
            renderPassDescriptor: MTLRenderPassDescriptor(),
            commandBuffer: commandBuffer
        )
    }

    try executeGraphPass()
    guard meshNode.object?.scale == simd_float3(repeating: 0.35),
          meshNode.object?.visible == true
    else
    {
        throw VerificationError.boxScaleFailed
    }

    let envelope: NodePort<Float> = sourceNode.port(named: "outputMediumEnvelope")
    envelope.send(0.65, force: true)
    try executeGraphPass()
    guard meshNode.object?.scale == simd_float3(repeating: 1),
          meshNode.object?.visible == true
    else
    {
        throw VerificationError.boxScaleFailed
    }
    print("Verified the box stays visible and scales uniformly from 0.35 to 1.0")
}

let pluginID = "com.jvclabs.FabricAudioAnalysis"
let registry = try NodeRegistry.shared

guard PluginLoader.shared.loadedPlugins[pluginID] != nil else
{
    let errors = registry.pluginLoadErrors.map(\.localizedDescription).joined(separator: "\n")
    throw VerificationError.missingPlugin(errors)
}

guard let liveNodeClass = registry.nodeClass(pluginID: pluginID, nodeID: "LiveAudioAnalysisNode"),
      liveNodeClass.name == "Live Audio Analysis" else
{
    throw VerificationError.missingNode("LiveAudioAnalysisNode")
}
let pluginNodes = registry.availableNodes.filter { $0.pluginBundleID == pluginID }
guard pluginNodes.count == 1 else
{
    throw VerificationError.unexpectedNode(pluginNodes.map(\.nodeName).joined(separator: ", "))
}
print("Discovered Live Audio Analysis as the plugin's only node")

guard let device = MTLCreateSystemDefaultDevice() else
{
    throw VerificationError.noMetalDevice
}
let context = Context(
    device: device,
    sampleCount: 1,
    colorPixelFormat: .bgra8Unorm,
    depthPixelFormat: .depth32Float,
    stencilPixelFormat: .invalid
)

let graph = Graph(context: context)
let liveNode = liveNodeClass.init(context: context)
let numericNode = NumberBinaryOperator(context: context)
graph.addNode(liveNode)
graph.addNode(numericNode)
let rmsOutput: NodePort<Float> = liveNode.port(named: "outputRMS")
guard graph.connect(rmsOutput, to: numericNode.inputNumber1) != nil else
{
    throw VerificationError.connectionFailed
}
let encodedGraph = try JSONEncoder().encode(graph)
let decoder = JSONDecoder()
decoder.context = DecoderContext(documentContext: context)
let reopenedGraph = try decoder.decode(Graph.self, from: encodedGraph)
guard reopenedGraph.nodes.count == 2,
      reopenedGraph.connections.count == 1,
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Live Audio Analysis" })
else
{
    throw VerificationError.graphRoundTripFailed
}
print("Saved and reopened Live Audio Analysis with a typed connection")

let existingSceneDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
).appending(path: "FabricScenes", directoryHint: .isDirectory)
if !CommandLine.arguments.contains("--write-samples")
{
    let fileName = "LiveAudioAnalysis.fabric"
    let sceneData = try Data(contentsOf: existingSceneDirectory.appending(path: fileName))
    let sceneDecoder = JSONDecoder()
    sceneDecoder.context = DecoderContext(documentContext: context)
    let existingScene = try sceneDecoder.decode(Graph.self, from: sceneData)
    guard existingScene.nodes.count == 6,
          existingScene.connections.count == 7,
          existingScene.nodes.contains(where: { type(of: $0).name == "Live Audio Analysis" })
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    let sceneRoundTripData = try JSONEncoder().encode(existingScene)
    let reopenedScene = try sceneDecoder.decode(Graph.self, from: sceneRoundTripData)
    guard Set(reopenedScene.nodes.map(\.id)) == Set(existingScene.nodes.map(\.id)),
          Set(reopenedScene.connections.map(\.id)) == Set(existingScene.connections.map(\.id))
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    print("Opened and round-tripped existing \(fileName) without rewriting it")
    try verifyBoxScaling(in: reopenedScene, context: context, device: device)
}

if CommandLine.arguments.contains("--write-samples")
{
    // The shell script runs this executable from the plugin repository root.
    let repositorySceneDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appending(path: "FabricScenes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: repositorySceneDirectory,
        withIntermediateDirectories: true
    )

    let fileName = "LiveAudioAnalysis.fabric"
    let sampleGraph = Graph(context: context)
    let sourceNode = liveNodeClass.init(context: context)
    sourceNode.offset = CGSize(width: -800, height: 0)
    let scaleOffsetNode = NumberBinaryOperator(context: context)
    scaleOffsetNode.inputNumber2.value = 0.35
    scaleOffsetNode.offset = CGSize(width: -500, height: 0)
    let scaleVectorNode = ComposeVectorNode(context: context, vectorType: .float3)
    scaleVectorNode.offset = CGSize(width: -200, height: 0)
    let boxNode = BoxGeometryNode(context: context)
    boxNode.offset = CGSize(width: -500, height: 450)
    let materialNode = BasicColorMaterialNode(context: context)
    materialNode.offset = CGSize(width: -200, height: 450)
    let meshNode = MeshNode(context: context)
    meshNode.offset = CGSize(width: 150, height: 150)
    sampleGraph.addNode(sourceNode)
    sampleGraph.addNode(scaleOffsetNode)
    sampleGraph.addNode(scaleVectorNode)
    sampleGraph.addNode(boxNode)
    sampleGraph.addNode(materialNode)
    sampleGraph.addNode(meshNode)

    let envelope: NodePort<Float> = sourceNode.port(named: "outputMediumEnvelope")
    guard sampleGraph.connect(envelope, to: scaleOffsetNode.inputNumber1) != nil else
    {
        throw VerificationError.connectionFailed
    }
    for componentIndex in 0 ..< 3
    {
        let component: ParameterPort<Float> = scaleVectorNode.port(
            named: "inputComponent\(componentIndex)"
        )
        guard sampleGraph.connect(scaleOffsetNode.outputNumber, to: component) != nil else
        {
            throw VerificationError.connectionFailed
        }
    }
    let scaleVector: NodePort<simd_float3> = scaleVectorNode.port(named: "outputVector")
    guard sampleGraph.connect(scaleVector, to: meshNode.inputScale) != nil,
          sampleGraph.connect(boxNode.outputGeometry, to: meshNode.inputGeometry) != nil,
          sampleGraph.connect(materialNode.outputMaterial, to: meshNode.inputMaterial) != nil
    else
    {
        throw VerificationError.connectionFailed
    }

    let encodedSample = try JSONEncoder().encode(sampleGraph)
    let object = try JSONSerialization.jsonObject(with: encodedSample)
    let readableSample = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    let sceneURL = repositorySceneDirectory.appending(path: fileName)
    try readableSample.write(to: sceneURL)
    let sampleDecoder = JSONDecoder()
    sampleDecoder.context = DecoderContext(documentContext: context)
    let reopenedSample = try sampleDecoder.decode(Graph.self, from: readableSample)
    guard reopenedSample.nodes.count == 6,
          reopenedSample.connections.count == 7,
          reopenedSample.nodes.contains(where: { type(of: $0).name == "Mesh" }),
          reopenedSample.nodes.contains(where: { type(of: $0).name == "Box Geometry" }),
          reopenedSample.nodes.contains(where: { type(of: $0).name == liveNodeClass.name })
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    try verifyBoxScaling(in: reopenedSample, context: context, device: device)
    print("Wrote \(fileName)")
}
