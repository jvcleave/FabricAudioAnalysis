@testable import AudioAnalysisCore
import AVFoundation
import XCTest

final class LiveAudioSampleRingTests: XCTestCase
{
    func testOverflowKeepsNewestMixedSamples() throws
    {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 6
        ))
        buffer.frameLength = 6
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for sampleIndex in 0 ..< 6
        {
            channels[0][sampleIndex] = Float(sampleIndex * 2)
            channels[1][sampleIndex] = 0
        }

        let ring = LiveAudioSampleRing(capacity: 4)
        XCTAssertEqual(ring.droppedSampleCount, 0)
        ring.append(buffer)
        XCTAssertEqual(ring.droppedSampleCount, 2)
        XCTAssertEqual(ring.take(upTo: 8), [2, 3, 4, 5])
        XCTAssertTrue(ring.take(upTo: 8).isEmpty)
        XCTAssertEqual(ring.droppedSampleCount, 2)
    }

    func testContentionDropsWholeBufferAndCountingContinuesAfterRecovery() throws
    {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 6
        ))
        buffer.frameLength = 6
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for sampleIndex in 0 ..< 6
        {
            samples[sampleIndex] = Float(sampleIndex)
        }

        let lock = NSLock()
        let ring = LiveAudioSampleRing(capacity: 4, lock: lock)
        lock.lock()
        ring.append(buffer)
        XCTAssertEqual(ring.droppedSampleCount, 6)
        lock.unlock()
        XCTAssertTrue(ring.take(upTo: 8).isEmpty)

        ring.append(buffer)
        XCTAssertEqual(ring.droppedSampleCount, 8)
        XCTAssertEqual(ring.take(upTo: 8), [2, 3, 4, 5])
        XCTAssertEqual(ring.droppedSampleCount, 8)
    }
}
