import AudioAnalysisCore
import Fabric
import Foundation
import Metal
import MetalPerformanceShaders
import Satin
import simd

/// Draws supplied waveform history and onset pulses; it owns no capture or DSP.
public final class WaveformTrailNode: Node
{
    public override class var name: String { "Waveform Trail" }
    public override class var nodeType: Node.NodeType { .Image(imageType: .Generator) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }
    public override class var nodeDescription: String
    {
        "Draws layered waveform history with glow, a scrolling onset trail, and a flashing center playhead. Uses supplied analysis without starting microphone capture."
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) + [
            ("inputWaveform", NodePort<ContiguousArray<Float>>(name: "Waveform History", kind: .Inlet, description: "Oldest-to-newest rows of 192 signed samples; accepts a single row too")),
            ("inputOnset", ParameterPort(parameter: BoolParameter("Onset", false, .toggle, "A hit pulse for the current graph pass"))),
            ("inputIntensity", ParameterPort(parameter: FloatParameter("Intensity", 1, 0, 1, .slider, "Strength of new onset markers"))),
            ("inputColor", ParameterPort(parameter: Float4Parameter("Color", simd_float4(0.12, 0.72, 1, 1), .colorpicker))),
            ("inputAmplitude", ParameterPort(parameter: FloatParameter("Amplitude", 0.25, 0, 0.5, .slider))),
            ("inputThickness", ParameterPort(parameter: FloatParameter("Thickness", 0.004, 0.001, 0.03, .slider))),
            ("inputGlow", ParameterPort(parameter: FloatParameter("Glow", 1.4, 0, 3, .slider))),
            ("inputDuration", ParameterPort(parameter: FloatParameter("Trail Duration", 4, 0.25, 10, .slider, "Seconds for a hit to travel from the center to the left edge"))),
            ("inputWidth", ParameterPort(parameter: IntParameter("Width", 1280, 64, 4096, .inputfield))),
            ("inputHeight", ParameterPort(parameter: IntParameter("Height", 320, 32, 2048, .inputfield))),
            ("outputImage", NodePort<FabricImage>(name: "Image", kind: .Outlet)),
        ]
    }

    private struct Uniforms
    {
        var color: simd_float4
        var shape: simd_float4
        var dimensions: SIMD4<UInt32>
    }

    private let onsetTrail = AudioOnsetTrail()
    private var pipeline: MTLComputePipelineState?
    private var pipelineError: String?
    private var waveformBuffer: MTLBuffer?

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
            let library = try context.device.makeDefaultLibrary(bundle: Bundle(for: WaveformTrailNode.self))
            guard let function = library.makeFunction(name: "fabricWaveformTrail") else
            {
                pipelineError = "Waveform Trail's shader is missing from the plugin bundle."
                return
            }
            pipeline = try context.device.makeComputePipelineState(function: function)
        }
        catch { pipelineError = error.localizedDescription }
    }

    public override func startExecution(renderer: GraphRenderer) throws
    {
        onsetTrail.reset()
        try super.startExecution(renderer: renderer)
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        onsetTrail.reset()
        waveformBuffer = nil
        try super.stopExecution(renderer: renderer)
    }

    private func makeUploadBuffer(floatCount: Int, label: String) throws -> MTLBuffer
    {
        do
        {
            return try context.gpuAllocator.makeBuffer(
                length: floatCount * MemoryLayout<Float>.stride, memoryClass: .cpuWrites, label: label
            )
        }
        catch
        {
            throw FabricError(.execution(.outOfMemory), severity: .recoverable, message: "Could not allocate \(label).")
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
            throw FabricError(.execution(.gpu), severity: .recoverable, message: pipelineError ?? "Waveform Trail is unavailable.")
        }
        let waveformInput: NodePort<ContiguousArray<Float>> = port(named: "inputWaveform")
        let onsetInput: ParameterPort<Bool> = port(named: "inputOnset")
        let intensityInput: ParameterPort<Float> = port(named: "inputIntensity")
        let time = executionInfo.timing.time
        onsetTrail.update(at: time, onset: onsetInput.value ?? false, intensity: intensityInput.value ?? 1)
        let widthInput: ParameterPort<Int> = port(named: "inputWidth")
        let heightInput: ParameterPort<Int> = port(named: "inputHeight")
        let width = min(max(widthInput.value ?? 1280, 64), 4096)
        let height = min(max(heightInput.value ?? 320, 32), 2048)
        let samples = waveformInput.value ?? []
        let samplesPerRow = AudioWaveformRow.sampleCount
        let maxRows = AudioWaveformRow.maximumHistoryRows
        let rowCount = min(max(samples.count / samplesPerRow, 1), maxRows)

        if waveformInput.valueDidChange
        {
            // Consume the update once, even when the Iterator evaluates again before Fabric clears port flags.
            waveformInput.valueDidChange = false
            // Leave the cache empty if allocation fails so the next evaluation can retry.
            waveformBuffer = nil
        }
        let waveform: MTLBuffer
        if let waveformBuffer
        {
            waveform = waveformBuffer
        }
        else
        {
            let capacity = maxRows * samplesPerRow
            waveform = try makeUploadBuffer(floatCount: capacity, label: "Waveform Trail samples")
            let destination = waveform.contents().bindMemory(to: Float.self, capacity: capacity)
            let visibleSamples = samples.suffix(capacity)
            for (sampleIndex, sample) in visibleSamples.enumerated()
            {
                destination[sampleIndex] = sample.isFinite ? min(max(sample, -1), 1) : 0
            }
            for sampleIndex in visibleSamples.count ..< capacity { destination[sampleIndex] = 0 }
            waveformBuffer = waveform
        }
        let columns = try makeUploadBuffer(floatCount: width, label: "Waveform Trail onset columns")
        let durationInput: ParameterPort<Float> = port(named: "inputDuration")
        onsetTrail.writeColumns(
            into: UnsafeMutableBufferPointer(start: columns.contents().bindMemory(to: Float.self, capacity: width), count: width),
            at: time,
            duration: Double(min(max(durationInput.value ?? 4, 0.25), 10))
        )
        let colorInput: ParameterPort<simd_float4> = port(named: "inputColor")
        let amplitudeInput: ParameterPort<Float> = port(named: "inputAmplitude")
        let thicknessInput: ParameterPort<Float> = port(named: "inputThickness")
        let glowInput: ParameterPort<Float> = port(named: "inputGlow")
        var uniforms = Uniforms(
            color: colorInput.value ?? simd_float4(0.12, 0.72, 1, 1),
            shape: simd_float4(amplitudeInput.value ?? 0.25, thicknessInput.value ?? 0.004, glowInput.value ?? 1.4, onsetTrail.flashStrength(at: time)),
            dimensions: SIMD4(UInt32(width), UInt32(height), UInt32(samplesPerRow), UInt32(rowCount))
        )
        let image = try renderer.newImage(withWidth: width, height: height, format: .rgba16Float)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else
        {
            throw FabricError(.execution(.gpu), severity: .recoverable, message: "Could not encode Waveform Trail.")
        }
        encoder.label = "Waveform Trail"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(image.texture, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setBuffer(waveform, offset: 0, index: 1)
        encoder.setBuffer(columns, offset: 0, index: 2)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
        encoder.endEncoding()
        let segment = (commandBuffer as? MPSCommandBuffer)?.rootCommandBuffer ?? commandBuffer
        if !segment.retainedReferences
        {
            // A graph command buffer may continue on a new segment. Keep resources through the one that reads them.
            segment.addCompletedHandler { [waveform, columns, texture = image.texture] _ in
                withExtendedLifetime((waveform, columns, texture)) {}
            }
        }
        let outputImage: NodePort<FabricImage> = port(named: "outputImage")
        outputImage.send(image)
    }
}
