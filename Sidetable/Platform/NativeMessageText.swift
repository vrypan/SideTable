import AppKit
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
        let style = MessageTextStyle(size: size, semibold: semibold, code: code, lineSpacing: lineSpacing)
        if view.source != text || view.style != style {
            view.source = text; view.style = style
            view.textStorage?.setAttributedString(style.attributed(text))
            view.setAccessibilityIdentifier(String(text.characters))
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextView, context: Context) -> CGSize? {
        view.measuredSize(width: proposal.width)
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

struct MessageTextStyle: Equatable {
    let size: Double
    var semibold = false
    var code = false
    var lineSpacing: CGFloat = 3

    @MainActor func attributed(_ source: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = code || intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: semibold ? .semibold : .regular)
                : NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if let link = run.link { attributes[.link] = link }
            if run.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        return result
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
            let manager = NSLayoutManager()
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
