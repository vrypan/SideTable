import SwiftUI
import Markdown
import ApronCore

struct ApronLinkPreview {
    let url: URL
    let title: String
    let detail: String
    let kind: String
    let icon: String

    /// Normalize equivalent link formats for deduplication without retaining tokens.
    static func destination(_ address: String, endpoint: String? = nil) -> URL? {
        guard let link = try? ApronLink(address, relativeTo: endpoint), link.token == nil,
              endpoint == nil || (try? ServerAddress.normalize(endpoint!)) == link.server else { return nil }
        var fields = ["server=" + ApronLink.encode(link.server.absoluteString)]
        for (key, value) in [("room", link.room), ("message", link.message), ("user", link.user)] {
            if let value { fields.append(key + "=" + ApronLink.encode(value)) }
        }
        return URL(string: "https://link.apron.chat/#" + fields.joined(separator: "&"))
    }

    init?(address: String, endpoint: String, store: RecordStore, serverTitle: String) {
        guard let url = Self.destination(address, endpoint: endpoint), let link = try? ApronLink(url.absoluteString) else { return nil }
        self.url = url
        if let room = link.room {
            let record = store.rooms[room] ?? [:]
            title = record.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? room
            if let id = link.message {
                kind = "Message"; icon = "bubble.left"
                if let message = store.messages[id], message.string("room_id") == room {
                    if message.bool("deleted") { detail = "Message deleted" }
                    else {
                        let body = message.object("body")
                        let text = Self.excerpt(body.string("text") ?? "", markdown: body.string("format") == "markdown")
                        detail = store.displayName(message.object("from")) + ": " + (text.isEmpty ? "Attachment" : text)
                    }
                } else { detail = "Open to view this message" }
            } else {
                kind = record.string("parent_room_id") == nil ? "Room" : "Thread"
                icon = record.string("parent_room_id") == nil ? "number" : "arrow.turn.down.right"
                detail = Self.excerpt(record.string("description") ?? "", markdown: true)
            }
        } else if let user = link.user {
            let profile = UserProfile(recorded: ["user_id": .string(user)], store: store)
            title = profile.name; detail = profile.bio ?? "@" + profile.id
            kind = "Profile"; icon = "person.crop.circle"
        } else {
            title = serverTitle; detail = link.server.host ?? link.server.absoluteString
            kind = "Server"; icon = "bubble.left.and.bubble.right"
        }
    }

    private static func excerpt(_ text: String, markdown: Bool) -> String {
        let bounded = String(text.prefix(1024))
        let parsed = markdown ? try? AttributedString(markdown: bounded, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) : nil
        return String(parsed?.characters ?? AttributedString(bounded).characters)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Cache only parsed URLs. Card details are always resolved from the source account's store.
@MainActor final class ApronLinkDiscovery {
    static let shared = ApronLinkDiscovery()
    private struct Key: Hashable { let text: String; let markdown: Bool }
    private var cache: [Key: [String]] = [:]
    private var order: [Key] = []

    func missingEmbeds(in text: String, markdown: Bool, endpoint: String, existing: [JSONObject]) -> [JSONObject] {
        guard text.utf8.count <= 65_536 else { return [] }
        let key = Key(text: text, markdown: markdown)
        let addresses: [String]
        if let cached = cache[key] { addresses = cached }
        else {
            var finder = ApronLinkFinder()
            if markdown { finder.visit(Document(parsing: text)) }
            else { finder.scan(text) }
            addresses = finder.addresses
            if order.count >= 100 { cache.removeValue(forKey: order.removeFirst()) }
            cache[key] = addresses; order.append(key)
        }
        var seen = Set(existing.filter { $0.string("kind") != "upload" }.compactMap {
            $0.string("url").flatMap { ApronLinkPreview.destination($0, endpoint: endpoint)?.absoluteString }
        })
        var embeds: [JSONObject] = []
        for address in addresses {
            guard let url = ApronLinkPreview.destination(address, endpoint: endpoint), seen.insert(url.absoluteString).inserted else { continue }
            embeds.append(["kind": .string("link"), "url": .string(url.absoluteString)])
            if embeds.count == 3 { break }
        }
        return embeds
    }
}

private struct ApronLinkFinder: MarkupWalker {
    private static let pattern = try! NSRegularExpression(pattern: #"(?:https://link\.apron\.chat/?#|apron:\?|sidetable://open/?\?)[^\s<>"`]+"#, options: .caseInsensitive)
    var addresses: [String] = []
    mutating func scan(_ text: String) {
        for match in Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard addresses.count < 32, let range = Range(match.range, in: text) else { break }
            add(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!)]}")))
        }
    }
    mutating func add(_ address: String) { if addresses.count < 32 { addresses.append(address) } }
    mutating func visitText(_ text: Markdown.Text) { scan(text.string) }
    mutating func visitLink(_ link: Markdown.Link) { if let address = link.destination { add(address) } }
    mutating func visitImage(_ image: Markdown.Image) {}
    mutating func visitInlineCode(_ code: InlineCode) {}
    mutating func visitCodeBlock(_ code: CodeBlock) {}
}

struct ApronLinkPreviewCard: View {
    let preview: ApronLinkPreview
    let serverTitle: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Label(preview.kind + " · " + serverTitle, systemImage: preview.icon)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(preview.title).font(.callout.weight(.semibold)).lineLimit(2)
                if !preview.detail.isEmpty {
                    Text(preview.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(12).frame(maxWidth: 420, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open " + preview.title)
        .accessibilityIdentifier("apronLinkPreview-" + preview.url.absoluteString)
    }
}
