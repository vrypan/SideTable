import Foundation
import Markdown
import ApronCore

struct GitHubPreview: Equatable {
    let url: URL
    let apiURL: URL
    let repository: String
    let fallbackTitle: String
    let category: String

    init?(_ address: String) {
        guard let url = URL(string: address), MediaPolicy.safeLink(url),
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""),
              url.port == nil || url.port == 443 else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.prefix(2).allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil && $0 != "." && $0 != ".." }) else { return nil }
        let repository = parts[0] + "/" + parts[1]
        let base = "https://github.com/" + repository
        let api = "https://api.github.com/repos/" + repository
        if parts.count == 2 {
            self.url = URL(string: base)!; apiURL = URL(string: api)!
            fallbackTitle = repository; category = "Repository"
        } else if parts.count == 4, ["pull", "issues"].contains(parts[2]),
                  parts[3].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil {
            self.url = URL(string: base + "/" + parts[2] + "/" + parts[3])!
            apiURL = URL(string: api + "/issues/" + parts[3])!
            category = parts[2] == "pull" ? "Pull request" : "Issue"
            fallbackTitle = category + " #" + parts[3]
        } else if parts.count == 4, parts[2] == "commit",
                  parts[3].range(of: #"^[a-fA-F0-9]{7,40}$"#, options: .regularExpression) != nil {
            self.url = URL(string: base + "/commit/" + parts[3])!
            apiURL = URL(string: api + "/commits/" + parts[3])!
            category = "Commit"; fallbackTitle = "Commit " + parts[3].prefix(7)
        } else { return nil }
        self.repository = repository
    }

    var fallback: JSONObject {
        ["site_name": .string("GitHub · " + repository), "title": .string(fallbackTitle)]
    }
    var embed: JSONObject { ["kind": .string("link"), "url": .string(url.absoluteString), "og": .object(fallback)] }

    func metadata(_ response: JSONObject) -> JSONObject? {
        let title: String?
        let description: String?
        switch category {
        case "Repository": title = response.string("full_name"); description = response.string("description")
        case "Commit":
            let lines = response.object("commit").string("message")?.split(separator: "\n", maxSplits: 1).map(String.init) ?? []
            title = lines.first; description = lines.count > 1 ? lines[1] : nil
        default: title = response.string("title"); description = response.string("body")
        }
        guard let title, !title.isEmpty else { return nil }
        var result = fallback
        result["title"] = .string(title)
        var summary = [category]
        if let state = response.string("state") { summary.append(state.capitalized) }
        if let author = response.object("user").string("login") { summary.append("by " + author) }
        if let description, !description.isEmpty {
            let plain = description.replacingOccurrences(of: #"<!--[\s\S]*?(?:-->|$)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            summary.append(String(plain.prefix(240)))
        }
        result["description"] = .string(summary.joined(separator: " · "))
        return result
    }

    /// Supplement received messages, leaving existing embeds untouched. Code is never unfurled.
    static func missingEmbeds(in source: String, existing: [JSONObject], markdown: Bool) -> [JSONObject] {
        guard source.utf8.count <= 65_536 else { return [] }
        var finder = GitHubLinkFinder()
        if markdown { finder.visit(Document(parsing: source)) }
        else { finder.find(source) }
        let existingURLs = Set(existing.compactMap { $0.string("url") }.map { GitHubPreview($0)?.url.absoluteString ?? $0 })
        return finder.links.filter { !existingURLs.contains($0.url.absoluteString) }.prefix(3).map(\.embed)
    }
}

private struct GitHubLinkFinder: MarkupWalker {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var links: [GitHubPreview] = []
    mutating func find(_ text: String) {
        guard links.count < 3 else { return }
        for match in Self.detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let address = match.url?.absoluteString { add(address) }
        }
    }
    mutating func add(_ address: String) {
        if links.count < 3, let link = GitHubPreview(address), !links.contains(link) { links.append(link) }
    }
    mutating func visitImage(_ image: Markdown.Image) {}
    mutating func visitText(_ text: Markdown.Text) { find(text.string) }
    mutating func visitLink(_ link: Markdown.Link) { if let destination = link.destination { add(destination) } }
}

/// Extraction depends only on message content, not transient row or server state.
/// Bounded storage also preserves results across LazyVStack row reconstruction.
@MainActor final class GitHubPreviewCache {
    struct Input: Hashable {
        let source: String
        let existing: [JSONObject]
        let markdown: Bool
    }
    static let shared = GitHubPreviewCache()
    private let capacity: Int
    private let extract: (Input) -> [JSONObject]
    private var entries: [Input: [JSONObject]] = [:]
    private var order: [Input] = []

    init(capacity: Int = 300, extract: @escaping (Input) -> [JSONObject] = {
        GitHubPreview.missingEmbeds(in: $0.source, existing: $0.existing, markdown: $0.markdown)
    }) {
        self.capacity = max(1, capacity)
        self.extract = extract
    }
    func missingEmbeds(in source: String, existing: [JSONObject], markdown: Bool) -> [JSONObject] {
        guard source.utf8.count <= 65_536 else { return [] }
        let input = Input(source: source, existing: existing, markdown: markdown)
        if let result = entries[input] { return result }
        let result = extract(input)
        if entries.count >= capacity { entries.removeValue(forKey: order.removeFirst()) }
        entries[input] = result; order.append(input)
        return result
    }
    func clear() { entries.removeAll(); order.removeAll() }
}

struct GitHubPreviewMetadata: Sendable {
    let value: JSONObject
    let expiresAt: Date
}

actor GitHubPreviewLoader {
    static let shared = GitHubPreviewLoader()
    private var blockedUntil = Date.distantPast
    private var failures: [URL: Date] = [:]

    func load(_ link: GitHubPreview, server: UUID, account: String) async -> GitHubPreviewMetadata? {
        guard Date() >= blockedUntil, Date() >= (failures[link.url] ?? .distantPast) else { return nil }
        do {
            let data = try await MediaCache.shared.data(for: link.apiURL, server: server, account: account, limit: 1024 * 1024, maxAge: 3600)
            let response = try JSONDecoder().decode(JSONObject.self, from: data)
            guard let value = link.metadata(response) else { return nil }
            let expiresAt = await MediaCache.shared.expirationDate(for: link.apiURL, server: server, account: account, maxAge: 3600)
            return GitHubPreviewMetadata(value: value, expiresAt: expiresAt)
        } catch {
            if failures.count >= 100 { failures.removeAll() }
            failures[link.url] = Date().addingTimeInterval(300)
            // Avoid repeated unauthenticated requests after an API failure or rate limit.
            blockedUntil = Date().addingTimeInterval(60)
            return nil
        }
    }
}
