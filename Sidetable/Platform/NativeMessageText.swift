import AppKit
import ApronCore
import SwiftUI

/// Read-only native text keeps selection commands while giving unselected text
/// the same message menu as the surrounding row.
struct NativeMessageText: NSViewRepresentable {
    let text: AttributedString
    let size: Double
    var semibold = false
    var code = false
    var lineSpacing: CGFloat = 3
    @Environment(\.messageActions) private var actions
    @Environment(\.messageMenuVisibility) private var menuVisibility
    @Environment(\.openURL) private var openURL

    func makeNSView(context: Context) -> MessageTextView {
        MessageTextViewPool.shared.take()
    }

    static func dismantleNSView(_ view: MessageTextView, coordinator: ()) {
        MessageTextViewPool.shared.recycle(view)
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.actions = actions
        view.menuVisibility = menuVisibility
        view.openLink = { openURL($0) }
        view.show(text, style: MessageTextStyle(size: size, semibold: semibold, code: code, lineSpacing: lineSpacing))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextView, context: Context) -> CGSize? {
        view.measuredSize(width: proposal.width)
    }
}

/// A code block's own native scroll view. Nested SwiftUI scroll views can hand
/// a gesture over a code block to the transcript, so each gesture is assigned
/// once: to the block when it can move that way, otherwise to the transcript.
struct CodeBlockText: NSViewRepresentable {
    let text: AttributedString
    let size: Double
    @Environment(\.messageActions) private var actions
    @Environment(\.messageMenuVisibility) private var menuVisibility
    @Environment(\.openURL) private var openURL

    func makeNSView(context: Context) -> CodeBlockScrollView {
        let view = CodeBlockScrollView()
        view.documentView = MessageTextViewPool.shared.take()
        return view
    }

    static func dismantleNSView(_ view: CodeBlockScrollView, coordinator: ()) {
        guard let text = view.documentView as? MessageTextView else { return }
        view.documentView = nil
        MessageTextViewPool.shared.recycle(text)
    }

    func updateNSView(_ view: CodeBlockScrollView, context: Context) {
        guard let textView = view.documentView as? MessageTextView else { return }
        textView.actions = actions
        textView.menuVisibility = menuVisibility
        textView.openLink = { openURL($0) }
        textView.show(text, style: MessageTextStyle(size: size, code: true, lineSpacing: 0))
        view.fitDocument()
    }
}

final class CodeBlockScrollView: NSScrollView {
    private enum Owner { case block, transcript }
    private var owner: Owner?

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        verticalScrollElasticity = .none; horizontalScrollElasticity = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() { super.layout(); fitDocument() }

    /// The text keeps its natural width so long lines scroll instead of wrapping.
    func fitDocument() {
        guard let text = documentView as? MessageTextView else { return }
        let natural = text.measuredSize(width: nil)
        let size = NSSize(width: max(natural.width, contentSize.width), height: natural.height)
        if text.frame.size != size { text.setFrameSize(size) }
        verticalLineScroll = text.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 14
        horizontalLineScroll = verticalLineScroll
    }

    override func scrollWheel(with event: NSEvent) {
        // A new gesture, or a plain mouse wheel notch, is assigned afresh.
        if event.phase == .began || event.phase == .mayBegin || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            owner = nil
        }
        var delta = NSPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas { delta.x *= horizontalLineScroll; delta.y *= verticalLineScroll }
        if owner == nil, delta != .zero { owner = canScroll(by: delta) ? .block : .transcript }
        if owner == .block { scroll(by: delta) }
        // The transcript also sees where each gesture starts and ends.
        if owner != .block || event.phase == .began || event.phase == .mayBegin || event.phase == .ended || event.phase == .cancelled {
            nextResponder?.scrollWheel(with: event)
        }
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled { owner = nil }
    }

    private var maximumOrigin: NSPoint {
        guard let document = documentView else { return .zero }
        return NSPoint(x: max(0, document.frame.width - contentView.bounds.width),
                       y: max(0, document.frame.height - contentView.bounds.height))
    }

    /// Positive deltas move toward the start, as with AppKit's own scroll events.
    private func target(_ delta: NSPoint) -> NSPoint {
        let origin = contentView.bounds.origin, limit = maximumOrigin
        let vertical = abs(delta.y) >= abs(delta.x)
        return NSPoint(x: vertical ? origin.x : min(limit.x, max(0, origin.x - delta.x)),
                       y: vertical ? min(limit.y, max(0, origin.y - delta.y)) : origin.y)
    }

    func canScroll(by delta: NSPoint) -> Bool { target(delta) != contentView.bounds.origin }

    private func scroll(by delta: NSPoint) {
        let next = target(delta)
        guard next != contentView.bounds.origin else { return }
        contentView.scroll(to: next)
        reflectScrolledClipView(contentView)
        flashScrollers()
    }
}

/// AppKit does not release NSTextView instances once created, and each live one
/// observes every view frame change, so scrolling slows as rows are rebuilt.
/// Reusing dismantled views bounds that cost by the most rows shown at once.
@MainActor final class MessageTextViewPool {
    static let shared = MessageTextViewPool()
    private var spare: [MessageTextView] = []
    private(set) var created = 0
    let limit: Int

    init(limit: Int = 256) { self.limit = limit }

    func take() -> MessageTextView {
        if let view = spare.popLast() { return view }
        created += 1
        return MessageTextView()
    }

    func recycle(_ view: MessageTextView) {
        view.actions = []; view.menuVisibility = { _ in }; view.openLink = { _ in }
        view.source = nil; view.style = nil
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.textStorage?.setAttributedString(NSAttributedString())
        view.setAccessibilityIdentifier(nil)
        if spare.count < limit { spare.append(view) }
    }
}

extension NSAttributedString.Key {
    /// Marks inline code, whose padded background `InlineCodeLayoutManager` draws.
    static let inlineCode = NSAttributedString.Key("SideTableInlineCode")
}

struct MessageTextStyle: Equatable {
    let size: Double
    var semibold = false
    var code = false
    var lineSpacing: CGFloat = 3

    /// Code blocks are set smaller than the surrounding message text.
    static func codeBlockSize(for size: Double) -> Double { max(10, size - 2) }

    /// Fits a code block's lines, up to a scrolling limit. The block's final newline ends
    /// its last line rather than starting another. Always-visible scroll bars, which
    /// people can choose in System Settings, also need room below the last line.
    @MainActor static func codeBlockHeight(_ code: String, size: Double, limit: CGFloat = 320,
                                           scrollerStyle: NSScroller.Style = NSScroller.preferredScrollerStyle) -> CGFloat {
        let lines = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count - (code.hasSuffix("\n") ? 1 : 0))
        let scroller = scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return min(limit, ceil(CGFloat(lines) * codeLineHeight(size)) + 4 + scroller)
    }

    @MainActor private static var codeLineHeights: [Double: CGFloat] = [:]
    @MainActor private static func codeLineHeight(_ size: Double) -> CGFloat {
        if let height = codeLineHeights[size] { return height }
        let height = NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: size, weight: .regular))
        codeLineHeights[size] = height
        return height
    }

    /// Horizontal space between inline code's text and the edge of its background.
    static let inlineCodePadding: CGFloat = 3

    @MainActor func attributed(_ source: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.baseWritingDirection = .natural
        let weight: NSFont.Weight = semibold ? .semibold : .regular
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            let inlineCode = !code && intent.contains(.code)
            var font = code || inlineCode ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if let link = run.link { attributes[.link] = link }
            if run.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Inline code stands out from prose; code blocks draw their own background.
            if inlineCode { attributes[.inlineCode] = true }
            let value = String(source[run.range].characters)
            let display = run.link?.scheme == "sidetable-mention" ? UserText.isolated(value) : UserText.clean(value)
            result.append(NSAttributedString(string: display, attributes: attributes))
        }
        // Kerning makes room for the padded background: before the code, and after it
        // for both the padding and the same gap again before the next character.
        let padding = Self.inlineCodePadding
        result.enumerateAttribute(.inlineCode, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            if range.location > 0 { result.addAttribute(.kern, value: padding, range: NSRange(location: range.location - 1, length: 1)) }
            result.addAttribute(.kern, value: padding * 2, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
        return result
    }
}

/// Draws inline code's rounded background with padding, which a background color
/// attribute cannot provide. Selection highlighting still draws above it.
final class InlineCodeLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let padding = MessageTextStyle.inlineCodePadding
            let lineSpacing = (storage.length > 0 ? storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)?.lineSpacing ?? 0
            NSColor.tertiarySystemFill.setFill()
            storage.enumerateAttribute(.inlineCode, in: characters) { value, range, _ in
                guard value != nil else { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                // One background per line the code occupies, fitted to its glyphs.
                enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                    let piece = NSIntersectionRange(glyphs, lineGlyphs)
                    guard piece.length > 0 else { return }
                    var fill = self.boundingRect(forGlyphRange: piece, in: container).offsetBy(dx: origin.x, dy: origin.y)
                    // Padding sits in the kerning before the code and after its last glyph,
                    // whose advance also holds the gap to the next character.
                    if piece.location == glyphs.location { fill.origin.x -= padding; fill.size.width += padding }
                    if NSMaxRange(piece) == NSMaxRange(glyphs) { fill.size.width -= padding }
                    if fill.minX < origin.x { fill.size.width -= origin.x - fill.minX; fill.origin.x = origin.x }
                    fill.size.height = max(0, fill.height - lineSpacing)
                    NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

final class MessageTextView: NSTextView, NSTextViewDelegate {
    var actions: [MessageAction] = []
    var menuVisibility: (Bool) -> Void = { _ in }
    var openLink: (URL) -> Void = { _ in }
    var source: AttributedString?
    var style: MessageTextStyle?

    private let ownedTextStorage: NSTextStorage?

    override init(frame: NSRect = .zero, textContainer: NSTextContainer? = nil) {
        let container: NSTextContainer
        if let textContainer { container = textContainer; ownedTextStorage = textContainer.layoutManager?.textStorage }
        else {
            let storage = NSTextStorage()
            ownedTextStorage = storage
            let manager = InlineCodeLayoutManager()
            container = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(container)
        }
        super.init(frame: frame, textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true
        drawsBackground = false; textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false; container.heightTracksTextView = false
        isHorizontallyResizable = false; isVerticallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = CGSize(width: max(1, newSize.width), height: CGFloat.greatestFiniteMagnitude)
    }

    func show(_ text: AttributedString, style: MessageTextStyle) {
        guard source != text || self.style != style else { return }
        source = text; self.style = style
        textStorage?.setAttributedString(style.attributed(text))
        setAccessibilityIdentifier(String(text.characters))
        invalidateIntrinsicContentSize()
    }

    func measuredSize(width: CGFloat?) -> CGSize {
        guard let textStorage else { return .zero }
        // SwiftUI measures several proposed widths before assigning the view's
        // frame. Measure the attributed text independently of that current frame.
        let proposedWidth = max(1, width ?? 1_000_000)
        let used = textStorage.boundingRect(with: CGSize(width: proposedWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width ?? ceil(used.width), height: ceil(max(used.height, font?.pointSize ?? 1)))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        // NSTextView's default handler can select the clicked word before asking
        // for a menu. Decide from the user's existing selection instead.
        guard let menu = menu(for: event) else { return }
        menuVisibility(true)
        defer { menuVisibility(false) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !actions.isEmpty else { return super.menu(for: event) }
        let hasSelection = window?.firstResponder === self && selectedRanges.contains { $0.rangeValue.length > 0 }
        let messageMenu = MessageAction.menu(actions)
        guard hasSelection else { return messageMenu }
        let selection = selectedRanges
        // Ask AppKit about a point inside the existing selection, so commands
        // such as Look Up describe the selected text rather than a nearby word.
        var selectionEvent = event
        if let window {
            let rect = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 1), actualRange: nil)
            let location = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            selectionEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: event.modifierFlags,
                timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure) ?? event
        }
        let menu = super.menu(for: selectionEvent) ?? NSMenu()
        setSelectedRanges(selection, affinity: selectionAffinity, stillSelecting: false)
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Message Actions", action: nil, keyEquivalent: "")
        item.submenu = messageMenu
        menu.addItem(item)
        return menu
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { openLink(url) }
        else if let address = link as? String, let url = URL(string: address) { openLink(url) }
        return true
    }
}
