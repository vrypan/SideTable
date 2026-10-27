import AppKit
import SwiftUI

/// Uses the actual document bounds, including padding and late row layout, to
/// finish a jump to Latest. Native user scrolling releases the bottom lock.
struct TranscriptScrollObserver: NSViewRepresentable {
    let request: UUID?
    var positionChanged: (String) -> Void = { _ in }
    var userScrolled: () -> Void = {}
    /// What the view currently believes; it may assume "not at the end" on its own.
    var believedAtEnd: Bool? = nil
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.changed = changed
        view.positionChanged = positionChanged
        view.userScrolled = userScrolled
        view.update(request, believedAtEnd: believedAtEnd)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        var positionChanged: (String) -> Void = { _ in }
        var userScrolled: () -> Void = {}
        private var positionTask: Task<Void, Never>?
        private var reportedPosition: String?
        private weak var scroll: NSScrollView?
        private var request: UUID?
        private var following = false
        /// The last observed position was the end; lazy row re-measurement must not move it.
        private var pinnedToEnd = false
        private var adjusting = false
        private var pending = false
        private var lastReported: Bool?
        private var stopped = false

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func update(_ next: UUID?, believedAtEnd: Bool? = nil) {
            attach()
            if request != next {
                request = next
                following = next != nil
            }
            // Restoring a position that needs no scrolling moves nothing, so no
            // notification would correct the view; compare against its belief instead.
            if let believedAtEnd, lastReported != nil { lastReported = believedAtEnd }
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
        @objc private func userScroll() { following = false; userScrolled() }
        @objc private func scrollEnded() { following = isAtEnd; schedule() }
        @objc private func boundsChanged() {
            guard !adjusting else { return }
            // AppKit clamps when the document shrinks, so a clamp still reads as the end.
            pinnedToEnd = isAtEnd
            if let type = NSApp.currentEvent?.type,
               [.scrollWheel, .leftMouseDragged, .keyDown].contains(type) { following = false; userScrolled() }
            schedule()
        }
        @objc private func layoutChanged() {
            guard !adjusting else { return }
            // LazyVStack can shrink then regrow the document as a scroll settles.
            // Re-pin synchronously, before further momentum events read the stale offset.
            if pinnedToEnd, !isAtEnd { scrollToEnd() }
            schedule()
        }
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
                if self.following {
                    self.scroll?.documentView?.layoutSubtreeIfNeeded()
                    self.scrollToEnd()
                }
                self.pinnedToEnd = self.isAtEnd
                self.schedulePositionReport()
                let atEnd = self.isAtEnd
                if self.lastReported != atEnd {
                    self.lastReported = atEnd
                    self.changed(atEnd)
                }
            }
        }
        private func scrollToEnd() {
            guard let scroll, let document = scroll.documentView else { return }
            adjusting = true
            defer { adjusting = false }
            let clip = scroll.contentView
            let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
            var bounds = clip.bounds
            bounds.origin.y = y
            let target = clip.constrainBoundsRect(bounds).origin
            if abs(clip.bounds.origin.y - target.y) > 0.5 {
                clip.scroll(to: target)
                scroll.reflectScrolledClipView(clip)
            }
        }
        private func schedulePositionReport() {
            positionTask?.cancel()
            positionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, !self.stopped, let scroll = self.scroll, let document = scroll.documentView else { return }
                let position: String?
                if self.isAtEnd { position = "bottom" }
                else {
                    let visible = scroll.documentVisibleRect
                    var candidates: [(String, CGFloat)] = []
                    var pending = [document]
                    while let view = pending.popLast() {
                        if let anchor = view as? TranscriptMessageAnchor.Anchor {
                            let rect = anchor.convert(anchor.bounds, to: document)
                            if rect.height > 0, rect.intersects(visible) {
                                candidates.append((anchor.messageID, document.isFlipped ? rect.minY : -rect.maxY))
                            }
                        } else { pending.append(contentsOf: view.subviews) }
                    }
                    position = candidates.min { $0.1 < $1.1 }?.0
                }
                if let position, self.reportedPosition != position {
                    self.reportedPosition = position
                    self.positionChanged(position)
                }
            }
        }
        func stop() { stopped = true; following = false; positionTask?.cancel(); NotificationCenter.default.removeObserver(self) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// A passive native marker: observing the reading position never sets a scroll target.
struct TranscriptMessageAnchor: NSViewRepresentable {
    let messageID: String
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.messageID = messageID }
    final class Anchor: NSView {
        var messageID = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

