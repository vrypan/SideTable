import AppKit
import ApronCore
import SwiftUI

/// A rendering snapshot, independent of the wire text and Markdown parse cache.
struct CustomEmojiRender: Equatable {
    let entry: CustomEmoji
    let bitmapID: UUID
    let frame: Int
    let image: NSImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.entry == rhs.entry && lhs.bitmapID == rhs.bitmapID && lhs.frame == rhs.frame }

    @MainActor static func frames(keys: Set<String>, store: CustomEmojiStore?, date: Date, reduceMotion: Bool) -> [String: Self] {
        guard let store else { return [:] }
        return keys.reduce(into: [:]) { result, key in
            guard let entry = store.catalog[key], let bitmap = store.bitmap(for: key, reduceMotion: reduceMotion) else { return }
            let frame = bitmap.index(at: date, reduceMotion: reduceMotion)
            result[key] = Self(entry: entry, bitmapID: bitmap.id, frame: frame, image: NSImage(cgImage: bitmap.frames[frame], size: .zero))
        }
    }
}

private struct EmojiDemand: Hashable {
    let generation: UUID?
    let keys: Set<String>
    let reduceMotion: Bool
}

/// The timeline ticks only when this visible text contains a loaded animation.
struct EmojiMessageText: View {
    let text: AttributedString
    let size: Double
    var semibold = false
    var lineSpacing: CGFloat = 3
    var store: CustomEmojiStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let keys = CustomEmojiText.keys(in: text, known: store?.keys.isEmpty == false ? store?.keys : nil)
        let animated = !reduceMotion && keys.contains { (store?.bitmap(for: $0, reduceMotion: reduceMotion)?.frames.count ?? 0) > 1 }
        TimelineView(.animation(minimumInterval: 0.05, paused: !animated)) { context in
            NativeMessageText(text: text, size: size, semibold: semibold, lineSpacing: lineSpacing,
                emojis: CustomEmojiRender.frames(keys: keys, store: store, date: context.date, reduceMotion: reduceMotion), emojiKeys: store?.keys)
        }
        .task(id: EmojiDemand(generation: store?.generation, keys: keys, reduceMotion: reduceMotion)) {
            await store?.prepare(keys: keys, reduceMotion: reduceMotion)
        }
    }
}

struct CustomEmojiView: View {
    let key: String
    let store: CustomEmojiStore
    var size: Double = 18
    var maximumWidth: Double = .infinity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entry = store.catalog[key]
        let bitmap = store.bitmap(for: key, reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion || (bitmap?.frames.count ?? 0) < 2)) { context in
            if let bitmap, let entry {
                let frame = bitmap.index(at: context.date, reduceMotion: reduceMotion)
                Image(nsImage: NSImage(cgImage: bitmap.frames[frame], size: .zero)).resizable().aspectRatio(entry.aspectRatio, contentMode: .fit)
                    .frame(width: min(maximumWidth, size * 4, size * entry.aspectRatio), height: min(size, maximumWidth / entry.aspectRatio))
            } else { Text(userText: ReactionEntry.isEmoji(key) ? key : "◻︎").font(.system(size: size)) }
        }
        .help(UserText.isolated(entry?.alt ?? key))
        .accessibilityLabel(UserText.clean(entry?.alt ?? key))
        .task(id: EmojiDemand(generation: store.generation, keys: [key], reduceMotion: reduceMotion)) {
            if !ReactionEntry.isEmoji(key) { await store.prepare(keys: [key], reduceMotion: reduceMotion) }
        }
    }
}

extension NSAttributedString.Key {
    static let customEmojiKey = NSAttributedString.Key("SideTableCustomEmojiKey")
}

@MainActor enum CustomEmojiAttachment {
    static func render(_ text: String, attributes: [NSAttributedString.Key: Any], frames: [String: CustomEmojiRender], font: NSFont, knownKeys: Set<String>? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let source = text as NSString
        var cursor = 0
        for match in CustomEmojiText.matches(text, keys: knownKeys ?? Set(frames.keys)) {
            guard let frame = frames[match.key] else { continue }
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: attributes))
            let attachment = NSTextAttachment()
            attachment.image = frame.image
            let height = ceil(font.ascender - font.descender)
            // Keep pathological wide metadata from overflowing the transcript, preserving its ratio.
            let width = min(height * 4, height * frame.entry.aspectRatio)
            attachment.bounds = NSRect(x: 0, y: font.descender, width: width, height: width / frame.entry.aspectRatio)
            let value = NSMutableAttributedString(attachment: attachment)
            var attrs = attributes
            attrs[.customEmojiKey] = match.key
            attrs[.toolTip] = UserText.clean(frame.entry.alt)
            value.addAttributes(attrs, range: NSRange(location: 0, length: value.length))
            result.append(value); cursor = NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string: source.substring(from: cursor), attributes: attributes))
        return result
    }
    static func renderedRange(for plainRange: NSRange, in text: NSAttributedString) -> NSRange {
        func offset(_ target: Int, roundUp: Bool) -> Int {
            var plain = 0, result = text.length
            text.enumerateAttribute(.customEmojiKey, in: NSRange(location: 0, length: text.length)) { value, range, stop in
                let unit = (value as? String).map { ($0 as NSString).length } ?? 1
                let length = range.length * unit
                if target <= plain + length {
                    let relative = max(0, target - plain)
                    result = range.location + min(range.length, (relative + (roundUp ? unit - 1 : 0)) / unit)
                    stop.pointee = true
                }
                plain += length
            }
            return result
        }
        let start = offset(plainRange.location, roundUp: false)
        let end = offset(NSMaxRange(plainRange), roundUp: plainRange.length > 0)
        return NSRange(location: start, length: max(0, end - start))
    }
    static func accessibleText(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            if let key = attrs[.customEmojiKey] as? String {
                result += String(repeating: attrs[.toolTip] as? String ?? key, count: range.length)
            } else { result += text.attributedSubstring(from: range).string }
        }
        return result
    }
    /// Native selection copies text keys, not attachment bytes or U+FFFC placeholders.
    static func plainText(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(.customEmojiKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let key = value as? String { result += String(repeating: key, count: range.length) }
            else { result += text.attributedSubstring(from: range).string }
        }
        return result
    }
}
