import AppKit
import Markdown
import ApronCore

extension NSAttributedString.Key {
    static let composerReference = NSAttributedString.Key("SideTableComposerReference")
}

/// Display attachments carry their original wire spelling. Markdown delimiters stay in the storage.
@MainActor enum ComposerPresentation {
    static let font = NSFont.systemFont(ofSize: 14)
    static var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }
    private static let references = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])[@#][A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?"#)
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func raw(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(.composerReference, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            result += value as? String ?? text.attributedSubstring(from: range).string
        }
        return result
    }
    static func rawRange(_ range: NSRange, in text: NSAttributedString) -> NSRange {
        let location = min(range.location, text.length)
        let clamped = NSRange(location: location, length: min(range.length, text.length - location))
        let start = raw(text.attributedSubstring(from: NSRange(location: 0, length: location)))
        let selected = raw(text.attributedSubstring(from: clamped))
        return NSRange(location: (start as NSString).length, length: (selected as NSString).length)
    }
    static func displayRange(_ range: NSRange, in text: NSAttributedString) -> NSRange {
        func offset(_ target: Int, end: Bool) -> Int {
            var rawOffset = 0, result = text.length
            text.enumerateAttribute(.composerReference, in: NSRange(location: 0, length: text.length)) { value, range, stop in
                let length = (value as? String).map { ($0 as NSString).length } ?? range.length
                if target <= rawOffset + length {
                    let relative = max(0, target - rawOffset)
                    result = range.location + (value == nil ? min(relative, range.length) : relative == 0 ? 0 : relative == length || end ? range.length : 0)
                    stop.pointee = true
                }
                rawOffset += length
            }
            return result
        }
        let start = offset(range.location, end: false)
        return NSRange(location: start, length: max(0, offset(NSMaxRange(range), end: range.length > 0) - start))
    }

    static func render(_ source: String, names: [String: String], markdown: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: attributes)
        guard source.utf8.count <= MessageMarkdown.maximumBytes else { return result }
        var excluded: [NSRange] = []
        if markdown {
            var lines = [source.startIndex]
            for index in source.utf8.indices {
                let byte = source.utf8[index], next = source.utf8.index(after: index)
                if byte == 10 || byte == 13 && (next == source.endIndex || source.utf8[next] != 10) { lines.append(next) }
            }
            func location(_ value: SourceLocation) -> String.Index? {
                guard value.line > 0, value.line <= lines.count, value.column > 0,
                      let index = source.utf8.index(lines[value.line - 1], offsetBy: value.column - 1, limitedBy: source.endIndex) else { return nil }
                return String.Index(index, within: source)
            }
            func range(_ node: any Markup) -> NSRange? {
                guard let span = node.range, let start = location(span.lowerBound), let end = location(span.upperBound), start <= end else { return nil }
                return NSRange(start..<end, in: source)
            }
            var stack: [(any Markup, Int)] = [(Document(parsing: source, options: [.disableSmartOpts]), 0)]
            var count = 0
            while let (node, depth) = stack.popLast() {
                count += 1
                guard count <= 4096, depth <= MessageMarkdown.maximumDepth else { return NSAttributedString(string: source, attributes: attributes) }
                if let span = range(node) {
                    if node is InlineCode || node is CodeBlock {
                        excluded.append(span)
                        result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor], range: span)
                        continue
                    }
                    if node is Markdown.Link || node is Markdown.Image || node is InlineHTML || node is HTMLBlock { excluded.append(span) }
                    if node is Strong || node is Heading {
                        result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: span)
                    } else if node is Emphasis {
                        result.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: span)
                    }
                }
                stack.append(contentsOf: node.children.map { ($0, depth + 1) })
            }
        }
        excluded += links.matches(in: source, range: NSRange(location: 0, length: result.length)).map(\.range)
        for match in references.matches(in: source, range: NSRange(location: 0, length: result.length)).reversed() {
            let raw = (source as NSString).substring(with: match.range)
            guard let name = names[raw], !name.isEmpty,
                  !excluded.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let label = UserText.isolated(String(raw.prefix(1)) + name)
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: style]
            let width = min(240, (label as NSString).size(withAttributes: attributes).width + 12)
            let image = NSImage(size: NSSize(width: width, height: 20))
            image.accessibilityDescription = UserText.clean(raw + " — " + name)
            image.lockFocus()
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: 20), xRadius: 5, yRadius: 5).fill()
            (label as NSString).draw(in: NSRect(x: 6, y: 1, width: width - 12, height: 18), withAttributes: attributes)
            image.unlockFocus()
            let attachment = NSTextAttachment()
            attachment.attachmentCell = ComposerReferenceCell(imageCell: image)
            let token = NSMutableAttributedString(attachment: attachment)
            token.addAttributes([.composerReference: raw, .toolTip: raw + " — " + name], range: NSRange(location: 0, length: token.length))
            result.replaceCharacters(in: match.range, with: token)
        }
        return result
    }
}

private final class ComposerReferenceCell: NSTextAttachmentCell {
    nonisolated override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }
}
