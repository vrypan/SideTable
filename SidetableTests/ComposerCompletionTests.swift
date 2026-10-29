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
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let editor = ComposerTextView()
    window.contentView = editor
    window.makeFirstResponder(editor)
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

@MainActor @Test func candidateUpdatesOnlyShowCompletionsForTheFocusedComposer() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let first = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let second = ComposerTextView(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
    window.contentView?.addSubview(first); window.contentView?.addSubview(second)
    let ada = ComposerSuggestion(insertion: "@ada", label: "Ada", search: "Ada")
    let adam = ComposerSuggestion(insertion: "@adam", label: "Adam", search: "Adam")
    first.candidates = [ada]
    window.makeFirstResponder(first)
    first.insertText("@ad", replacementRange: NSRange(location: 0, length: 0))
    #expect(window.childWindows?.count == 1)
    window.makeFirstResponder(second)
    #expect(window.childWindows?.isEmpty != false)
    first.candidates = [ada, adam]
    #expect(window.childWindows?.isEmpty != false)
    second.insertText("@ad", replacementRange: NSRange(location: 0, length: 0))
    second.candidates = [ada, adam]
    #expect(window.childWindows?.count == 1)
    #expect(window.firstResponder === second)
    second.hideCompletions()
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

@Test func emojiFavoritesPersistAndScopeCustomKeysToServerAndAccount() throws {
    let suite = "EmojiFavoritesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = EmojiFavorites(defaults: defaults, scope: "server-a/ada")
    first.toggle("🚀", custom: false)
    first.toggle(":wave:", custom: true)
    #expect(EmojiFavorites(defaults: defaults, scope: "server-a/ada").keys == ["🚀", ":wave:"])
    #expect(EmojiFavorites(defaults: defaults, scope: "server-b/ada").keys == ["🚀"])
    #expect(EmojiFavorites(defaults: defaults, scope: "server-a/bob").keys == ["🚀"])
    first.toggle(":wave:", custom: true)
    #expect(first.keys == ["🚀"])
    first.toggle("not an emoji", custom: false)
    first.toggle(":not valid:", custom: true)
    EmojiFavorites(defaults: defaults).toggle(":unscoped:", custom: true)
    #expect(first.keys == ["🚀"])
}

@MainActor @Test func repeatedPickerInsertionsPreserveFocusAndAdvanceTheCaret() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let search = NSTextView(frame: NSRect(x: 0, y: 100, width: 300, height: 50))
    window.contentView?.addSubview(editor); window.contentView?.addSubview(search)
    editor.string = "hi "; editor.setSelectedRange(NSRange(location: 3, length: 0))
    window.makeFirstResponder(search)
    let first = ComposerInsertion(text: "👋", focus: false)
    editor.apply(first); editor.apply(first)
    editor.apply(ComposerInsertion(text: ":wave:", focus: false))
    #expect(editor.string == "hi 👋 :wave: ")
    #expect(window.firstResponder === search)
    #expect(editor.selectedRange().location == (editor.string as NSString).length)
    editor.apply(ComposerInsertion(text: "🚀"))
    #expect(editor.string == "hi 👋 :wave: 🚀")
    #expect(window.firstResponder === editor)
}

@MainActor @Test func composerTokensRoundTripRawIDsAndPreserveMarkdownSyntax() throws {
    let raw = "👋 @ada **hello** #1791590929296 *world* `@ada` https://example.com/#1791590929296 [@ada](https://example.com/)"
    let rendered = ComposerPresentation.render(raw, names: ["@ada": "Ada", "#1791590929296": "Release planning"], markdown: true)
    #expect(ComposerPresentation.raw(rendered) == raw)
    var tokens: [String] = []
    rendered.enumerateAttribute(.composerReference, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
        if let value = value as? String { tokens.append(value) }
    }
    #expect(tokens == ["@ada", "#1791590929296"])
    #expect(rendered.string.contains("**hello**") && rendered.string.contains("*world*") && rendered.string.contains("`@ada`"))
    let bold = (rendered.string as NSString).range(of: "hello").location
    let font = try #require(rendered.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)
    #expect(font == ComposerPresentation.font)
    let range = (raw as NSString).range(of: "#1791590929296")
    let display = ComposerPresentation.displayRange(range, in: rendered)
    #expect(display.length == 1)
    #expect(ComposerPresentation.rawRange(display, in: rendered) == range)
}

@MainActor @Test func composerTokenDeletionCopyUndoAndRedoKeepWireText() throws {
    let editor = ComposerTextView()
    editor.configurePresentation(names: ["@ada": "Ada", "#room": "Planning"], markdown: true)
    editor.setSource("Hi @ada #room")
    let storage = try #require(editor.textStorage)
    editor.setSelectedRange(NSRange(location: 0, length: storage.length))
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    #expect(editor.writeSelection(to: clipboard, type: .string))
    #expect(clipboard.string(forType: .string) == "Hi @ada #room")
    editor.setSelectedRange(NSRange(location: storage.length, length: 0))
    let manager = editor.sourceUndoManager
    manager.groupsByEvent = false
    manager.beginUndoGrouping()
    editor.deleteBackward(nil)
    manager.endUndoGrouping()
    #expect(editor.sourceText == "Hi @ada ")
    #expect(manager.canUndo)
    editor.isEditable = false; editor.undo(nil)
    #expect(editor.sourceText == "Hi @ada ")
    editor.isEditable = true
    manager.undo()
    #expect(editor.sourceText == "Hi @ada #room")
    manager.redo()
    #expect(editor.sourceText == "Hi @ada ")
    manager.beginUndoGrouping()
    editor.insertText("**bold**", replacementRange: editor.selectedRange())
    manager.endUndoGrouping()
    #expect(editor.sourceText == "Hi @ada **bold**")
    editor.configurePresentation(names: ["@ada": "Renamed Ada"], markdown: true)
    #expect(editor.sourceText == "Hi @ada **bold**")
    manager.undo()
    #expect(editor.sourceText == "Hi @ada ")
}

@MainActor @Test func composerTokensDoNotEatFollowingTextAndExternalDraftReplacements() throws {
    let editor = ComposerTextView()
    editor.configurePresentation(names: ["@ada": "Ada"], markdown: true)
    editor.setSource("@ada")
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    editor.insertText("x", replacementRange: editor.selectedRange())
    #expect(editor.sourceText == "@adax" && editor.string == "@adax")
    editor.setSource("@ada and more")
    #expect(editor.sourceText == "@ada and more")
    editor.setSource("a different room")
    #expect(editor.sourceText == "a different room" && !editor.sourceUndoManager.canUndo)
}

@MainActor @Test func composerMarkedTextIsNotReformattedAndEditorReturnInsertsNewline() throws {
    let editor = ComposerTextView()
    editor.configurePresentation(names: ["@ada": "Ada"], markdown: true)
    editor.setSource("Hi ")
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    editor.setMarkedText("@ada", selectedRange: NSRange(location: 4, length: 0), replacementRange: editor.selectedRange())
    #expect(editor.hasMarkedText())
    editor.configurePresentation(names: ["@ada": "Renamed Ada"], markdown: true)
    #expect(editor.string == "Hi @ada")
    editor.insertText("@ada", replacementRange: editor.markedRange())
    editor.unmarkText()
    #expect(!editor.hasMarkedText() && editor.sourceText == "Hi @ada")
    #expect(editor.string.contains("\u{fffc}"))
    editor.hideCompletions()
    editor.returnSends = false
    var sends = 0
    editor.send = { sends += 1 }
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    editor.keyDown(with: enter)
    #expect(editor.sourceText == "Hi @ada\n" && sends == 0)
    #expect(editor.validateMenuItem(NSMenuItem(title: "Undo", action: #selector(ComposerTextView.undo(_:)), keyEquivalent: "z")))
    editor.setContext("another-account/room")
    #expect(!editor.sourceUndoManager.canUndo)
}

@MainActor @Test func composerMarkdownHandlesUnicodeAndWindowsLineEndings() throws {
    let source = "🙂\r\n**bold** @ada\r\n```\r\n@ada\r\n```"
    let rendered = ComposerPresentation.render(source, names: ["@ada": "Ada"], markdown: true)
    #expect(ComposerPresentation.raw(rendered) == source)
    #expect(rendered.string.filter { $0 == "\u{fffc}" }.count == 1)
    let bold = (rendered.string as NSString).range(of: "bold").location
    let font = try #require(rendered.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)
    #expect(font == ComposerPresentation.font)
}

@MainActor @Test func composerStylesOnlyCodeAndKeepsLanguageFencesLiteral() throws {
    let source = "# Heading\n\n**bold** and *italic* with `single`\n\n```swift\nlet user = \"@ada\"\n```"
    let rendered = ComposerPresentation.render(source, names: ["@ada": "Ada"], markdown: true)
    #expect(rendered.string == source)
    #expect(ComposerPresentation.raw(rendered) == source)
    for word in ["Heading", "bold", "italic"] {
        let location = (source as NSString).range(of: word).location
        #expect(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont == ComposerPresentation.font)
        #expect(rendered.attribute(.backgroundColor, at: location, effectiveRange: nil) == nil)
    }
    for word in ["single", "swift", "let user", "@ada"] {
        let location = (source as NSString).range(of: word).location
        let font = try #require(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(font == NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        #expect(rendered.attribute(.backgroundColor, at: location, effectiveRange: nil) != nil)
    }
}
