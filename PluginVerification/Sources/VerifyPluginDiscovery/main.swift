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
    case boxColorFailed(String)
    case captureOutputFailed
}

let restingBoxColor = simd_float4(1, 1, 1, 1)
let onsetBoxColor = simd_float4(1, 0, 0, 1)
let onsetFlashDuration: Float = 0.2

func verifyCaptureOutputs(in graph: Graph, sourceNode: Node, context: Context, device: MTLDevice) throws
{
    let microphoneEnabled: ParameterPort<Bool> = sourceNode.port(named: "inputEnabled")
    microphoneEnabled.value = false
    let waveform: NodePort<ContiguousArray<Float>> = sourceNode.port(named: "outputWaveformHistory")
    let droppedSamples: NodePort<Int> = sourceNode.port(named: "outputDroppedSamples")
    guard let commandQueue = device.makeCommandQueue(), waveform.value == nil else
    {
        throw VerificationError.captureOutputFailed
    }
    let renderer = GraphRenderer(context: context, graph: graph)
    try renderer.startExecution()
    defer { renderer.teardown() }

    func executeGraphPass(for node: Node) throws
    {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else
        {
            throw VerificationError.noCommandBuffer
        }
        try renderer.execute(
            graph: graph,
            executionInfo: renderer.currentExecutionInfo,
            renderPassDescriptor: MTLRenderPassDescriptor(),
            commandBuffer: commandBuffer,
            forceEvaluationForTheseNodes: [node]
        )
    }

    try executeGraphPass(for: sourceNode)
    guard waveform.value == nil, droppedSamples.value == 0 else
    {
        throw VerificationError.captureOutputFailed
    }

    waveform.published = true
    graph.rebuildPublishedParameterGroup()
    try executeGraphPass(for: sourceNode)
    guard waveform.value?.count == 24 * 192,
          waveform.value?.allSatisfy({ $0 == 0 }) == true
    else
    {
        throw VerificationError.captureOutputFailed
    }

    waveform.published = false
    graph.rebuildPublishedParameterGroup()
    try executeGraphPass(for: sourceNode)
    let waveformSink = SampleAndHoldNode(context: context, portType: .Array(portType: .Float))
    graph.addNode(waveformSink)
    let waveformInput: NodePort<ContiguousArray<Float>> = waveformSink.port(named: "inputValue")
    guard graph.connect(waveform, to: waveformInput) != nil else
    {
        throw VerificationError.connectionFailed
    }
    try executeGraphPass(for: waveformSink)
    guard waveformInput.value == waveform.value, waveformInput.value?.count == 24 * 192 else
    {
        throw VerificationError.captureOutputFailed
    }
    print("Verified unused waveform output stays empty, while published and connected outputs receive history")
    print("Verified Dropped Samples initializes to zero without microphone capture")
}

func verifyBoxResponse(in graph: Graph, context: Context, device: MTLDevice) throws
{
    guard let sourceNode = graph.nodes.first(where: { type(of: $0).name == "Live Audio Analysis" }),
          let meshNode = graph.nodes.compactMap({ $0 as? MeshNode }).first,
          let materialNode = graph.nodes.compactMap({ $0 as? BasicColorMaterialNode }).first,
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
    var previousTime: TimeInterval = 0
    var frameNumber = 0

    func executeGraphPass(at time: TimeInterval) throws
    {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else
        {
            throw VerificationError.noCommandBuffer
        }
        try renderer.execute(
            graph: graph,
            executionInfo: GraphExecutionInfo(timing: GraphExecutionTiming(
                time: time,
                deltaTime: time - previousTime,
                displayTime: time,
                systemTime: time,
                hostMediaTime: time,
                frameNumber: frameNumber
            )),
            renderPassDescriptor: MTLRenderPassDescriptor(),
            commandBuffer: commandBuffer
        )
        previousTime = time
        frameNumber += 1
    }

    try executeGraphPass(at: 0)
    guard meshNode.object?.scale == simd_float3(repeating: 0.35),
          meshNode.object?.visible == true
    else
    {
        throw VerificationError.boxScaleFailed
    }
    guard simd_distance(materialNode.material.color, restingBoxColor) < 0.00001 else
    {
        throw VerificationError.boxColorFailed("resting: actual color=\(materialNode.material.color), input color=\(String(describing: materialNode.inputColor.value))")
    }

    let envelope: NodePort<Float> = sourceNode.port(named: "outputMediumEnvelope")
    envelope.send(0.65, force: true)
    try executeGraphPass(at: 0.01)
    guard meshNode.object?.scale == simd_float3(repeating: 1),
          meshNode.object?.visible == true
    else
    {
        throw VerificationError.boxScaleFailed
    }
    print("Verified the box stays visible and scales uniformly from 0.35 to 1.0")

    let onset: NodePort<Bool> = sourceNode.port(named: "outputOnset")
    onset.send(true, force: true)
    try executeGraphPass(at: 0.02)
    guard simd_distance(materialNode.material.color, onsetBoxColor) < 0.00001 else
    {
        throw VerificationError.boxColorFailed("onset: actual color=\(materialNode.material.color), input color=\(String(describing: materialNode.inputColor.value))")
    }
    onset.send(false, force: true)
    try executeGraphPass(at: 0.12)
    guard simd_distance(materialNode.material.color, onsetBoxColor) < 0.00001 else
    {
        throw VerificationError.boxColorFailed("held onset: actual color=\(materialNode.material.color), input color=\(String(describing: materialNode.inputColor.value))")
    }
    try executeGraphPass(at: 0.23)
    guard simd_distance(materialNode.material.color, restingBoxColor) < 0.00001,
          meshNode.object?.scale == simd_float3(repeating: 1),
          meshNode.object?.visible == true
    else
    {
        throw VerificationError.boxColorFailed("released onset: actual color=\(materialNode.material.color), input color=\(String(describing: materialNode.inputColor.value))")
    }
    print("Verified an onset flashes the box red for 0.2 seconds before returning to white")

    if CommandLine.arguments.contains("--measure-box")
    {
        let clock = ContinuousClock()
        var executionMilliseconds: [Double] = []
        executionMilliseconds.reserveCapacity(1000)
        for frameIndex in 0 ..< 1200
        {
            envelope.send(Float(frameIndex % 101) / 100, force: true)
            onset.send(frameIndex % 30 == 0, force: true)
            let start = clock.now
            try executeGraphPass(at: 0.3 + Double(frameIndex) / 60)
            if frameIndex >= 200
            {
                let duration = start.duration(to: clock.now).components
                executionMilliseconds.append(
                    Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                )
            }
        }
        executionMilliseconds.sort()
        let median = executionMilliseconds[executionMilliseconds.count / 2]
        let percentile95 = executionMilliseconds[executionMilliseconds.count * 95 / 100]
        let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))
        print("Synthetic box graph CPU pass: median \(median.formatted(precision)) ms, p95 \(percentile95.formatted(precision)) ms across 1000 passes")
        print("Timing excludes microphone capture, FFT, drawing, and GPU completion")
    }
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
guard pluginNodes.count == 2,
      registry.nodeClass(pluginID: pluginID, nodeID: "WaveformTrailNode") != nil else
{
    throw VerificationError.unexpectedNode(pluginNodes.map(\.nodeName).joined(separator: ", "))
}
print("Discovered Live Audio Analysis and Waveform Trail")

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
try verifyCaptureOutputs(in: graph, sourceNode: liveNode, context: context, device: device)

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
    guard existingScene.nodes.count == 8,
          existingScene.connections.count == 10,
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
    try verifyBoxResponse(in: reopenedScene, context: context, device: device)
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
    let onsetFlashNode = NumberTriggerNode(context: context)
    onsetFlashNode.userName = "Onset Flash"
    onsetFlashNode.inputMinDurationSecs.value = onsetFlashDuration
    onsetFlashNode.offset = CGSize(width: -500, height: 800)
    let onsetColorNode = EasingNode(context: context, portType: .Color)
    onsetColorNode.userName = "Onset Color"
    let restingColor: ParameterPort<simd_float4> = onsetColorNode.port(named: "inputFrom")
    let flashColor: ParameterPort<simd_float4> = onsetColorNode.port(named: "inputTo")
    restingColor.value = restingBoxColor
    flashColor.value = onsetBoxColor
    onsetColorNode.offset = CGSize(width: -200, height: 800)
    let meshNode = MeshNode(context: context)
    meshNode.offset = CGSize(width: 150, height: 150)
    sampleGraph.addNode(sourceNode)
    sampleGraph.addNode(scaleOffsetNode)
    sampleGraph.addNode(scaleVectorNode)
    sampleGraph.addNode(boxNode)
    sampleGraph.addNode(materialNode)
    sampleGraph.addNode(meshNode)
    sampleGraph.addNode(onsetFlashNode)
    sampleGraph.addNode(onsetColorNode)

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
    let onset: NodePort<Bool> = sourceNode.port(named: "outputOnset")
    let outputColor: NodePort<simd_float4> = onsetColorNode.port(named: "outputValue")
    guard sampleGraph.connect(scaleVector, to: meshNode.inputScale) != nil,
          sampleGraph.connect(boxNode.outputGeometry, to: meshNode.inputGeometry) != nil,
          sampleGraph.connect(materialNode.outputMaterial, to: meshNode.inputMaterial) != nil,
          sampleGraph.connect(onset, to: onsetFlashNode.inputTarget) != nil,
          sampleGraph.connect(onsetFlashNode.outputValue, to: onsetColorNode.inputProgress) != nil,
          sampleGraph.connect(outputColor, to: materialNode.inputColor) != nil
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
    guard reopenedSample.nodes.count == 8,
          reopenedSample.connections.count == 10,
          reopenedSample.nodes.contains(where: { type(of: $0).name == "Mesh" }),
          reopenedSample.nodes.contains(where: { type(of: $0).name == "Box Geometry" }),
          reopenedSample.nodes.contains(where: { type(of: $0).name == liveNodeClass.name })
    else
    {
        throw VerificationError.graphRoundTripFailed
    }
    try verifyBoxResponse(in: reopenedSample, context: context, device: device)
    print("Wrote \(fileName)")
}

let advancedSceneURL = existingSceneDirectory.appending(path: "LiveAudioAnalysisAdvanced.fabric")
if CommandLine.arguments.contains("--write-advanced")
{
    let advancedScene = try AdvancedSceneBuilder(context: context, registry: registry, sourceClass: liveNodeClass).build()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(advancedScene).write(to: advancedSceneURL)
    print("Wrote LiveAudioAnalysisAdvanced.fabric")
}
if FileManager.default.fileExists(atPath: advancedSceneURL.path)
{
    let decoder = JSONDecoder()
    decoder.context = DecoderContext(documentContext: context)
    let advancedScene = try decoder.decode(Graph.self, from: Data(contentsOf: advancedSceneURL))
    let reopenedScene = try decoder.decode(Graph.self, from: JSONEncoder().encode(advancedScene))
    guard Set(sceneNodes(in: advancedScene).map(\.id)) == Set(sceneNodes(in: reopenedScene).map(\.id)),
          sceneConnectionIDs(in: advancedScene) == sceneConnectionIDs(in: reopenedScene) else
    {
        throw VerificationError.graphRoundTripFailed
    }
    let previewURL = CommandLine.arguments.contains("--write-advanced") || CommandLine.arguments.contains("--preview-advanced")
        ? existingSceneDirectory.appending(path: "LiveAudioAnalysisAdvanced-preview.png") : nil
    try verifyAdvancedScene(reopenedScene, context: context, previewURL: previewURL)
}
