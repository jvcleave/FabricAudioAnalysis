import Foundation

enum AudioFileSourceURL
{
    static func resolve(_ value: String) -> URL?
    {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        if trimmedValue.hasPrefix("file://")
        {
            guard let url = URL(string: trimmedValue), url.isFileURL else { return nil }
            return url
        }
        guard trimmedValue.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmedValue)
    }
}
