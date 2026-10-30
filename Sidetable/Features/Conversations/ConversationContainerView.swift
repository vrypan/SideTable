import SwiftUI
import AppKit
import ApronCore

/// One conversation occupies the full area to the right of the two sidebars.
struct ConversationContainerView: View {
    @Bindable var model: AppModel
    @State private var visible = false

    var body: some View {
        if let panel = model.activePanel,
           let server = model.servers.first(where: { $0.id == panel.serverID && $0.account == panel.account }) {
            ConversationView(model: model, server: server, room: panel.room, isThread: panel.isThread,
                             panel: panel, panelVisible: visible)
                .id(panel.key)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PanelVisibilityReader { visible = $0 })
        }
    }
}

/// A divider beside a resizable column. Dragging changes only that column's width;
/// double-clicking restores the default. A leading-edge handle widens its column
/// when dragged toward the leading side.
struct ResizeHandle: View {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultWidth: CGFloat
    var leadingEdge = false
    let title: String
    let identifier: String
    let resized: (CGFloat) -> Void
    let finished: () -> Void
    @State private var dragStart: CGFloat?
    @State private var cursorPushed = false
    @State private var hovering = false
    static let width: CGFloat = 14

    var body: some View {
        Rectangle().fill(.separator).frame(width: 1)
            .frame(width: Self.width).frame(maxHeight: .infinity)
            .background(cursorPushed ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                updateCursor()
            }
            .onDisappear { hovering = false; dragStart = nil; updateCursor() }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? width
                    dragStart = start
                    updateCursor()
                    let delta = leadingEdge ? -value.translation.width : value.translation.width
                    resized((start + delta).rounded().clamped(to: range))
                }
                .onEnded { _ in dragStart = nil; updateCursor(); finished() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { resized(defaultWidth.clamped(to: range)); finished() })
            .help("Drag to resize; double-click for the default width")
            .accessibilityElement()
            .accessibilityLabel("Resize \(title)")
            .accessibilityIdentifier(identifier)
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resized((width + 40).clamped(to: range))
                case .decrement: resized((width - 40).clamped(to: range))
                @unknown default: break
                }
                finished()
            }
    }
    private func updateCursor() {
        let needed = hovering || dragStart != nil
        guard needed != cursorPushed else { return }
        if needed { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        cursorPushed = needed
    }
}

/// Measure clipping by the horizontal panel scroll view in AppKit, where the
/// transcript's own scroll views cannot interfere with the result.
struct PanelVisibilityReader: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed; view.refresh() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var reported: Bool?
        private var pending = false
        private var stopped = false
        override init(frame: NSRect) {
            super.init(frame: frame)
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification,
                         NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
        override func layout() { super.layout(); refresh() }
        @objc private func geometryChanged(_ notification: Notification) {
            if let view = notification.object as? NSView {
                // Vertical transcript scroll views are descendants/siblings of this
                // probe; only ancestor clipping and panel geometry affect visibility.
                guard view === self || isDescendant(of: view) else { return }
            } else if let owner = notification.object as? NSWindow {
                guard owner === window else { return }
            } else { return }
            refresh()
        }
        @objc func refresh() {
            guard !stopped, !pending else { return }
            pending = true
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.pending = false
                let visible = self.window != nil && !self.isHiddenOrHasHiddenAncestor
                    && ConversationPanel.isFullyVisible(frame: self.bounds, viewport: self.visibleRect)
                guard self.reported != visible else { return }
                self.reported = visible
                self.changed(visible)
            }
        }
        func stop() { stopped = true; NotificationCenter.default.removeObserver(self) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
