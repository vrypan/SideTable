import SwiftUI
import AppKit

/// Tracks the actual owning window, including Settings/sheets taking focus,
/// minimization, occlusion, application activation, and window closure.
struct WindowAttentionReader: NSViewRepresentable {
    var changed: (Bool) -> Void
    var deactivated: () -> Void
    func makeNSView(context: Context) -> AttentionView { AttentionView(changed: changed, deactivated: deactivated) }
    func updateNSView(_ view: AttentionView, context: Context) { view.changed = changed; view.deactivated = deactivated; view.refresh() }
    static func dismantleNSView(_ view: AttentionView, coordinator: ()) { view.stop() }

    final class AttentionView: NSView {
        var changed: (Bool) -> Void
        var deactivated: () -> Void
        private var reported: Bool?
        private var revision = 0
        private var stopped = false
        init(changed: @escaping (Bool) -> Void, deactivated: @escaping () -> Void) {
            self.changed = changed; self.deactivated = deactivated
            super.init(frame: .zero)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(received), name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
        @objc private func received(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification, notification.object as? NSWindow === window {
                report(false)
            } else { refresh() }
        }
        func refresh() {
            guard !stopped else { return }
            let active = window.map { NSApp.isActive && $0.isKeyWindow && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            report(active)
        }
        private func report(_ active: Bool) {
            if !active { deactivated() }
            guard reported != active else { return }
            reported = active; revision += 1
            let revision = revision
            // SwiftUI can attach a representable during a view update.
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.revision == revision else { return }
                self.changed(active)
            }
        }
        func stop() { stopped = true; deactivated(); NotificationCenter.default.removeObserver(self) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
