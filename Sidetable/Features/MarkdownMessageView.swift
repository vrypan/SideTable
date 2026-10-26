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

struct MessageMarkdown {
    static let maximumBytes = 64 * 1024
    static let maximumDepth = 32
    let blocks: [MessageBlock]
    let usedFallback: Bool

    init(_ source: String, endpoint: String? = nil) {
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
        func inline(_ node: any Markup) -> AttributedString {
            if let text = node as? Markdown.Text { return AttributedString(text.string) }
            if let code = node as? InlineCode {
                var text = AttributedString(code.code); text.inlinePresentationIntent = .code; return text
            }
            if node is SoftBreak { return AttributedString("\n") }
            if node is LineBreak { return AttributedString("\n") }
            if let html = node as? InlineHTML { return AttributedString(html.rawHTML) }
            var text = node.children.reduce(into: AttributedString()) { $0 += inline($1) }
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
    var endpoint: String? = nil
    var reviewLink: ((URL) -> Void)? = nil
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
        .environment(\.openURL, OpenURLAction { MessageNavigation.open($0, relativeTo: endpoint, review: reviewLink) })
        .onChange(of: source, initial: true) { _, value in parsed = MessageMarkdown(value, endpoint: endpoint) }
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
