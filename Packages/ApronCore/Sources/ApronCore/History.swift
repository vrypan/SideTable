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

/// History a session holds, saved by the app and handed to a later session so that
/// sign-in recovery fetches only the log entries after each stream's checkpoint.
public struct HistorySeed: Codable, Sendable, Equatable {
    public struct Stream: Codable, Sendable, Equatable {
        /// Newest log entry the saved records cover contiguously.
        public var checkpoint: UInt64
        /// Retention bound observed when the records were fetched.
        public var lowerBound: UInt64
        /// Inclusive cursor for older pages; nil when nothing older remains.
        public var before: UInt64?
        public init(checkpoint: UInt64, lowerBound: UInt64, before: UInt64?) {
            self.checkpoint = checkpoint; self.lowerBound = lowerBound; self.before = before
        }
    }
    public struct Reaction: Codable, Sendable, Equatable {
        public var message: String
        public var user: String
        public var record: JSONObject
        public init(message: String, user: String, record: JSONObject) { self.message = message; self.user = user; self.record = record }
    }
    public var account: String
    public var streams: [String: Stream]
    public var rooms: [JSONObject]
    public var joined: [String]
    public var users: [JSONObject]
    public var messages: [JSONObject]
    public var reactions: [Reaction]
    public init(account: String, streams: [String: Stream], rooms: [JSONObject], joined: [String],
                users: [JSONObject], messages: [JSONObject], reactions: [Reaction]) {
        self.account = account; self.streams = streams; self.rooms = rooms; self.joined = joined
        self.users = users; self.messages = messages; self.reactions = reactions
    }
}
