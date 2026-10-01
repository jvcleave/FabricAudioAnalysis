import AudioAnalysisCore
import Foundation
import XCTest

final class AudioFrameAnalyzerTests: XCTestCase
{
    func testSilenceAndRepeatedToneHaveFiniteMeasurements() throws
    {
        let analyzer = try AudioFrameAnalyzer()
        let silence = [Float](repeating: 0, count: AudioFrameAnalyzer.fftSize)
        let silentFrame = try analyzer.analyze(samples: silence, sampleRate: 48_000)
        XCTAssertEqual(silentFrame.rms, 0)
        XCTAssertEqual(silentFrame.loudnessDB, -140)
        XCTAssertEqual(silentFrame.spectralCentroidHz, 0)
        XCTAssertEqual(silentFrame.spectralFlux, 0)

        let tone = (0 ..< AudioFrameAnalyzer.fftSize).map
        {
            sinf(2 * .pi * 1_000 * Float($0) / 48_000)
        }
        let firstToneFrame = try analyzer.analyze(samples: tone, sampleRate: 48_000)
        let repeatedToneFrame = try analyzer.analyze(samples: tone, sampleRate: 48_000)

        XCTAssertEqual(firstToneFrame.rms, 0.7, accuracy: 0.05)
        XCTAssertEqual(firstToneFrame.spectralCentroidHz, 1_000, accuracy: 250)
        XCTAssertGreaterThan(firstToneFrame.bandEnergies.mid, firstToneFrame.bandEnergies.bass)
        XCTAssertGreaterThan(firstToneFrame.bandEnergies.mid, firstToneFrame.bandEnergies.high)
        XCTAssertGreaterThan(firstToneFrame.spectralFlux, repeatedToneFrame.spectralFlux)
        XCTAssertTrue(repeatedToneFrame.rms.isFinite)
        XCTAssertTrue(repeatedToneFrame.spectralCentroidHz.isFinite)
    }

    func testOnsetDetectorRequiresHistoryAndRespectsRefractoryFrames()
    {
        let detector = AudioOnsetDetector()
        XCTAssertFalse(detector.detect(spectralFlux: 0, frameIndex: 0))
        XCTAssertFalse(detector.detect(spectralFlux: 0, frameIndex: 1))
        XCTAssertFalse(detector.detect(spectralFlux: 0, frameIndex: 2))
        XCTAssertTrue(detector.detect(spectralFlux: 12, frameIndex: 3))
        XCTAssertFalse(detector.detect(spectralFlux: 15, frameIndex: 4))
        XCTAssertFalse(detector.detect(spectralFlux: 0, frameIndex: 5))
        XCTAssertTrue(detector.detect(spectralFlux: 20, frameIndex: 6))
    }

    func testLowSampleRateKeepsUnavailableBandsAtZero() throws
    {
        let analyzer = try AudioFrameAnalyzer()
        let tone = (0 ..< AudioFrameAnalyzer.fftSize).map
        {
            sinf(2 * .pi * 440 * Float($0) / 3_000)
        }
        let frame = try analyzer.analyze(samples: tone, sampleRate: 3_000)

        XCTAssertGreaterThan(frame.bandEnergies.lowMid, 0)
        XCTAssertEqual(frame.bandEnergies.high, 0)
        XCTAssertTrue(frame.spectralCentroidHz.isFinite)
    }
}
