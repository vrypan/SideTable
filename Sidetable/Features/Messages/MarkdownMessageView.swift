import SwiftUI
import AppKit
import Markdown
import ApronCore

extension SwiftUI.Text {
    /// Isolate each separately supplied user string from surrounding UI text.
    init(userText: String) { self.init(verbatim: UserText.isolated(userText)) }
}

struct MessageBlock: Identifiable {
    enum Kind: Equatable { case paragraph, paragraphGroup, heading(Int), code(String), rule }
    let id: Int
    let kind: Kind
    var text: AttributedString
    var indent: Int = 0
    var quote: Bool = false
    var marker: String = ""
}

/// Paragraph geometry carried through the parsed-text cache into native rendering.
/// Headings, quote rules, code blocks and separators retain their own views.
struct MessageParagraphLayout: Hashable, Sendable {
    var indent: Int
    var marker: String
    var firstLine: Bool
    var gapBefore: Bool
    var markerRun: Bool = false
}

enum MessageParagraphAttribute: AttributedStringKey {
    typealias Value = MessageParagraphLayout
    static let name = "SideTableMessageParagraph"
}

extension MessageBlock {
    static func coalesced(_ blocks: [Self]) -> [Self] {
        var result: [Self] = []
        var pending: [Self] = []
        func flush() {
            guard pending.count > 1 else {
                result.append(contentsOf: pending); pending.removeAll(keepingCapacity: true); return
            }
            var text = AttributedString()
            for (index, block) in pending.enumerated() {
                if index > 0 { text += AttributedString("\n") }
                var remaining = block.text[block.text.startIndex..<block.text.endIndex]
                var firstLine = true
                repeat {
                    let end = remaining.characters.firstIndex(of: "\n")
                        .map { remaining.characters.index(after: $0) } ?? remaining.endIndex
                    var line = AttributedString(remaining[remaining.startIndex..<end])
                    let layout = MessageParagraphLayout(indent: block.indent, marker: block.marker,
                                                        firstLine: firstLine, gapBefore: firstLine && index > 0)
                    line[MessageParagraphAttribute.self] = layout
                    if firstLine && !block.marker.isEmpty {
                        var marker = AttributedString("\t" + block.marker + "\t")
                        var markerLayout = layout; markerLayout.markerRun = true
                        marker[MessageParagraphAttribute.self] = markerLayout
                        text += marker
                    }
                    text += line
                    remaining = remaining[end..<remaining.endIndex]
                    firstLine = false
                } while !remaining.characters.isEmpty
            }
            result.append(Self(id: pending[0].id, kind: .paragraphGroup, text: text))
            pending.removeAll(keepingCapacity: true)
        }
        for block in blocks {
            if block.kind == .paragraph && !block.quote { pending.append(block) }
            else { flush(); result.append(block) }
        }
        flush()
        return result
    }
}

/// Presentation only: wire text and mention IDs remain unchanged.
enum MentionDisplay {
    private static let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])@([A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?)"#)

    static func text(_ source: String, names: [String: String]) -> String {
        String(attributed(source, names: names).characters)
    }

    static func attributed(_ source: String, names: [String: String]) -> AttributedString {
        var result = AttributedString()
        var cursor = source.startIndex
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let idRange = Range(match.range(at: 1), in: source),
                  let name = names[String(source[idRange])], !name.isEmpty,
                  let range = Range(match.range, in: source) else { continue }
            result += AttributedString(String(source[cursor..<range.lowerBound]))
            var mention = AttributedString("@" + name)
            var destination = URLComponents()
            destination.scheme = "sidetable-mention"; destination.host = "user"
            destination.queryItems = [URLQueryItem(name: "id", value: String(source[idRange]))]
            mention.link = destination.url
            result += mention
            cursor = range.upperBound
        }
        result += AttributedString(String(source[cursor...]))
        return result
    }

    static func userID(_ url: URL, names: [String: String]) -> String? {
        guard url.scheme == "sidetable-mention", url.host == "user",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
              names[id] != nil else { return nil }
        return id
    }

}

/// Room and thread references follow protocol Appendix A.3; titles are literal text.
enum RoomReferenceDisplay {
    static func isReference(_ url: URL?) -> Bool {
        url?.scheme == "apron" && url?.host == nil && url?.query?.hasPrefix("room=") == true
    }
    private static let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])#([A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?)"#)
    static func ids(in source: String) -> Set<String> {
        Set(expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        })
    }
    static func attributed(_ source: String, names: [String: String], rooms: [String: String]) -> AttributedString {
        var result = AttributedString()
        var cursor = source.startIndex
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let idRange = Range(match.range(at: 1), in: source),
                  let title = rooms[String(source[idRange])],
                  let range = Range(match.range, in: source) else { continue }
            result += MentionDisplay.attributed(String(source[cursor..<range.lowerBound]), names: names)
            let id = String(source[idRange])
            var reference = AttributedString("#" + (title.isEmpty ? id : title))
            reference.link = URL(string: "apron:?room=" + ApronLink.encode(id))
            result += reference
            cursor = range.upperBound
        }
        result += MentionDisplay.attributed(String(source[cursor...]), names: names)
        return result
    }
}

/// Detect web links before mentions so URL paths and query strings remain intact.
enum MessageTextDisplay {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ source: String, names: [String: String] = [:], roomNames: [String: String] = [:]) -> AttributedString {
        var result = AttributedString()
        var cursor = source.startIndex
        for match in detector.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  MediaPolicy.safeLink(url), let range = Range(match.range, in: source) else { continue }
            result += RoomReferenceDisplay.attributed(String(source[cursor..<range.lowerBound]), names: names, rooms: roomNames)
            var link = AttributedString(String(source[range]))
            link.link = url
            result += link
            cursor = range.upperBound
        }
        result += RoomReferenceDisplay.attributed(String(source[cursor...]), names: names, rooms: roomNames)
        return result
    }
}

struct MessageMarkdown {
    static let maximumBytes = 64 * 1024
    static let maximumDepth = 32
    let blocks: [MessageBlock]
    let displayBlocks: [MessageBlock]
    let usedFallback: Bool

    init(_ source: String, endpoint: String? = nil, mentionNames: [String: String] = [:], roomNames: [String: String] = [:]) {
        func fallback() -> [MessageBlock] {
            // Characters may contain arbitrarily many combining scalars. Bound
            // UTF-8 bytes instead, stopping only at a complete scalar boundary.
            var text = ""
            var bytes = 0
            for scalar in source.unicodeScalars {
                let size = scalar.utf8.count
                guard bytes + size <= Self.maximumBytes else { break }
                text.unicodeScalars.append(scalar)
                bytes += size
            }
            if source.utf8.count > bytes {
                text += "\n[Message truncated for display. Use Copy Text for the full source.]"
            }
            return [MessageBlock(id: 0, kind: .paragraph, text: AttributedString(text))]
        }
        guard source.utf8.count <= Self.maximumBytes else { blocks = fallback(); displayBlocks = blocks; usedFallback = true; return }
        let document = Markdown.Document(parsing: source, options: [.disableSmartOpts])
        var stack: [(any Markup, Int)] = [(document, 0)]
        var count = 0
        while let (node, depth) = stack.popLast() {
            count += 1
            guard depth <= Self.maximumDepth, count <= 4096 else { blocks = fallback(); displayBlocks = blocks; usedFallback = true; return }
            stack.append(contentsOf: node.children.map { ($0, depth + 1) })
        }
        var result: [MessageBlock] = []
        func inline(_ node: any Markup, mentions: Bool = true) -> AttributedString {
            if let text = node as? Markdown.Text { return mentions ? MessageTextDisplay.attributed(text.string, names: mentionNames, roomNames: roomNames) : AttributedString(text.string) }
            if let code = node as? InlineCode {
                var text = AttributedString(code.code); text.inlinePresentationIntent = .code; return text
            }
            if node is SoftBreak { return AttributedString("\n") }
            if node is LineBreak { return AttributedString("\n") }
            if let html = node as? InlineHTML { return AttributedString(html.rawHTML) }
            var text = node.children.reduce(into: AttributedString()) { $0 += inline($1, mentions: mentions && !(node is Markdown.Link) && !(node is Markdown.Image)) }
            if node is Strong || node is Emphasis {
                for run in text.runs {
                    text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(node is Strong ? .stronglyEmphasized : .emphasized)
                }
            }
            if node is Strikethrough { text.strikethroughStyle = .single }
            if let link = node as? Markdown.Link, let destination = link.destination,
               let url = URL(string: destination), MessageNavigation.destination(url, relativeTo: endpoint) != .blocked { text.link = url }
            if node is Markdown.Image { text = AttributedString("[Image: ") + text + AttributedString("]") }
            return text
        }
        func visit(_ node: any Markup, indent: Int = 0, quote: Bool = false, marker: String = "") {
            func append(_ kind: MessageBlock.Kind, _ text: AttributedString) {
                result.append(MessageBlock(id: result.count, kind: kind, text: text, indent: indent, quote: quote, marker: marker))
            }
            switch node {
            case let code as CodeBlock: append(.code(code.language ?? ""), AttributedString(code.code))
            case let heading as Heading: append(.heading(heading.level), inline(heading))
            case is Paragraph: append(.paragraph, inline(node))
            case is ThematicBreak: append(.rule, AttributedString())
            case let html as HTMLBlock: append(.paragraph, AttributedString(html.rawHTML))
            case is BlockQuote:
                for child in node.children { visit(child, indent: indent, quote: true) }
            case is UnorderedList, is OrderedList:
                let start = (node as? OrderedList).map { Int($0.startIndex) }
                for (offset, item) in node.children.enumerated() {
                    let label = start.map { "\($0 + offset)." } ?? "•"
                    for (index, child) in item.children.enumerated() {
                        visit(child, indent: indent + 1, quote: quote, marker: index == 0 ? label : "")
                    }
                }
            case is Markdown.Document, is ListItem:
                for child in node.children { visit(child, indent: indent, quote: quote, marker: marker) }
            default: append(.paragraph, AttributedString(node.format()))
            }
        }
        visit(document)
        blocks = result; displayBlocks = MessageBlock.coalesced(result); usedFallback = false
    }
}

/// Rows are rebuilt as the reader scrolls; parsing synchronously from a cache keeps
/// a rebuilt row at its final layout in its first frame.
@MainActor final class MessageMarkdownCache {
    static let shared = MessageMarkdownCache()
    private struct Key: Hashable { let source: String; let endpoint: String?; let mentionNames: [String: String]; let roomNames: [String: String] }
    private struct Entry { let value: MessageMarkdown; let cost: Int; var lastUse: UInt64 }
    private var entries: [Key: Entry] = [:]
    /// Least recently used entries are evicted first, so rows on screen stay parsed.
    private var clock: UInt64 = 0
    let limit: Int
    let byteLimit: Int
    private(set) var retainedBytes = 0
    var entryCount: Int { entries.count }

    init(limit: Int = 1000, byteLimit: Int = 8 * 1024 * 1024) {
        self.limit = max(0, limit); self.byteLimit = max(0, byteLimit)
    }

    func parsed(_ source: String, endpoint: String?, mentionNames: [String: String], roomNames: [String: String] = [:]) -> MessageMarkdown {
        let key = Key(source: source, endpoint: endpoint, mentionNames: mentionNames, roomNames: roomNames)
        clock &+= 1
        if let parsed = entries[key] {
            entries[key]?.lastUse = clock
            return parsed.value
        }
        let parsed = MessageMarkdown(source, endpoint: endpoint, mentionNames: mentionNames, roomNames: roomNames)
        // Never retain an oversized original just to cache its bounded fallback.
        guard limit > 0, source.utf8.count <= MessageMarkdown.maximumBytes else { return parsed }
        // Account for retained text plus conservative container/run overhead.
        // Shared string storage may make the actual cost smaller than this estimate.
        let cost = source.utf8.count + (endpoint?.utf8.count ?? 0) + 256
            + roomNames.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 128 }
            + mentionNames.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 128 }
            + (parsed.blocks + parsed.displayBlocks).reduce(0) { $0 + String($1.text.characters).utf8.count + $1.text.runs.count * 256 + 128 }
        guard cost <= byteLimit else { return parsed }
        // A linear scan is cheap beside the parse that precedes every insertion.
        while entries.count >= limit || retainedBytes + cost > byteLimit,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            if let removed = entries.removeValue(forKey: oldest) { retainedBytes -= removed.cost }
        }
        entries[key] = Entry(value: parsed, cost: cost, lastUse: clock)
        retainedBytes += cost
        return parsed
    }

    func contains(_ source: String, endpoint: String?, mentionNames: [String: String], roomNames: [String: String] = [:]) -> Bool {
        entries[Key(source: source, endpoint: endpoint, mentionNames: mentionNames, roomNames: roomNames)] != nil
    }

    func clear() {
        entries.removeAll(); retainedBytes = 0
    }
}

struct MarkdownMessageView: View {
    let source: String
    let size: Double
    var mentionNames: [String: String] = [:]
    var roomNames: [String: String] = [:]
    var endpoint: String? = nil
    var reviewLink: ((URL) -> Void)? = nil
    var showMention: ((String) -> Void)? = nil
    var emojiStore: CustomEmojiStore? = nil
    // Kept injectable for before/after rendering benchmarks.
    var mergeParagraphs = true
    var body: some View {
        let _ = RenderProfile.count("markdownBody")
        let parsed = MessageMarkdownCache.shared.parsed(source, endpoint: endpoint, mentionNames: mentionNames, roomNames: roomNames)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(mergeParagraphs ? parsed.displayBlocks : parsed.blocks) { block in
                HStack(alignment: .top, spacing: 7) {
                    if block.quote { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3) }
                    if !block.marker.isEmpty { Text(userText: block.marker).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing) }
                    content(block).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, CGFloat(max(0, block.indent - 1)) * 16)
            }
        }
        .font(.system(size: size))
        .environment(\.openURL, OpenURLAction { url in
            if let id = MentionDisplay.userID(url, names: mentionNames), let showMention {
                showMention(id)
                return .handled
            }
            return MessageNavigation.open(url, relativeTo: endpoint, review: reviewLink)
        })
    }
    @ViewBuilder private func content(_ block: MessageBlock) -> some View {
        switch block.kind {
        case .rule: Rectangle().fill(.separator).frame(height: 1).padding(.vertical, 4)
        case .code(let language):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(userText: language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                    }.font(.caption).buttonStyle(.borderless).accessibilityLabel("Copy code block")
                }
                let codeSize = MessageTextStyle.codeBlockSize(for: size)
                CodeBlockText(text: block.text, size: codeSize)
                    .frame(maxWidth: .infinity)
                    .frame(height: MessageTextStyle.codeBlockHeight(String(block.text.characters), size: codeSize))
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        case .heading(let level):
            EmojiMessageText(text: block.text, size: size + Double(max(1, 7 - level)), semibold: true, lineSpacing: 0, store: emojiStore)
                .accessibilityAddTraits(.isHeader)
        case .paragraph, .paragraphGroup: EmojiMessageText(text: block.text, size: size, store: emojiStore).fixedSize(horizontal: false, vertical: true)
        }
    }
}
