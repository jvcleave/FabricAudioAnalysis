import Foundation

public enum AudioFileAnalysisSettingsError: LocalizedError
{
    case staleBookmark
    case invalidFileURL

    public var errorDescription: String?
    {
        switch self
        {
            case .staleBookmark:
                return "The selected audio file bookmark is stale. Choose the file again in node settings."
            case .invalidFileURL:
                return "Choose a local audio file URL or absolute path for analysis."
        }
    }
}

/// New selections save a local file URL. Older saved graphs can still resolve
/// their security-scoped bookmarks.
public struct AudioFileAnalysisSettings: Codable, Equatable, Sendable
{
    public let bookmarkData: Data?
    public let fileURLString: String?
    public let fileName: String?
    public let analysisFramesPerSecond: Int

    public init(analysisFramesPerSecond: Int = 30)
    {
        bookmarkData = nil
        fileURLString = nil
        fileName = nil
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }

    public init(fileURL: URL, analysisFramesPerSecond: Int = 30)
    {
        bookmarkData = nil
        fileURLString = fileURL.absoluteString
        fileName = fileURL.lastPathComponent
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }

    public func changingFrameRate(to framesPerSecond: Int) -> Self
    {
        Self(
            bookmarkData: bookmarkData,
            fileURLString: fileURLString,
            fileName: fileName,
            analysisFramesPerSecond: framesPerSecond
        )
    }

    private init(bookmarkData: Data?, fileURLString: String?, fileName: String?, analysisFramesPerSecond: Int)
    {
        self.bookmarkData = bookmarkData
        self.fileURLString = fileURLString
        self.fileName = fileName
        self.analysisFramesPerSecond = analysisFramesPerSecond
    }

    func resolvedFileURL() throws -> URL?
    {
        if let fileURLString { return AudioFileSourceURL.resolve(fileURLString) }
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
