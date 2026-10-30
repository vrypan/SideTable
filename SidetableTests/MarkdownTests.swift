import Foundation
import AppKit
import Testing
import ApronCore
@testable import Sidetable

@Test func markdownRendersBlocksAndPreservesCode() {
    let parsed = MessageMarkdown("# Heading\n\n> quoted **word**\n\n3. first\n   - nested\n4. next\n\n```swift\n  let x = 1\n\n```\n\n---\n\n    indented\n")
    #expect(!parsed.usedFallback)
    #expect(parsed.blocks.first?.kind == .heading(1))
    #expect(parsed.blocks.contains { $0.quote })
    #expect(parsed.blocks.contains { $0.marker == "3." })
    #expect(parsed.blocks.contains { $0.marker == "•" && $0.indent == 2 })
    #expect(parsed.blocks.contains { $0.kind == .code("swift") && String($0.text.characters) == "  let x = 1\n\n" })
    #expect(parsed.blocks.contains { $0.kind == .code("") && String($0.text.characters) == "indented\n" })
    #expect(parsed.blocks.contains { $0.kind == .rule })
}

@Test func markdownKeepsUntrustedContentInert() {
    let parsed = MessageMarkdown("Καλημέρα 👋 [safe](https://example.com) [bad](javascript:alert) ![alt](https://evil.example/pixel)\n\n<script>alert(1)</script>")
    let links = parsed.blocks.flatMap { $0.text.runs.compactMap(\.link) }
    #expect(links == [URL(string: "https://example.com")!])
    #expect(parsed.blocks.contains { String($0.text.characters).contains("[Image: alt]") })
    #expect(parsed.blocks.contains { String($0.text.characters).contains("<script>") })
    #expect(parsed.blocks.contains { String($0.text.characters).contains("Καλημέρα 👋") })
}

@Test func markdownBoundsWorkAndEditsDoNotReuseOldContent() {
    #expect(MessageMarkdown(String(repeating: "x", count: MessageMarkdown.maximumBytes + 1)).usedFallback)
    #expect(MessageMarkdown(String(repeating: "> ", count: 40) + "deep").usedFallback)
    let malformed = MessageMarkdown("**unfinished [link\n\ntext")
    #expect(!malformed.blocks.isEmpty)
    #expect(String(MessageMarkdown("old").blocks[0].text.characters) == "old")
    #expect(String(MessageMarkdown("new").blocks[0].text.characters) == "new")
}

@Test func markdownPreservesValidatedApronLinksWithoutAllowingOtherSchemes() throws {
    let apron = "apron:?server=wss://server.apron.chat/&room=1792516364563&message=1792891956790"
    let sideTable = "sidetable://open?server=wss://chat.example/&room=general"
    let web = "https://link.apron.chat/#server=wss://chat.example/&room=general"
    let parsed = MessageMarkdown("[message](\(apron)) [room](\(sideTable)) [shared](\(web)) [unsafe](apron:?server=ws://remote.example/&room=general) [file](file:///tmp/test)")
    #expect(parsed.blocks.flatMap { $0.text.runs.compactMap(\.link) }.map(\.absoluteString) == [apron, sideTable, web])
    for value in [apron, sideTable, web] {
        #expect(MessageNavigation.destination(try #require(URL(string: value))) == .review)
    }
    #expect(MessageNavigation.destination(try #require(URL(string: "https://example.com"))) == .web)
    for value in ["javascript:alert(1)", "file:///tmp/test", "sidetable://other?server=wss://chat.example/",
                  "apron:?server=ws://remote.example/", "apron:?server=wss://chat.example/&token=test"] {
        #expect(MessageNavigation.destination(try #require(URL(string: value))) == .blocked)
    }
    // Navigation support must not permit custom schemes for downloading media.
    #expect(!MediaPolicy.safeLink(try #require(URL(string: apron))))
}

@MainActor @Test func clickingAnApronMessageLinkOpensReviewWithoutConnecting() throws {
    let model = AppModel(preview: true)
    let existing = model.servers.map(\.id)
    let url = try #require(URL(string: "apron:?server=wss://other.example/&room=general&message=100"))
    _ = MessageNavigation.open(url, review: model.receiveLink)
    #expect(model.showOpenLink)
    #expect(model.openLinkText == url.absoluteString)
    #expect(model.servers.map(\.id) == existing)
    model.showOpenLink = false
    _ = MessageNavigation.open(try #require(URL(string: "apron:?server=file:///tmp/test")), review: model.receiveLink)
    #expect(!model.showOpenLink)
}

@MainActor @Test func relativeMessageLinksKeepTheirSourceServerAndRequireReview() throws {
    let endpoint = "wss://source.example/ws"
    let url = try #require(URL(string: "apron:?room=ops&user=ada%2Bwork"))
    let parsed = MessageMarkdown("[Ops](\(url.absoluteString))", endpoint: endpoint)
    #expect(parsed.blocks.flatMap { $0.text.runs.compactMap(\.link) } == [url])
    #expect(MessageNavigation.destination(url) == .blocked)
    let model = AppModel(preview: true)
    let existing = model.servers.map(\.id)
    _ = MessageNavigation.open(url, relativeTo: endpoint, review: model.receiveLink)
    #expect(model.showOpenLink)
    let reviewed = try ApronLink(model.openLinkText)
    #expect(reviewed.server.absoluteString == endpoint)
    #expect(reviewed.room == "ops" && reviewed.user == "ada+work")
    #expect(model.servers.map(\.id) == existing)
    let explicit = try #require(URL(string: "apron:?server=wss://explicit.example/&room=ops"))
    #expect(MessageNavigation.resolvedLink(explicit, relativeTo: endpoint) == explicit)
    let unsafe = try #require(URL(string: "apron:?server=file:///tmp/test&room=ops"))
    #expect(MessageNavigation.resolvedLink(unsafe, relativeTo: endpoint) == nil)
}

@Test func mentionsDisplayNamesWithoutChangingUnknownIDsOrPrefixes() {
    let names = ["stephancill_2586": "stephancill", "ada": "Ada **Admin**", "ada+tag@example.com": "Ada"]
    let source = "👋 @stephancill_2586, @ada! @unknown @ada_other mail@ada @ada+tag@example.com"
    #expect(MentionDisplay.text(source, names: names) == "👋 @stephancill, @Ada **Admin**! @unknown @ada_other mail@ada @Ada")
    #expect(source.contains("@stephancill_2586"))
}

@Test func markdownMentionsPreserveCodeLinksAndLiteralDisplayNames() {
    let source = "Hello **@ada** `@ada` [@ada](https://example.com/@ada)\n\n```\n@ada\n```"
    let parsed = MessageMarkdown(source, mentionNames: ["ada": "Ada **Admin**"])
    let rendered = parsed.blocks.map { String($0.text.characters) }.joined(separator: "\n")
    #expect(rendered.contains("Hello @Ada **Admin** @ada @ada"))
    #expect(parsed.blocks.contains { $0.kind == .code("") && String($0.text.characters) == "@ada\n" })
    #expect(parsed.blocks.flatMap { $0.text.runs.compactMap(\.link) }.filter { $0.scheme == "https" } == [URL(string: "https://example.com/@ada")!])
}

@Test func clickableMentionsRetainExactUserIdentity() throws {
    let names = ["stephancill_2586": "stephancill", "ada+tag@example.com": "Ada", "another": "Ada"]
    let source = "@stephancill_2586 @ada+tag@example.com @another @unknown"
    let rendered = MentionDisplay.attributed(source, names: names)
    #expect(String(rendered.characters) == "@stephancill @Ada @Ada @unknown")
    let links = rendered.runs.compactMap(\.link)
    #expect(links.compactMap { MentionDisplay.userID($0, names: names) } == ["stephancill_2586", "ada+tag@example.com", "another"])
    #expect(MentionDisplay.userID(try #require(URL(string: "https://example.com/?id=another")), names: names) == nil)
    #expect(MentionDisplay.userID(links[0], names: [:]) == nil)
    let markdown = MessageMarkdown("**@stephancill_2586** `@another`", mentionNames: names)
    let markdownLinks = markdown.blocks.flatMap { $0.text.runs.compactMap(\.link) }
    #expect(markdownLinks.compactMap { MentionDisplay.userID($0, names: names) } == ["stephancill_2586"])
}

@Test func plainMessageURLsAreLinkedWithoutChangingTextOrMentions() {
    let source = "Cupertino: Official Trailer | CBS\nhttps://www.youtube.com/watch?v=GMQXI9SP7T0\nKudos: https://farcaster.xyz/pjc/0xdf3b2c9e. Hi @ada"
    let result = MessageTextDisplay.attributed(source, names: ["ada": "Ada"])
    #expect(String(result.characters) == source.replacingOccurrences(of: "@ada", with: "@Ada"))
    let links = result.runs.compactMap { $0.link?.absoluteString }
    #expect(links.contains("https://www.youtube.com/watch?v=GMQXI9SP7T0"))
    #expect(links.contains("https://farcaster.xyz/pjc/0xdf3b2c9e"))
    #expect(links.contains { $0.hasPrefix("sidetable-mention:") })
    let url = "https://example.com/@ada?q=hello&v=2"
    #expect(String(MessageTextDisplay.attributed(url, names: ["ada": "Ada"]).characters) == url)
    #expect(MessageTextDisplay.attributed("file:///tmp/test javascript:alert(1)").runs.allSatisfy { $0.link == nil })
}

@Test func bareMarkdownURLsLinkButCodeAndExplicitLabelsStayIntact() {
    let parsed = MessageMarkdown("https://example.com/path\n\n`https://example.com/code`\n\n[https://example.com/label](https://example.org/target)\n\n```\nhttps://example.com/fenced\n```")
    #expect(parsed.blocks[0].text.runs.contains { $0.link?.absoluteString == "https://example.com/path" })
    #expect(parsed.blocks[1].text.runs.allSatisfy { $0.link == nil })
    #expect(parsed.blocks[2].text.runs.allSatisfy { $0.link?.absoluteString == "https://example.org/target" })
    #expect(parsed.blocks[3].text.runs.allSatisfy { $0.link == nil })
}

@MainActor @Test func markdownCacheReusesParsesButNotAcrossMentionNamesOrSources() {
    let cache = MessageMarkdownCache(limit: 2)
    let first = cache.parsed("Hi @ben", endpoint: nil, mentionNames: ["ben": "Ben"])
    #expect(cache.parsed("Hi @ben", endpoint: nil, mentionNames: ["ben": "Ben"]).blocks.map(\.text) == first.blocks.map(\.text))
    let renamed = cache.parsed("Hi @ben", endpoint: nil, mentionNames: ["ben": "Benjamin"])
    #expect(String(renamed.blocks[0].text.characters) == "Hi @Benjamin")
    let edited = cache.parsed("Hi again", endpoint: nil, mentionNames: [:])
    #expect(String(edited.blocks[0].text.characters) == "Hi again")
    #expect(String(cache.parsed("Hi @ben", endpoint: nil, mentionNames: ["ben": "Ben"]).blocks[0].text.characters) == "Hi @Ben")
}

@Test func noticesFollowTheLatestMessageKnownWhenTheyArrived() {
    func message(_ id: String) -> JSONObject { ["message_id": .string(id), "room_id": .string("general")] }
    func notice(_ text: String, room: String? = "general", after: UInt64?) -> Notice {
        var record: JSONObject = ["body": .object(["text": .string(text)])]
        if let room { record["room_id"] = .string(room) }
        return Notice(record: record, after: after)
    }
    let notices = [notice("welcome", after: nil), notice("old", after: 5), notice("reply", after: 20),
                   notice("other room", room: "random", after: 20), notice("everywhere", room: nil, after: 25)]
    let placed = TranscriptNotices(notices, room: "general", messages: [message("10"), message("20"), message("30")])
    #expect(placed.leading.map { $0.record.object("body").string("text") } == ["welcome", "old"])
    // Room-less notices appear once per server, not in every conversation.
    #expect(placed.after["20"]?.map { $0.record.object("body").string("text") } == ["reply"])
    #expect(placed.after["10"] == nil && placed.after["30"] == nil)
    #expect(placed.latest == notices[2].id)
}

@MainActor @Test func inlineCodeHasABackgroundAndCodeBlocksAreSmaller() throws {
    let parsed = MessageMarkdown("Run `make check` now")
    let text = MessageTextStyle(size: 14).attributed(parsed.blocks[0].text)
    let code = (text.string as NSString).range(of: "make check")
    #expect(text.attribute(.inlineCode, at: code.location, effectiveRange: nil) != nil)
    #expect(text.attribute(.inlineCode, at: 0, effectiveRange: nil) == nil)
    // Room for the padded background on both sides, without changing the text.
    #expect(text.attribute(.kern, at: code.location - 1, effectiveRange: nil) as? CGFloat == MessageTextStyle.inlineCodePadding)
    #expect(text.attribute(.kern, at: NSMaxRange(code) - 1, effectiveRange: nil) as? CGFloat == MessageTextStyle.inlineCodePadding * 2)
    #expect(text.string == "Run make check now")
    // Inline code keeps the message's point size.
    let font = try #require(text.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
    #expect(font.isFixedPitch && font.pointSize == 14)
    // Code blocks already sit on their own background.
    let block = MessageTextStyle(size: 14, code: true).attributed(AttributedString("let x = 1"))
    #expect(block.attribute(.inlineCode, at: 0, effectiveRange: nil) == nil)
    #expect(MessageTextStyle.codeBlockSize(for: 14) == 12 && MessageTextStyle.codeBlockSize(for: 11) == 10)
    let two = MessageTextStyle.codeBlockHeight("let x = 1\nprint(x)\n", size: 12)
    #expect(two == MessageTextStyle.codeBlockHeight("let x = 1\nprint(x)", size: 12))
    #expect(two < MessageTextStyle.codeBlockHeight("a\nb\nc", size: 12))
    #expect(MessageTextStyle.codeBlockHeight(String(repeating: "line\n", count: 500), size: 12) == 320)
    // Always-visible scroll bars get room below the last line.
    #expect(MessageTextStyle.codeBlockHeight("a", size: 12, scrollerStyle: .legacy)
            > MessageTextStyle.codeBlockHeight("a", size: 12, scrollerStyle: .overlay))
}

@MainActor private final class RecordingScrollResponder: NSResponder {
    var deltas: [CGFloat] = []
    override func scrollWheel(with event: NSEvent) { deltas.append(event.scrollingDeltaY) }
}

@MainActor private func scrollGesture(_ deltas: [Int32]) -> [NSEvent] {
    let steps = [(1, Int32(0))] + deltas.map { (2, $0) } + [(4, Int32(0))]
    return steps.map { phase, delta in
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return NSEvent(cgEvent: event)!
    }
}

@MainActor @Test func codeBlocksKeepGesturesTheyCanScrollAndPassOnTheRest() {
    let view = CodeBlockScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let text = MessageTextView()
    text.show(AttributedString((1...40).map { "line \($0)" }.joined(separator: "\n")), style: MessageTextStyle(size: 12, code: true, lineSpacing: 0))
    view.documentView = text
    view.fitDocument()
    let transcript = RecordingScrollResponder()
    view.nextResponder = transcript
    // Toward the start from the top: the transcript takes the whole gesture.
    for event in scrollGesture([20, 20]) { view.scrollWheel(with: event) }
    #expect(view.contentView.bounds.origin.y == 0)
    #expect(transcript.deltas.filter { $0 != 0 } == [20, 20])
    // Toward the end: the block scrolls and the transcript gets no movement.
    transcript.deltas = []
    for event in scrollGesture([-30, -30]) { view.scrollWheel(with: event) }
    #expect(view.contentView.bounds.origin.y == 60)
    #expect(transcript.deltas.allSatisfy { $0 == 0 })
    // Reaching the end mid-gesture stops at the end rather than moving the transcript.
    let end = text.frame.height - view.contentView.bounds.height
    for event in scrollGesture([-10_000, -40]) { view.scrollWheel(with: event) }
    #expect(view.contentView.bounds.origin.y == end)
    #expect(transcript.deltas.allSatisfy { $0 == 0 })
}

@Test func markdownFallbackBoundsUTF8IncludingLongCombiningSequences() throws {
    let notice = "\n[Message truncated for display. Use Copy Text for the full source.]"
    for source in [String(repeating: "界", count: 30_000), String(repeating: "👋", count: 20_000),
                   "a" + String(repeating: "\u{0301}", count: 40_000)] {
        let parsed = MessageMarkdown(source)
        #expect(parsed.usedFallback)
        let text = String(try #require(parsed.blocks.first).text.characters)
        #expect(text.hasSuffix(notice))
        let prefix = String(text.dropLast(notice.count))
        #expect(prefix.utf8.count <= MessageMarkdown.maximumBytes)
        #expect(source.utf8.starts(with: prefix.utf8))
        #expect(!prefix.contains("\u{FFFD}"))
    }
    let exact = String(repeating: "👋", count: MessageMarkdown.maximumBytes / 4)
    #expect(!MessageMarkdown(exact).usedFallback)
}

@MainActor @Test func markdownCacheBoundsRetainedTextAndCanReleaseIt() {
    let cache = MessageMarkdownCache(byteLimit: 2400)
    for index in 0..<20 {
        _ = cache.parsed("Message \(index): " + String(repeating: "x", count: 400), endpoint: nil, mentionNames: [:])
        #expect(cache.retainedBytes <= cache.byteLimit)
    }
    #expect(cache.entryCount > 0 && cache.entryCount < 20)
    let count = cache.entryCount, bytes = cache.retainedBytes
    let oversized = cache.parsed(String(repeating: "x", count: MessageMarkdown.maximumBytes + 1), endpoint: nil, mentionNames: [:])
    #expect(oversized.usedFallback)
    #expect(cache.entryCount == count && cache.retainedBytes == bytes)
    _ = cache.parsed("@ada", endpoint: nil, mentionNames: ["ada": String(repeating: "a", count: 3000)])
    #expect(cache.entryCount == count && cache.retainedBytes == bytes)
    cache.clear()
    #expect(cache.entryCount == 0 && cache.retainedBytes == 0)
    let disabled = MessageMarkdownCache(limit: 0)
    #expect(!disabled.parsed("hello", endpoint: nil, mentionNames: [:]).blocks.isEmpty)
    #expect(disabled.entryCount == 0)
}

@MainActor @Test func nativeRenderingIgnoresOverridesAndIsolatesMentionNames() throws {
    let source = "Hello @ada \u{202E}exe.txt\u{202C} שלום"
    let attributed = MessageTextDisplay.attributed(source, names: ["ada": "אב\u{2069}\u{202E}"])
    let rendered = MessageTextStyle(size: 14).attributed(attributed)
    #expect(rendered.string == "Hello \u{2068}@אב\u{2069} exe.txt שלום")
    #expect(source.contains("\u{202E}"))
    let index = (rendered.string as NSString).range(of: "@אב").location
    let link = try #require(rendered.attribute(.link, at: index, effectiveRange: nil) as? URL)
    #expect(MentionDisplay.userID(link, names: ["ada": "אב"]) == "ada")
    let paragraph = try #require(rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
    #expect(paragraph.baseWritingDirection == .natural)
}

@MainActor @Test func liveServerMetadataReplacesWithoutChangingSavedIdentity() {
    let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
    let saved = server.profile
    #expect(server.displayTitle == saved.address)
    server.snapshot.server = ["title": .string("Team"), "description": .string("**Hello**"), "avatar": .string("https://chat.example/icon")]
    #expect(server.displayTitle == "Team" && server.serverDescription == "**Hello**" && server.serverAvatar != nil)
    server.snapshot.server = ["title": .number(1)]
    #expect(server.displayTitle == saved.address && server.serverDescription == nil && server.serverAvatar == nil)
    #expect(server.profile.address == saved.address && server.profile.id == saved.id)
}

@Test func roomReferencesUseProtocolBoundariesAndKeepExactDestinations() throws {
    let rooms = ["1791590929296": "Release planning", "ops": "Operations", "a+b@c:d": "Federated **room**"]
    let source = "See #1791590929296, (#ops). tag#ops α#ops #missing #a+b@c:d!"
    let rendered = MessageTextDisplay.attributed(source, roomNames: rooms)
    #expect(String(rendered.characters) == "See #Release planning, (#Operations). tag#ops α#ops #missing #Federated **room**!")
    let links = rendered.runs.compactMap(\.link)
    let parsed = try links.map { try ApronLink($0.absoluteString, relativeTo: "wss://chat.example/") }
    #expect(parsed.compactMap(\.room) == ["1791590929296", "ops", "a+b@c:d"])
    #expect(parsed.allSatisfy { $0.server.absoluteString == "wss://chat.example/" && $0.token == nil && $0.user == nil })
    #expect(String(MessageTextDisplay.attributed(source).characters) == source)
}

@Test func markdownRoomReferencesPreserveCodeURLsAndExplicitLinkLabels() {
    let parsed = MessageMarkdown("**#ops** @ada\n\n`#ops`\n\n[#ops](https://example.org/)\n\nhttps://example.org/#ops\n\n```\n#ops\n```", mentionNames: ["ada": "Ada #ops"], roomNames: ["ops": "Operations"])
    #expect(String(parsed.blocks[0].text.characters) == "#Operations @Ada #ops")
    #expect(parsed.blocks[0].text.runs.filter { RoomReferenceDisplay.isReference($0.link) }.count == 1)
    #expect(String(parsed.blocks[1].text.characters) == "#ops" && parsed.blocks[1].text.runs.allSatisfy { $0.link == nil })
    #expect(String(parsed.blocks[2].text.characters) == "#ops")
    #expect(parsed.blocks[2].text.runs.allSatisfy { $0.link?.absoluteString == "https://example.org/" })
    #expect(String(parsed.blocks[3].text.characters) == "https://example.org/#ops")
    #expect(parsed.blocks[4].text.runs.allSatisfy { $0.link == nil })
}

@MainActor @Test func roomReferenceCacheTracksRenamesAndServerSpecificNames() {
    let cache = MessageMarkdownCache()
    let first = cache.parsed("#ops", endpoint: "wss://one.example/", mentionNames: [:], roomNames: ["ops": "Operations"])
    #expect(String(first.blocks[0].text.characters) == "#Operations")
    let renamed = cache.parsed("#ops", endpoint: "wss://one.example/", mentionNames: [:], roomNames: ["ops": "Planning"])
    #expect(String(renamed.blocks[0].text.characters) == "#Planning")
    let other = cache.parsed("#ops", endpoint: "wss://two.example/", mentionNames: [:])
    #expect(String(other.blocks[0].text.characters) == "#ops" && other.blocks[0].text.runs.allSatisfy { $0.link == nil })
}

@MainActor @Test func markdownCacheEvictsTheLeastRecentlyUsedEntry() {
    let cache = MessageMarkdownCache(limit: 2)
    _ = cache.parsed("first", endpoint: nil, mentionNames: [:])
    _ = cache.parsed("second", endpoint: nil, mentionNames: [:])
    _ = cache.parsed("first", endpoint: nil, mentionNames: [:]) // A row still on screen.
    _ = cache.parsed("third", endpoint: nil, mentionNames: [:])
    #expect(cache.contains("first", endpoint: nil, mentionNames: [:]))
    #expect(!cache.contains("second", endpoint: nil, mentionNames: [:]))
    #expect(cache.contains("third", endpoint: nil, mentionNames: [:]))
    #expect(cache.entryCount == 2)
}

@MainActor @Test func mergedMarkdownPreservesBoundariesLinksAndListGeometry() throws {
    let source = """
    # Heading

    Intro **bold** with [a link](https://example.com).

    Another paragraph
    with a soft break.

    - First item with enough words to wrap at narrow widths.
    - Second item
      1. Nested item

    > A quote

    ```swift
    let value = 1
    ```

    ---
    """
    let parsed = MessageMarkdown(source)
    #expect(parsed.displayBlocks.count < parsed.blocks.count)
    #expect(parsed.displayBlocks.filter { $0.kind == .heading(1) }.count == 1)
    #expect(parsed.displayBlocks.filter { $0.quote }.count == 1)
    #expect(parsed.displayBlocks.contains { $0.kind == .code("swift") })
    #expect(parsed.displayBlocks.contains { $0.kind == .rule })
    let group = try #require(parsed.displayBlocks.first { $0.kind == .paragraphGroup })
    let native = MessageTextStyle(size: 14).attributed(group.text)
    #expect(native.string.contains("Another paragraph\nwith a soft break."))
    #expect(native.string.contains("\t•\tFirst item"))
    let list = (native.string as NSString).range(of: "First item")
    let listStyle = try #require(native.attribute(.paragraphStyle, at: list.location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(listStyle.headIndent == 25 && listStyle.firstLineHeadIndent == 0)
    let nested = (native.string as NSString).range(of: "Nested item")
    let nestedStyle = try #require(native.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(nestedStyle.headIndent == 41 && nestedStyle.firstLineHeadIndent == 16)
    let soft = (native.string as NSString).range(of: "with a soft break")
    let softStyle = try #require(native.attribute(.paragraphStyle, at: soft.location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(softStyle.paragraphSpacingBefore == 0)
    let another = (native.string as NSString).range(of: "Another paragraph")
    let anotherStyle = try #require(native.attribute(.paragraphStyle, at: another.location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(anotherStyle.paragraphSpacingBefore == 5)
    let link = (native.string as NSString).range(of: "a link")
    #expect(native.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    let view = MessageTextView()
    view.show(group.text, style: MessageTextStyle(size: 14))
    view.setSelectedRange(NSRange(location: list.location, length: nested.location + nested.length - list.location))
    let selected = view.selectedRange()
    #expect(view.measuredSize(width: 220).height > view.measuredSize(width: 500).height)
    #expect(view.selectedRange() == selected)
}

@Test func mergedMarkdownLeavesSingleBlocksAndQuotedParagraphsSeparate() {
    let single = MessageMarkdown("Only **one** paragraph")
    #expect(single.displayBlocks.count == 1 && single.displayBlocks[0].kind == .paragraph)
    let quotes = MessageMarkdown("> First quote\n>\n> Second quote\n\nOutside")
    #expect(quotes.displayBlocks.count == quotes.blocks.count)
    let fallback = MessageMarkdown(String(repeating: "x", count: MessageMarkdown.maximumBytes + 1))
    #expect(fallback.usedFallback && fallback.displayBlocks.count == 1)
}
