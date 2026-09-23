import Fabric
import Foundation
import Metal
import Satin
import simd

private enum VerificationError: Error
{
    case missingPlugin(String)
    case missingNode(String)
    case missingCoreNode(String)
    case noMetalDevice
    case noCommandBuffer
    case connectionFailed
    case graphRoundTripFailed
    case boxScaleFailed
    case waveformRenderFailed(String)
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
    ("Audio3DWaveformNode", "Audio 3D Waveform"),
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
      let liveNodeClass = discoveredNodes["LiveAudioAnalysisNode"],
      let waveformNodeClass = discoveredNodes["Audio3DWaveformNode"]
else
{
    throw VerificationError.graphRoundTripFailed
}

let graph = Graph(context: context)
let fileNode = fileNodeClass.init(context: context)
let liveNode = liveNodeClass.init(context: context)
let waveformNode = waveformNodeClass.init(context: context)
let numericNode = NumberBinaryOperator(context: context)
graph.addNode(fileNode)
graph.addNode(liveNode)
graph.addNode(waveformNode)
graph.addNode(numericNode)

let rmsOutput: NodePort<Float> = fileNode.port(named: "outputRMS")
guard graph.connect(rmsOutput, to: numericNode.inputNumber1) != nil else
{
    throw VerificationError.connectionFailed
}
let waveformHistory: NodePort<ContiguousArray<Float>> = fileNode.port(named: "outputWaveformHistory")
let waveformInput: NodePort<ContiguousArray<Float>> = waveformNode.port(named: "inputHistory")
guard graph.connect(waveformHistory, to: waveformInput) != nil else
{
    throw VerificationError.connectionFailed
}

let encodedGraph = try JSONEncoder().encode(graph)
let decoder = JSONDecoder()
decoder.context = DecoderContext(documentContext: context)
let reopenedGraph = try decoder.decode(Graph.self, from: encodedGraph)
guard reopenedGraph.nodes.count == 4,
      reopenedGraph.connections.count == 2,
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio File Analysis" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Live Audio Analysis" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio 3D Waveform" })
else
{
    throw VerificationError.graphRoundTripFailed
}
print("Saved and reopened all three plugin nodes with typed connections")

let existingSceneDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
).appending(path: "FabricScenes", directoryHint: .isDirectory)
for (fileName, expectedConnectionCount) in [
    ("AudioFileAnalysis.fabric", 7),
    ("LiveAudioAnalysis.fabric", 8),
]
{
    let sceneData = try Data(contentsOf: existingSceneDirectory.appending(path: fileName))
    let sceneDecoder = JSONDecoder()
    sceneDecoder.context = DecoderContext(documentContext: context)
    let existingScene = try sceneDecoder.decode(Graph.self, from: sceneData)
    guard existingScene.nodes.count == 6,
          existingScene.connections.count == expectedConnectionCount
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    print("Opened existing \(fileName) without rewriting it")
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

    for (nodeClass, fileName) in [
        (fileNodeClass, "AudioFileAnalysis.fabric"),
        (liveNodeClass, "LiveAudioAnalysis.fabric"),
    ]
    {
        let sampleGraph = Graph(context: context)
        let sourceNode = nodeClass.init(context: context)
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
              reopenedSample.nodes.contains(where: { type(of: $0).name == nodeClass.name })
        else
        {
            throw VerificationError.graphRoundTripFailed
        }
        if fileName == "AudioFileAnalysis.fabric"
        {
            guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer(),
                  let reopenedMesh = reopenedSample.nodes.compactMap({ $0 as? MeshNode }).first
            else
            {
                throw VerificationError.noCommandBuffer
            }
            let renderer = GraphRenderer(context: context, graph: reopenedSample)
            try renderer.startExecution(graph: reopenedSample)
            try renderer.execute(
                graph: reopenedSample,
                executionInfo: renderer.currentExecutionInfo,
                renderPassDescriptor: MTLRenderPassDescriptor(),
                commandBuffer: commandBuffer
            )
            guard reopenedMesh.object?.scale == simd_float3(repeating: 0.35) else
            {
                throw VerificationError.boxScaleFailed
            }
            try renderer.stopExecution(graph: reopenedSample)
            print("Rendered box starts at 0.35 scale before audio is selected")
        }
        print("Wrote \(fileName)")
    }
}

if CommandLine.arguments.contains("--write-waveform-samples")
{
    guard let imageMeshClass = registry.nodeClass(
        pluginID: "graphics.fabric.CoreNodes",
        nodeID: "ImageMeshNode"
    ) else
    {
        throw VerificationError.missingCoreNode("ImageMeshNode")
    }
    let sceneDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appending(path: "FabricScenes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: sceneDirectory,
        withIntermediateDirectories: true
    )

    for (sourceClass, fileName) in [
        (fileNodeClass, "Audio3DWaveformFile.fabric"),
        (liveNodeClass, "Audio3DWaveformLive.fabric"),
    ]
    {
        let sampleGraph = Graph(context: context)
        let source = sourceClass.init(context: context)
        source.offset = CGSize(width: -550, height: 0)
        let visualizer = waveformNodeClass.init(context: context)
        visualizer.offset = CGSize(width: -150, height: 0)
        let imageMesh = imageMeshClass.init(context: context)
        imageMesh.offset = CGSize(width: 300, height: 0)
        sampleGraph.addNode(source)
        sampleGraph.addNode(visualizer)
        sampleGraph.addNode(imageMesh)

        let history: NodePort<ContiguousArray<Float>> = source.port(named: "outputWaveformHistory")
        let historyInput: NodePort<ContiguousArray<Float>> = visualizer.port(named: "inputHistory")
        let image: NodePort<FabricImage> = visualizer.port(named: "outputImage")
        let imageInput: NodePort<FabricImage> = imageMesh.port(named: "inputImage")
        guard sampleGraph.connect(history, to: historyInput) != nil,
              sampleGraph.connect(image, to: imageInput) != nil
        else
        {
            throw VerificationError.connectionFailed
        }

        let encoded = try JSONEncoder().encode(sampleGraph)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let readable = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let sceneURL = sceneDirectory.appending(path: fileName)
        try readable.write(to: sceneURL)
        let sceneDecoder = JSONDecoder()
        sceneDecoder.context = DecoderContext(documentContext: context)
        let reopened = try sceneDecoder.decode(Graph.self, from: readable)
        guard reopened.nodes.count == 3,
              reopened.connections.count == 2
        else
        {
            throw VerificationError.graphRoundTripFailed
        }

        if fileName == "Audio3DWaveformFile.fabric"
        {
            guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer(),
                  let reopenedVisualizer = reopened.nodes.first(where: {
                      type(of: $0).name == "Audio 3D Waveform"
                  })
            else
            {
                throw VerificationError.noCommandBuffer
            }
            let renderer = GraphRenderer(context: context, graph: reopened)
            try renderer.startExecution(graph: reopened)
            try renderer.execute(
                graph: reopened,
                executionInfo: renderer.currentExecutionInfo,
                renderPassDescriptor: MTLRenderPassDescriptor(),
                commandBuffer: commandBuffer
            )
            let outputImage: NodePort<FabricImage> = reopenedVisualizer.port(named: "outputImage")
            guard let renderedTexture = outputImage.value?.texture else
            {
                throw VerificationError.waveformRenderFailed("The image outlet was empty")
            }
            let pixelCount = renderedTexture.width * renderedTexture.height
            guard let readbackBuffer = device.makeBuffer(
                length: pixelCount * 4 * MemoryLayout<UInt16>.stride,
                options: .storageModeShared
            ),
                let blitEncoder = commandBuffer.makeBlitCommandEncoder()
            else
            {
                throw VerificationError.waveformRenderFailed("The image readback buffer was unavailable")
            }
            blitEncoder.copy(
                from: renderedTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(
                    width: renderedTexture.width,
                    height: renderedTexture.height,
                    depth: 1
                ),
                to: readbackBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: renderedTexture.width * 8,
                destinationBytesPerImage: pixelCount * 8
            )
            blitEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else
            {
                throw VerificationError.waveformRenderFailed(
                    commandBuffer.error?.localizedDescription ?? "The GPU did not finish"
                )
            }
            let pixels = readbackBuffer.contents().bindMemory(
                to: UInt16.self,
                capacity: pixelCount * 4
            )
            let litPixelCount = (0 ..< pixelCount).reduce(into: 0) { count, pixelIndex in
                if pixels[pixelIndex * 4 + 1] > 0 { count += 1 }
            }
            guard litPixelCount > 100 else
            {
                throw VerificationError.waveformRenderFailed("The rendered image contained no visible lines")
            }
            try renderer.stopExecution(graph: reopened)
            print("Rendered Audio 3D Waveform with \(litPixelCount) visible pixels")
        }
        print("Wrote \(fileName)")
    }
}
