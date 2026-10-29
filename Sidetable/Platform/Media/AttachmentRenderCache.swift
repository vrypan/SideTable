import SwiftUI
import AppKit
import QuickLook
import ImageIO
import UniformTypeIdentifiers
import ApronCore

/// Decoded thumbnails and link metadata for attachments already shown, scoped by
/// server and account. The disk cache stays authoritative; this only avoids an
/// asynchronous reload, and the height change it causes, when a row is rebuilt.
@MainActor final class AttachmentRenderCache {
    static let shared = AttachmentRenderCache()
    private final class Metadata { let entry: GitHubPreviewMetadata; init(_ entry: GitHubPreviewMetadata) { self.entry = entry } }
    private let images = NSCache<NSString, NSImage>()
    private var sizes: [String: CGSize?] = [:]
    private let metadata = NSCache<NSString, Metadata>()
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init, imageByteLimit: Int = 64 * 1024 * 1024) {
        self.now = now
        images.countLimit = 300
        images.totalCostLimit = max(1, imageByteLimit)
        metadata.countLimit = 500
    }
    nonisolated static func key(_ url: URL, server: UUID, account: String) -> String {
        "\(server.uuidString)|\(account)|\(url.absoluteString)"
    }
    func image(_ key: String) -> NSImage? { images.object(forKey: key as NSString) }
    func store(image: NSImage, _ key: String) {
        storeSize(image.size, key)
        // Pixel storage, not compressed file size or point dimensions, determines
        // the decoded memory cost. Keep dimensions even when an image cannot fit.
        images.removeObject(forKey: key as NSString)
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let cost = bitmap.bytesPerRow * bitmap.height
        guard cost <= images.totalCostLimit else { return }
        images.setObject(image, forKey: key as NSString, cost: cost)
    }
    /// Remembers image sizes, including unknown ones, so repeated renders do not touch the disk.
    func imageSize(_ key: String, lookup: () -> CGSize?) -> CGSize? {
        if let known = sizes[key] { return known }
        let size = lookup()
        storeSize(size, key)
        return size
    }
    private func storeSize(_ size: CGSize?, _ key: String) {
        if sizes.count >= 2000 { sizes.removeAll() }
        sizes[key] = .some(size)
    }
    func metadataEntry(_ key: String) -> GitHubPreviewMetadata? {
        guard let entry = metadata.object(forKey: key as NSString)?.entry else { return nil }
        guard entry.expiresAt > now() else { metadata.removeObject(forKey: key as NSString); return nil }
        return entry
    }
    func metadata(_ key: String) -> JSONObject? { metadataEntry(key)?.value }
    func store(metadata value: JSONObject, _ key: String, expiresAt: Date? = nil) {
        metadata.setObject(Metadata(GitHubPreviewMetadata(value: value, expiresAt: expiresAt ?? now().addingTimeInterval(3600))), forKey: key as NSString)
    }
    func clear() { images.removeAllObjects(); metadata.removeAllObjects(); sizes.removeAll() }
}
