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
