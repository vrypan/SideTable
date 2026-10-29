import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Avatars are raster images, never documents. Credentials and redirects are not accepted.
enum AvatarLoader {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumPixels = 16_000_000
    static func inlineData(_ source: String) -> Data? {
        guard source.utf8.count <= maximumBytes * 4 / 3 + 128,
              let comma = source.firstIndex(of: ","),
              ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(source[..<comma].lowercased()),
              let data = Data(base64Encoded: String(source[source.index(after: comma)...])), data.count <= maximumBytes else { return nil }
        return data
    }
    static func remoteURL(_ source: String, endpoint: URL) -> URL? {
        guard let url = URL(string: source), MediaPolicy.safeLink(url),
              MediaPolicy.allows(url, endpoint: endpoint) || url.scheme == "https" else { return nil }
        return url
    }
    static func load(_ source: String, endpoint: URL) async throws -> Data {
        if source.lowercased().hasPrefix("data:") {
            guard let data = inlineData(source) else { throw URLError(.cannotDecodeContentData) }
            return data
        }
        guard let url = remoteURL(source, endpoint: endpoint) else { throw URLError(.unsupportedURL) }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData); request.timeoutInterval = 20
        return try await BoundedDownload.data(for: request, session: session, limit: maximumBytes) { response in
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  response.expectedContentLength <= maximumBytes else { throw URLError(.badServerResponse) }
        }.0
    }
    @MainActor static func image(_ data: Data) -> NSImage? {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels / height,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}
