import Foundation
import Markdown
import Observation
import AppKit
import ApronCore

struct ComposerLink: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }

    func embed(metadata: JSONObject? = nil) -> JSONObject {
        var result: JSONObject = ["kind": .string("link"), "url": .string(id)]
        // Fallbacks are descriptive text. The server owns proxying preview media.
        if let metadata {
            let text = metadata.filter { ["title", "site_name", "description"].contains($0.key) && $0.value.string != nil }
            if !text.isEmpty { result["og"] = .object(text) }
        }
        return result
    }
}

/// A bounded, content-only cache avoids reparsing drafts when unrelated UI state changes.
@MainActor final class ComposerLinkDiscovery {
    static let shared = ComposerLinkDiscovery()
    private var entries: [String: [ComposerLink]] = [:]
    private var order: [String] = []

    func links(in source: String) -> [ComposerLink] {
        guard source.utf8.count <= 65_536 else { return [] }
        if let links = entries[source] { return links }
        var finder = ComposerLinkFinder()
        finder.visit(Document(parsing: source))
        if entries.count >= 100 { entries.removeValue(forKey: order.removeFirst()) }
        entries[source] = finder.links; order.append(source)
        return finder.links
    }
    func clear() { entries.removeAll(); order.removeAll() }
}

private struct ComposerLinkFinder: MarkupWalker {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var links: [ComposerLink] = []
    mutating func add(_ value: String) {
        guard links.count < 3, let url = URL(string: value), MediaPolicy.safeLink(url),
              let host = url.host, !host.isEmpty, !links.contains(where: { $0.url == url }) else { return }
        links.append(ComposerLink(url: url))
    }
    mutating func visitText(_ text: Markdown.Text) {
        guard links.count < 3 else { return }
        for match in Self.detector.matches(in: text.string, range: NSRange(text.string.startIndex..., in: text.string)) {
            if let url = match.url { add(url.absoluteString) }
        }
    }
    mutating func visitLink(_ link: Markdown.Link) { if let destination = link.destination { add(destination) } }
    mutating func visitImage(_ image: Markdown.Image) {}
    mutating func visitInlineCode(_ code: InlineCode) {}
    mutating func visitCodeBlock(_ code: CodeBlock) {}
}

/// Composer fetches never participate in message submission. Each send freezes
/// whichever unexpired metadata is ready, or just the selected URLs.
@MainActor @Observable final class ComposerLinkPreviewLoader {
    struct Request: Equatable {
        let key: DraftKey
        let links: [ComposerLink]
    }
    typealias Fetch = @Sendable (GitHubPreview, UUID, String) async -> GitHubPreviewMetadata?
    typealias WebFetch = @Sendable (URL) async -> ComposerWebPreview?
    private struct Entry {
        let metadata: JSONObject
        let image: NSImage?
        let expiresAt: Date
    }
    private var request: Request?
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let webFetch: WebFetch

    init(preview: Bool = false, delay: Duration = .milliseconds(350), fetch: @escaping Fetch = { link, server, account in
        await GitHubPreviewLoader.shared.load(link, server: server, account: account)
    }, webFetch: @escaping WebFetch = { url in await ComposerWebPreviewFetcher().load(url) }) {
        self.delay = delay
        if preview {
            let fixture = ComposerWebPreview(metadata: ["title": .string("A website with an image")],
                imageData: NSImage(named: NSImage.applicationIconName)?.tiffRepresentation)
            self.fetch = { _, _, _ in nil }
            self.webFetch = { _ in fixture }
        } else {
            self.fetch = fetch; self.webFetch = webFetch
        }
    }
    func metadata(for request: Request, now: Date = Date()) -> [String: JSONObject] {
        guard self.request == request else { return [:] }
        return entries.filter { $0.value.expiresAt > now && !$0.value.metadata.isEmpty }.mapValues(\.metadata)
    }
    func images(for request: Request, now: Date = Date()) -> [String: NSImage] {
        guard self.request == request else { return [:] }
        return entries.filter { $0.value.expiresAt > now }.compactMapValues(\.image)
    }
    func refresh(_ request: Request) async {
        let generation = UUID()
        self.generation = generation
        let selected = Set(request.links.map(\.id))
        entries = self.request?.key == request.key
            ? entries.filter { selected.contains($0.key) && $0.value.expiresAt > Date() } : [:]
        self.request = request
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled, self.generation == generation else { return }
        let fetch = fetch, webFetch = webFetch
        await withTaskGroup(of: (String, GitHubPreviewMetadata?, ComposerWebPreview?).self) { group in
            for link in request.links where entries[link.id] == nil {
                group.addTask {
                    async let web = webFetch(link.url)
                    let github: GitHubPreviewMetadata?
                    if let preview = GitHubPreview(link.id) {
                        github = await fetch(preview, request.key.server, request.key.account)
                    } else { github = nil }
                    return (link.id, github, await web)
                }
            }
            for await (id, github, web) in group {
                guard !Task.isCancelled, self.generation == generation else { group.cancelAll(); return }
                var metadata = web?.metadata ?? [:]
                if let github { metadata.merge(github.value) { _, github in github } }
                let expires = github?.expiresAt ?? Date().addingTimeInterval(web == nil ? 60 : 3600)
                entries[id] = Entry(metadata: metadata, image: web?.imageData.flatMap(AttachmentPresentation.thumbnail), expiresAt: expires)
            }
        }
    }
}
