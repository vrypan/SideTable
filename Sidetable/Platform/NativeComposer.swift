import AppKit
import SwiftUI

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    var candidates: [ComposerSuggestion] = []
    var insertion: ComposerInsertion?
    var referenceNames: [String: String] = [:]
    var markdown = true
    var returnSends = true
    var contextID: String? = nil
    var autofocus = false
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
        editor.isRichText = true; editor.drawsBackground = false; editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 2, height: 6)
        editor.setContext(contextID)
        editor.configurePresentation(names: referenceNames, markdown: markdown)
        editor.returnSends = returnSends
        editor.focusOnAttach = autofocus
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
        editor.setContext(contextID)
        editor.configurePresentation(names: referenceNames, markdown: markdown)
        editor.setSource(text)
        editor.returnSends = returnSends
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
            guard let editor = notification.object as? ComposerTextView else { return }
            parent.text = editor.sourceText; editor.needsDisplay = true
        }
    }
}

final class ComposerTextView: NSTextView {
    var focusOnAttach = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAttach, window != nil else { return }
        focusOnAttach = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.isEditable else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: self.string.utf16.count, length: 0))
        }
    }

    var returnSends = true
    private var presentationEnabled = false
    private var referenceNames: [String: String] = [:]
    private var markdown = true
    private var rendering = false
    private let sourceUndo = UndoManager()
    private struct SourceState { let text: String; let selection: NSRange }
    private var beforeEdit: SourceState?
    // AppKit's range-based undo cannot survive attachment compaction. Register only raw snapshots.
    override var undoManager: UndoManager? { presentationEnabled ? nil : super.undoManager }
    var sourceUndoManager: UndoManager { sourceUndo }
    private var sourceContext: String?
    func setContext(_ context: String?) {
        guard sourceContext != context else { return }
        sourceContext = context; sourceUndo.removeAllActions(); beforeEdit = nil; hideCompletions()
    }
    @objc func undo(_ sender: Any?) { if isEditable && sourceUndo.canUndo { sourceUndo.undo() } }
    @objc func redo(_ sender: Any?) { if isEditable && sourceUndo.canRedo { sourceUndo.redo() } }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if presentationEnabled, menuItem.action == #selector(undo(_:)) { return isEditable && sourceUndo.canUndo }
        if presentationEnabled, menuItem.action == #selector(redo(_:)) { return isEditable && sourceUndo.canRedo }
        return super.validateMenuItem(menuItem)
    }
    var sourceText: String { presentationEnabled ? textStorage.map(ComposerPresentation.raw) ?? string : string }
    var sourceSelection: NSRange { presentationEnabled ? textStorage.map { ComposerPresentation.rawRange(selectedRange(), in: $0) } ?? selectedRange() : selectedRange() }
    func configurePresentation(names: [String: String], markdown: Bool) {
        let changed = !presentationEnabled || referenceNames != names || self.markdown != markdown
        if !presentationEnabled { sourceUndo.levelsOfUndo = 100 }
        presentationEnabled = true; allowsUndo = false; isRichText = true; importsGraphics = false
        referenceNames = names; self.markdown = markdown
        if changed { renderSource() }
    }
    func setSource(_ text: String) {
        guard !hasMarkedText(), sourceText != text else { return }
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: ComposerPresentation.attributes))
        sourceUndo.removeAllActions(); beforeEdit = nil; renderSource()
    }
    private func renderSource() {
        guard presentationEnabled, !rendering, !hasMarkedText(), let storage = textStorage else { return }
        let text = sourceText, selection = sourceSelection
        rendering = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            storage.setAttributedString(ComposerPresentation.render(text, names: referenceNames, markdown: markdown))
        }
        setSelectedRange(ComposerPresentation.displayRange(selection, in: storage))
        typingAttributes = ComposerPresentation.attributes
        rendering = false; needsDisplay = true
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, presentationEnabled, !rendering, beforeEdit == nil {
            beforeEdit = SourceState(text: sourceText, selection: sourceSelection)
        }
        return allowed
    }
    private func restore(_ state: SourceState) {
        let inverse = SourceState(text: sourceText, selection: sourceSelection)
        sourceUndo.registerUndo(withTarget: self) { $0.restore(inverse) }
        textStorage?.setAttributedString(NSAttributedString(string: state.text, attributes: ComposerPresentation.attributes))
        setSelectedRange(state.selection)
        beforeEdit = nil; renderSource(); super.didChangeText(); hideCompletions()
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if presentationEnabled {
            let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String ?? "")
            super.insertText(NSAttributedString(string: text, attributes: ComposerPresentation.attributes), replacementRange: replacementRange)
        } else { super.insertText(insertString, replacementRange: replacementRange) }
    }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard presentationEnabled, let storage = textStorage else { return super.writeSelection(to: pasteboard, type: type) }
        guard type == .string else { return false }
        return pasteboard.setString(ComposerPresentation.raw(storage.attributedSubstring(from: selectedRange())), forType: .string)
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { presentationEnabled ? [.string] : super.writablePasteboardTypes }
    override func unmarkText() { super.unmarkText(); if presentationEnabled { finishPresentationEdit() } }
    private func finishPresentationEdit() {
        guard !hasMarkedText() else { return }
        if let before = beforeEdit {
            beforeEdit = nil
            if before.text != sourceText { sourceUndo.registerUndo(withTarget: self) { $0.restore(before) } }
        }
        renderSource()
    }


    func apply(_ insertion: ComposerInsertion) {
        guard lastInsertionID != insertion.id else { return }
        lastInsertionID = insertion.id
        if insertion.focus { window?.makeFirstResponder(self) }
        insertText(CustomEmojiText.insertion(insertion.text, into: sourceText, range: sourceSelection), replacementRange: selectedRange())
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
        let types: [NSPasteboard.PasteboardType] = presentationEnabled ? [.string] : super.readablePasteboardTypes
        guard acceptsAttachments else { return types }
        return [.fileURL, .png, .tiff] + types.filter { ![.fileURL, .png, .tiff].contains($0) }
    }
    override func paste(_ sender: Any?) {
        if !stageAttachments(from: .general) { super.paste(sender) }
    }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if stageAttachments(from: pasteboard) { return true }
        if presentationEnabled {
            guard let text = pasteboard.string(forType: .string) else { return false }
            insertText(text, replacementRange: selectedRange()); return true
        }
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
        if presentationEnabled, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { redo(nil) } else { undo(nil) }; return
        }
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
            if event.modifierFlags.contains(.shift) || !returnSends { insertNewlineIgnoringFieldEditor(nil); return }
            if isEditable { send?() }; return
        }
        super.keyDown(with: event)
    }
    override func didChangeText() {
        if presentationEnabled { finishPresentationEdit() }
        super.didChangeText()
        refreshCompletions()
    }
    override func resignFirstResponder() -> Bool {
        hideCompletions()
        return super.resignFirstResponder()
    }
    private func refreshCompletions() {
        guard isEditable, !hasMarkedText(), let query = ComposerCompletion.query(in: sourceText, selection: sourceSelection) else {
            hideCompletions(); return
        }
        completionQuery = query
        suggestions = ComposerCompletion.suggestions(for: query, candidates: candidates)
        selectedSuggestion = 0
        if suggestions.isEmpty { hideCompletions() } else { showCompletions() }
    }
    func selectionDidChange() {
        guard !rendering else { return }
        if let completionQuery, completionQuery != ComposerCompletion.query(in: sourceText, selection: sourceSelection) { hideCompletions() }
    }
    func hideCompletions() {
        if let panel = completionPanel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        completionPanel = nil; suggestions = []; completionQuery = nil
    }
    private func chooseCompletion(_ index: Int) {
        guard let query = completionQuery, suggestions.indices.contains(index),
              query == ComposerCompletion.query(in: sourceText, selection: sourceSelection) else { hideCompletions(); return }
        if query.marker == ":" { RecentEmojis().record(suggestions[index].insertion) }
        let replacement = suggestions[index].insertion + " "
        hideCompletions()
        window?.makeFirstResponder(self)
        let range = textStorage.map { ComposerPresentation.displayRange(query.range, in: $0) } ?? query.range
        insertText(replacement, replacementRange: range)
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
        let displayRange = textStorage.map { ComposerPresentation.displayRange(query.range, in: $0) } ?? query.range
        let caret = firstRect(forCharacterRange: NSRange(location: displayRange.location, length: 0), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? window.frame
        panel.setFrame(NSRect(x: min(max(caret.minX, screen.minX), screen.maxX - 320),
            y: min(caret.maxY + 4, screen.maxY - height), width: 320, height: height), display: true)
        if completionPanel == nil { window.addChildWindow(panel, ordered: .above); completionPanel = panel }
        panel.orderFront(nil)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); renderSource() }
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
