import AudioSourceProcessorCore
import Fabric
import Foundation
import Metal
import Satin
import simd

private struct AudioWaveformUniforms
{
    var viewport: SIMD4<Float>
    var grid: SIMD4<Float>
    var waveform: SIMD4<Float>
    var angles: SIMD4<Float>
    var color: SIMD4<Float>
}

private struct Audio3DWaveformError: LocalizedError
{
    let message: String
    var errorDescription: String? { message }
}

/// Renders the bounded waveform history from either audio analysis node to an
/// image. MESS's projected ribbon shader is adapted to Fabric's command buffer.
public final class Audio3DWaveformNode: Node
{
    public override class var name: String { "Audio 3D Waveform" }
    public override class var nodeType: Node.NodeType { .Image(imageType: .Generator) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Processor }
    public override class var nodeTimeMode: Node.TimeMode { .Idle }
    public override class var nodeDescription: String
    {
        "Draws a layered perspective waveform from signed audio history rows."
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) +
        [
            ("inputHistory", NodePort<ContiguousArray<Float>>(name: "Waveform History", kind: .Inlet, description: "24 oldest-to-newest rows of 192 signed samples from an audio analysis node")),
            ("inputWidth", ParameterPort(parameter: IntParameter("Width", 1280, 64, 4096, .inputfield, "Output image width in pixels"))),
            ("inputHeight", ParameterPort(parameter: IntParameter("Height", 720, 64, 4096, .inputfield, "Output image height in pixels"))),
            ("inputHistoryRows", ParameterPort(parameter: IntParameter("History", 24, 1, 24, .inputfield, "Number of waveform rows to draw"))),
            ("inputAmplitude", ParameterPort(parameter: FloatParameter("Amplitude", 0.6, 0, 4, .slider, "Vertical waveform displacement"))),
            ("inputLineThickness", ParameterPort(parameter: FloatParameter("Line Thickness", 1.5, 0.25, 10, .slider, "Waveform line radius in pixels"))),
            ("inputSpacing", ParameterPort(parameter: FloatParameter("Spacing", 1.1, 0.1, 4, .slider, "Depth spacing between waveform rows"))),
            ("inputAngleX", ParameterPort(parameter: FloatParameter("Angle X", 0.43, -1.57, 1.57, .slider, "Perspective rotation around X"))),
            ("inputAngleY", ParameterPort(parameter: FloatParameter("Angle Y", -0.23, -1.57, 1.57, .slider, "Perspective rotation around Y"))),
            ("inputScale", ParameterPort(parameter: FloatParameter("Scale", 1.98, 0.4, 3, .slider, "Projected waveform scale"))),
            ("inputFade", ParameterPort(parameter: FloatParameter("Fade", 0, 0, 2, .slider, "Depth fade toward older rows"))),
            ("inputColor", ParameterPort(parameter: Float4Parameter("Color", simd_float4(0.22, 1, 0.35, 1), .zero, .one, .colorpicker, "Waveform line color"))),
            ("inputTransparentBackground", ParameterPort(parameter: BoolParameter("Transparent Background", false, .toggle, "Clear the output with transparent pixels"))),
            ("outputImage", NodePort<FabricImage>(name: "Image", kind: .Outlet, description: "Rendered perspective waveform image")),
        ]
    }

    public var inputHistory: NodePort<ContiguousArray<Float>> { port(named: "inputHistory") }
    public var inputWidth: ParameterPort<Int> { port(named: "inputWidth") }
    public var inputHeight: ParameterPort<Int> { port(named: "inputHeight") }
    public var inputHistoryRows: ParameterPort<Int> { port(named: "inputHistoryRows") }
    public var inputAmplitude: ParameterPort<Float> { port(named: "inputAmplitude") }
    public var inputLineThickness: ParameterPort<Float> { port(named: "inputLineThickness") }
    public var inputSpacing: ParameterPort<Float> { port(named: "inputSpacing") }
    public var inputAngleX: ParameterPort<Float> { port(named: "inputAngleX") }
    public var inputAngleY: ParameterPort<Float> { port(named: "inputAngleY") }
    public var inputScale: ParameterPort<Float> { port(named: "inputScale") }
    public var inputFade: ParameterPort<Float> { port(named: "inputFade") }
    public var inputColor: ParameterPort<simd_float4> { port(named: "inputColor") }
    public var inputTransparentBackground: ParameterPort<Bool> { port(named: "inputTransparentBackground") }
    public var outputImage: NodePort<FabricImage> { port(named: "outputImage") }

    private var pipeline: MTLRenderPipelineState?
    private var pipelineError: String?
    private let historyBufferPool = WaveformHistoryBufferPool()

    public required init(context: Context)
    {
        super.init(context: context)
        preparePipeline()
    }

    public required init(from decoder: any Decoder) throws
    {
        try super.init(from: decoder)
        preparePipeline()
    }

    private func preparePipeline()
    {
        do
        {
            let library = try context.device.makeDefaultLibrary(bundle: Bundle(for: Self.self))
            guard let vertex = library.makeFunction(name: "audio3DWaveformVertex"),
                  let fragment = library.makeFunction(name: "audio3DWaveformFragment")
            else
            {
                pipelineError = "The Audio 3D Waveform Metal functions are missing from the plug-in bundle."
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Audio 3D Waveform"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
            pipelineError = nil
        }
        catch
        {
            pipelineError = "The Audio 3D Waveform pipeline could not be created: \(error)"
        }
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        guard let pipeline else
        {
            throw Audio3DWaveformError(message: pipelineError ?? "The waveform renderer is unavailable.")
        }

        let expectedSampleCount = AudioWaveformRow.sampleCount
            * AudioWaveformRow.maximumHistoryRows
        let history = inputHistory.value ?? ContiguousArray<Float>(
            repeating: 0,
            count: expectedSampleCount
        )
        guard history.count == expectedSampleCount,
              history.allSatisfy(\.isFinite)
        else
        {
            throw Audio3DWaveformError(
                message: "Waveform History requires 24 rows of 192 finite signed samples."
            )
        }

        let width = min(max(inputWidth.value ?? 1280, 64), 4096)
        let height = min(max(inputHeight.value ?? 720, 64), 4096)
        let visibleRows = min(max(inputHistoryRows.value ?? 24, 1), 24)
        let image = try renderer.newImage(withWidth: width, height: height, format: .rgba16Float)
        image.texture.label = "Audio 3D Waveform"

        let historyByteCount = history.count * MemoryLayout<Float>.stride
        guard let bufferSlot = historyBufferPool.acquire(
            device: context.device,
            length: historyByteCount
        ) else
        {
            throw Audio3DWaveformError(message: "The waveform GPU buffers are busy.")
        }
        history.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress
            {
                bufferSlot.buffer.contents().copyMemory(
                    from: baseAddress,
                    byteCount: historyByteCount
                )
            }
        }

        var uniforms = AudioWaveformUniforms(
            viewport: simd_float4(Float(width), Float(height), Float(width) / Float(height), 0),
            grid: simd_float4(
                Float(AudioWaveformRow.sampleCount),
                Float(visibleRows),
                Float(AudioWaveformRow.maximumHistoryRows - visibleRows),
                min(max(inputSpacing.value ?? 1.1, 0.1), 4)
            ),
            waveform: simd_float4(
                min(max(inputAmplitude.value ?? 0.6, 0), 4),
                min(max(inputLineThickness.value ?? 1.5, 0.25), 10),
                min(max(inputScale.value ?? 1.98, 0.4), 3),
                min(max(inputFade.value ?? 0, 0), 2)
            ),
            angles: simd_float4(
                min(max(inputAngleX.value ?? 0.43, -1.57), 1.57),
                min(max(inputAngleY.value ?? -0.23, -1.57), 1.57),
                0,
                0
            ),
            color: inputColor.value ?? simd_float4(0.22, 1, 0.35, 1)
        )

        let waveformPass = MTLRenderPassDescriptor()
        waveformPass.colorAttachments[0].texture = image.texture
        waveformPass.colorAttachments[0].loadAction = .clear
        waveformPass.colorAttachments[0].storeAction = .store
        waveformPass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: inputTransparentBackground.value == true ? 0 : 1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: waveformPass)
        else
        {
            historyBufferPool.release(slotIndex: bufferSlot.slotIndex)
            throw Audio3DWaveformError(message: "The waveform render encoder could not be created.")
        }
        encoder.label = "Audio 3D Waveform"
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<AudioWaveformUniforms>.stride,
            index: 0
        )
        encoder.setVertexBuffer(bufferSlot.buffer, offset: 0, index: 1)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<AudioWaveformUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: (AudioWaveformRow.sampleCount - 1) * visibleRows * 6
        )
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [historyBufferPool] _ in
            historyBufferPool.release(slotIndex: bufferSlot.slotIndex)
        }
        outputImage.send(image)
    }
}
