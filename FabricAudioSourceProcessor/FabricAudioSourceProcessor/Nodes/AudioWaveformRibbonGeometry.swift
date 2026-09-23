import AudioSourceProcessorCore
import Fabric
import Foundation
import Metal
import Satin
import simd

#if SWIFT_PACKAGE
import SatinCore
#endif

/// A single indexed mesh containing independent ribbons for each history row.
/// The same object is updated as audio changes, so downstream Mesh nodes keep
/// their geometry identity and transforms.
final class AudioWaveformRibbonGeometry: SatinGeometry
{
    private var history = ContiguousArray<Float>(
        repeating: 0,
        count: AudioWaveformRow.sampleCount * AudioWaveformRow.maximumHistoryRows
    )
    private var visibleRows = AudioWaveformRow.maximumHistoryRows
    private var width: Float = 2
    private var depth: Float = 1.2
    private var amplitude: Float = 0.6
    private var thickness: Float = 0.01

    override init(context: Context)
    {
        super.init(context: context)
        mutability = .dynamicData
    }

    func setWaveform(
        history: ContiguousArray<Float>,
        visibleRows: Int,
        width: Float,
        depth: Float,
        amplitude: Float,
        thickness: Float
    )
    {
        self.history = history
        self.visibleRows = visibleRows
        self.width = width
        self.depth = depth
        self.amplitude = amplitude
        self.thickness = thickness
        _updateData = true
    }

    override func generateGeometryData() -> GeometryData
    {
        let samplesPerRow = AudioWaveformRow.sampleCount
        let rowCount = visibleRows
        let vertexCount = rowCount * samplesPerRow * 2
        let triangleCount = rowCount * (samplesPerRow - 1) * 2
        var data = createGeometryData()
        guard let rawVertices = malloc(vertexCount * MemoryLayout<SatinVertex>.stride)
        else
        {
            return data
        }
        guard let rawTriangles = malloc(triangleCount * MemoryLayout<TriangleIndices>.stride)
        else
        {
            free(rawVertices)
            return data
        }
        let vertices = rawVertices.bindMemory(to: SatinVertex.self, capacity: vertexCount)
        let triangles = rawTriangles.bindMemory(to: TriangleIndices.self, capacity: triangleCount)
        let firstVisibleRow = AudioWaveformRow.maximumHistoryRows - rowCount
        let halfThickness = thickness * 0.5

        for rowOffset in 0 ..< rowCount
        {
            let historyRow = firstVisibleRow + rowOffset
            let rowFraction = rowCount > 1
                ? Float(rowOffset) / Float(rowCount - 1) : 0.5
            let rowDepth = (rowFraction - 0.5) * depth
            let rowVertexStart = rowOffset * samplesPerRow * 2
            let rowTriangleStart = rowOffset * (samplesPerRow - 1) * 2

            for sampleIndex in 0 ..< samplesPerRow
            {
                let sampleFraction = Float(sampleIndex) / Float(samplesPerRow - 1)
                let positionX = (sampleFraction - 0.5) * width
                let positionY = history[historyRow * samplesPerRow + sampleIndex] * amplitude
                let previousIndex = max(0, sampleIndex - 1)
                let nextIndex = min(samplesPerRow - 1, sampleIndex + 1)
                let tangentX = Float(nextIndex - previousIndex)
                    * width / Float(samplesPerRow - 1)
                let tangentY = (history[historyRow * samplesPerRow + nextIndex]
                    - history[historyRow * samplesPerRow + previousIndex]) * amplitude
                let normalLength = max((tangentX * tangentX + tangentY * tangentY).squareRoot(), 0.0001)
                let offsetX = -tangentY / normalLength * halfThickness
                let offsetY = tangentX / normalLength * halfThickness
                let vertexIndex = rowVertexStart + sampleIndex * 2
                let uv = simd_float2(sampleFraction, rowFraction)
                vertices[vertexIndex] = SatinVertex(
                    position: simd_float3(positionX - offsetX, positionY - offsetY, rowDepth),
                    normal: simd_float3(0, 0, 1),
                    uv: uv
                )
                vertices[vertexIndex + 1] = SatinVertex(
                    position: simd_float3(positionX + offsetX, positionY + offsetY, rowDepth),
                    normal: simd_float3(0, 0, 1),
                    uv: uv
                )

                if sampleIndex < samplesPerRow - 1
                {
                    let nextVertex = vertexIndex + 2
                    let triangleIndex = rowTriangleStart + sampleIndex * 2
                    triangles[triangleIndex] = TriangleIndices(
                        i0: UInt32(vertexIndex),
                        i1: UInt32(nextVertex),
                        i2: UInt32(vertexIndex + 1)
                    )
                    triangles[triangleIndex + 1] = TriangleIndices(
                        i0: UInt32(nextVertex),
                        i1: UInt32(nextVertex + 1),
                        i2: UInt32(vertexIndex + 1)
                    )
                }
            }
        }

        data.vertexCount = Int32(vertexCount)
        data.vertexData = vertices
        data.indexCount = Int32(triangleCount)
        data.indexData = triangles
        return data
    }
}
