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
