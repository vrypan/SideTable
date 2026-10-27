import SwiftUI
import AppKit
import ApronCore

struct ConversationPanelsView: View {
    @Bindable var model: AppModel
    @State private var visiblePanels: Set<UUID> = []
    static let rowSpace = "conversationPanelRow"

    var body: some View {
        GeometryReader { viewport in
            let shown = model.panels.compactMap { panel in
                model.servers.first(where: { $0.id == panel.serverID && $0.account == panel.account }).map { (panel, $0) }
            }
            let handles = CGFloat(shown.count) * PanelResizeHandle.width
            let widths = ConversationPanel.displayedWidths(shown.map(\.0.width), viewport: viewport.size.width - handles)
            let slots = widths.map { $0 + PanelResizeHandle.width }
            let dragged = model.panelDrag.flatMap { drag in shown.firstIndex { $0.0.id == drag.id }.map { (index: $0, drag: drag) } }
            let target = dragged.map { ConversationPanel.dropIndex(widths: slots, pointer: $0.drag.pointer) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.0.id) { index, item in
                            let (panel, server) = item
                            HStack(spacing: 0) {
                            ConversationView(model: model, server: server, room: panel.room, isThread: panel.isThread,
                                             panel: panel, panelVisible: visiblePanels.contains(panel.id))
                                .id(panel.key)
                                .frame(width: widths[index])
                                .frame(maxHeight: .infinity)
                                .overlay(alignment: .top) {
                                    Rectangle().fill(model.activePanelID == panel.id ? Color.accentColor.opacity(0.7) : Color.clear).frame(height: 2)
                                }
                                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                                    if model.activePanelID != panel.id { model.focusPanel(panel.id) }
                                })
                                .background(PanelVisibilityReader { visible in
                                    if visible { visiblePanels.insert(panel.id) }
                                    else { visiblePanels.remove(panel.id) }
                                })
                                .sheet(isPresented: Binding(get: { panel.showMembers }, set: { panel.showMembers = $0 })) {
                                    MembersView(model: model, server: server, room: panel.room, close: { panel.showMembers = false })
                                        .frame(width: 320, height: 480)
                                }
                            // Outside the panel, so the transcript's scroller cannot take the drag.
                            PanelResizeHandle(width: widths[index], title: server.title(panel.room)) { width in
                                panel.width = width
                            } finished: {
                                model.savePanelLayout()
                            }
                            }
                            .offset(x: Self.offset(index: index, dragged: dragged, target: target, slots: slots))
                            .zIndex(dragged?.index == index ? 1 : 0)
                            .shadow(color: .black.opacity(dragged?.index == index ? 0.25 : 0), radius: 12)
                            .animation(dragged == nil ? nil : .easeOut(duration: 0.15), value: target)
                            .id(panel.id)
                        }
                    }
                    .scrollTargetLayout()
                    .coordinateSpace(name: Self.rowSpace)
                    .frame(height: viewport.size.height)
                }
                .scrollTargetBehavior(.viewAligned)
                .onChange(of: model.panelDrag) { _, current in
                    guard let current, current.released else { return }
                    // Reorder and clear the drag in one unanimated update: the shifted panels
                    // already sit in their new slots, so nothing snaps back or cross-fades.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if let from = shown.firstIndex(where: { $0.0.id == current.id }) {
                            let index = ConversationPanel.dropIndex(widths: slots, pointer: current.pointer)
                            if index != from { model.movePanel(current.id, to: index) }
                        }
                        model.panelDrag = nil
                    }
                }
                .onChange(of: model.activePanelID, initial: true) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
    }
}

extension ConversationPanelsView {
    /// The dragged panel follows the pointer; panels it passes slide over to show the drop slot.
    static func offset(index: Int, dragged: (index: Int, drag: PanelDrag)?, target: Int?, slots: [CGFloat]) -> CGFloat {
        guard let dragged, let target else { return 0 }
        if index == dragged.index { return dragged.drag.offset }
        let width = slots[dragged.index]
        if dragged.index < index && index <= target { return -width }
        if target <= index && index < dragged.index { return width }
        return 0
    }
}

/// A divider on a panel's trailing edge. Dragging changes only that panel's width;
/// double-clicking restores the default.
private struct PanelResizeHandle: View {
    let width: CGFloat
    let title: String
    let resized: (CGFloat) -> Void
    let finished: () -> Void
    @State private var dragStart: CGFloat?
    @State private var cursorPushed = false
    static let width: CGFloat = 7

    var body: some View {
        Rectangle().fill(.separator).frame(width: 1)
            .frame(width: Self.width).frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
                else if !inside, cursorPushed, dragStart == nil { NSCursor.pop(); cursorPushed = false }
            }
            .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? width
                    dragStart = start
                    resized(max(ConversationPanel.minimumWidth, (start + value.translation.width).rounded()))
                }
                .onEnded { _ in dragStart = nil; finished() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { resized(ConversationPanel.defaultWidth); finished() })
            .help("Drag to resize; double-click for the default width")
            .accessibilityElement()
            .accessibilityLabel("Resize \(title)")
            .accessibilityIdentifier("panelResizeHandle-" + title)
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resized(width + 40)
                case .decrement: resized(max(ConversationPanel.minimumWidth, width - 40))
                @unknown default: break
                }
                finished()
            }
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
