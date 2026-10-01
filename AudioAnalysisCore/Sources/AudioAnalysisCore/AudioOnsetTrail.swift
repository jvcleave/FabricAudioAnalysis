import Foundation

/// A bounded history of onset pulses, positioned by scene time rather than
/// analysis cadence. Repeated evaluations at the same time record only once.
public final class AudioOnsetTrail
{
    private var eventTimes: [TimeInterval]
    private var intensities: [Float]
    private var writeIndex = 0
    public private(set) var count = 0
    private var lastUpdateTime: TimeInterval?

    public init(capacity: Int = 512)
    {
        precondition(capacity > 0)
        eventTimes = .init(repeating: 0, count: capacity)
        intensities = .init(repeating: 0, count: capacity)
    }

    public func reset()
    {
        writeIndex = 0
        count = 0
        lastUpdateTime = nil
    }

    public func update(at time: TimeInterval, onset: Bool, intensity: Float)
    {
        guard time.isFinite else { return }
        if let lastUpdateTime, time < lastUpdateTime { reset() }
        guard lastUpdateTime != time else { return }
        lastUpdateTime = time
        guard onset else { return }
        eventTimes[writeIndex] = time
        intensities[writeIndex] = intensity.isFinite ? min(max(intensity, 0.05), 1) : 0.05
        writeIndex = (writeIndex + 1) % eventTimes.count
        count = min(count + 1, eventTimes.count)
    }

    public func flashStrength(at time: TimeInterval) -> Float
    {
        guard count > 0, time.isFinite else { return 0 }
        let newestIndex = (writeIndex + eventTimes.count - 1) % eventTimes.count
        let age = time - eventTimes[newestIndex]
        guard age >= 0, age < 0.2 else { return 0 }
        return Float(1 - age / 0.2)
    }

    /// The newest hit is at the center playhead; older hits move to the left.
    /// Writes directly into a reusable upload buffer, including empty columns.
    public func writeColumns(
        into columns: UnsafeMutableBufferPointer<Float>,
        at time: TimeInterval,
        duration: TimeInterval
    )
    {
        for columnIndex in columns.indices { columns[columnIndex] = 0 }
        guard !columns.isEmpty, time.isFinite, duration.isFinite, duration > 0 else { return }
        let centerColumn = columns.count / 2
        for eventOffset in 0 ..< count
        {
            let eventIndex = (writeIndex + eventTimes.count - count + eventOffset) % eventTimes.count
            let age = time - eventTimes[eventIndex]
            guard age >= 0, age <= duration else { continue }
            let columnIndex = centerColumn - Int(age / duration * Double(centerColumn))
            columns[columnIndex] = max(columns[columnIndex], intensities[eventIndex])
        }
    }
}
