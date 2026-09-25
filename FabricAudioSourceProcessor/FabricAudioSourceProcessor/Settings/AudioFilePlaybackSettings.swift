import Foundation

public struct AudioFilePlaybackSettings: Codable, Equatable, Sendable
{
    public let bookmarkData: Data?
    public let fileURLString: String?
    public let fileName: String?

    public init()
    {
        bookmarkData = nil
        fileURLString = nil
        fileName = nil
    }

    public init(fileURL: URL)
    {
        bookmarkData = nil
        fileURLString = fileURL.absoluteString
        fileName = fileURL.lastPathComponent
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
