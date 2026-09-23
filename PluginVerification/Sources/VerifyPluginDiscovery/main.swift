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
      let liveNodeClass = discoveredNodes["LiveAudioAnalysisNode"],
      let waveformNodeClass = discoveredNodes["Audio3DWaveformNode"],
      let waveformGeometryClass = discoveredNodes["AudioWaveformGeometryNode"]
else
{
    throw VerificationError.graphRoundTripFailed
}

let graph = Graph(context: context)
let fileNode = fileNodeClass.init(context: context)
let liveNode = liveNodeClass.init(context: context)
let waveformNode = waveformNodeClass.init(context: context)
let waveformGeometryNode = waveformGeometryClass.init(context: context)
let numericNode = NumberBinaryOperator(context: context)
graph.addNode(fileNode)
graph.addNode(liveNode)
graph.addNode(waveformNode)
graph.addNode(waveformGeometryNode)
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
guard reopenedGraph.nodes.count == 5,
      reopenedGraph.connections.count == 3,
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio File Analysis" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Live Audio Analysis" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio 3D Waveform" }),
      reopenedGraph.nodes.contains(where: { type(of: $0).name == "Audio Waveform Geometry" })
else
{
    throw VerificationError.graphRoundTripFailed
}
print("Saved and reopened all four plugin nodes with typed connections")

let existingSceneDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
).appending(path: "FabricScenes", directoryHint: .isDirectory)
for (fileName, expectedNodeCount, expectedConnectionCount) in [
    ("AudioFileAnalysis.fabric", 6, 7),
    ("LiveAudioAnalysis.fabric", 6, 8),
    ("Audio3DWaveformFile.fabric", 3, 2),
    ("Audio3DWaveformLive.fabric", 3, 2),
]
{
    let sceneData = try Data(contentsOf: existingSceneDirectory.appending(path: fileName))
    let sceneDecoder = JSONDecoder()
    sceneDecoder.context = DecoderContext(documentContext: context)
    let existingScene = try sceneDecoder.decode(Graph.self, from: sceneData)
    guard existingScene.nodes.count == expectedNodeCount,
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
