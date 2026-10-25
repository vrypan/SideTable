import SwiftUI
import AppKit
import QuickLook
import ImageIO
import UniformTypeIdentifiers
import ApronCore

/// Presentation hints only; decoding still verifies that downloaded bytes are an image.
struct AttachmentPresentation {
    let embed: JSONObject
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
        let metadata = embed.object("og").object("image")
        if let width = metadata["width"]?.number, let height = metadata["height"]?.number, width > 0, height > 0, width < 1_000_000, height < 1_000_000 {
            return "\(format) · \(Int(width)) × \(Int(height))"
        }
        return format
    }
    static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 840
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

struct AttachmentView: View {
    let embed: JSONObject
    let endpoint: URL
    let serverID: UUID
    let account: String
    var mediaOrigins: [String] = []
    @State private var linkMetadata: JSONObject?
    @State private var image: NSImage?
    @State private var previewURL: URL?
    @State private var busy = false
    @State private var loadingImage = false
    @State private var imageLoadID = UUID()
    @State private var error: String?
    @State private var loadedSize: Int?
    private var presentation: AttachmentPresentation {
        var enriched = embed
        if let linkMetadata { enriched["og"] = .object(linkMetadata) }
        return AttachmentPresentation(embed: enriched)
    }
    private var url: URL? { presentation.url }
    private var title: String { presentation.title }
    private var imageSource: URL? {
        presentation.imageURL ?? embed.object("og").object("image").string("url").flatMap(URL.init(string:))
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
            } else if let image, presentation.imageURL != nil {
                Button { if let url { download(url, save: false) } } label: {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(!canDownload || busy)
                    .accessibilityLabel("Preview \(title)").help("Open in Quick Look")
                HStack(spacing: 8) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if busy { ProgressView().controlSize(.mini) }
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(for: presentation.fileType ?? .data))
                            .resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Button { if let url { download(url, save: false) } } label: {
                            Text(title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain).disabled(!canDownload || busy).help("Open in Quick Look")
                        Text(url == nil ? (embed.string("kind") == "upload" ? "Upload pending…" : "Preview unavailable") : detail)
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
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
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
        .task(id: LoadIdentity(embed: embed, endpoint: endpoint, origins: mediaOrigins, server: serverID, account: account)) {
            imageLoadID = UUID(); loadingImage = false
            image = nil; error = nil; loadedSize = nil; previewURL = nil; linkMetadata = nil
            if presentation.isLink, let url, let github = GitHubPreview(url.absoluteString),
               embed.object("og").string("title") == nil || embed.object("og") == github.fallback {
                let metadata = await GitHubPreviewLoader.shared.load(github, server: serverID, account: account)
                guard !Task.isCancelled else { return }
                linkMetadata = metadata
            }
            guard let imageURL = imageSource, allows(imageURL) else { return }
            await loadImage(imageURL, limit: 8 * 1024 * 1024, automatic: true)
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 210).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(presentation.linkSite).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption)
                }.foregroundStyle(.secondary)
                Text(presentation.linkTitle).font(.callout.weight(.semibold)).lineLimit(3)
                if let description = presentation.linkDescription {
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                if let host = url?.host, host != presentation.linkSite {
                    Text(host).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private struct LoadIdentity: Equatable { let embed: JSONObject; let endpoint: URL; let origins: [String]; let server: UUID; let account: String }

    private func loadImage(_ url: URL, limit: Int, automatic: Bool) async {
        let loadID = UUID()
        imageLoadID = loadID; loadingImage = true
        defer { if imageLoadID == loadID { loadingImage = false } }
        do {
            let data = try await fetch(url, limit: limit)
            try Task.checkCancellation()
            guard imageLoadID == loadID else { return }
            guard let thumbnail = AttachmentPresentation.thumbnail(data) else { throw URLError(.cannotDecodeContentData) }
            image = thumbnail; error = nil
            if url == self.url { loadedSize = data.count }
        } catch {
            if imageLoadID == loadID && !Task.isCancelled && !automatic { self.error = error.localizedDescription }
        }
    }

    private func download(_ url: URL, save: Bool) {
        guard !busy else { return }
        var destination: URL?
        let name = (title as NSString).lastPathComponent
        let filename = ["", ".", "..", "/"].contains(name) ? "Attachment" : name
        if save {
            let panel = NSSavePanel(); panel.nameFieldStringValue = filename
            guard panel.runModal() == .OK else { return }; destination = panel.url
        } else if previewURL != nil {
            // A fresh URL also lets Quick Look reopen the same attachment.
            previewURL = nil
        }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await fetch(url, limit: 64 * 1024 * 1024)
                loadedSize = data.count
                if let destination { try data.write(to: destination, options: .atomic) }
                else {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidetablePreviews").appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent(filename)
                    try data.write(to: file, options: .atomic); previewURL = file
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard allows(url) else { throw URLError(.unsupportedURL) }
        return try await MediaCache.shared.data(for: url, server: serverID, account: account, limit: limit)
    }
}
