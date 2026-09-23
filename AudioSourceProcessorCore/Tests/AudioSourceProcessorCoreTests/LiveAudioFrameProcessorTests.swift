import AudioSourceProcessorCore
import XCTest

final class LiveAudioFrameProcessorTests: XCTestCase
{
    func testRollingWindowExpiresOldPeakAndResetRestartsTime() throws
    {
        let processor = try LiveAudioFrameProcessor()
        let loudSamples = [Float](repeating: 1, count: AudioFrameAnalyzer.fftSize)
        let quietSamples = [Float](repeating: 0.1, count: AudioFrameAnalyzer.fftSize)

        let loud = try processor.process(
            samples: loudSamples,
            rmsSampleCount: 1600,
            sampleRate: 48_000
        )
        let quiet = try processor.process(
            samples: quietSamples,
            rmsSampleCount: 1600,
            sampleRate: 48_000
        )
        XCTAssertEqual(loud.rmsNormalized, 1)
        XCTAssertEqual(quiet.rmsNormalized, 0.1, accuracy: 0.001)
        XCTAssertEqual(quiet.frameIndex, 1)
        XCTAssertEqual(quiet.timeSeconds, 1 / 30, accuracy: 0.001)

        var settled = quiet
        for _ in 0 ..< LiveAudioFrameProcessor.normalizationFrameCount - 1
        {
            settled = try processor.process(
                samples: quietSamples,
                rmsSampleCount: 1600,
                sampleRate: 48_000
            )
        }
        XCTAssertEqual(settled.rmsNormalized, 1, accuracy: 0.001)
        XCTAssertTrue(settled.peakHeldRMS.isFinite)
        XCTAssertTrue(settled.fastEnvelope.isFinite)

        processor.reset()
        let restarted = try processor.process(
            samples: quietSamples,
            rmsSampleCount: 1600,
            sampleRate: 48_000
        )
        XCTAssertEqual(restarted.frameIndex, 0)
        XCTAssertEqual(restarted.timeSeconds, 0)
        XCTAssertEqual(restarted.rmsNormalized, 1)
    }
}
