import Foundation
import Metal

/// Reuses shared buffers across in-flight Fabric command buffers without
/// waiting on the render thread. A slot is released by GPU completion.
final class WaveformHistoryBufferPool: @unchecked Sendable
{
    private struct Slot
    {
        let buffer: MTLBuffer
        var isInUse: Bool
    }

    private let lock = NSLock()
    private var slots: [Slot] = []
    private let maximumSlotCount = 6

    func acquire(device: MTLDevice, length: Int) -> (buffer: MTLBuffer, slotIndex: Int)?
    {
        lock.lock()
        defer { lock.unlock() }
        if let slotIndex = slots.firstIndex(where: { !$0.isInUse && $0.buffer.length >= length })
        {
            slots[slotIndex].isInUse = true
            return (slots[slotIndex].buffer, slotIndex)
        }
        guard slots.count < maximumSlotCount,
              let buffer = device.makeBuffer(length: length, options: .storageModeShared)
        else
        {
            return nil
        }
        slots.append(Slot(buffer: buffer, isInUse: true))
        return (buffer, slots.count - 1)
    }

    func release(slotIndex: Int)
    {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(slotIndex) else { return }
        slots[slotIndex].isInUse = false
    }
}
