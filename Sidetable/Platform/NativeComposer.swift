import AppKit
import SwiftUI

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    var acceptsAttachments = false
    var pasteFiles: ([StagedFile]) -> Void = { _ in }
    var pasteError: (String) -> Void = { _ in }
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
        editor.acceptsAttachments = acceptsAttachments; editor.pasteFiles = pasteFiles; editor.pasteError = pasteError
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
        editor.acceptsAttachments = acceptsAttachments; editor.pasteFiles = pasteFiles; editor.pasteError = pasteError
        editor.isEditable = enabled; editor.send = send; editor.placeholder = placeholder; editor.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        init(_ parent: NativeComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; editor.needsDisplay = true
        }
    }
}

final class ComposerTextView: NSTextView {
    var send: (() -> Void)?
    var placeholder = ""
    var acceptsAttachments = false
    var pasteFiles: (([StagedFile]) -> Void)?
    var pasteError: ((String) -> Void)?
    override func paste(_ sender: Any?) {
        guard isEditable, acceptsAttachments, !hasMarkedText() else { super.paste(sender); return }
        do {
            let files = try ClipboardAttachments.files(from: .general)
            if !files.isEmpty { pasteFiles?(files); return }
            super.paste(sender)
        } catch { pasteError?(error.localizedDescription) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if hasMarkedText() { super.keyDown(with: event); return }
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil); return }
            if isEditable { send?() }; return
        }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 7, y: 6), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}
