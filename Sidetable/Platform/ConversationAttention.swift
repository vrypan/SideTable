import Foundation
import ApronCore

/// Each transcript owns a registration; removing one cannot remove another
/// window's attention. Account and server identity are part of every key.
@MainActor
final class ConversationAttention {
    private var readers: [UUID: DraftKey] = [:]
    func update(_ view: UUID, key: DraftKey, readingLatest: Bool) {
        readers[view] = readingLatest ? key : nil
    }
    func remove(_ view: UUID) { readers.removeValue(forKey: view) }
    func remove(server: UUID) { readers = readers.filter { $0.value.server != server } }
    func contains(_ key: DraftKey) -> Bool { readers.values.contains(key) }
}

/// Per-pane arrival accounting, independent of history pages and record edits.
struct ConversationArrivals {
    private var observed: Int?
    private(set) var unread = 0

    mutating func receive(total: Int, followingLatest: Bool) -> Bool {
        defer { observed = total }
        guard let observed, total >= observed else { unread = 0; return false }
        let added = total - observed
        guard added > 0 else { return false }
        if followingLatest { unread = 0; return true }
        unread += added
        return false
    }

    mutating func reachedLatest() { unread = 0 }
    var label: String {
        unread == 0 ? "Latest" : "\(unread) new message\(unread == 1 ? "" : "s")"
    }
}

/// Keep the divider stable while browsing history, then advance it on reaching the latest message.
struct ConversationUnreadBoundary {
    private(set) var readThrough: UInt64

    init(readMarker: String?, messages: [JSONObject], unreadCount: Int) {
        readThrough = readMarker.flatMap(UInt64.init)
            ?? (unreadCount > 0 ? 0 : messages.last?.logID("message_id") ?? 0)
    }

    mutating func reachedLatest(_ messageID: String?) {
        guard let messageID, let latest = UInt64(messageID) else { return }
        readThrough = max(readThrough, latest)
    }

    func firstUnread(in messages: [JSONObject], account: String) -> String? {
        messages.first {
            ($0.logID("message_id") ?? 0) > readThrough
                && $0.object("from").string("user_id") != account && !$0.bool("deleted")
        }?.string("message_id")
    }
}
