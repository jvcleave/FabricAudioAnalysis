import AudioAnalysisCore
import XCTest

final class AudioOnsetTrailTests: XCTestCase
{
    func testTrailMovesOnRenderTimeWithoutNewAudioAndExpires() throws
    {
        let trail = AudioOnsetTrail()
        trail.update(at: 0, onset: true, intensity: 0.8)
        trail.update(at: 0, onset: true, intensity: 0.8)
        XCTAssertEqual(trail.count, 1)
        var columns = [Float](repeating: 0, count: 64)
        columns.withUnsafeMutableBufferPointer { trail.writeColumns(into: $0, at: 0, duration: 4) }
        XCTAssertEqual(columns[32], 0.8)
        trail.update(at: 2, onset: false, intensity: 0)
        columns.withUnsafeMutableBufferPointer { trail.writeColumns(into: $0, at: 2, duration: 4) }
        XCTAssertEqual(columns[32], 0)
        XCTAssertEqual(columns[16], 0.8)
        columns.withUnsafeMutableBufferPointer { trail.writeColumns(into: $0, at: 5, duration: 4) }
        XCTAssertTrue(columns.allSatisfy { $0 == 0 })
        XCTAssertEqual(trail.flashStrength(at: 0.1), 0.5, accuracy: 0.001)
        XCTAssertEqual(trail.flashStrength(at: 0.3), 0)
    }

    func testBoundedHistoryAndRewindDiscardPreviousTimeline()
    {
        let trail = AudioOnsetTrail(capacity: 2)
        for eventIndex in 0 ..< 4 { trail.update(at: Double(eventIndex), onset: true, intensity: 1) }
        XCTAssertEqual(trail.count, 2)
        var columns = [Float](repeating: 0, count: 64)
        columns.withUnsafeMutableBufferPointer { trail.writeColumns(into: $0, at: 3, duration: 4) }
        XCTAssertEqual(columns.filter { $0 > 0 }.count, 2)
        trail.update(at: 0, onset: false, intensity: 0)
        XCTAssertEqual(trail.count, 0)
        columns.withUnsafeMutableBufferPointer { trail.writeColumns(into: $0, at: 0, duration: 4) }
        XCTAssertTrue(columns.allSatisfy { $0 == 0 })
    }
}
