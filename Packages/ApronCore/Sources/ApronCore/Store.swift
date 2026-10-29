import Foundation

/// Immutable store snapshots may share derived data across actors. Mutating the
/// corresponding source dictionary installs a fresh cache before the next read.
private final class StoreDerivedCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func get(_ build: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let result = build()
        value = result
        return result
    }
}

public struct RecordKey: Hashable, Codable, Sendable {
    public let first: String
    public let second: String
    public init(_ first: String, _ second: String) { self.first = first; self.second = second }
}

/// Authoritative snapshots only. Pending sends and cached presentation never enter this store.
/// A transient notice, such as a `~private` command reply. It is shown but never
/// installed as a message (§3.5.3). Message IDs are ordered log IDs, so the latest
/// one known on arrival places the notice in a transcript, with or without a room.
public struct Notice: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let record: JSONObject
    public let after: UInt64?
    public init(record: JSONObject, after: UInt64? = nil) { self.record = record; self.after = after }
}

public struct RecordStore: Sendable, Equatable {
    private var messageRecords: [String: JSONObject] = [:]
    private var messageIDsByRoom: [String: Set<String>] = [:]
    public var messages: [String: JSONObject] {
        get { messageRecords }
        set {
            // Preserve the public bulk/direct-mutation API. Live and history
            // updates use setMessage below to invalidate only affected rooms.
            messageRecords = newValue
            messageIDsByRoom = [:]
            timelines = [:]
            for (id, record) in newValue {
                if let room = record.string("room_id") { messageIDsByRoom[room, default: []].insert(id) }
            }
            for room in messageIDsByRoom.keys { timelines[room] = StoreDerivedCache() }
        }
    }
    public var rooms: [String: JSONObject] = [:]
    public var reactions: [RecordKey: JSONObject] = [:] {
        didSet { reactionSummaries = StoreDerivedCache() }
    }
    public var memberships: [RecordKey: JSONObject] = [:]
    public var users: [String: JSONObject] = [:]
    public var members: [String: Set<String>] = [:]
    public var memberObjects: [RecordKey: JSONObject] = [:]
    public var membershipBaselines: [String: UInt64] = [:]
    public var joined: Set<String> = []
    public var notices: [Notice] = []
    public var ownID: String?
    public var aliases: [String: String] = [:]
    private var timelines: [String: StoreDerivedCache<[JSONObject]>] = [:]
    private var reactionSummaries = StoreDerivedCache<[String: [String: [String]]]>()
    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Derived caches do not affect authoritative store equality.
        lhs.messages == rhs.messages && lhs.rooms == rhs.rooms && lhs.reactions == rhs.reactions
            && lhs.memberships == rhs.memberships && lhs.users == rhs.users && lhs.members == rhs.members
            && lhs.memberObjects == rhs.memberObjects && lhs.membershipBaselines == rhs.membershipBaselines
            && lhs.joined == rhs.joined && lhs.notices == rhs.notices && lhs.ownID == rhs.ownID && lhs.aliases == rhs.aliases
    }

    public mutating func apply(_ frame: WireFrame) {
        let p = frame.params ?? [:]
        switch frame.method {
        case "message": installMessage(p)
        case "reactions": installReactions(p)
        case "room_update": applyListing(p)
        case "user":
            if let old = p.object("old").string("user_id"), let new = p.object("new").string("user_id"), old != new { aliases[old] = new }
            if !p.object("you").isEmpty { mergeUser(p.object("you"), own: true) }
            if !p.object("new").isEmpty { mergeUser(p.object("new")) }
        default: break
        }
    }

    public mutating func applyHistory(_ p: JSONObject) {
        for room in p.objects("rooms") { installRoom(room, includeDelivery: false) }
        for message in p.objects("messages") { installMessage(message) }
        for reaction in p.objects("reactions") { installReactions(reaction) }
        for membership in p.objects("memberships") { installMembership(membership) }
    }

    public mutating func applyListing(_ p: JSONObject, full: Bool = false) {
        if full { joined = Set(p.objects("joined").compactMap { $0.string("room_id") }) }
        for u in p.objects("users") { mergeUser(u, complete: true) }
        for name in ["joined", "not_joined", "updated"] {
            for r in p.objects(name) {
                guard let id = r.string("room_id") else { continue }
                installRoom(r)
                if name == "joined" { joined.insert(id) }
                if r["members"] != nil {
                    membershipBaselines[id] = r.logID("latest_log_id") ?? 0
                    members[id] = Set(r.objects("members").compactMap { $0.string("user_id") })
                    for user in r.objects("members") {
                        mergeUser(user)
                        if let uid = user.string("user_id") { memberObjects[RecordKey(id, uid)] = user }
                    }
                    for (key, entry) in memberships where key.first == id && (entry.logID("log_id") ?? 0) > (r.logID("latest_log_id") ?? 0) {
                        if entry.bool("joined") { members[id, default: []].insert(key.second) }
                        else { members[id]?.remove(key.second) }
                        memberObjects[key] = entry.object("user")
                    }
                }
            }
        }
        for m in p.objects("memberships") { installMembership(m) }
        for r in p.objects("left") {
            if let id = r.string("room_id") { joined.remove(id); clearRoom(id); rooms.removeValue(forKey: id) }
        }
    }

    public mutating func installMessage(_ raw: JSONObject, depth: Int = 0) {
        guard depth < 16 else { return }
        guard let id = raw.string("message_id"), let version = raw.logID("log_id"), LogID(id) != nil,
              raw.string("room_id") != nil, raw.object("from").string("user_id") != nil else {
            if depth == 0 && raw.string("message_id") == nil { appendNotice(raw) }
            return
        }
        if raw.object("from").string("user_id") == "~private" {
            if depth == 0 { appendNotice(raw) }; return
        }
        let previous = messages[id]?.logID("log_id") ?? 0
        guard version > previous || (version == previous && raw.bool("deleted")) else { return }
        let keys = Set(["message_id", "log_id", "room_id", "from", "body", "reply_to", "deleted", "ext"])
        var record = raw.filter { keys.contains($0.key) }
        if let reference = raw["reply_to"]?.object, let refID = reference.string("message_id"), LogID(refID) != nil {
            if reference["log_id"] != nil { installMessage(reference, depth: depth + 1) }
            record["reply_to"] = .object(["message_id": .string(refID)])
        }
        if raw.bool("deleted") { record.removeValue(forKey: "body"); record.removeValue(forKey: "ext") }
        setMessage(record, id: id)
    }

    private mutating func appendNotice(_ raw: JSONObject) {
        let latest = messages.values.compactMap { $0.logID("message_id") }.max()
        notices.append(Notice(record: raw, after: latest))
        notices = Array(notices.suffix(100))
    }

    public mutating func installRoom(_ raw: JSONObject) {
        installRoom(raw, includeDelivery: true)
    }

    private mutating func installRoom(_ raw: JSONObject, includeDelivery: Bool) {
        guard let id = raw.string("room_id") else { return }
        let deliveryKeys = ["latest_log_id", "history_log_id", "member_count"]
        let old = rooms[id] ?? [:]
        var record = old
        if (raw.logID("log_id") ?? 0) > (old.logID("log_id") ?? 0) || old.isEmpty {
            record = raw.filter { ["room_id", "log_id", "parent_room_id", "private", "title", "description", "ext"].contains($0.key) }
            // Logged fields are complete snapshots; delivery fields are not.
            for key in deliveryKeys { record[key] = old[key] }
        }
        // Delivery values describe the current connection, never historical rooms.
        if includeDelivery {
            for key in deliveryKeys { if let value = raw[key] { record[key] = value } }
        }
        rooms[id] = record
    }

    public mutating func installReactions(_ raw: JSONObject) {
        guard let message = raw.string("message_id"), let version = raw.logID("log_id") else { return }
        for entry in raw.objects("reactions") {
            guard let user = entry.object("from").string("user_id") else { continue }
            let key = RecordKey(message, user)
            guard version > (reactions[key]?.logID("log_id") ?? 0) else { continue }
            reactions[key] = ["log_id": raw["log_id"]!, "from": .object(entry.object("from")),
                              "emojis": .array(Set(entry.strings("emojis")).sorted().map(JSONValue.string)),
                              "room_id": raw["room_id"] ?? .null]
        }
    }

    public mutating func installMembership(_ raw: JSONObject) {
        guard let room = raw.string("room_id"), let version = raw.logID("log_id") else { return }
        for entry in raw.objects("members") {
            guard let user = entry.object("user").string("user_id") else { continue }
            let key = RecordKey(room, user)
            guard version > (memberships[key]?.logID("log_id") ?? 0) else { continue }
            var record = entry; record["log_id"] = raw["log_id"]; record["room_id"] = .string(room)
            memberships[key] = record
            guard version > (membershipBaselines[room] ?? 0) else { continue }
            memberObjects[key] = entry.object("user")
            if entry.bool("joined") { members[room, default: []].insert(user) }
            else { members[room]?.remove(user) }
        }
    }

    public mutating func mergeUser(_ raw: JSONObject, complete: Bool = false, own: Bool = false) {
        guard let id = raw.string("user_id") else { return }
        var patch = raw
        let prior = users[id] ?? [:]
        if id == ownID && !own { patch["status"] = prior["status"] }
        if own || patch.string("status") != "offline" { patch.removeValue(forKey: "seen") }
        if complete { users[id] = patch; return }
        var merged = prior.mergingUserPatch(patch)
        // `seen` belongs to shown offline presence, never to the chosen status in `you`.
        if own || merged.string("status") != "offline" || (patch["status"] != nil && patch["seen"] == nil) {
            merged.removeValue(forKey: "seen")
        }
        users[id] = merged
    }

    public func displayName(_ recorded: JSONObject) -> String {
        let id = recorded.string("user_id") ?? "Unknown"
        var canonical = id
        var seen = Set<String>()
        while let next = aliases[canonical], seen.insert(canonical).inserted { canonical = next }
        let source = users[canonical] ?? [:]
        let name = source["name"] != nil ? source.string("name") : recorded.string("name")
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? id
    }

    private mutating func setMessage(_ record: JSONObject, id: String) {
        let oldRoom = messageRecords[id]?.string("room_id")
        let newRoom = record.string("room_id")
        messageRecords[id] = record
        if oldRoom != newRoom {
            if let oldRoom {
                messageIDsByRoom[oldRoom]?.remove(id)
                timelines[oldRoom] = StoreDerivedCache()
            }
            if let newRoom { messageIDsByRoom[newRoom, default: []].insert(id) }
        }
        if let newRoom { timelines[newRoom] = StoreDerivedCache() }
    }

    public func timeline(_ room: String) -> [JSONObject] {
        timelines[room]?.get {
            (messageIDsByRoom[room] ?? []).compactMap { messageRecords[$0] }
                .map { ($0.logID("message_id") ?? 0, $0) }
                .sorted { $0.0 < $1.0 }.map(\.1)
        } ?? []
    }
    public func reactionSummary(_ message: String) -> [String: [String]] {
        guard messages[message]?.bool("deleted") != true else { return [:] }
        return reactionSummaries.get {
            var grouped: [String: [String: [String]]] = [:]
            for (key, value) in reactions {
                for emoji in Set(value.strings("emojis").map(ReactionEntry.key)) { grouped[key.first, default: [:]][emoji, default: []].append(key.second) }
            }
            return grouped.mapValues { $0.mapValues { $0.sorted() } }
        }[message] ?? [:]
    }
    public mutating func clearRoom(_ room: String) {
        let ids = messageIDsByRoom.removeValue(forKey: room) ?? []
        for id in ids { messageRecords[id] = nil }
        timelines[room] = nil
        reactions = reactions.filter { !ids.contains($0.key.first) && $0.value.string("room_id") != room }
        memberships = memberships.filter { $0.key.first != room }
        members[room] = nil
        memberObjects = memberObjects.filter { $0.key.first != room }
        membershipBaselines[room] = nil
    }
}
