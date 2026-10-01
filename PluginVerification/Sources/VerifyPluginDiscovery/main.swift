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
}

let pluginID = "com.jvclabs.FabricAudioSourceProcessor"
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
for (fileName, minimumNodeCount, minimumConnectionCount) in [
    ("LiveAudioAnalysis.fabric", 6, 7),
    ("AudioDepthBlocksLive.fabric", 19, 19),
]
{
    if fileName == "LiveAudioAnalysis.fabric"
        && CommandLine.arguments.contains("--write-samples")
    {
        continue
    }
    if fileName == "AudioDepthBlocksLive.fabric"
        && CommandLine.arguments.contains("--write-depth-blocks-sample")
    {
        continue
    }
    let sceneData = try Data(contentsOf: existingSceneDirectory.appending(path: fileName))
    let sceneDecoder = JSONDecoder()
    sceneDecoder.context = DecoderContext(documentContext: context)
    let existingScene = try sceneDecoder.decode(Graph.self, from: sceneData)
    guard existingScene.nodes.count >= minimumNodeCount,
          existingScene.connections.count >= minimumConnectionCount,
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
    print("Wrote \(fileName)")
}

if CommandLine.arguments.contains("--write-depth-blocks-sample")
{
    let columnCount = 12
    let rowCount = 24
    let blockCount = columnCount * rowCount
    let scene = Graph(context: context)

    let liveAnalysis = liveNodeClass.init(context: context)
    liveAnalysis.offset = CGSize(width: -1400, height: -250)

    let waveformResample = ArrayResampleTypeAgnosticNode(
        context: context, portType: .Array(portType: .Float)
    )
    waveformResample.inputCount.value = blockCount
    waveformResample.offset = CGSize(width: -1100, height: -250)

    let zeroArray = RepeatNode(context: context, portType: .Float)
    let zeroValue: ParameterPort<Float> = zeroArray.port(named: "inputValue")
    zeroValue.value = 0
    zeroArray.inputCount.value = blockCount
    zeroArray.offset = CGSize(width: -1100, height: 50)

    let waveformMagnitude = PairwiseDistanceArrayNode(
        context: context, portType: .Array(portType: .Float)
    )
    waveformMagnitude.offset = CGSize(width: -800, height: -250)

    let depthFloor = RepeatNode(context: context, portType: .Float)
    let depthFloorValue: ParameterPort<Float> = depthFloor.port(named: "inputValue")
    depthFloorValue.value = 0.15
    depthFloor.inputCount.value = blockCount
    depthFloor.offset = CGSize(width: -800, height: 50)

    let blendDepth = EasingNode(context: context, portType: .Array(portType: .Float))
    blendDepth.inputProgress.value = 0.7
    blendDepth.offset = CGSize(width: -500, height: -250)

    let blockWidth = RepeatNode(context: context, portType: .Float)
    let blockWidthValue: ParameterPort<Float> = blockWidth.port(named: "inputValue")
    blockWidthValue.value = 0.82
    blockWidth.inputCount.value = blockCount
    blockWidth.offset = CGSize(width: -500, height: 50)

    let blockScales = ComposeVectorArrayNode(context: context, vectorType: .float3)
    blockScales.offset = CGSize(width: -200, height: -200)

    let envelopeGain = NumberRemapNode(context: context)
    envelopeGain.inputNewMinNumber.value = 1
    envelopeGain.inputNewMaxNumber.value = 18
    envelopeGain.inputClamp.value = true
    envelopeGain.offset = CGSize(width: -1100, height: -600)

    let overallScale = ComposeVectorNode(context: context, vectorType: .float3)
    let overallScaleX: ParameterPort<Float> = overallScale.port(named: "inputComponent0")
    let overallScaleY: ParameterPort<Float> = overallScale.port(named: "inputComponent1")
    overallScaleX.value = 1
    overallScaleY.value = 1
    overallScale.offset = CGSize(width: -800, height: -600)

    let onsetFlash = NumberTriggerNode(context: context)
    onsetFlash.inputMinDurationSecs.value = 0.2
    onsetFlash.offset = CGSize(width: -1100, height: -900)

    let onsetColor = EasingNode(context: context, portType: .Vector4)
    let restingColor: ParameterPort<simd_float4> = onsetColor.port(named: "inputFrom")
    let flashColor: ParameterPort<simd_float4> = onsetColor.port(named: "inputTo")
    restingColor.value = simd_float4(0.25, 0.9, 1.0, 1.0)
    flashColor.value = simd_float4(1.0, 0.35, 0.08, 1.0)
    onsetColor.offset = CGSize(width: -800, height: -900)

    let grid = GridPointsNode(context: context)
    grid.inputColumns.value = columnCount
    grid.inputRows.value = rowCount
    grid.inputColumnSpacing.value = 0.23
    grid.inputRowSpacing.value = 0.12
    grid.offset = CGSize(width: -500, height: 450)

    let transforms = ComposeTransformArrayNode(context: context, strategy: TransformCompositionMode.trs)
    transforms.offset = CGSize(width: 100, height: 50)

    let box = BoxGeometryNode(context: context)
    box.inputWidthParam.value = 0.23
    box.inputHeightParam.value = 0.12
    box.inputDepthParam.value = 2.0
    box.offset = CGSize(width: 100, height: 450)

    let material = BasicDiffuseMaterialNode(context: context)
    material.inputColor.value = simd_float4(0.25, 0.9, 1.0, 1.0)
    material.offset = CGSize(width: 400, height: 450)

    let blocks = InstancedMeshNode(context: context)
    blocks.inputCastsShadow.value = false
    blocks.inputDoubleSided.value = true
    blocks.inputOrientation.value = simd_quatf(
        angle: -0.35, axis: simd_float3(1, 0, 0)
    ).vector
    blocks.offset = CGSize(width: 700, height: 50)

    let camera = PerspectiveCameraNode(context: context)
    camera.inputPosition.value = simd_float3(0, 0, 7.5)
    camera.offset = CGSize(width: 400, height: 750)

    let light = DirectionalLightNode(context: context)
    light.inputPosition.value = simd_float3(-2, 3, 5)
    light.offset = CGSize(width: 700, height: 750)

    for node in [
        liveAnalysis, waveformResample, zeroArray, waveformMagnitude,
        depthFloor, blendDepth, blockWidth, blockScales, envelopeGain,
        overallScale, onsetFlash, onsetColor, grid, transforms,
        box, material, blocks, camera, light,
    ]
    {
        scene.addNode(node)
    }

    let waveformHistory: NodePort<ContiguousArray<Float>> = liveAnalysis.port(named: "outputWaveformHistory")
    let mediumEnvelope: NodePort<Float> = liveAnalysis.port(named: "outputMediumEnvelope")
    let onset: NodePort<Bool> = liveAnalysis.port(named: "outputOnset")
    let resampleInput: NodePort<ContiguousArray<Float>> = waveformResample.port(named: "inputArray")
    let resampledWaveform: NodePort<ContiguousArray<Float>> = waveformResample.port(named: "outputArray")
    let zeroValues: NodePort<ContiguousArray<Float>> = zeroArray.port(named: "outputArray")
    let magnitudeInputA: NodePort<ContiguousArray<Float>> = waveformMagnitude.port(named: "inputA")
    let magnitudeInputB: NodePort<ContiguousArray<Float>> = waveformMagnitude.port(named: "inputB")
    let magnitudes = waveformMagnitude.outputDistances
    let floorValues: NodePort<ContiguousArray<Float>> = depthFloor.port(named: "outputArray")
    let blendFrom: NodePort<ContiguousArray<Float>> = blendDepth.port(named: "inputFrom")
    let blendTo: NodePort<ContiguousArray<Float>> = blendDepth.port(named: "inputTo")
    let blendedDepth: NodePort<ContiguousArray<Float>> = blendDepth.port(named: "outputValue")
    let widths: NodePort<ContiguousArray<Float>> = blockWidth.port(named: "outputArray")
    let scaleX: NodePort<ContiguousArray<Float>> = blockScales.port(named: "inputComponent0")
    let scaleY: NodePort<ContiguousArray<Float>> = blockScales.port(named: "inputComponent1")
    let scaleZ: NodePort<ContiguousArray<Float>> = blockScales.port(named: "inputComponent2")
    let scaleVectors: NodePort<ContiguousArray<simd_float3>> = blockScales.port(named: "outputArray")
    let transformPositions: NodePort<ContiguousArray<simd_float3>> = transforms.port(named: "inputPositions")
    let transformScales: NodePort<ContiguousArray<simd_float3>> = transforms.port(named: "inputScales")
    let transformOutput: NodePort<ContiguousArray<simd_float4x4>> = transforms.port(named: "outputTransforms")
    let overallScaleZ: ParameterPort<Float> = overallScale.port(named: "inputComponent2")
    let overallScaleVector: NodePort<simd_float3> = overallScale.port(named: "outputVector")
    let outputColor: NodePort<simd_float4> = onsetColor.port(named: "outputValue")

    let connected = [
        scene.connect(waveformHistory, to: resampleInput),
        scene.connect(resampledWaveform, to: magnitudeInputA),
        scene.connect(zeroValues, to: magnitudeInputB),
        scene.connect(magnitudes, to: blendTo),
        scene.connect(floorValues, to: blendFrom),
        scene.connect(widths, to: scaleX),
        scene.connect(widths, to: scaleY),
        scene.connect(blendedDepth, to: scaleZ),
        scene.connect(grid.outputPositions, to: transformPositions),
        scene.connect(scaleVectors, to: transformScales),
        scene.connect(transformOutput, to: blocks.inputTransforms),
        scene.connect(box.outputGeometry, to: blocks.inputGeometry),
        scene.connect(material.outputMaterial, to: blocks.inputMaterial),
        scene.connect(mediumEnvelope, to: envelopeGain.inputNumber),
        scene.connect(envelopeGain.outputNumber, to: overallScaleZ),
        scene.connect(overallScaleVector, to: blocks.inputScale),
        scene.connect(onset, to: onsetFlash.inputTarget),
        scene.connect(onsetFlash.outputValue, to: onsetColor.inputProgress),
        scene.connect(outputColor, to: material.inputColor),
    ]
    guard connected.allSatisfy({ $0 != nil }) else
    {
        throw VerificationError.connectionFailed
    }

    let encoded = try JSONEncoder().encode(scene)
    let object = try JSONSerialization.jsonObject(with: encoded)
    let readable = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    let sceneURL = existingSceneDirectory.appending(path: "AudioDepthBlocksLive.fabric")
    try readable.write(to: sceneURL)

    let sceneDecoder = JSONDecoder()
    sceneDecoder.context = DecoderContext(documentContext: context)
    let reopened = try sceneDecoder.decode(Graph.self, from: readable)
    guard reopened.nodes.count == 19,
          reopened.connections.count == 19,
          let reopenedBlocks = reopened.nodes.compactMap({ $0 as? InstancedMeshNode }).first,
          let reopenedMaterial = reopened.nodes.compactMap({ $0 as? BasicDiffuseMaterialNode }).first,
          let reopenedLive = reopened.nodes.first(where: { type(of: $0).name == "Live Audio Analysis" })
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    let microphoneEnabled: ParameterPort<Bool> = reopenedLive.port(named: "inputEnabled")
    microphoneEnabled.value = false
    guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else
    {
        throw VerificationError.noCommandBuffer
    }
    let renderer = GraphRenderer(context: context, graph: reopened)
    try renderer.startExecution()
    try renderer.execute(
        graph: reopened,
        executionInfo: renderer.currentExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor(),
        commandBuffer: commandBuffer
    )
    guard reopenedBlocks.inputTransforms.value?.count == blockCount,
          reopenedBlocks.object != nil
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    let silenceDepth = reopenedBlocks.inputTransforms.value?[0].columns.2.z ?? 0
    let reopenedWaveform: NodePort<ContiguousArray<Float>> = reopenedLive.port(named: "outputWaveformHistory")
    let reopenedEnvelope: NodePort<Float> = reopenedLive.port(named: "outputMediumEnvelope")
    let reopenedOnset: NodePort<Bool> = reopenedLive.port(named: "outputOnset")
    reopenedWaveform.send(
        ContiguousArray(repeating: 0.03, count: 12 * 192)
            + ContiguousArray(repeating: 0.09, count: 12 * 192),
        force: true
    )
    reopenedEnvelope.send(0.5, force: true)
    reopenedOnset.send(true, force: true)
    guard let motionCommandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else
    {
        throw VerificationError.noCommandBuffer
    }
    try renderer.execute(
        graph: reopened,
        executionInfo: renderer.currentExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor(),
        commandBuffer: motionCommandBuffer
    )
    let activeDepths = reopenedBlocks.inputTransforms.value?.map { $0.columns.2.z } ?? []
    let overallGain = reopenedBlocks.object?.scale.z ?? 0
    let restingDepthInWorld = silenceDepth * 2
    let flashedColor = reopenedMaterial.inputColor.value
    guard let minimumActiveDepth = activeDepths.min(),
          let maximumActiveDepth = activeDepths.max(),
          minimumActiveDepth * 2 * overallGain > restingDepthInWorld + 0.3,
          (maximumActiveDepth - minimumActiveDepth) * 2 * overallGain > 0.3,
          overallGain > 9,
          let flashedColor,
          flashedColor.x > 0.95,
          flashedColor.y > 0.3 && flashedColor.y < 0.4,
          flashedColor.z < 0.12
    else
    {
        throw NSError(
            domain: "DepthBlocksMotion",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "silence=\(silenceDepth), minimum=\(activeDepths.min() ?? -1), maximum=\(activeDepths.max() ?? -1), gain=\(overallGain), color=\(String(describing: reopenedMaterial.inputColor.value)), onset=\(String(describing: reopenedOnset.value))"
            ]
        )
    }
    try renderer.stopExecution()
    print("Wrote AudioDepthBlocksLive.fabric with \(blockCount) waveform-driven blocks")
}
