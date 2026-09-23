import AudioSourceProcessorCore
import Foundation
import XCTest

final class AudioFileProcessorTests: XCTestCase
{
    func testChunkedFileAnalysisAndGraphTimeSelection() async throws
    {
        let audioURL = URL.temporaryDirectory.appending(path: "fabric-audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeTestWave(to: audioURL)

        let analysis = try await AudioFileProcessor().process(
            url: audioURL,
            framesPerSecond: 30
        )

        XCTAssertEqual(analysis.frameCount, 30)
        XCTAssertEqual(analysis.durationSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(analysis.framesPerSecond, 30, accuracy: 0.001)
        XCTAssertEqual(analysis.frames[0].measurements.rms, 0)
        XCTAssertGreaterThan(analysis.frames[15].measurements.rms, 0.6)
        XCTAssertGreaterThan(
            analysis.frames[15].bandsNormalized.mid,
            analysis.frames[15].bandsNormalized.bass
        )
        XCTAssertEqual(analysis.frames.map(\.rmsNormalized).max(), 1)
        XCTAssertTrue(analysis.frames.allSatisfy { $0.rmsNormalized.isFinite })

        XCTAssertEqual(analysis.frame(at: 0.9, loop: false)?.frameIndex, 27)
        XCTAssertEqual(analysis.frame(at: 0.1, loop: false)?.frameIndex, 3)
        XCTAssertEqual(analysis.frame(at: 1.5, loop: false)?.frameIndex, 29)
        XCTAssertEqual(analysis.frame(at: -0.1, loop: true)?.frameIndex, 27)
        XCTAssertEqual(analysis.frame(at: 1.1, loop: true)?.frameIndex, 3)
    }

    /// A one-second PCM16 WAV crosses several 8192-sample decoding chunks.
    private func writeTestWave(to url: URL) throws
    {
        let sampleRate: UInt32 = 48_000
        let sampleCount = Int(sampleRate)
        let audioByteCount = UInt32(sampleCount * MemoryLayout<Int16>.size)
        var wave = Data()

        wave.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 + audioByteCount, to: &wave)
        wave.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &wave)
        appendLittleEndian(UInt16(1), to: &wave)
        appendLittleEndian(UInt16(1), to: &wave)
        appendLittleEndian(sampleRate, to: &wave)
        appendLittleEndian(sampleRate * 2, to: &wave)
        appendLittleEndian(UInt16(2), to: &wave)
        appendLittleEndian(UInt16(16), to: &wave)
        wave.append(contentsOf: "data".utf8)
        appendLittleEndian(audioByteCount, to: &wave)

        for sampleIndex in 0 ..< sampleCount
        {
            let amplitude: Double = sampleIndex < sampleCount / 4
                ? 0
                : sin(2 * .pi * 1_000 * Double(sampleIndex) / Double(sampleRate))
            let sample = Int16(amplitude * 32_767)
            appendLittleEndian(sample, to: &wave)
        }

        try wave.write(to: url)
    }

    private func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data)
    {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
    }
}
