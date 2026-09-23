import Fabric
import Foundation
import Metal
import Satin

private enum VerificationError: Error
{
    case missingPlugin(String)
    case missingNode(String)
    case noMetalDevice
    case connectionFailed
    case graphRoundTripFailed
}

let pluginID = "com.jvclabs.FabricAudioSourceProcessor"
let registry = try NodeRegistry.shared

guard PluginLoader.shared.loadedPlugins[pluginID] != nil else
{
    let errors = registry.pluginLoadErrors.map(\.localizedDescription).joined(separator: "\n")
    throw VerificationError.missingPlugin(errors)
}

var discoveredNodes: [String: Node.Type] = [:]
for (nodeID, displayName) in [
    ("AudioFileAnalysisNode", "Audio File Analysis"),
    ("LiveAudioAnalysisNode", "Live Audio Analysis"),
]
{
    guard let nodeClass = registry.nodeClass(pluginID: pluginID, nodeID: nodeID),
          nodeClass.name == displayName else
    {
        throw VerificationError.missingNode(nodeID)
    }
    discoveredNodes[nodeID] = nodeClass
    print("Discovered \(nodeClass.name)")
}

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
guard let fileNodeClass = discoveredNodes["AudioFileAnalysisNode"],
      let liveNodeClass = discoveredNodes["LiveAudioAnalysisNode"]
else
{
    throw VerificationError.graphRoundTripFailed
}

let graph = Graph(context: context)
let fileNode = fileNodeClass.init(context: context)
let liveNode = liveNodeClass.init(context: context)
let numericNode = NumberBinaryOperator(context: context)
graph.addNode(fileNode)
graph.addNode(liveNode)
graph.addNode(numericNode)

let rmsOutput: NodePort<Float> = fileNode.port(named: "outputRMS")
guard graph.connect(rmsOutput, to: numericNode.inputNumber1) != nil else
{
    throw VerificationError.connectionFailed
}

let encodedGraph = try JSONEncoder().encode(graph)
let decoder = JSONDecoder()
decoder.context = DecoderContext(documentContext: context)
let reopenedGraph = try decoder.decode(Graph.self, from: encodedGraph)
guard reopenedGraph.nodes.count == 3,
      reopenedGraph.connections.count == 1,
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio File Analysis" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Live Audio Analysis" })
else
{
    throw VerificationError.graphRoundTripFailed
}
print("Saved and reopened both nodes with a typed connection")

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

    for (nodeClass, fileName) in [
        (fileNodeClass, "AudioFileAnalysis.fabric"),
        (liveNodeClass, "LiveAudioAnalysis.fabric"),
    ]
    {
        let sampleGraph = Graph(context: context)
        let sourceNode = nodeClass.init(context: context)
        sourceNode.offset = CGSize(width: -250, height: 0)
        let mathNode = NumberBinaryOperator(context: context)
        mathNode.offset = CGSize(width: 250, height: 0)
        sampleGraph.addNode(sourceNode)
        sampleGraph.addNode(mathNode)
        let rms: NodePort<Float> = sourceNode.port(named: "outputRMS")
        guard sampleGraph.connect(rms, to: mathNode.inputNumber1) != nil else
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
        guard reopenedSample.nodes.count == 2,
              reopenedSample.connections.count == 1
        else
        {
            throw VerificationError.graphRoundTripFailed
        }
        print("Wrote \(fileName)")
    }
}
