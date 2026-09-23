import AudioSourceProcessorCore
import XCTest

final class AudioWaveformRowTests: XCTestCase
{
    func testHistoryPadsOlderRowsAndKeepsSignedSamples() throws
    {
        let negative = AudioWaveformRow([-1, -0.5, 0, 0.5, 1][...])
        let positive = AudioWaveformRow([Float](repeating: 0.75, count: 64)[...])
        let history = AudioWaveformRow.flattenedHistory([negative, positive][...])

        XCTAssertEqual(
            history.count,
            AudioWaveformRow.sampleCount * AudioWaveformRow.maximumHistoryRows
        )
        let firstVisibleIndex = (AudioWaveformRow.maximumHistoryRows - 2)
            * AudioWaveformRow.sampleCount
        XCTAssertTrue(history[..<firstVisibleIndex].allSatisfy { $0 == 0 })
        XCTAssertEqual(history[firstVisibleIndex], -1)
        XCTAssertEqual(history[firstVisibleIndex + AudioWaveformRow.sampleCount - 1], 1)
        XCTAssertEqual(history.last ?? 0, 0.75, accuracy: 0.01)
    }
}
