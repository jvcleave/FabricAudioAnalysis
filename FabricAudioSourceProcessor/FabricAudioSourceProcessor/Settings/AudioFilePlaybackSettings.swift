import Foundation

public struct AudioFilePlaybackSettings: Codable, Equatable, Sendable
{
    public let bookmarkData: Data?
    public let fileName: String?

    public init()
    {
        bookmarkData = nil
        fileName = nil
    }

    public init(fileURL: URL) throws
    {
        bookmarkData = try fileURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        fileName = fileURL.lastPathComponent
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
