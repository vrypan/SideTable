import Foundation

public struct RoomHistory: Sendable, Equatable {
    public var before: UInt64?
    public var isLoading = false
    public var completionID = UUID()
    public var error: String?
    public init(before: UInt64? = nil) { self.before = before }
    public var hasOlder: Bool { before != nil }
}

/// Bounds describe the pre-compaction log slice, not the returned messages.
struct BackwardHistoryPage {
    let head: UInt64
    let lowerBound: UInt64
    let nextBefore: UInt64?

    init(_ page: JSONObject, before: UInt64? = nil) throws {
        guard let head = page.logID("latest_log_id"), page["history_log_id"] != nil else {
            throw ClientError.invalidHistory
        }
        self.head = head
        if page["history_log_id"] == .null { lowerBound = head + 1 }
        else if let lower = page.logID("history_log_id"), lower <= head { lowerBound = lower }
        else { throw ClientError.invalidHistory }
        if page["first_log_id"] != nil || page["last_log_id"] != nil {
            guard let first = page.logID("first_log_id"), let last = page.logID("last_log_id"),
                  first <= last, first >= lowerBound, last <= min(before ?? head, head) else {
                throw ClientError.invalidHistory
            }
            if page.bool("more") {
                guard first > lowerBound else { throw ClientError.invalidHistory }
                nextBefore = first - 1
            } else { nextBefore = nil }
        } else {
            guard !page.bool("more"), ["messages", "rooms", "reactions", "memberships"].allSatisfy({ page.objects($0).isEmpty }) else {
                throw ClientError.invalidHistory
            }
            nextBefore = nil
        }
    }
}
