import Fabric
import Foundation
import Satin
import simd

enum AdvancedSceneError: Error
{
    case missingNode(String)
    case invalidExpression(String)
    case connectionFailed(String)
    case verificationFailed(String)
}

/// Builds the saved example with the same public graph API available to plugins.
final class AdvancedSceneBuilder
{
    let graph: Graph
    let source: Node
    private let context: Context
    private let registry: NodeRegistry
    private var groupNodes: [Node] = []
    private let textColor = simd_float4(0.75, 0.82, 0.93, 1)
    private let mutedColor = simd_float4(0.34, 0.44, 0.59, 1)

    init(context: Context, registry: NodeRegistry, sourceClass: Node.Type)
    {
        self.context = context
        self.registry = registry
        graph = Graph(context: context)
        source = sourceClass.init(context: context)
        source.offset = CGSize(width: -1000, height: 0)
        graph.addNode(source)
    }

    @discardableResult
    private func add<SelectedNode: Node>(_ node: SelectedNode, name: String) -> SelectedNode
    {
        node.userName = name
        let index = groupNodes.count
        node.offset = CGSize(width: (index % 4) * 350, height: (index / 4) * 420)
        graph.addNode(node)
        groupNodes.append(node)
        return node
    }

    private func connect(_ outlet: Fabric.Port, _ inlet: Fabric.Port) throws
    {
        guard graph.connect(outlet, to: inlet) != nil else
        {
            throw AdvancedSceneError.connectionFailed("\(outlet.name) → \(inlet.name)")
        }
    }

    private func input(_ outputName: String, to node: Node, port: String) throws
    {
        let outlet: Fabric.Port = source.port(named: outputName)
        let inlet: Fabric.Port = node.port(named: port)
        inlet.publishedName = outlet.name
        try connect(outlet, inlet)
    }

    private func expression(_ expression: String, name: String) throws -> MathExpressionNode
    {
        let node = add(MathExpressionNode(context: context, expression: expression), name: name)
        guard node.deriveStatuses().isEmpty else { throw AdvancedSceneError.invalidExpression(expression) }
        return node
    }

    private func group(_ name: String, position: CGPoint) throws
    {
        guard let anchor = groupNodes.first else { return }
        let subgraph = try graph.createSubgraph(from: groupNodes, centeredOn: anchor, usingClass: SubgraphNode.self)
        subgraph.userName = name
        subgraph.offset = CGSize(width: position.x, height: position.y)
        groupNodes.removeAll(keepingCapacity: true)
    }

    private func material(_ color: simd_float4, name: String) -> BasicColorMaterialNode
    {
        let node = add(BasicColorMaterialNode(context: context), name: name)
        node.inputColor.value = color
        return node
    }

    private func mesh(geometry: BaseGeometryNode, material: BasicColorMaterialNode, name: String,
                      position: simd_float3, scale: simd_float3 = .one) throws -> MeshNode
    {
        let node = add(MeshNode(context: context), name: name)
        node.inputPosition.value = position
        node.inputScale.value = scale
        node.inputOrientation.value = simd_float4(0, 0, 0, 1)
        node.inputDoubleSided.value = true
        try connect(geometry.outputGeometry, node.inputGeometry)
        try connect(material.outputMaterial, node.inputMaterial)
        return node
    }

    @discardableResult
    private func label(_ text: String, at position: simd_float3, size: Float = 0.13,
                       material: BasicColorMaterialNode) throws -> TesselatedTextGeometryNode
    {
        let geometry = add(TesselatedTextGeometryNode(context: context), name: text)
        geometry.inputText.value = text
        _ = try mesh(geometry: geometry, material: material, name: "\(text) Label", position: position,
                     scale: simd_float3(repeating: size))
        return geometry
    }

    private func plane(name: String, position: simd_float3, scale: simd_float3,
                       material: BasicColorMaterialNode) throws -> MeshNode
    {
        let geometry = add(PlaneGeometryNode(context: context), name: "\(name) Geometry")
        return try mesh(geometry: geometry, material: material, name: name, position: position, scale: scale)
    }

    func build() throws -> Graph
    {
        let camera = OrthographicCameraNode(context: context)
        camera.userName = "Dashboard Camera"
        camera.inputScale.value = simd_float3(repeating: 2.7)
        camera.offset = CGSize(width: -1000, height: 1000)
        graph.addNode(camera)
        try buildBackground()
        try buildWaveform()
        try buildFrequencyBands()
        try buildEnvelopes()
        try buildLevels()
        try buildDiagnostics()
        return graph
    }

    private func buildBackground() throws
    {
        let background = material(simd_float4(0.014, 0.023, 0.045, 1), name: "Loudness Background")
        let brightness = try expression("let level = clamp(loudness, 0, 1); out color = vec4(0.014 + level * 0.018, 0.023 + level * 0.025, 0.045 + level * 0.04, 1)", name: "Loudness Brightness")
        try input("outputLoudnessNormalized", to: brightness, port: "loudness")
        try connect(brightness.port(named: "color"), background.inputColor)
        _ = try plane(name: "Background", position: simd_float3(0, 0, -0.5), scale: simd_float3(20, 12, 1), material: background)
        let brightText = material(textColor, name: "Header Text")
        let mutedText = material(mutedColor, name: "Header Detail")
        try label("AUDIO ANALYSIS", at: simd_float3(-2.98, 2.22, 0), size: 0.25, material: brightText)
        try label("LIVE INPUT  /  21 OUTPUTS", at: simd_float3(3.25, 2.24, 0), size: 0.12, material: mutedText)
        try label("WAVEFORM HISTORY", at: simd_float3(-3.45, 1.86, 0), size: 0.12, material: mutedText)
        try label("CENTROID COLOR  /  ONSET TRAIL", at: simd_float3(3.12, 1.86, 0), size: 0.1, material: mutedText)
        try group("Loudness & Layout", position: CGPoint(x: -500, y: -800))
    }

    private func buildWaveform() throws
    {
        guard let waveformClass = registry.nodeClass(pluginID: "com.jvclabs.FabricAudioAnalysis", nodeID: "WaveformTrailNode"),
              let imageClass = registry.availableNodes.first(where: { $0.nodeName == "Image Mesh" })?.nodeClass
        else { throw AdvancedSceneError.missingNode("Waveform Trail or Image Mesh") }
        let trail = add(waveformClass.init(context: context), name: "Waveform & Onset Trail")
        try input("outputWaveformHistory", to: trail, port: "inputWaveform")
        try input("outputOnset", to: trail, port: "inputOnset")
        try input("outputSpectralFlux", to: trail, port: "inputIntensity")
        let color = try expression("let hue = clamp(centroid / max(sampleRate * 0.25, 1), 0, 1); out color = vec4(0.12 + hue * 0.76, 0.78 - hue * 0.48, 1, 1)", name: "Centroid to Color")
        try input("outputSpectralCentroid", to: color, port: "centroid")
        try input("outputSampleRate", to: color, port: "sampleRate")
        try connect(color.port(named: "color"), trail.port(named: "inputColor"))
        let display = add(imageClass.init(context: context), name: "Waveform Display")
        let size: ParameterPort<Float> = display.port(named: "inputSize")
        let position: ParameterPort<simd_float3> = display.port(named: "inputPosition")
        let orientation: ParameterPort<simd_float4> = display.port(named: "inputOrientation")
        size.value = 8.2
        position.value = simd_float3(0, 0.73, 0)
        orientation.value = simd_float4(0, 0, 0, 1)
        try connect(trail.port(named: "outputImage"), display.port(named: "inputImage"))
        try group("Waveform & Onsets", position: CGPoint(x: -500, y: -300))
    }

    private func buildFrequencyBands() throws
    {
        let mutedText = material(mutedColor, name: "Band Labels")
        try label("FREQUENCY BANDS", at: simd_float3(-3.45, -0.55, 0), size: 0.13, material: mutedText)
        let bands: [(String, String, simd_float4)] = [
            ("Sub Bass", "outputSubBass", simd_float4(0.2, 0.65, 1, 1)),
            ("Bass", "outputBass", simd_float4(0.22, 0.82, 0.92, 1)),
            ("Low Mid", "outputLowMid", simd_float4(0.28, 0.9, 0.63, 1)),
            ("Mid", "outputMid", simd_float4(0.96, 0.72, 0.24, 1)),
            ("High", "outputHigh", simd_float4(0.97, 0.37, 0.48, 1)),
        ]
        let track = material(simd_float4(0.06, 0.1, 0.16, 1), name: "Band Tracks")
        for (index, band) in bands.enumerated()
        {
            let horizontal = -3.88 + Float(index) * 0.67
            _ = try plane(name: "\(band.0) Track", position: simd_float3(horizontal, -1.4, -0.1), scale: simd_float3(0.34, 1.3, 1), material: track)
            let fill = material(band.2, name: "\(band.0) Color")
            let bar = try plane(name: "\(band.0) Bar", position: .zero, scale: .one, material: fill)
            let movement = try expression("let height = 0.03 + clamp(energy, 0, 1) * 1.27; out scale = vec3(0.34, height, 1); out position = vec3(\(horizontal), -2.05 + height * 0.5, 0)", name: "\(band.0) Height")
            try input(band.1, to: movement, port: "energy")
            try connect(movement.port(named: "scale"), bar.inputScale)
            try connect(movement.port(named: "position"), bar.inputPosition)
            try label(band.0.uppercased(), at: simd_float3(horizontal, -2.28, 0), size: 0.085, material: mutedText)
        }
        try group("Frequency Bands", position: CGPoint(x: -500, y: 250))
    }

    private func buildEnvelopes() throws
    {
        let center = simd_float3(0.8, -1.43, 0)
        let mutedText = material(mutedColor, name: "Envelope Labels")
        try label("ENVELOPES", at: simd_float3(0.8, -0.55, 0), material: mutedText)
        let rings: [(String, String, Float, simd_float4)] = [
            ("Fast", "outputFastEnvelope", 0.3, simd_float4(1, 0.56, 0.22, 1)),
            ("Medium", "outputMediumEnvelope", 0.5, simd_float4(0.22, 0.82, 0.95, 1)),
            ("Slow", "outputSlowEnvelope", 0.7, simd_float4(0.72, 0.48, 0.95, 1)),
        ]
        for ring in rings
        {
            let geometry = add(TorusGeometryNode(context: context), name: "\(ring.0) Ring Geometry")
            geometry.inputMajorRadius.value = 1
            geometry.inputMinorRadius.value = 1.4
            geometry.inputMinorResolution.value = 8
            geometry.inputMajorResolution.value = 80
            let color = material(ring.3, name: "\(ring.0) Ring Color")
            let shape = try mesh(geometry: geometry, material: color, name: "\(ring.0) Envelope Ring", position: center)
            shape.inputOrientation.value = simd_float4(0.7071068, 0, 0, 0.7071068)
            let movement = try expression("let radius = \(ring.2) + clamp(envelope, 0, 1) * 0.1; out scale = vec3(radius, radius, radius)", name: "\(ring.0) Radius")
            try input(ring.1, to: movement, port: "envelope")
            try connect(movement.port(named: "scale"), shape.inputScale)
        }
        let sphere = add(SphereGeometryNode(context: context), name: "RMS Center Geometry")
        sphere.inputRadius.value = 0.18
        sphere.inputAngularResolution.value = 24
        sphere.inputVerticalResolution.value = 16
        let sphereMaterial = material(.one, name: "Onset Center Color")
        let sphereMesh = try mesh(geometry: sphere, material: sphereMaterial, name: "RMS Center", position: center)
        let movement = try expression("let size = 0.65 + clamp(rms, 0, 1) * 0.7; out scale = vec3(size, size, size)", name: "RMS Center Scale")
        try input("outputRMSNormalized", to: movement, port: "rms")
        try connect(movement.port(named: "scale"), sphereMesh.inputScale)
        let trigger = add(NumberTriggerNode(context: context), name: "Onset Flash")
        trigger.inputMinDurationSecs.value = 0.2
        let easing = add(EasingNode(context: context, portType: .Color), name: "White to Red")
        let from: ParameterPort<simd_float4> = easing.port(named: "inputFrom")
        let to: ParameterPort<simd_float4> = easing.port(named: "inputTo")
        from.value = .one
        to.value = simd_float4(1, 0.055, 0.025, 1)
        try input("outputOnset", to: trigger, port: "inputTarget")
        try connect(trigger.outputValue, easing.port(named: "inputProgress"))
        try connect(easing.port(named: "outputValue"), sphereMaterial.inputColor)
        let orange = material(rings[0].3, name: "Fast Label Color")
        let cyan = material(rings[1].3, name: "Medium Label Color")
        let purple = material(rings[2].3, name: "Slow Label Color")
        try label("FAST", at: simd_float3(0.2, -2.28, 0), size: 0.09, material: orange)
        try label("MEDIUM", at: simd_float3(0.8, -2.28, 0), size: 0.09, material: cyan)
        try label("SLOW", at: simd_float3(1.4, -2.28, 0), size: 0.09, material: purple)
        try group("Envelopes & RMS Center", position: CGPoint(x: 50, y: -300))
    }

    private func buildLevels() throws
    {
        let mutedText = material(mutedColor, name: "Level Labels")
        try label("LEVEL / PEAK", at: simd_float3(3.27, -0.55, 0), material: mutedText)
        let track = material(simd_float4(0.06, 0.1, 0.16, 1), name: "Level Tracks")
        let peakColor = material(textColor, name: "Peak Marker Color")
        let meters: [(String, String, String, Float, simd_float4)] = [
            ("RMS", "outputRMSNormalized", "outputPeakRMS", 2.82, simd_float4(0.3, 0.83, 0.7, 1)),
            ("FLUX", "outputSpectralFlux", "outputPeakFlux", 3.72, simd_float4(1, 0.48, 0.23, 1)),
        ]
        for meter in meters
        {
            _ = try plane(name: "\(meter.0) Track", position: simd_float3(meter.3, -1.4, -0.1), scale: simd_float3(0.28, 1.3, 1), material: track)
            let color = material(meter.4, name: "\(meter.0) Color")
            let bar = try plane(name: "\(meter.0) Meter", position: .zero, scale: .one, material: color)
            let transform = try expression("let height = 0.03 + clamp(level, 0, 1) * 1.27; out scale = vec3(0.28, height, 1); out position = vec3(\(meter.3), -2.05 + height * 0.5, 0); out peakPosition = vec3(\(meter.3), -2.05 + clamp(peak, 0, 1) * 1.3, 0.05)", name: "\(meter.0) Level & Peak")
            try input(meter.1, to: transform, port: "level")
            try input(meter.2, to: transform, port: "peak")
            try connect(transform.port(named: "scale"), bar.inputScale)
            try connect(transform.port(named: "position"), bar.inputPosition)
            let peak = try plane(name: "\(meter.0) Peak Marker", position: .zero, scale: simd_float3(0.48, 0.025, 1), material: peakColor)
            try connect(transform.port(named: "peakPosition"), peak.inputPosition)
            try label(meter.0, at: simd_float3(meter.3, -2.28, 0), size: 0.1, material: mutedText)
        }
        try group("Levels & Peaks", position: CGPoint(x: 50, y: 250))
    }

    private func buildDiagnostics() throws
    {
        let text = material(textColor, name: "Readout Color")
        let left = add(StringFormatterNode(context: context, formatString: "RMS {rms:.3f}    LOUDNESS {loudness:.1f} dB"), name: "Raw Level Readout")
        try input("outputRMS", to: left, port: "rms")
        try input("outputLoudnessDB", to: left, port: "loudness")
        let leftGeometry = try label("Raw Levels", at: simd_float3(-2.83, -2.53, 0), size: 0.11, material: text)
        try connect(left.outputString, leftGeometry.inputText)
        let right = add(StringFormatterNode(context: context, formatString: "RUNNING {running:b}    {sampleRate:.0f} Hz    DROPPED {dropped:d}"), name: "Capture Readout")
        try input("outputRunning", to: right, port: "running")
        try input("outputSampleRate", to: right, port: "sampleRate")
        try input("outputDroppedSamples", to: right, port: "dropped")
        let rightGeometry = try label("Capture Status", at: simd_float3(2.65, -2.53, 0), size: 0.105, material: text)
        try connect(right.outputString, rightGeometry.inputText)
        try group("Capture & Raw Readouts", position: CGPoint(x: 50, y: -800))
    }
}
