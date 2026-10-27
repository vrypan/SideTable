import SwiftUI
import AppKit
import ApronCore

struct ConversationPanelsView: View {
    @Bindable var model: AppModel
    @State private var visiblePanels: Set<UUID> = []

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HSplitView {
                        ForEach(model.panels) { panel in
                            if let server = model.servers.first(where: { $0.id == panel.serverID }), server.account == panel.account {
                                ConversationView(model: model, server: server, room: panel.room, isThread: panel.isThread,
                                                 panel: panel, panelVisible: visiblePanels.contains(panel.id))
                                    .id(panel.key)
                                .frame(minWidth: 340, idealWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .top) {
                                    Rectangle().fill(model.activePanelID == panel.id ? Color.accentColor.opacity(0.7) : Color.clear).frame(height: 2)
                                }
                                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                                    if model.activePanelID != panel.id { model.focusPanel(panel.id) }
                                })
                                .background(PanelVisibilityReader(layoutName: "SideTable-panels-" + model.panels.map { $0.id.uuidString }.joined(separator: "-")) { visible in
                                    if visible { visiblePanels.insert(panel.id) }
                                    else { visiblePanels.remove(panel.id) }
                                })
                                .sheet(isPresented: Binding(get: { panel.showMembers }, set: { panel.showMembers = $0 })) {
                                    MembersView(model: model, server: server, room: panel.room, close: { panel.showMembers = false })
                                        .frame(width: 320, height: 480)
                                }
                                .id(panel.id)
                            }
                        }
                    }
                    .frame(width: max(viewport.size.width, CGFloat(model.panels.count) * 340 + CGFloat(max(0, model.panels.count - 1)) * 2), height: viewport.size.height)
                }
                .onChange(of: model.activePanelID, initial: true) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
    }
}

/// Native split views can host their children in separate SwiftUI roots.
/// Measure clipping in AppKit rather than propagating geometry preferences across those roots.
struct PanelVisibilityReader: NSViewRepresentable {
    var layoutName: String? = nil
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed; view.layoutName = layoutName; view.refresh() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        var layoutName: String?
        private var reported: Bool?
        private var pending = false
        private var stopped = false
        override init(frame: NSRect) {
            super.init(frame: frame)
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification,
                         NSWindow.didResizeNotification, NSSplitView.didResizeSubviewsNotification] {
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
                if let name = self.layoutName {
                    var ancestor = self.superview
                    while let view = ancestor {
                        if let split = view as? NSSplitView {
                            if split.autosaveName != name { split.autosaveName = name }
                            break
                        }
                        ancestor = view.superview
                    }
                }
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
