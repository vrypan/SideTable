import Foundation
import Observation
import ApronCore

/// View-lifetime transcript state. SwiftUI owns scroll execution and async tasks;
/// this object owns the synchronous transitions that decide what to display.
@MainActor @Observable
final class ConversationTranscriptState {
    let attentionID = UUID()
    private(set) var windowActive = false
    private(set) var unreadBoundary: ConversationUnreadBoundary?
    /// Programmatic positioning must not clear the New divider before user navigation.
    private(set) var userNavigated = false
    private(set) var arrivals = ConversationArrivals()
    var atBottom = false
    static let initialMessageCount = 30
    var visibleCount = initialMessageCount
    var positionedLatest = false
    var scrollRequest: UUID?
    var scrollPosition: String?
    var historyAnchor: String?

    func setWindowActive(_ active: Bool) {
        if active { userNavigated = false }
        windowActive = active
    }

    func userScrolled() { userNavigated = true }

    func changeRoom() {
        atBottom = false
        visibleCount = Self.initialMessageCount
        historyAnchor = nil
        scrollPosition = nil
        positionedLatest = false
        userNavigated = false
        arrivals = ConversationArrivals()
    }

    func revealEarlier(messages: [JSONObject]) -> String? {
        let anchor = scrollPosition ?? messages.suffix(visibleCount).first?.string("message_id")
        positionedLatest = true
        atBottom = false
        visibleCount += 150
        return anchor
    }

    func beginHistory(messages: [JSONObject]) {
        historyAnchor = scrollPosition ?? messages.first?.string("message_id")
        positionedLatest = true
        atBottom = false
    }

    func revealSavedMessage(_ id: String, messages: [JSONObject]) {
        guard let index = messages.firstIndex(where: { $0.string("message_id") == id }) else { return }
        // Only expand the displayed suffix far enough to include the saved row.
        visibleCount = max(visibleCount, messages.count - index)
    }

    func revealLinkedMessage(messageCount: Int) {
        positionedLatest = true
        atBottom = false
        scrollRequest = nil
        visibleCount = max(visibleCount, messageCount)
    }

    func requestLatest() {
        userNavigated = true
        historyAnchor = nil
        positionedLatest = true
        scrollRequest = UUID()
    }

    func receiveArrivals(total: Int, loadingHistory: Bool, searching: Bool) {
        let following = positionedLatest && atBottom && windowActive && historyAnchor == nil
            && !loadingHistory && !searching
        if arrivals.receive(total: total, followingLatest: following) { scrollRequest = UUID() }
    }

    func clearArrivals() { arrivals.reachedLatest() }

    func captureUnreadBoundary(readMarker: String?, messages: [JSONObject], unreadCount: Int) {
        guard unreadBoundary == nil else { return }
        unreadBoundary = ConversationUnreadBoundary(readMarker: readMarker, messages: messages, unreadCount: unreadCount)
    }

    func reachedLatest(_ message: String?, eligible: Bool) {
        if eligible, userNavigated { unreadBoundary?.reachedLatest(message) }
    }
}
