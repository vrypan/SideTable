import AppKit
import SwiftUI

/// Observes native geometry but delegates positioning to SwiftUI, so lazy rows
/// are materialized along with each jump. User scrolling releases the bottom lock.
struct TranscriptScrollObserver: NSViewRepresentable {
    let request: UUID?
    var scrollToLatest: () -> Void
    var diagnosticServer: UUID? = nil
    var diagnosticRoom: String? = nil
    var layoutReady: () -> Void = {}
    var positionReported: () -> Void = {}
    var positionChanged: (String) -> Void = { _ in }
    var userScrolled: () -> Void = {}
    /// What the view currently believes; it may assume "not at the end" on its own.
    var believedAtEnd: Bool? = nil
    /// While nobody is reading, arrivals stack below the reading position instead of moving it.
    var holdsPosition = false
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.scrollToLatest = scrollToLatest
        view.diagnosticServer = diagnosticServer
        view.diagnosticRoom = diagnosticRoom
        view.layoutReady = layoutReady
        view.positionReported = positionReported
        view.changed = changed
        view.positionChanged = positionChanged
        view.userScrolled = userScrolled
        view.update(request, believedAtEnd: believedAtEnd, holdsPosition: holdsPosition)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var scrollToLatest: () -> Void = {}
        var changed: (Bool) -> Void = { _ in }
        var positionChanged: (String) -> Void = { _ in }
        var userScrolled: () -> Void = {}
        var diagnosticServer: UUID?
        var layoutReady: () -> Void = {}
        var positionReported: () -> Void = {}
        var diagnosticRoom: String?
        private struct LayoutSample: Equatable {
            let offset: CGFloat
            let viewport: CGFloat
            let document: CGFloat
            let rows: Int
            let atEnd: Bool
        }
        private var lastSample: LayoutSample?
        var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
        private var positionTask: Task<Void, Never>?
        private var reportedPosition: String?
        private weak var scroll: NSScrollView?
        private var request: UUID?
        private var following = false
        private var needsEndPosition = false
        private struct EndGeometry: Equatable {
            let document: NSRect
            let viewport: NSRect
        }
        private var lastRequestedGeometry: EndGeometry?
        /// The last observed position was the end; lazy row re-measurement must not move it.
        private var pinnedToEnd = false
        private var holding = false
        private var adjusting = false
        private var pending = false
        private var lastReported: Bool?
        private var stopped = false

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func update(_ next: UUID?, believedAtEnd: Bool? = nil, holdsPosition: Bool = false) {
            attach()
            if request != next {
                request = next
                following = next != nil
                lastRequestedGeometry = nil
            }
            // Returning must not resume an earlier jump to Latest past the unseen arrivals.
            if holdsPosition, !holding { following = false; needsEndPosition = false }
            holding = holdsPosition
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
        @objc private func userScroll() {
            following = false; needsEndPosition = false; pinnedToEnd = false
            userScrolled()
        }
        @objc private func scrollEnded() { following = isAtEnd; schedule() }
        @objc private func boundsChanged() {
            guard !adjusting else { return }
            // AppKit clamps when the document shrinks, so a clamp still reads as the end.
            pinnedToEnd = isAtEnd
            if let event = currentEvent(), isScrollInteraction(event) {
                following = false; needsEndPosition = false
                userScrolled()
            }
            schedule()
        }
        private func isScrollInteraction(_ event: NSEvent) -> Bool {
            switch event.type {
            case .scrollWheel, .leftMouseDragged:
                return true
            case .keyDown:
                // Return in the composer can still be current while sending changes
                // both the viewport and document height. Only transcript navigation
                // should release a requested jump to the latest message.
                let navigationKeys: Set<UInt16> = [49, 115, 116, 119, 121, 125, 126]
                guard navigationKeys.contains(event.keyCode), let scroll,
                      let responder = scroll.window?.firstResponder as? NSView else { return false }
                return responder === scroll || responder.isDescendant(of: scroll)
            default:
                return false
            }
        }

        @objc private func layoutChanged() {
            guard !adjusting else { return }
            // Defer positioning out of AppKit's layout notification. Mutating the
            // clip bounds here bypasses SwiftUI's lazy-row realization and can
            // leave a geometrically correct viewport containing no message rows.
            if pinnedToEnd, !holding { needsEndPosition = true }
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
                if let scroll = self.scroll, scroll.documentVisibleRect.height > 0,
                   (scroll.documentView?.bounds.height ?? 0) > 0 { self.layoutReady() }
                if (self.following || self.needsEndPosition), !self.holding {
                    self.needsEndPosition = false
                    self.requestEndPosition()
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
        private func requestEndPosition() {
            guard let scroll, let document = scroll.documentView else { return }
            let geometry = EndGeometry(document: document.bounds, viewport: scroll.documentVisibleRect)
            guard geometry != lastRequestedGeometry else { return }
            lastRequestedGeometry = geometry
            adjusting = true
            defer { adjusting = false }
            scrollToLatest()
        }
        private func schedulePositionReport() {
            positionTask?.cancel()
            positionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, !self.stopped, let scroll = self.scroll, let document = scroll.documentView else { return }
                let position: String?
                if self.isAtEnd && self.diagnosticServer == nil { position = "bottom" }
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
                    if !candidates.isEmpty { self.positionReported() }
                    position = self.isAtEnd ? "bottom" : candidates.min { $0.1 < $1.1 }?.0
                    if let server = self.diagnosticServer, let room = self.diagnosticRoom {
                        let sample = LayoutSample(offset: visible.minY, viewport: visible.height,
                                                  document: document.bounds.height, rows: candidates.count, atEnd: self.isAtEnd)
                        if sample != self.lastSample {
                            self.lastSample = sample
                            DiagnosticLog.shared.transcript(server: server, room: room, offset: Double(sample.offset),
                                viewportHeight: Double(sample.viewport), documentHeight: Double(sample.document),
                                visibleRows: sample.rows, atEnd: sample.atEnd)
                        }
                    }
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

