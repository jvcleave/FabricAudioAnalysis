import AudioAnalysisCore
import Fabric
import Foundation
import Metal
import Satin
import Synchronization
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

    /// A slot is reused only after its submitted GPU work completes. If all
    /// three are busy, retain the previous image instead of waiting for the GPU.
    private final class UploadSlot: @unchecked Sendable
    {
        let isBusy = Atomic<Bool>(false)
        let waveform: MTLBuffer
        let columns: MTLBuffer
        var waveformRevision = -1

        init?(device: MTLDevice)
        {
            guard let waveform = device.makeBuffer(length: 24 * 192 * MemoryLayout<Float>.stride, options: .storageModeShared),
                  let columns = device.makeBuffer(length: 4096 * MemoryLayout<Float>.stride, options: .storageModeShared)
            else { return nil }
            self.waveform = waveform
            self.columns = columns
        }
    }

    private let onsetTrail = AudioOnsetTrail()
    private var pipeline: MTLComputePipelineState?
    private var pipelineError: String?
    private var uploadSlots: [UploadSlot] = []
    private var waveformRevision = 0

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
        try super.stopExecution(renderer: renderer)
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
        if waveformInput.valueDidChange { waveformRevision += 1 }

        if uploadSlots.isEmpty
        {
            for _ in 0 ..< 3
            {
                guard let slot = UploadSlot(device: context.device) else
                {
                    uploadSlots.removeAll()
                    throw FabricError(.execution(.gpu), severity: .recoverable, message: "Could not allocate Waveform Trail's upload buffers.")
                }
                uploadSlots.append(slot)
            }
        }
        guard let slot = uploadSlots.first(where: { !$0.isBusy.exchange(true, ordering: .acquiringAndReleasing) }) else { return }
        var submitted = false
        defer { if !submitted { slot.isBusy.store(false, ordering: .releasing) } }

        let widthInput: ParameterPort<Int> = port(named: "inputWidth")
        let heightInput: ParameterPort<Int> = port(named: "inputHeight")
        let width = min(max(widthInput.value ?? 1280, 64), 4096)
        let height = min(max(heightInput.value ?? 320, 32), 2048)
        let samples = waveformInput.value ?? []
        let rowCount = min(max(samples.count / 192, 1), 24)
        if slot.waveformRevision != waveformRevision
        {
            let destination = slot.waveform.contents().bindMemory(to: Float.self, capacity: 24 * 192)
            for sampleIndex in 0 ..< 24 * 192 { destination[sampleIndex] = 0 }
            for (sampleIndex, sample) in samples.suffix(24 * 192).enumerated()
            {
                destination[sampleIndex] = sample.isFinite ? min(max(sample, -1), 1) : 0
            }
            slot.waveformRevision = waveformRevision
        }
        let durationInput: ParameterPort<Float> = port(named: "inputDuration")
        onsetTrail.writeColumns(
            into: UnsafeMutableBufferPointer(start: slot.columns.contents().bindMemory(to: Float.self, capacity: width), count: width),
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
            dimensions: SIMD4(UInt32(width), UInt32(height), 192, UInt32(rowCount))
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
        encoder.setBuffer(slot.waveform, offset: 0, index: 1)
        encoder.setBuffer(slot.columns, offset: 0, index: 2)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in slot.isBusy.store(false, ordering: .releasing) }
        submitted = true
        let outputImage: NodePort<FabricImage> = port(named: "outputImage")
        outputImage.send(image)
    }
}
