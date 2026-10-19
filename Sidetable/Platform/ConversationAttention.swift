import Foundation

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
