import Foundation
import Testing
@testable import ApronCore

@Test func reactionComparisonCollapsesPresentationSelectorsPerUser() {
    var store = RecordStore()
    store.reactions[RecordKey("1", "ada")] = ["emojis": .array([.string("❤"), .string("❤️"), .string(":party:")])]
    store.reactions[RecordKey("1", "bob")] = ["emojis": .array([.string("❤️")])]
    #expect(store.reactionSummary("1") == ["❤": ["ada", "bob"], ":party:": ["ada"]])
    #expect(store.reactions[RecordKey("1", "ada")]?.strings("emojis") == ["❤", "❤️", ":party:"])
    #expect(ReactionEntry.toggled("❤", in: ["❤️", "❤", ":removed:"]) == [":removed:"])
    #expect(ReactionEntry.toggled("👍", in: [":removed:"]) == [":removed:", "👍"])
    for value in ["❤", "❤️", "👍🏽", "🏳️‍🌈", "👨‍👩‍👧", "1️⃣"] { #expect(ReactionEntry.isEmoji(value)) }
    for value in ["1", "a", ":party:", "👍👍", ""] { #expect(!ReactionEntry.isEmoji(value)) }
}

@Test func permissionsUseTypedDefaultsAndCurrentCapabilities() {
    var snapshot = SessionSnapshot()
    snapshot.server = ["capabilities": .array([.string("ext:permissions"), .string("ext:settings")]),
                       "ext": .object(["settings": .object(["guest_posting": .bool(false)])])]
    snapshot.isGuest = true
    snapshot.you = ["user_id": .string("ada"), "roles": .array([.string("admin")])]
    #expect(!snapshot.readOnly) // New permissions override the obsolete guest setting.
    let other: JSONObject = ["from": .object(["user_id": .string("bob")])]
    #expect(!snapshot.canMove(other))
    #expect(!snapshot.canAddMembers(to: "public"))
    snapshot.store.rooms["private"] = ["private": .bool(true)]
    snapshot.store.joined.insert("private")
    #expect(snapshot.canAddMembers(to: "private"))
    snapshot.you["ext"] = .object(["permissions": .object(["write": .string("false"), "add_members": .bool(true), "move_any": .bool(true)])])
    #expect(!snapshot.readOnly && snapshot.canMove(other) && snapshot.canAddMembers(to: "public"))
    snapshot.you["ext"] = .object(["permissions": .object(["write": .bool(false)])])
    #expect(snapshot.readOnly && !snapshot.canAddMembers(to: "private"))
    snapshot.server = [:]
    #expect(!snapshot.readOnly && !snapshot.canMove(other))
    #expect(snapshot.canMove(["from": .object(["user_id": .string("ada")])]))
}

@Test func privateRoomLimitsExcludeThreadsAndUnjoinedRooms() {
    var snapshot = SessionSnapshot()
    snapshot.server = ["capabilities": .array([.string("ext:settings")]), "ext": .object(["settings": .object(["private_rooms": .number(2)])])]
    snapshot.store.rooms = ["a": ["private": .bool(true)], "b": ["private": .bool(true)],
                            "thread": ["private": .bool(true), "parent_room_id": .string("a")]]
    snapshot.store.joined = ["a", "thread"]
    #expect(!snapshot.privateRoomLimitReached)
    snapshot.store.joined.insert("b")
    #expect(snapshot.privateRoomLimitReached)
    snapshot.server["capabilities"] = .array([])
    #expect(!snapshot.privateRoomLimitReached)
}

@Test func serverAddressesNormalizeEquivalentURIsWithoutMergingDistinctPaths() throws {
    #expect(try ServerAddress.normalize("WSS://CHAT.example:443/a/../%7ews/%2f?q=%7e%2f").absoluteString == "wss://chat.example/~ws/%2F?q=~%2F")
    #expect(try ServerAddress.normalize("ws://localhost:80") == ServerAddress.normalize("ws://LOCALHOST/"))
    #expect(try ServerAddress.normalize("wss://chat.example/a//b") != ServerAddress.normalize("wss://chat.example/a/b"))
    #expect(try ServerAddress.normalize("wss://chat.example/%2E%2E/ws") == ServerAddress.normalize("wss://chat.example/ws"))
    #expect(try ServerAddress.normalize("wss://chat.example/a/") != ServerAddress.normalize("wss://chat.example/a"))
}

@Test func userTextRemovesOverridesWithoutChangingOrdinaryRTLText() {
    let source = "שלום ملف\u{202E}exe.txt\u{202C}"
    #expect(UserText.clean(source) == "שלום ملفexe.txt")
    #expect(UserText.isolated("\u{2069}אב\u{2066}") == "\u{2068}אב\u{2069}")
}

@Test func categorizedCooldownsRespectScopeAccountAndExpiration() throws {
    var limits = RequestLimits()
    let now = Date(timeIntervalSince1970: 100)
    let error = RPCError(code: -32002, message: "Slow down", data: .object(["retry_after": .number(10), "ext": .object(["limits": .string("write")])]))
    limits.record(error, method: "message", params: [:], account: "ada", extended: true, now: now)
    #expect(throws: RPCError.self) { try limits.check(method: "reactions", params: [:], account: "ada", now: now) }
    try limits.check(method: "command", params: [:], account: "ada", now: now)
    try limits.check(method: "history", params: [:], account: "ada", now: now)
    try limits.check(method: "message", params: [:], account: "bob", now: now)
    try limits.check(method: "message", params: [:], account: "ada", now: now.addingTimeInterval(10))
    limits.record(error, method: "history", params: [:], account: "ada", extended: true, now: now)
    // A category on a method it cannot count falls back to that method alone.
    try limits.check(method: "message", params: [:], account: "ada", now: now)
    #expect(throws: RPCError.self) { try limits.check(method: "history", params: [:], account: "ada", now: now) }
}

@Test func uploadCooldownCountsOnlyNewUploadsAndRequiresCapability() throws {
    let now = Date(timeIntervalSince1970: 100)
    let upload: JSONObject = ["body": .object(["embeds": .array([.object(["kind": .string("upload")])])])]
    let existing: JSONObject = ["body": .object(["embeds": .array([.object(["kind": .string("upload"), "embed_id": .string("e1")])])])]
    let error = RPCError(code: -32002, message: "Wait", data: .object(["retry_after": .number(10), "ext": .object(["limits": .string("upload")])]))
    var limits = RequestLimits()
    limits.record(error, method: "message", params: upload, account: "ada", extended: true, now: now)
    #expect(throws: RPCError.self) { try limits.check(method: "command", params: upload, account: "ada", now: now) }
    try limits.check(method: "message", params: existing, account: "ada", now: now)
    try limits.check(method: "message", params: [:], account: "ada", now: now)
    var legacy = RequestLimits()
    legacy.record(error, method: "message", params: upload, account: "ada", extended: false, now: now)
    try legacy.check(method: "command", params: upload, account: "ada", now: now)
}
