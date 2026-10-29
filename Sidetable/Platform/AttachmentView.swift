import SwiftUI
import AppKit
import QuickLook
import ImageIO
import UniformTypeIdentifiers
import ApronCore

/// Presentation hints only; decoding still verifies that downloaded bytes are an image.
struct AttachmentPresentation {
    let embed: JSONObject
    init(embed: JSONObject, fallbackMetadata: JSONObject? = nil) {
        var enriched = embed
        if Self.githubFallback(for: embed) != nil, let fallbackMetadata { enriched["og"] = .object(fallbackMetadata) }
        self.embed = enriched
    }
    static func githubFallback(for embed: JSONObject) -> GitHubPreview? {
        guard embed.string("kind") != "upload", let address = embed.string("url"),
              let link = GitHubPreview(address),
              embed.object("og").string("title") == nil || embed.object("og") == link.fallback else { return nil }
        return link
    }
    var url: URL? { embed.string("url").flatMap(URL.init(string:)) }
    var title: String { embed.string("title") ?? embed.object("og").string("title") ?? url?.lastPathComponent.nonEmpty ?? "Attachment" }
    var isLink: Bool { embed.string("kind") != "upload" && (embed.string("kind") == "link" || !embed.object("og").isEmpty) }
    var linkTitle: String { embed.object("og").string("title")?.nonEmpty ?? embed.string("title")?.nonEmpty ?? url?.absoluteString ?? "Link" }
    var linkSite: String { embed.object("og").string("site_name")?.nonEmpty ?? url?.host ?? "Website" }
    var linkDescription: String? { embed.object("og").string("description")?.nonEmpty }
    var fileType: UTType? { UTType(filenameExtension: (title as NSString).pathExtension) }
    var imageURL: URL? {
        // A link's OG image is a thumbnail, not an uploaded image attachment.
        guard embed.string("kind") == "upload", embed.object("og").object("video").isEmpty,
              embed.object("og").object("audio").isEmpty else { return nil }
        if let fileType, !fileType.isDynamic, !fileType.conforms(to: .image) { return nil }
        if let address = embed.object("og").object("image").string("url") { return URL(string: address) }
        return fileType?.conforms(to: .image) == true ? url : nil
    }
    var detail: String {
        let format = fileType?.localizedDescription ?? (title as NSString).pathExtension.uppercased().nonEmpty ?? "File"
        if let size = reportedImageSize { return "\(format) · \(Int(size.width)) × \(Int(size.height))" }
        return format
    }
    static func thumbnail(_ data: Data) -> NSImage? {
        MediaCache.downsample(data).map { NSImage(cgImage: $0, size: .zero) }
    }
    /// Pixel dimensions the server or sender reported for the inline image, if plausible.
    var reportedImageSize: CGSize? {
        let metadata = embed.object("og").object("image")
        guard let width = metadata["width"]?.number, let height = metadata["height"]?.number,
              width > 0, height > 0, width < 1_000_000, height < 1_000_000 else { return nil }
        return CGSize(width: width, height: height)
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

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

struct AttachmentView: View {
    let embed: JSONObject
    let endpoint: URL
    let serverID: UUID
    let account: String
    var mediaOrigins: [String] = []
    @State private var linkMetadata: GitHubPreviewMetadata?
    @State private var image: NSImage?
    @State private var previewURL: URL?
    @State private var previewTask: Task<Void, Never>?
    @State private var busy = false
    @State private var loadingImage = false
    @State private var imageLoadID = UUID()
    @State private var error: String?
    @State private var loadedSize: Int?
    @State private var imageFailed = false
    private var presentation: AttachmentPresentation {
        let local = linkMetadata.flatMap { $0.expiresAt > Date() ? $0.value : nil }
        return AttachmentPresentation(embed: embed, fallbackMetadata: local ?? linkKey.flatMap(AttachmentRenderCache.shared.metadata))
    }
    private var linkKey: String? { AttachmentPresentation(embed: embed).url.map(renderKey) }
    private func renderKey(_ url: URL) -> String { AttachmentRenderCache.key(url, server: serverID, account: account) }
    /// LazyVStack rebuilds rows it scrolled away from. Showing an already decoded image
    /// in the first frame keeps the row from shrinking and regrowing under the reader.
    private var shownImage: NSImage? {
        image ?? imageSource.flatMap { allows($0) ? AttachmentRenderCache.shared.image(renderKey($0)) : nil }
    }
    private var url: URL? { presentation.url }
    private var title: String { presentation.title }
    private var imageSource: URL? {
        presentation.imageURL ?? embed.object("og").object("image").string("url").flatMap(URL.init(string:))
    }
    /// The inline image's size before it loads, so its row keeps its final height.
    private var expectedImageSize: CGSize? {
        guard !imageFailed, let source = imageSource, allows(source) else { return nil }
        if let size = presentation.reportedImageSize { return size }
        return AttachmentRenderCache.shared.imageSize(renderKey(source)) {
            MediaCache.shared.thumbnailPixelSize(for: source, server: serverID, account: account)
        }
    }
    private func allows(_ url: URL) -> Bool { MediaPolicy.allows(url, endpoint: endpoint, mediaOrigins: mediaOrigins) }
    private var canDownload: Bool { !presentation.isLink && (url.map(allows) ?? false) }
    private var detail: String {
        presentation.detail + (loadedSize.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if presentation.isLink {
                if let url, MediaPolicy.safeLink(url) {
                    Link(destination: url) { linkCard }.buttonStyle(.plain)
                } else { linkCard }
            } else if let image = shownImage, presentation.imageURL != nil {
                Button { if let url { download(url, save: false) } } label: {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(!canDownload || busy)
                    .accessibilityLabel("Preview \(title)").help("Open in Quick Look")
                HStack(spacing: 8) {
                    Text(userText: title).lineLimit(1).truncationMode(.middle)
                    if busy { ProgressView().controlSize(.mini) }
                }.font(.caption).foregroundStyle(.secondary)
            } else if presentation.imageURL != nil, let size = expectedImageSize {
                imagePlaceholder(size, maxHeight: 300)
                Text(userText: title).lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    if let image = shownImage {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(for: presentation.fileType ?? .data))
                            .resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Button { if let url { download(url, save: false) } } label: {
                            Text(userText: title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain).disabled(!canDownload || busy).help("Open in Quick Look")
                        Text(userText: url == nil ? (embed.string("kind") == "upload" ? "Upload pending…" : "Preview unavailable") : detail)
                            .font(.caption).foregroundStyle(.secondary)
                        if let imageURL = presentation.imageURL, allows(imageURL), !loadingImage {
                            Button("Load image") { Task { await loadImage(imageURL, limit: 64 * 1024 * 1024, automatic: false) } }
                                .font(.caption).disabled(busy)
                        } else if canDownload {
                            Button("Preview") { if let url { download(url, save: false) } }.font(.caption).disabled(busy)
                        } else if let url, MediaPolicy.safeLink(url) {
                            Link("Open in Browser", destination: url).font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                    if busy || loadingImage { ProgressView().controlSize(.small) }
                    if canDownload {
                        Button { if let url { download(url, save: true) } } label: { Image(systemName: "arrow.down.to.line") }
                            .buttonStyle(.borderless).help("Save attachment…").accessibilityLabel("Save \(title)").disabled(busy)
                    }
                }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error { Text(userText: error).font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .contextMenu {
            if let url, MediaPolicy.safeLink(url) {
                if canDownload {
                    Button("Preview") { download(url, save: false) }.disabled(busy)
                    Button("Save…") { download(url, save: true) }.disabled(busy)
                }
                Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                Link("Open in Browser", destination: url)
            }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { old, new in
            if let old, old != new { Task { await MediaCache.shared.releasePreview(old) } }
        }
        .onDisappear { dismissPreview() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaCacheCleared)) { notification in
            if notification.object == nil || notification.object as? UUID == serverID { dismissPreview() }
        }
        .task(id: LoadIdentity(embed: embed, endpoint: endpoint, origins: mediaOrigins, server: serverID, account: account)) {
            imageLoadID = UUID(); loadingImage = false
            image = nil; error = nil; loadedSize = nil; previewURL = nil; imageFailed = false
            guard let imageURL = imageSource, allows(imageURL),
                  AttachmentRenderCache.shared.image(renderKey(imageURL)) == nil else { return }
            await loadImage(imageURL, limit: 8 * 1024 * 1024, automatic: true)
        }
        .task(id: LoadIdentity(embed: embed, endpoint: endpoint, origins: mediaOrigins, server: serverID, account: account)) {
            linkMetadata = nil
            guard let github = AttachmentPresentation.githubFallback(for: embed), let key = linkKey else { return }
            while !Task.isCancelled {
                let entry: GitHubPreviewMetadata?
                if let cached = AttachmentRenderCache.shared.metadataEntry(key) { entry = cached }
                else { entry = await GitHubPreviewLoader.shared.load(github, server: serverID, account: account) }
                guard !Task.isCancelled, let entry else { return }
                linkMetadata = entry
                AttachmentRenderCache.shared.store(metadata: entry.value, key, expiresAt: entry.expiresAt)
                do { try await Task.sleep(for: .seconds(max(1, entry.expiresAt.timeIntervalSinceNow))) }
                catch { return }
                linkMetadata = nil
            }
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = shownImage {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 210).accessibilityHidden(true)
            } else if let size = expectedImageSize {
                imagePlaceholder(size, maxHeight: 210)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(userText: presentation.linkSite).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption)
                }.foregroundStyle(.secondary)
                Text(userText: presentation.linkTitle).font(.callout.weight(.semibold)).lineLimit(3)
                if let description = presentation.linkDescription {
                    Text(userText: description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                if let host = url?.host, host != presentation.linkSite {
                    Text(userText: host).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Lays out exactly like the loaded image: resizable, scaled to fit, and bounded the same way.
    private func imagePlaceholder(_ size: CGSize, maxHeight: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3))
            .aspectRatio(size, contentMode: .fit)
            .overlay { if loadingImage { ProgressView().controlSize(.small) } }
            .frame(maxWidth: 420, maxHeight: maxHeight, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel(loadingImage ? "Loading \(title)" : title)
    }

    private struct LoadIdentity: Equatable { let embed: JSONObject; let endpoint: URL; let origins: [String]; let server: UUID; let account: String }

    private func loadImage(_ url: URL, limit: Int, automatic: Bool) async {
        let loadID = UUID()
        imageLoadID = loadID; loadingImage = true
        defer { if imageLoadID == loadID { loadingImage = false } }
        do {
            guard allows(url) else { throw URLError(.unsupportedURL) }
            // Decoding runs on the cache actor, away from the main thread.
            let loaded = try await MediaCache.shared.thumbnail(for: url, server: serverID, account: account, limit: limit)
            try Task.checkCancellation()
            guard imageLoadID == loadID else { return }
            let thumbnail = NSImage(cgImage: loaded.image, size: .zero)
            image = thumbnail; error = nil; imageFailed = false
            AttachmentRenderCache.shared.store(image: thumbnail, renderKey(url))
            if url == self.url, let size = loaded.originalSize { loadedSize = size }
        } catch {
            guard imageLoadID == loadID && !Task.isCancelled else { return }
            if automatic { imageFailed = true } else { self.error = error.localizedDescription }
        }
    }

    private func download(_ url: URL, save: Bool) {
        guard !busy else { return }
        var destination: URL?
        let name = (UserText.clean(title) as NSString).lastPathComponent
        let filename = ["", ".", "..", "/"].contains(name) ? "Attachment" : name
        if save {
            let panel = NSSavePanel(); panel.nameFieldStringValue = filename
            guard panel.runModal() == .OK else { return }; destination = panel.url
        } else if previewURL != nil {
            // A fresh URL also lets Quick Look reopen the same attachment.
            dismissPreview()
        }
        busy = true; error = nil
        let task = Task { @MainActor in
            defer { busy = false }
            do {
                if let destination {
                    let data = try await fetch(url, limit: 64 * 1024 * 1024)
                    loadedSize = data.count
                    try data.write(to: destination, options: .atomic)
                } else {
                    guard allows(url) else { throw URLError(.unsupportedURL) }
                    let file = try await MediaCache.shared.previewFile(for: url, server: serverID, account: account, filename: filename)
                    guard !Task.isCancelled else { await MediaCache.shared.releasePreview(file); return }
                    previewURL = file
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        if !save { previewTask = task }
    }
    private func dismissPreview() {
        previewTask?.cancel(); previewTask = nil
        if let file = previewURL { Task { await MediaCache.shared.releasePreview(file) } }
        previewURL = nil
    }
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard allows(url) else { throw URLError(.unsupportedURL) }
        return try await MediaCache.shared.data(for: url, server: serverID, account: account, limit: limit)
    }
}
