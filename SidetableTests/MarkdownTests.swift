import Foundation
import Testing
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
