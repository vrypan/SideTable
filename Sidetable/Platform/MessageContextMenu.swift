import AppKit
import SwiftUI

@MainActor struct MessageAction {
    let title: String
    var enabled = true
    var destructive = false
    var children: [MessageAction]? = nil
    var perform: () -> Void = {}

    static func menu(_ actions: [MessageAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            let item = ActionItem(action)
            if let children = action.children { item.submenu = self.menu(children) }
            menu.addItem(item)
        }
        return menu
    }

    @MainActor private final class ActionItem: NSMenuItem {
        let perform: () -> Void
        init(_ action: MessageAction) {
            perform = action.perform
            super.init(title: action.title, action: #selector(invoke), keyEquivalent: "")
            target = self; isEnabled = action.enabled
        }
        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func invoke() { perform() }
    }
}

private struct MessageMenuVisibilityKey: EnvironmentKey {
    static let defaultValue: @MainActor (Bool) -> Void = { _ in }
}

private struct MessageActionsKey: EnvironmentKey {
    static let defaultValue: [MessageAction] = []
}
extension EnvironmentValues {
    var messageMenuVisibility: @MainActor (Bool) -> Void {
        get { self[MessageMenuVisibilityKey.self] }
        set { self[MessageMenuVisibilityKey.self] = newValue }
    }
    var messageActions: [MessageAction] {
        get { self[MessageActionsKey.self] }
        set { self[MessageActionsKey.self] = newValue }
    }
}

/// Native menus run a tracking loop that can defer SwiftUI state redraws.
/// Update the decorative row background directly for the menu's lifetime.
@MainActor final class MessageMenuHighlight {
    weak var view: NSView?
    private(set) var isVisible = false

    func setVisible(_ visible: Bool) {
        isVisible = visible
        guard let view else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = (visible ? NSColor.controlAccentColor.withAlphaComponent(0.15) : .clear).cgColor
        }
        view.needsDisplay = true
        view.displayIfNeeded()
    }
}

struct MessageMenuHighlightView: NSViewRepresentable {
    let highlight: MessageMenuHighlight
    let actions: [MessageAction]
    func makeNSView(context: Context) -> Background {
        let view = Background()
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: Background, context: Context) {
        highlight.view = view
        view.highlight = highlight; view.actions = actions
        highlight.setVisible(highlight.isVisible)
    }
    final class Background: NSView {
        var highlight: MessageMenuHighlight?
        var actions: [MessageAction] = []
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }
        override func rightMouseDown(with event: NSEvent) {
            guard !actions.isEmpty else { return }
            highlight?.setVisible(true)
            defer { highlight?.setVisible(false) }
            NSMenu.popUpContextMenu(MessageAction.menu(actions), with: event, for: self)
        }
    }
}
