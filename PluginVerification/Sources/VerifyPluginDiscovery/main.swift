import AVFoundation
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
    case playbackFailed(String)
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
    ("AudioFilePlaybackNode", "Audio File Playback"),
    ("LiveAudioAnalysisNode", "Live Audio Analysis"),
    ("Audio3DWaveformNode", "Audio 3D Waveform"),
    ("AudioWaveformGeometryNode", "Audio Waveform Geometry"),
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
      let playbackNodeClass = discoveredNodes["AudioFilePlaybackNode"],
      let liveNodeClass = discoveredNodes["LiveAudioAnalysisNode"],
      let waveformNodeClass = discoveredNodes["Audio3DWaveformNode"],
      let waveformGeometryClass = discoveredNodes["AudioWaveformGeometryNode"]
else
{
    throw VerificationError.graphRoundTripFailed
}

let graph = Graph(context: context)
let fileNode = fileNodeClass.init(context: context)
let playbackNode = playbackNodeClass.init(context: context)
let liveNode = liveNodeClass.init(context: context)
let waveformNode = waveformNodeClass.init(context: context)
let waveformGeometryNode = waveformGeometryClass.init(context: context)
let numericNode = NumberBinaryOperator(context: context)
graph.addNode(fileNode)
graph.addNode(playbackNode)
graph.addNode(liveNode)
graph.addNode(waveformNode)
graph.addNode(waveformGeometryNode)
graph.addNode(numericNode)

let rmsOutput: NodePort<Float> = fileNode.port(named: "outputRMS")
guard graph.connect(rmsOutput, to: numericNode.inputNumber1) != nil else
{
    throw VerificationError.connectionFailed
}
let playbackTime: NodePort<Float> = playbackNode.port(named: "outputCurrentTime")
let analysisTime: ParameterPort<Float> = fileNode.port(named: "inputTime")
guard graph.connect(playbackTime, to: analysisTime) != nil else
{
    throw VerificationError.connectionFailed
}
let waveformHistory: NodePort<ContiguousArray<Float>> = fileNode.port(named: "outputWaveformHistory")
let waveformInput: NodePort<ContiguousArray<Float>> = waveformNode.port(named: "inputHistory")
guard graph.connect(waveformHistory, to: waveformInput) != nil else
{
    throw VerificationError.connectionFailed
}
let liveWaveformHistory: NodePort<ContiguousArray<Float>> = liveNode.port(named: "outputWaveformHistory")
let geometryWaveformInput: NodePort<ContiguousArray<Float>> = waveformGeometryNode.port(named: "inputHistory")
guard graph.connect(liveWaveformHistory, to: geometryWaveformInput) != nil else
{
    throw VerificationError.connectionFailed
}

let encodedGraph = try JSONEncoder().encode(graph)
let decoder = JSONDecoder()
decoder.context = DecoderContext(documentContext: context)
let reopenedGraph = try decoder.decode(Graph.self, from: encodedGraph)
guard reopenedGraph.nodes.count == 6,
      reopenedGraph.connections.count == 4,
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio File Analysis" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio File Playback" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Live Audio Analysis" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio 3D Waveform" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio Waveform Geometry" })
else
{
    throw VerificationError.graphRoundTripFailed
}
print("Saved and reopened all five plugin nodes with typed connections")

let existingSceneDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
).appending(path: "FabricScenes", directoryHint: .isDirectory)
for (fileName, expectedNodeCount, expectedConnectionCount) in [
    ("AudioFileAnalysis.fabric", 6, 7),
    ("LiveAudioAnalysis.fabric", 6, 8),
    ("Audio3DWaveformFile.fabric", 3, 2),
    ("Audio3DWaveformLive.fabric", 3, 2),
    ("AudioWaveformPlayback.fabric", 7, 9),
]
{
    if fileName == "AudioWaveformPlayback.fabric"
        && CommandLine.arguments.contains("--write-playback-sample")
    {
        continue
    }
    let sceneData = try Data(contentsOf: existingSceneDirectory.appending(path: fileName))
    let sceneDecoder = JSONDecoder()
    sceneDecoder.context = DecoderContext(documentContext: context)
    let existingScene = try sceneDecoder.decode(Graph.self, from: sceneData)
    let allowsLocalPlaybackEdits = fileName == "AudioWaveformPlayback.fabric"
    let nodeCountMatches = allowsLocalPlaybackEdits
        ? existingScene.nodes.count >= expectedNodeCount
        : existingScene.nodes.count == expectedNodeCount
    let connectionCountMatches = allowsLocalPlaybackEdits
        ? existingScene.connections.count >= expectedConnectionCount
        : existingScene.connections.count == expectedConnectionCount
    guard nodeCountMatches, connectionCountMatches
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
            try renderer.startExecution(graph: reopened, trace: true)
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
            guard let unchangedCommandBuffer = device.makeCommandQueue()?.makeCommandBuffer()
            else
            {
                throw VerificationError.noCommandBuffer
            }
            try renderer.execute(
                graph: reopened,
                executionInfo: renderer.currentExecutionInfo,
                renderPassDescriptor: MTLRenderPassDescriptor(),
                commandBuffer: unchangedCommandBuffer
            )
            let unchangedExecution = renderer.executionTrace?.executions.last?
                .nodeExecutions.first(where: { $0.nodeID == reopenedVisualizer.id })
            guard unchangedExecution?.result == .skippedClean else
            {
                throw VerificationError.waveformRenderFailed(
                    "The visualizer redrew unchanged waveform history"
                )
            }
            unchangedCommandBuffer.commit()

            let amplitude: ParameterPort<Float> = reopenedVisualizer.port(named: "inputAmplitude")
            amplitude.value = 0.7
            guard let changedCommandBuffer = device.makeCommandQueue()?.makeCommandBuffer()
            else
            {
                throw VerificationError.noCommandBuffer
            }
            try renderer.execute(
                graph: reopened,
                executionInfo: renderer.currentExecutionInfo,
                renderPassDescriptor: MTLRenderPassDescriptor(),
                commandBuffer: changedCommandBuffer
            )
            let changedExecution = renderer.executionTrace?.executions.last?
                .nodeExecutions.first(where: { $0.nodeID == reopenedVisualizer.id })
            guard changedExecution?.result == .executed else
            {
                throw VerificationError.waveformRenderFailed(
                    "The visualizer did not redraw after a control change"
                )
            }
            changedCommandBuffer.commit()
            changedCommandBuffer.waitUntilCompleted()
            try renderer.stopExecution(graph: reopened)
            print("Rendered Audio 3D Waveform with \(litPixelCount) visible pixels; skipped unchanged input and redrew after a control change")
        }
        print("Wrote \(fileName)")
    }
}

if CommandLine.arguments.contains("--write-geometry-samples")
{
    let sceneDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appending(path: "FabricScenes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: sceneDirectory,
        withIntermediateDirectories: true
    )

    for (sourceClass, fileName) in [
        (fileNodeClass, "AudioWaveformGeometryFile.fabric"),
        (liveNodeClass, "AudioWaveformGeometryLive.fabric"),
    ]
    {
        let sampleGraph = Graph(context: context)
        let source = sourceClass.init(context: context)
        source.offset = CGSize(width: -600, height: 0)
        let geometryNode = waveformGeometryClass.init(context: context)
        geometryNode.offset = CGSize(width: -200, height: 0)
        let materialNode = BasicColorMaterialNode(context: context)
        materialNode.inputColor.value = simd_float4(0.22, 1, 0.35, 1)
        materialNode.offset = CGSize(width: -200, height: 400)
        let meshNode = MeshNode(context: context)
        meshNode.inputCastsShadow.value = false
        meshNode.inputDoubleSided.value = true
        meshNode.offset = CGSize(width: 250, height: 100)
        sampleGraph.addNode(source)
        sampleGraph.addNode(geometryNode)
        sampleGraph.addNode(materialNode)
        sampleGraph.addNode(meshNode)

        let history: NodePort<ContiguousArray<Float>> = source.port(named: "outputWaveformHistory")
        let historyInput: NodePort<ContiguousArray<Float>> = geometryNode.port(named: "inputHistory")
        let geometryOutput: NodePort<Geometry> = geometryNode.port(named: "outputGeometry")
        guard sampleGraph.connect(history, to: historyInput) != nil,
              sampleGraph.connect(geometryOutput, to: meshNode.inputGeometry) != nil,
              sampleGraph.connect(materialNode.outputMaterial, to: meshNode.inputMaterial) != nil
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
        try readable.write(to: sceneDirectory.appending(path: fileName))
        let sceneDecoder = JSONDecoder()
        sceneDecoder.context = DecoderContext(documentContext: context)
        let reopened = try sceneDecoder.decode(Graph.self, from: readable)
        guard reopened.nodes.count == 4,
              reopened.connections.count == 3
        else
        {
            throw VerificationError.graphRoundTripFailed
        }

        if fileName == "AudioWaveformGeometryFile.fabric"
        {
            guard let reopenedGeometryNode = reopened.nodes.first(where: {
                type(of: $0).name == "Audio Waveform Geometry"
            }),
                let reopenedMesh = reopened.nodes.compactMap({ $0 as? MeshNode }).first,
                let firstCommandBuffer = device.makeCommandQueue()?.makeCommandBuffer()
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
                commandBuffer: firstCommandBuffer
            )
            let geometryOutput: NodePort<Geometry> = reopenedGeometryNode.port(named: "outputGeometry")
            guard let geometry = geometryOutput.value as? SatinGeometry,
                  reopenedMesh.object != nil
            else
            {
                throw VerificationError.waveformRenderFailed("The waveform mesh did not receive geometry")
            }
            geometry.update()
            guard geometry.vertexCount == 24 * 192 * 2,
                  geometry.indexCount == 24 * 191 * 6
            else
            {
                throw VerificationError.waveformRenderFailed("The waveform ribbon topology is incomplete")
            }
            firstCommandBuffer.commit()

            let historyInput: NodePort<ContiguousArray<Float>> = reopenedGeometryNode.port(named: "inputHistory")
            var excitedHistory = historyInput.value ?? ContiguousArray<Float>(repeating: 0, count: 24 * 192)
            excitedHistory[23 * 192 + 96] = 1
            historyInput.value = excitedHistory
            guard let changedCommandBuffer = device.makeCommandQueue()?.makeCommandBuffer()
            else
            {
                throw VerificationError.noCommandBuffer
            }
            try renderer.execute(
                graph: reopened,
                executionInfo: renderer.currentExecutionInfo,
                renderPassDescriptor: MTLRenderPassDescriptor(),
                commandBuffer: changedCommandBuffer
            )
            geometry.update()
            guard geometry.bounds.max.y > 0.5 else
            {
                throw VerificationError.waveformRenderFailed("The geometry did not follow a changed audio sample")
            }
            changedCommandBuffer.commit()

            let outputSize = 512
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: outputSize,
                height: outputSize,
                mipmapped: false
            )
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            guard let outputTexture = device.makeTexture(descriptor: textureDescriptor),
                  let drawCommandBuffer = device.makeCommandQueue()?.makeCommandBuffer(),
                  let readbackBuffer = device.makeBuffer(
                    length: outputSize * outputSize * 4,
                    options: .storageModeShared
                  )
            else
            {
                throw VerificationError.waveformRenderFailed("The geometry render target was unavailable")
            }
            renderer.resize(
                size: (width: Float(outputSize), height: Float(outputSize)),
                scaleFactor: 1
            )
            let drawPass = MTLRenderPassDescriptor()
            drawPass.colorAttachments[0].texture = outputTexture
            drawPass.colorAttachments[0].loadAction = .clear
            drawPass.colorAttachments[0].storeAction = .store
            try renderer.executeAndDraw(
                graph: reopened,
                renderPassDescriptor: drawPass,
                commandBuffer: drawCommandBuffer
            )
            guard let blitEncoder = drawCommandBuffer.makeBlitCommandEncoder() else
            {
                throw VerificationError.waveformRenderFailed("The geometry image readback was unavailable")
            }
            blitEncoder.copy(
                from: outputTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: outputSize, height: outputSize, depth: 1),
                to: readbackBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: outputSize * 4,
                destinationBytesPerImage: outputSize * outputSize * 4
            )
            blitEncoder.endEncoding()
            drawCommandBuffer.commit()
            drawCommandBuffer.waitUntilCompleted()
            guard drawCommandBuffer.status == .completed else
            {
                throw VerificationError.waveformRenderFailed(
                    drawCommandBuffer.error?.localizedDescription ?? "The geometry draw did not finish"
                )
            }
            let pixelBytes = readbackBuffer.contents().bindMemory(
                to: UInt8.self,
                capacity: outputSize * outputSize * 4
            )
            let litPixels = (0 ..< outputSize * outputSize).reduce(into: 0) { count, pixelIndex in
                if pixelBytes[pixelIndex * 4 + 1] > 0 { count += 1 }
            }
            guard litPixels > 100 else
            {
                throw VerificationError.waveformRenderFailed("The geometry mesh drew no visible pixels")
            }
            try renderer.stopExecution(graph: reopened)
            print("Built 3D waveform ribbons with \(geometry.vertexCount) vertices, an audio-driven shape change, and \(litPixels) visible pixels")
        }
        print("Wrote \(fileName)")
    }
}

if CommandLine.arguments.contains("--write-playback-sample")
{
    let playbackGraph = Graph(context: context)
    let playerNode = playbackNodeClass.init(context: context)
    playerNode.offset = CGSize(width: -1100, height: 0)
    let analysisNode = fileNodeClass.init(context: context)
    analysisNode.offset = CGSize(width: -800, height: 0)
    let scaleOffsetNode = NumberBinaryOperator(context: context)
    scaleOffsetNode.inputNumber2.value = 0.35
    scaleOffsetNode.offset = CGSize(width: -500, height: 0)
    let scaleVectorNode = ComposeVectorNode(context: context, vectorType: .float3)
    scaleVectorNode.offset = CGSize(width: -200, height: 0)
    let boxNode = BoxGeometryNode(context: context)
    boxNode.offset = CGSize(width: -500, height: 450)
    let materialNode = BasicColorMaterialNode(context: context)
    materialNode.inputColor.value = simd_float4(0.22, 1, 0.35, 1)
    materialNode.offset = CGSize(width: -200, height: 450)
    let meshNode = MeshNode(context: context)
    meshNode.inputCastsShadow.value = false
    meshNode.inputDoubleSided.value = true
    meshNode.offset = CGSize(width: 150, height: 150)
    for node in [playerNode, analysisNode, scaleOffsetNode, scaleVectorNode, boxNode, materialNode, meshNode]
    {
        playbackGraph.addNode(node)
    }

    let timeOutput: NodePort<Float> = playerNode.port(named: "outputCurrentTime")
    let timeInput: ParameterPort<Float> = analysisNode.port(named: "inputTime")
    let fileURLOutput: NodePort<String> = playerNode.port(named: "outputFileURL")
    let fileURLInput: ParameterPort<String> = analysisNode.port(named: "inputFileURL")
    let envelopeOutput: NodePort<Float> = analysisNode.port(named: "outputMediumEnvelope")
    guard playbackGraph.connect(timeOutput, to: timeInput) != nil,
          playbackGraph.connect(fileURLOutput, to: fileURLInput) != nil,
          playbackGraph.connect(envelopeOutput, to: scaleOffsetNode.inputNumber1) != nil
    else
    {
        throw VerificationError.connectionFailed
    }
    for componentIndex in 0 ..< 3
    {
        let component: ParameterPort<Float> = scaleVectorNode.port(
            named: "inputComponent\(componentIndex)"
        )
        guard playbackGraph.connect(scaleOffsetNode.outputNumber, to: component) != nil else
        {
            throw VerificationError.connectionFailed
        }
    }
    let scaleVector: NodePort<simd_float3> = scaleVectorNode.port(named: "outputVector")
    guard playbackGraph.connect(scaleVector, to: meshNode.inputScale) != nil,
          playbackGraph.connect(boxNode.outputGeometry, to: meshNode.inputGeometry) != nil,
          playbackGraph.connect(materialNode.outputMaterial, to: meshNode.inputMaterial) != nil
    else
    {
        throw VerificationError.connectionFailed
    }

    let encoded = try JSONEncoder().encode(playbackGraph)
    let object = try JSONSerialization.jsonObject(with: encoded)
    let readable = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    let sceneDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appending(path: "FabricScenes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: sceneDirectory,
        withIntermediateDirectories: true
    )
    try readable.write(to: sceneDirectory.appending(path: "AudioWaveformPlayback.fabric"))
    let sceneDecoder = JSONDecoder()
    sceneDecoder.context = DecoderContext(documentContext: context)
    let reopened = try sceneDecoder.decode(Graph.self, from: readable)
    guard reopened.nodes.count == 7,
          reopened.connections.count == 9,
          reopened.nodes.contains(where: { type(of: $0).name == "Box Geometry" })
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    print("Wrote AudioWaveformPlayback.fabric with a 0.35 box scale offset")
}

if CommandLine.arguments.contains("--verify-playback")
{
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appending(path: "fabric-audio-playback-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let audioURL = temporaryDirectory.appending(path: "test-tone.caf")
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100),
          let sampleData = buffer.floatChannelData else
    {
        throw VerificationError.playbackFailed("Could not prepare test audio")
    }
    buffer.frameLength = 44_100
    for sampleIndex in 0 ..< Int(buffer.frameLength)
    {
        sampleData[0][sampleIndex] = sin(2 * Float.pi * 440 * Float(sampleIndex) / 44_100) * 0.1
    }
    do
    {
        let audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try audioFile.write(from: buffer)
    }

    let testGraph = Graph(context: context)
    let playerNode = playbackNodeClass.init(context: context)
    let analysisNode = fileNodeClass.init(context: context)
    let scaleOffsetNode = NumberBinaryOperator(context: context)
    scaleOffsetNode.inputNumber2.value = 0.35
    let scaleVectorNode = ComposeVectorNode(context: context, vectorType: .float3)
    let boxNode = BoxGeometryNode(context: context)
    let materialNode = BasicColorMaterialNode(context: context)
    let meshNode = MeshNode(context: context)
    for node in [playerNode, analysisNode, scaleOffsetNode, scaleVectorNode, boxNode, materialNode, meshNode]
    {
        testGraph.addNode(node)
    }
    let fileURLInput: ParameterPort<String> = playerNode.port(named: "inputFileURL")
    let volumeInput: ParameterPort<Float> = playerNode.port(named: "inputVolume")
    let playingInput: ParameterPort<Bool> = playerNode.port(named: "inputPlaying")
    let loopInput: ParameterPort<Bool> = playerNode.port(named: "inputLoop")
    let seekInput: ParameterPort<Float> = playerNode.port(named: "inputSeekTime")
    let currentTimeOutput: NodePort<Float> = playerNode.port(named: "outputCurrentTime")
    let durationOutput: NodePort<Float> = playerNode.port(named: "outputDuration")
    let readyOutput: NodePort<Bool> = playerNode.port(named: "outputReady")
    let timeInput: ParameterPort<Float> = analysisNode.port(named: "inputTime")
    let fileURLOutput: NodePort<String> = playerNode.port(named: "outputFileURL")
    let analysisFileURLInput: ParameterPort<String> = analysisNode.port(named: "inputFileURL")
    let analysisReadyOutput: NodePort<Bool> = analysisNode.port(named: "outputReady")
    let mediumEnvelopeOutput: NodePort<Float> = analysisNode.port(named: "outputMediumEnvelope")
    guard testGraph.connect(currentTimeOutput, to: timeInput) != nil,
          testGraph.connect(fileURLOutput, to: analysisFileURLInput) != nil,
          testGraph.connect(mediumEnvelopeOutput, to: scaleOffsetNode.inputNumber1) != nil else
    {
        throw VerificationError.connectionFailed
    }
    for componentIndex in 0 ..< 3
    {
        let component: ParameterPort<Float> = scaleVectorNode.port(named: "inputComponent\(componentIndex)")
        guard testGraph.connect(scaleOffsetNode.outputNumber, to: component) != nil else
        {
            throw VerificationError.connectionFailed
        }
    }
    let scaleVector: NodePort<simd_float3> = scaleVectorNode.port(named: "outputVector")
    guard testGraph.connect(scaleVector, to: meshNode.inputScale) != nil,
          testGraph.connect(boxNode.outputGeometry, to: meshNode.inputGeometry) != nil,
          testGraph.connect(materialNode.outputMaterial, to: meshNode.inputMaterial) != nil
    else
    {
        throw VerificationError.connectionFailed
    }
    fileURLInput.value = audioURL.absoluteString
    volumeInput.value = 0
    loopInput.value = false
    let testRenderer = GraphRenderer(context: context, graph: testGraph)
    try testRenderer.startExecution(graph: testGraph)

    func executePlaybackPass() throws
    {
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else
        {
            throw VerificationError.noCommandBuffer
        }
        try testRenderer.execute(
            graph: testGraph,
            executionInfo: testRenderer.currentExecutionInfo,
            renderPassDescriptor: MTLRenderPassDescriptor(),
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    var observedPlayback = false
    for _ in 0 ..< 30
    {
        try executePlaybackPass()
        if readyOutput.value == true,
           (durationOutput.value ?? 0) > 0.9,
           (currentTimeOutput.value ?? 0) > 0.05
        {
            observedPlayback = true
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard observedPlayback,
          abs((timeInput.value ?? 0) - (currentTimeOutput.value ?? 0)) < 0.01,
          analysisFileURLInput.value == audioURL.absoluteString
    else
    {
        throw VerificationError.playbackFailed(
            "Player time did not advance into Audio File Analysis: ready=\(readyOutput.value == true), duration=\(durationOutput.value ?? -1), playerTime=\(currentTimeOutput.value ?? -1), analysisTime=\(timeInput.value ?? -1)"
        )
    }

    var observedAnalysis = false
    for _ in 0 ..< 80
    {
        try executePlaybackPass()
        if analysisReadyOutput.value == true,
           (mediumEnvelopeOutput.value ?? 0) > 0,
           (meshNode.object?.scale.x ?? 0) > 0.35
        {
            observedAnalysis = true
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard observedAnalysis else
    {
        throw VerificationError.playbackFailed(
            "Audio File Analysis did not process the player's selected file"
        )
    }

    playingInput.value = false
    try executePlaybackPass()
    let pausedTime = currentTimeOutput.value ?? 0
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    try executePlaybackPass()
    guard abs((currentTimeOutput.value ?? 0) - pausedTime) < 0.04 else
    {
        throw VerificationError.playbackFailed("Pause did not hold the player clock")
    }

    seekInput.value = 0.5
    var observedSeek = false
    for _ in 0 ..< 20
    {
        try executePlaybackPass()
        if abs((currentTimeOutput.value ?? 0) - 0.5) < 0.06
        {
            observedSeek = true
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    guard observedSeek,
          abs((timeInput.value ?? 0) - 0.5) < 0.06 else
    {
        throw VerificationError.playbackFailed("Seek did not update the analysis time")
    }

    loopInput.value = true
    seekInput.value = 0.85
    playingInput.value = true
    var reachedEndOfLoop = false
    var observedLoop = false
    for _ in 0 ..< 35
    {
        try executePlaybackPass()
        let time = currentTimeOutput.value ?? 0
        if time > 0.8 { reachedEndOfLoop = true }
        if reachedEndOfLoop, time < 0.3
        {
            observedLoop = true
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard observedLoop else
    {
        throw VerificationError.playbackFailed("Loop did not restart the player clock")
    }
    try testRenderer.stopExecution(graph: testGraph)
    let isPlayingOutput: NodePort<Bool> = playerNode.port(named: "outputPlaying")
    guard isPlayingOutput.value == false,
          currentTimeOutput.value == 0 else
    {
        throw VerificationError.playbackFailed("Stopping the graph did not reset playback")
    }
    print("Verified audio playback, shared file analysis, pause, seek, loop, clock connection, and graph stop")
}
