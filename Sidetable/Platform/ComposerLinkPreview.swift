import Foundation
import Markdown
import Observation
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
    private var request: Request?
    private var entries: [String: GitHubPreviewMetadata] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let delay: Duration

    init(delay: Duration = .milliseconds(350), fetch: @escaping Fetch = { link, server, account in
        await GitHubPreviewLoader.shared.load(link, server: server, account: account)
    }) {
        self.delay = delay; self.fetch = fetch
    }
    func metadata(for request: Request, now: Date = Date()) -> [String: JSONObject] {
        guard self.request == request else { return [:] }
        return entries.filter { $0.value.expiresAt > now }.mapValues(\.value)
    }
    func refresh(_ request: Request) async {
        let generation = UUID()
        self.generation = generation
        self.request = request; entries = [:]
        do { try await Task.sleep(for: delay) } catch { return }
        for link in request.links {
            guard !Task.isCancelled, self.generation == generation else { return }
            guard let github = GitHubPreview(link.id) else { continue }
            let metadata = await fetch(github, request.key.server, request.key.account)
            guard !Task.isCancelled, self.generation == generation else { return }
            if let metadata { entries[link.id] = metadata }
        }
    }
}
