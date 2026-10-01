import Foundation

/// A signed, downsampled waveform row. Quantization keeps live history compact;
/// the full PCM window is discarded after each analysis frame.
public struct AudioWaveformRow: Equatable, Sendable
{
    public static let sampleCount = 192
    public static let maximumHistoryRows = 24

    private let samples: ContiguousArray<Int8>

    public init(_ sourceSamples: ArraySlice<Float>)
    {
        guard !sourceSamples.isEmpty else
        {
            samples = ContiguousArray(repeating: 0, count: Self.sampleCount)
            return
        }

        var compressed = ContiguousArray<Int8>()
        compressed.reserveCapacity(Self.sampleCount)
        let sourceCount = sourceSamples.count
        for sampleIndex in 0 ..< Self.sampleCount
        {
            let sourceOffset = min(
                sampleIndex * sourceCount / Self.sampleCount,
                sourceCount - 1
            )
            let sample = sourceSamples[sourceSamples.startIndex + sourceOffset]
            let finiteSample = sample.isFinite ? sample : 0
            compressed.append(Int8((min(max(finiteSample, -1), 1) * 127).rounded()))
        }
        samples = compressed
    }

    public static func flattenedHistory(
        _ rows: ArraySlice<AudioWaveformRow>
    ) -> ContiguousArray<Float>
    {
        let rowCount = Self.maximumHistoryRows
        var result = ContiguousArray<Float>(
            repeating: 0,
            count: rowCount * Self.sampleCount
        )
        let visibleRows = rows.suffix(rowCount)
        let initialRow = rowCount - visibleRows.count
        for (rowOffset, row) in visibleRows.enumerated()
        {
            let baseIndex = (initialRow + rowOffset) * Self.sampleCount
            for sampleIndex in 0 ..< Self.sampleCount
            {
                result[baseIndex + sampleIndex] = Float(row.samples[sampleIndex]) / 127
            }
        }
        return result
    }
}
