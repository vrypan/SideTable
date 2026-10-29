import AppKit
import SwiftUI

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    var candidates: [ComposerSuggestion] = []
    var insertion: ComposerInsertion?
    var acceptsAttachments = false
    var pasteFiles: ([StagedFile]) -> Void = { _ in }
    var pasteError: (String) -> Void = { _ in }
    var focused: () -> Void = {}
    var send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let editor = ComposerTextView()
        editor.isRichText = false; editor.drawsBackground = false; editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 2, height: 6)
        editor.delegate = context.coordinator
        editor.candidates = candidates
        editor.acceptsAttachments = acceptsAttachments; editor.pasteFiles = pasteFiles; editor.pasteError = pasteError
        editor.focused = focused
        editor.send = send; editor.placeholder = placeholder
        editor.setAccessibilityLabel("Message composer")
        editor.setAccessibilityIdentifier("messageComposer")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? ComposerTextView else { return }
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        editor.candidates = candidates
        editor.acceptsAttachments = acceptsAttachments; editor.pasteFiles = pasteFiles; editor.pasteError = pasteError
        editor.focused = focused
        editor.isEditable = enabled; editor.send = send; editor.placeholder = placeholder; editor.needsDisplay = true
        if let insertion { editor.apply(insertion) }
        if !enabled { editor.hideCompletions() }
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        (view.documentView as? ComposerTextView)?.hideCompletions()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        init(_ parent: NativeComposer) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? ComposerTextView)?.selectionDidChange()
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; editor.needsDisplay = true
        }
    }
}

final class ComposerTextView: NSTextView {
    func apply(_ insertion: ComposerInsertion) {
        guard lastInsertionID != insertion.id else { return }
        lastInsertionID = insertion.id
        if insertion.focus { window?.makeFirstResponder(self) }
        insertText(CustomEmojiText.insertion(insertion.text, into: string, range: selectedRange()), replacementRange: selectedRange())
    }

    var candidates: [ComposerSuggestion] = [] {
        didSet { if candidates != oldValue { refreshCompletions() } }
    }
    var lastInsertionID: UUID?
    private var completionPanel: CompletionPanel?
    private var suggestions: [ComposerSuggestion] = []
    private var completionQuery: ComposerCompletion.Query?
    private var selectedSuggestion = 0
    var focused: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focused?() }
        return result
    }
    var send: (() -> Void)?
    var placeholder = ""
    var acceptsAttachments = false
    var pasteFiles: (([StagedFile]) -> Void)?
    var pasteError: ((String) -> Void)?
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // AppKit validates Paste before dispatching it. A plain-text view must
        // advertise image support or image-only clipboard contents just beep.
        let types = super.readablePasteboardTypes
        guard acceptsAttachments else { return types }
        return [.fileURL, .png, .tiff] + types.filter { ![.fileURL, .png, .tiff].contains($0) }
    }
    override func paste(_ sender: Any?) {
        if !stageAttachments(from: .general) { super.paste(sender) }
    }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if stageAttachments(from: pasteboard) { return true }
        return super.readSelection(from: pasteboard, type: type)
    }
    private func stageAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, acceptsAttachments, let pasteFiles else { return false }
        do {
            let files = try ClipboardAttachments.files(from: pasteboard)
            guard !files.isEmpty else { return false }
            // Typing (including inline predictions) can leave marked text. Keep the
            // draft intact instead of falling back to AppKit's file-path insertion.
            if hasMarkedText() { unmarkText() }
            hideCompletions()
            pasteFiles(files)
        } catch { pasteError?(error.localizedDescription) }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), !suggestions.isEmpty {
            switch event.keyCode {
            case 53: hideCompletions(); return
            case 125: selectedSuggestion = (selectedSuggestion + 1) % suggestions.count; showCompletions(); return
            case 126: selectedSuggestion = (selectedSuggestion + suggestions.count - 1) % suggestions.count; showCompletions(); return
            case 48: chooseCompletion(selectedSuggestion); return
            case 36, 76:
                if !event.modifierFlags.contains(.shift) { chooseCompletion(selectedSuggestion); return }
            default: break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if hasMarkedText() { super.keyDown(with: event); return }
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil); return }
            if isEditable { send?() }; return
        }
        super.keyDown(with: event)
    }
    override func didChangeText() {
        super.didChangeText()
        refreshCompletions()
    }
    override func resignFirstResponder() -> Bool {
        hideCompletions()
        return super.resignFirstResponder()
    }
    private func refreshCompletions() {
        guard isEditable, !hasMarkedText(), let query = ComposerCompletion.query(in: string, selection: selectedRange()) else {
            hideCompletions(); return
        }
        completionQuery = query
        suggestions = ComposerCompletion.suggestions(for: query, candidates: candidates)
        selectedSuggestion = 0
        if suggestions.isEmpty { hideCompletions() } else { showCompletions() }
    }
    func selectionDidChange() {
        if let completionQuery, completionQuery != ComposerCompletion.query(in: string, selection: selectedRange()) { hideCompletions() }
    }
    func hideCompletions() {
        if let panel = completionPanel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        completionPanel = nil; suggestions = []; completionQuery = nil
    }
    private func chooseCompletion(_ index: Int) {
        guard let query = completionQuery, suggestions.indices.contains(index),
              query == ComposerCompletion.query(in: string, selection: selectedRange()) else { hideCompletions(); return }
        if query.marker == ":" { RecentEmojis().record(suggestions[index].insertion) }
        let replacement = suggestions[index].insertion + " "
        hideCompletions()
        window?.makeFirstResponder(self)
        insertText(replacement, replacementRange: query.range)
    }
    private func showCompletions() {
        guard let window, let query = completionQuery else { return }
        let panel = completionPanel ?? CompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let items = suggestions
        let selected = selectedSuggestion
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { [weak self] in self?.chooseCompletion(index) } label: {
                    Text(item.label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(7)
                        .background(index == selected ? Color.accentColor.opacity(0.2) : .clear)
                }.buttonStyle(.plain)
            }
        }.padding(4).frame(width: 320).background(Color(nsColor: .windowBackgroundColor)))
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        let height = CGFloat(items.count * 30 + 8)
        let caret = firstRect(forCharacterRange: NSRange(location: query.range.location, length: 0), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? window.frame
        panel.setFrame(NSRect(x: min(max(caret.minX, screen.minX), screen.maxX - 320),
            y: min(caret.maxY + 4, screen.maxY - height), width: 320, height: height), display: true)
        if completionPanel == nil { window.addChildWindow(panel, ordered: .above); completionPanel = panel }
        panel.orderFront(nil)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 7, y: 6), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}

private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
