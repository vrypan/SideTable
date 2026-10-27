import AppKit
import SwiftUI
import Testing
@testable import Sidetable

@MainActor @Test func messageTextMenuUsesActionsWithoutSelectingTheClickedWord() throws {
    let view = MessageTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    view.isEditable = false; view.isSelectable = true
    view.string = "A message with selectable words"
    var replied = false
    view.actions = [MessageAction(title: "Reply", perform: { replied = true }), MessageAction(title: "Edit…", enabled: false)]
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    let menu = try #require(view.menu(for: event))
    #expect(menu.items.map(\.title) == ["Reply", "Edit…"])
    #expect(!menu.items[1].isEnabled)
    #expect(view.selectedRange().length == 0)
    menu.performActionForItem(at: 0)
    #expect(replied)
}

@MainActor @Test func selectedMessageTextKeepsNativeCopyAndAddsMessageActions() throws {
    let view = MessageTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    view.isEditable = false; view.isSelectable = true
    view.string = "Select just these words"
    view.actions = [MessageAction(title: "Reply"), MessageAction(title: "Move to…", children: [MessageAction(title: "General")])]
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.makeFirstResponder(view)
    let selected = NSRange(location: 7, length: 4)
    view.setSelectedRange(selected)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    let menu = try #require(view.menu(for: event))
    #expect(menu.items.contains { $0.action == #selector(NSText.copy(_:)) })
    let submenu = try #require(menu.items.last?.submenu)
    #expect(menu.items.last?.title == "Message Actions")
    #expect(submenu.items.map(\.title) == ["Reply", "Move to…"])
    #expect(submenu.items.last?.submenu?.items.first?.title == "General")
    #expect(view.selectedRange() == selected)
    // A selection left in an inactive text view must not change its next menu.
    window.makeFirstResponder(nil)
    #expect(view.menu(for: event)?.items.first?.title == "Reply")
}

@MainActor @Test func nativeMessageTextPreservesMarkdownStylesAndLinkRouting() throws {
    let parsed = MessageMarkdown("**Bold** *italic* `code` [link](https://example.com/)")
    let rendered = MessageTextStyle(size: 15).attributed(try #require(parsed.blocks.first).text)
    let source = rendered.string as NSString
    let bold = try #require(rendered.attribute(.font, at: source.range(of: "Bold").location, effectiveRange: nil) as? NSFont)
    let italic = try #require(rendered.attribute(.font, at: source.range(of: "italic").location, effectiveRange: nil) as? NSFont)
    let code = try #require(rendered.attribute(.font, at: source.range(of: "code").location, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
    #expect(code.isFixedPitch)
    let url = try #require(rendered.attribute(.link, at: source.range(of: "link").location, effectiveRange: nil) as? URL)
    #expect(url.absoluteString == "https://example.com/")
    let view = MessageTextView()
    var opened: URL?
    view.openLink = { opened = $0 }
    #expect(view.textView(view, clickedOnLink: url, at: 0))
    #expect(opened == url)
}

@MainActor @Test func nativeMessageTextMeasuresWrappingWithoutChangingSelection() {
    let view = MessageTextView()
    view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(MessageTextStyle(size: 15).attributed(AttributedString(String(repeating: "A readable message. ", count: 12))))
    view.setSelectedRange(NSRange(location: 2, length: 8))
    let narrow = view.measuredSize(width: 180)
    let wide = view.measuredSize(width: 600)
    #expect(narrow.width == 180 && wide.width == 600)
    #expect(!view.string.isEmpty)
    #expect(narrow.height > wide.height)
    #expect(wide.height > 15)
    #expect(view.measuredSize(width: 180) == narrow)
    #expect(view.selectedRange() == NSRange(location: 2, length: 8))
}

@MainActor @Test func messageContextHighlightUpdatesImmediatelyAndClears() {
    let highlight = MessageMenuHighlight()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    view.wantsLayer = true
    highlight.view = view
    highlight.setVisible(true)
    #expect(highlight.isVisible)
    #expect(view.layer?.backgroundColor?.alpha == 0.15)
    highlight.setVisible(false)
    #expect(!highlight.isVisible)
    #expect(view.layer?.backgroundColor?.alpha == 0)
}
