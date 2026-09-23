import Foundation

public enum AudioFileAnalysisSettingsError: LocalizedError
{
    case staleBookmark

    public var errorDescription: String?
    {
        switch self
        {
            case .staleBookmark:
                return "The selected audio file bookmark is stale. Choose the file again in node settings."
        }
    }
}

/// The bookmark travels with a saved graph; the source may need relinking on
/// another machine or after its security scope expires.
public struct AudioFileAnalysisSettings: Codable, Equatable, Sendable
{
    public let bookmarkData: Data?
    public let fileName: String?
    public let analysisFramesPerSecond: Int

    public init(analysisFramesPerSecond: Int = 30)
    {
        bookmarkData = nil
        fileName = nil
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }

    public init(fileURL: URL, analysisFramesPerSecond: Int = 30) throws
    {
        bookmarkData = try fileURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        fileName = fileURL.lastPathComponent
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }

    public func changingFrameRate(to framesPerSecond: Int) -> Self
    {
        Self(
            bookmarkData: bookmarkData,
            fileName: fileName,
            analysisFramesPerSecond: framesPerSecond
        )
    }

    private init(bookmarkData: Data?, fileName: String?, analysisFramesPerSecond: Int)
    {
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }

    func resolvedFileURL() throws -> URL?
    {
        guard let bookmarkData else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else
        {
            throw AudioFileAnalysisSettingsError.staleBookmark
        }
        return url
    }
}
