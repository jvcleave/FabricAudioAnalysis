import CoreGraphics
import Fabric
import Foundation
import ImageIO
import Metal
import Satin
import UniformTypeIdentifiers
import simd

func sceneNodes(in graph: Graph) -> [Node]
{
    graph.nodes.flatMap { node in
        [node] + ((node as? SubgraphNode).map { sceneNodes(in: $0.subGraph) } ?? [])
    }
}

func sceneConnectionIDs(in graph: Graph) -> Set<UUID>
{
    graph.nodes.compactMap { $0 as? SubgraphNode }.reduce(into: Set(graph.connections.map(\.id)))
    {
        $0.formUnion(sceneConnectionIDs(in: $1.subGraph))
    }
}

func verifyAdvancedScene(_ graph: Graph, context: Context, previewURL: URL?) throws
{
    let nodes = sceneNodes(in: graph)
    guard let source = nodes.first(where: { type(of: $0).name == "Live Audio Analysis" }),
          let trail = nodes.first(where: { type(of: $0).name == "Waveform Trail" }),
          nodes.filter({ type(of: $0).name == "Live Audio Analysis" }).count == 1,
          graph.nodes.compactMap({ $0 as? SubgraphNode }).count == 6
    else { throw AdvancedSceneError.verificationFailed("Scene structure") }
    let outputs = source.ports.filter { $0.kind == .Outlet }
    guard outputs.count == 21, outputs.allSatisfy({ !$0.connectedInlets.isEmpty }) else
    {
        throw AdvancedSceneError.verificationFailed("Unconnected outputs: \(outputs.filter { $0.connectedInlets.isEmpty }.map(\.name))")
    }
    let enabled: ParameterPort<Bool> = source.port(named: "inputEnabled")
    enabled.value = false
    let device = context.device
    guard let queue = device.makeCommandQueue() else { throw AdvancedSceneError.verificationFailed("Command queue") }
    let width = 1280
    let height = 720
    let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    colorDescriptor.usage = [.renderTarget, .shaderRead]
    colorDescriptor.storageMode = .shared
    guard let color = device.makeTexture(descriptor: colorDescriptor) else { throw AdvancedSceneError.verificationFailed("Render target") }
    let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
    depthDescriptor.usage = .renderTarget
    depthDescriptor.storageMode = .private
    guard let depth = device.makeTexture(descriptor: depthDescriptor) else { throw AdvancedSceneError.verificationFailed("Depth target") }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = color
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    let renderer = GraphRenderer(context: context, graph: graph)
    renderer.resize(size: (Float(width), Float(height)), scaleFactor: 1)
    try renderer.startExecution()
    defer { renderer.teardown() }
    var previousTime: TimeInterval = 0
    var frameNumber = 0
    func draw(at time: TimeInterval) throws
    {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw AdvancedSceneError.verificationFailed("Command buffer") }
        try renderer.executeAndDraw(executionInfo: GraphExecutionInfo(timing: GraphExecutionTiming(
            time: time, deltaTime: time - previousTime, displayTime: time, systemTime: time,
            hostMediaTime: time, frameNumber: frameNumber
        )), renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw AdvancedSceneError.verificationFailed(commandBuffer.error?.localizedDescription ?? "GPU execution") }
        previousTime = time
        frameNumber += 1
    }
    try draw(at: 0)
    func sendFloat(_ key: String, _ value: Float)
    {
        let output: NodePort<Float> = source.port(named: key)
        output.send(value, force: true)
    }
    let values: [(String, Float)] = [
        ("outputRMS", 0.125), ("outputRMSNormalized", 0.64),
        ("outputLoudnessDB", -18.1), ("outputLoudnessNormalized", 0.7),
        ("outputSubBass", 0.8), ("outputBass", 0.64), ("outputLowMid", 0.43),
        ("outputMid", 0.71), ("outputHigh", 0.3), ("outputSpectralFlux", 0.6),
        ("outputSpectralCentroid", 3500), ("outputPeakRMS", 0.9), ("outputPeakFlux", 0.83),
        ("outputFastEnvelope", 0.8), ("outputMediumEnvelope", 0.55), ("outputSlowEnvelope", 0.4),
        ("outputSampleRate", 48000),
    ]
    for value in values { sendFloat(value.0, value.1) }
    let running: NodePort<Bool> = source.port(named: "outputRunning")
    running.send(true, force: true)
    let dropped: NodePort<Int> = source.port(named: "outputDroppedSamples")
    dropped.send(128, force: true)
    let waveform: NodePort<ContiguousArray<Float>> = source.port(named: "outputWaveformHistory")
    let samples = (0 ..< 24 * 192).map { index -> Float in
        let row = Float(index / 192)
        let phase = Float(index % 192) / 191 * Float.pi * 12
        return (sin(phase + row * 0.14) * 0.55 + sin(phase * 2.3 - row * 0.12) * 0.18) * (0.7 + sin(phase * 0.31) * 0.3)
    }
    waveform.send(ContiguousArray(samples), force: true)
    let onset: NodePort<Bool> = source.port(named: "outputOnset")
    for frame in 1 ... 80
    {
        onset.send(frame % 20 == 0, force: true)
        try draw(at: Double(frame) * 0.05)
    }
    func mesh(named name: String) throws -> MeshNode
    {
        guard let mesh = nodes.first(where: { $0.userName == name }) as? MeshNode else
        {
            throw AdvancedSceneError.verificationFailed(name)
        }
        return mesh
    }
    if let previewURL { try writePreview(color, to: previewURL) }
    guard let bassScale = try mesh(named: "Bass Bar").object?.scale,
          abs(bassScale.y - (0.03 + 0.64 * 1.27)) < 0.0001,
          let centerScale = try mesh(named: "RMS Center").object?.scale,
          abs(centerScale.x - (0.65 + 0.64 * 0.7)) < 0.0001,
          let peakPosition = try mesh(named: "RMS Peak Marker").object?.position,
          abs(peakPosition.y - (-2.05 + 0.9 * 1.3)) < 0.0001,
          let centerColor = nodes.first(where: { $0.userName == "Onset Center Color" }) as? BasicColorMaterialNode,
          simd_distance(centerColor.material.color, simd_float4(1, 0.055, 0.025, 1)) < 0.004,
          let readout = nodes.first(where: { $0.userName == "Capture Readout" }) as? StringFormatterNode,
          readout.outputString.value == "RUNNING true    48000 Hz    DROPPED 128"
    else { throw AdvancedSceneError.verificationFailed("Synthetic visual response") }
    let imageOutput: NodePort<FabricImage> = trail.port(named: "outputImage")
    guard let image = imageOutput.value, image.texture.width == 1280, image.texture.height == 320 else
    {
        throw AdvancedSceneError.verificationFailed("Waveform image")
    }
    let hitPixel = try waveformPixel(image.texture, queue: queue)
    guard hitPixel.x > 0.65, hitPixel.x > hitPixel.y * 3 else
    {
        throw AdvancedSceneError.verificationFailed("Red waveform playhead")
    }
    onset.send(false, force: true)
    try draw(at: 4.25)
    guard simd_distance(centerColor.material.color, .one) < 0.0001 else
    {
        throw AdvancedSceneError.verificationFailed("Onset flash release")
    }
    guard let releasedImage = imageOutput.value else { throw AdvancedSceneError.verificationFailed("Released waveform image") }
    let releasedPixel = try waveformPixel(releasedImage.texture, queue: queue)
    guard releasedPixel.z > releasedPixel.x, releasedPixel.y > 0.4 else
    {
        throw AdvancedSceneError.verificationFailed("Waveform playhead flash release")
    }
    print("Verified all 21 outputs are connected, nested graphs reopen, meters and peak markers respond, onset flashes release, and the waveform shader renders")
}

private func waveformPixel(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> simd_float4
{
    guard let buffer = queue.device.makeBuffer(length: 256, options: .storageModeShared),
          let commandBuffer = queue.makeCommandBuffer(),
          let encoder = commandBuffer.makeBlitCommandEncoder()
    else { throw AdvancedSceneError.verificationFailed("Waveform pixel readback") }
    encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: texture.width / 2, y: 40, z: 0),
                 sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                 destinationBytesPerRow: 256, destinationBytesPerImage: 256)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else { throw AdvancedSceneError.verificationFailed("Waveform readback GPU execution") }
    let channels = buffer.contents().bindMemory(to: UInt16.self, capacity: 4)
    return simd_float4(Float(Float16(bitPattern: channels[0])), Float(Float16(bitPattern: channels[1])),
                       Float(Float16(bitPattern: channels[2])), Float(Float16(bitPattern: channels[3])))
}

private func writePreview(_ texture: MTLTexture, to url: URL) throws
{
    let bytesPerRow = texture.width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
    texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw AdvancedSceneError.verificationFailed("Preview image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw AdvancedSceneError.verificationFailed("Preview write") }
}
