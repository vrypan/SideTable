import AppKit
import SwiftUI

/// Uses the actual document bounds, including padding and late row layout, to
/// finish a jump to Latest. Native user scrolling releases the bottom lock.
struct TranscriptScrollObserver: NSViewRepresentable {
    let request: UUID?
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.changed = changed
        view.update(request)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        private weak var scroll: NSScrollView?
        private var request: UUID?
        private var following = false
        private var adjusting = false
        private var pending = false
        private var lastReported: Bool?
        private var stopped = false

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func update(_ next: UUID?) {
            attach()
            if request != next {
                request = next
                following = next != nil
            }
            schedule()
        }
        private func attach() {
            guard !stopped, let owner = enclosingScrollView, scroll !== owner else { return }
            NotificationCenter.default.removeObserver(self)
            scroll = owner
            owner.contentView.postsBoundsChangedNotifications = true
            owner.documentView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: owner.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: owner.documentView)
            NotificationCenter.default.addObserver(self, selector: #selector(userScroll), name: NSScrollView.willStartLiveScrollNotification, object: owner)
            NotificationCenter.default.addObserver(self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: owner)
            schedule()
        }
        @objc private func userScroll() { following = false }
        @objc private func scrollEnded() { following = isAtEnd; schedule() }
        @objc private func boundsChanged() {
            if !adjusting, let type = NSApp.currentEvent?.type,
               [.scrollWheel, .leftMouseDragged, .keyDown].contains(type) { following = false }
            schedule()
        }
        @objc private func layoutChanged() { schedule() }
        private var isAtEnd: Bool {
            guard let scroll, let document = scroll.documentView else { return false }
            let visible = scroll.documentVisibleRect
            if document.bounds.height <= visible.height { return true }
            let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            return remaining <= 1
        }
        private func schedule() {
            guard !stopped, !pending else { return }
            pending = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !self.stopped else { return }
                self.pending = false
                if self.following, let scroll = self.scroll, let document = scroll.documentView {
                    self.adjusting = true
                    document.layoutSubtreeIfNeeded()
                    let clip = scroll.contentView
                    let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
                    var bounds = clip.bounds
                    bounds.origin.y = y
                    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                    scroll.reflectScrolledClipView(clip)
                    self.adjusting = false
                }
                let atEnd = self.isAtEnd
                if self.lastReported != atEnd {
                    self.lastReported = atEnd
                    self.changed(atEnd)
                }
            }
        }
        func stop() { stopped = true; following = false; NotificationCenter.default.removeObserver(self) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
