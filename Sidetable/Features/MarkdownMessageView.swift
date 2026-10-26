import SwiftUI
import AppKit
import Markdown

struct MessageBlock: Identifiable {
    enum Kind: Equatable { case paragraph, heading(Int), code(String), rule }
    let id: Int
    let kind: Kind
    var text: AttributedString
    var indent: Int = 0
    var quote: Bool = false
    var marker: String = ""
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

/// Detect web links before mentions so URL paths and query strings remain intact.
enum MessageTextDisplay {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ source: String, names: [String: String] = [:]) -> AttributedString {
        var result = AttributedString()
        var cursor = source.startIndex
        for match in detector.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  MediaPolicy.safeLink(url), let range = Range(match.range, in: source) else { continue }
            result += MentionDisplay.attributed(String(source[cursor..<range.lowerBound]), names: names)
            var link = AttributedString(String(source[range]))
            link.link = url
            result += link
            cursor = range.upperBound
        }
        result += MentionDisplay.attributed(String(source[cursor...]), names: names)
        return result
    }
}

struct MessageMarkdown {
    static let maximumBytes = 64 * 1024
    static let maximumDepth = 32
    let blocks: [MessageBlock]
    let usedFallback: Bool

    init(_ source: String, endpoint: String? = nil, mentionNames: [String: String] = [:]) {
        func fallback() -> [MessageBlock] {
            let text = String(source.prefix(Self.maximumBytes)) + (source.count > Self.maximumBytes ? "\n[Message truncated for display. Use Copy Text for the full source.]" : "")
            return [MessageBlock(id: 0, kind: .paragraph, text: AttributedString(text))]
        }
        guard source.utf8.count <= Self.maximumBytes else { blocks = fallback(); usedFallback = true; return }
        let document = Markdown.Document(parsing: source, options: [.disableSmartOpts])
        var stack: [(any Markup, Int)] = [(document, 0)]
        var count = 0
        while let (node, depth) = stack.popLast() {
            count += 1
            guard depth <= Self.maximumDepth, count <= 4096 else { blocks = fallback(); usedFallback = true; return }
            stack.append(contentsOf: node.children.map { ($0, depth + 1) })
        }
        var result: [MessageBlock] = []
        func inline(_ node: any Markup, mentions: Bool = true) -> AttributedString {
            if let text = node as? Markdown.Text { return mentions ? MessageTextDisplay.attributed(text.string, names: mentionNames) : AttributedString(text.string) }
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
        blocks = result; usedFallback = false
    }
}

struct MarkdownMessageView: View {
    let source: String
    let size: Double
    var mentionNames: [String: String] = [:]
    var endpoint: String? = nil
    var reviewLink: ((URL) -> Void)? = nil
    var showMention: ((String) -> Void)? = nil
    @State private var parsed: MessageMarkdown?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parsed {
                ForEach(parsed.blocks) { block in
                    HStack(alignment: .top, spacing: 7) {
                        if block.quote { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3) }
                        if !block.marker.isEmpty { Text(block.marker).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing) }
                        content(block).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, CGFloat(max(0, block.indent - 1)) * 16)
                }
            } else { Text(String(source.prefix(MessageMarkdown.maximumBytes))).textSelection(.enabled) }
        }
        .font(.system(size: size))
        .environment(\.openURL, OpenURLAction { url in
            if let id = MentionDisplay.userID(url, names: mentionNames), let showMention {
                showMention(id)
                return .handled
            }
            return MessageNavigation.open(url, relativeTo: endpoint, review: reviewLink)
        })
        .onChange(of: source, initial: true) { _, value in parsed = MessageMarkdown(value, endpoint: endpoint, mentionNames: mentionNames) }
        .onChange(of: mentionNames) { _, _ in parsed = MessageMarkdown(source, endpoint: endpoint, mentionNames: mentionNames) }
    }
    @ViewBuilder private func content(_ block: MessageBlock) -> some View {
        switch block.kind {
        case .rule: Rectangle().fill(.separator).frame(height: 1).padding(.vertical, 4)
        case .code(let language):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                    }.font(.caption).buttonStyle(.borderless).accessibilityLabel("Copy code block")
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(block.text).font(.system(size: size, design: .monospaced))
                        .lineLimit(nil).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(320, Double(String(block.text.characters).split(separator: "\n", omittingEmptySubsequences: false).count) * size * 1.5 + 4))
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        case .heading(let level):
            Text(block.text).font(.system(size: size + Double(max(1, 7 - level)), weight: .semibold))
                .textSelection(.enabled).accessibilityAddTraits(.isHeader)
        case .paragraph: Text(block.text).textSelection(.enabled).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
