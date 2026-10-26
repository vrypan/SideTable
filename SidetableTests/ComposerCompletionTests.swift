import AppKit
import Testing
@testable import Sidetable

@Test func completionFindsCaretTokenWithoutChangingOtherText() throws {
    let text = "Hello 👋 @ad and more"
    let position = (text as NSString).range(of: "@ad").upperBound
    let query = try #require(ComposerCompletion.query(in: text, selection: NSRange(location: position, length: 0)))
    #expect(query.marker == "@" && query.text == "ad")
    #expect((text as NSString).replacingCharacters(in: query.range, with: "@ada ") == "Hello 👋 @ada  and more")
    let candidates = [ComposerSuggestion(insertion: "@ada", label: "Ada Lovelace", search: "Ada Lovelace ada"), ComposerSuggestion(insertion: "#ada", label: "Room", search: "ada")]
    #expect(ComposerCompletion.suggestions(for: query, candidates: candidates).map(\.insertion) == ["@ada"])
    for value in ["mail@ada", "https://host", "`@ad", "```swift\n@ad", "hello"] {
        #expect(ComposerCompletion.query(in: value, selection: NSRange(location: (value as NSString).length, length: 0)) == nil)
    }
    #expect(ComposerCompletion.query(in: "@ad", selection: NSRange(location: 2, length: 1)) == nil)
}

@Test func emojiCatalogSupportsAliasesDescriptionsAndSequences() throws {
    #expect(EmojiCatalog.entries.count > 1000)
    #expect(EmojiCatalog.matching("thumbsup").contains { $0.emoji == "👍" })
    #expect(!EmojiCatalog.matching("rocket").isEmpty)
    #expect(EmojiCatalog.matching(" LAUNCH ").contains { $0.emoji == "🚀" })
    #expect(EmojiCatalog.matching("🚀").map(\.emoji) == ["🚀"])
    #expect(EmojiCatalog.matching(" ").count == EmojiCatalog.entries.count)
    #expect(EmojiCatalog.matching("no-such-emoji-search").isEmpty)
    let query = try #require(ComposerCompletion.query(in: ":rocket", selection: NSRange(location: 7, length: 0)))
    #expect(ComposerCompletion.suggestions(for: query, candidates: []).contains { $0.insertion == "🚀" })
    #expect(EmojiCatalog.entries.contains { $0.emoji.unicodeScalars.contains { $0.value == 0x200D } })
}

@MainActor @Test func nativeCompletionInsertionUsesSelectionAndUndo() throws {
    let editor = ComposerTextView()
    editor.allowsUndo = true
    editor.string = "Hello world"
    editor.setSelectedRange(NSRange(location: 6, length: 5))
    editor.insertText("🚀", replacementRange: editor.selectedRange())
    #expect(editor.string == "Hello 🚀")
}

@MainActor @Test func returnAcceptsCompletionBeforeSendingAndEscapeDismisses() throws {
    let editor = ComposerTextView()
    editor.isEditable = true
    editor.candidates = [ComposerSuggestion(insertion: "@ada", label: "Ada", search: "Ada")]
    var sends = 0
    editor.send = { sends += 1 }
    func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    editor.insertText("Hi @ad", replacementRange: NSRange(location: 0, length: 0))
    editor.keyDown(with: try key(36, "\r"))
    #expect(editor.string == "Hi @ada ")
    #expect(sends == 0)
    editor.keyDown(with: try key(36, "\r"))
    #expect(sends == 1)
    editor.insertText("@ad", replacementRange: editor.selectedRange())
    editor.keyDown(with: try key(53, "\u{1b}"))
    editor.keyDown(with: try key(36, "\r"))
    #expect(sends == 2)
}

@Test func recentEmojisPersistInSelectionOrderWithoutDuplicates() throws {
    let suite = "RecentEmojisTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = RecentEmojis(defaults: defaults)
    #expect(history.entries.map(\.emoji) == ["👍", "❤️", "🎉", "👀", "✨", "😀", "🚀"])
    for emoji in ["👍", "🔥", "🚀", "😀", "🎉", "👀", "✨", "❤️", "🚀"] { history.record(emoji) }
    #expect(RecentEmojis(defaults: defaults).entries.map(\.emoji) == ["🚀", "❤️", "✨", "👀", "🎉", "😀", "🔥"])
    history.record("not an emoji")
    #expect(history.entries.first?.emoji == "🚀")
}

@Test func recentEmojisFillUnusedSlotsAndIgnoreStaleEntries() throws {
    let suite = "RecentEmojisTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["unknown", "🚀", "🚀"], forKey: "recentEmojis")
    #expect(RecentEmojis(defaults: defaults).entries.map(\.emoji) == ["🚀", "👍", "❤️", "🎉", "👀", "✨", "😀"])
}
