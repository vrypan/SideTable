import Foundation
import Testing
import ApronCore
@testable import Sidetable

@Test func roomLinksRoundTripAndNeverIncludeServerCredentials() throws {
    let url = try #require(RoomLink.url(endpoint: "wss://chat.example:8443/ws", room: "private+one&two"))
    let parsed = try ApronLink(url.absoluteString)
    #expect(parsed.server.absoluteString == "wss://chat.example:8443/ws")
    #expect(parsed.room == "private+one&two")
    #expect(parsed.message == nil && parsed.token == nil)
    #expect(url.absoluteString.hasPrefix("https://link.apron.chat/#"))
    for endpoint in ["wss://user:password@chat.example/", "wss://chat.example/?token=secret", "ws://remote.example/"] {
        #expect(RoomLink.url(endpoint: endpoint, room: "general") == nil)
    }
    for room in ["", "has spaces", "new\nline"] {
        #expect(RoomLink.url(endpoint: "wss://chat.example/", room: room) == nil)
    }
}

@Test func roomTextEditsPreservePrivacyAndExtensionsWithoutResendingDeliveryFields() {
    let original: JSONObject = ["room_id": .string("private"), "title": .string("Old"), "description": .string("Old description"),
        "private": .bool(true), "parent_room_id": .string("general"), "log_id": .string("100"),
        "members": .array([.object(["user_id": .string("ada")])]), "member_count": .number(10),
        "ext": .object(["custom": .object(["value": .string("preserved")])])]
    let params = RoomDetails.editParameters(original, title: "Updated", description: "")
    #expect(params == ["room_id": .string("private"), "title": .string("Updated"), "description": .string(""),
                       "private": .bool(true), "ext": original["ext"]!])
    #expect(original.string("title") == "Old")
    let publicParams = RoomDetails.editParameters(["room_id": .string("general")], title: "General", description: "Purpose")
    #expect(publicParams["private"] == nil && publicParams["ext"] == nil)
}

@Test func privateTopLevelRoomEditsCanClearTheTitle() {
    let room: JSONObject = ["room_id": .string("dm"), "title": .string("Ada, Bob"), "private": .bool(true)]
    #expect(RoomDetails.titleIsOptional(room))
    #expect(!RoomDetails.titleIsOptional(["room_id": .string("general"), "title": .string("General")]))
    var thread = room; thread["parent_room_id"] = .string("dm")
    #expect(!RoomDetails.titleIsOptional(thread))
    for title in ["", "  "] {
        #expect(RoomDetails.editParameters(room, title: title, description: "")
            == ["room_id": .string("dm"), "description": .string(""), "private": .bool(true)])
    }
}

@Test func roomMemberSummaryUsesTotalCountAndDistinguishesUnknownMembership() {
    #expect(RoomDetails.memberSummary(room: [:], members: nil) == "Members not loaded")
    #expect(RoomDetails.memberSummary(room: [:], members: []) == "0 members")
    #expect(RoomDetails.memberSummary(room: [:], members: ["ada"]) == "1 member")
    #expect(RoomDetails.memberSummary(room: ["member_count": .number(20)], members: ["ada", "bob"]) == "20 members")
    #expect(RoomDetails.memberSummary(room: ["member_count": .number(1)], members: ["ada", "bob"]) == "2 members")
}

@Test func muteCountdownTracksExpiryAndIndefiniteMutes() throws {
    let now = Date(timeIntervalSince1970: 10000)
    var snapshot = SessionSnapshot()
    snapshot.mutedUntil["general"] = now.addingTimeInterval(1800)
    let mute = try #require(RoomMuteCountdown.active(snapshot: snapshot, room: "general", parent: nil, now: now))
    #expect(mute.label == "30m" && !mute.indefinite)
    #expect(RoomMuteCountdown.active(snapshot: snapshot, room: "general", parent: nil, now: now.addingTimeInterval(1800)) == nil)
    snapshot.mutedUntil["general"] = .distantFuture
    let forever = try #require(RoomMuteCountdown.active(snapshot: snapshot, room: "general", parent: nil, now: now))
    #expect(forever.indefinite && forever.label == "∞" && forever.detail.contains("until resumed"))
}

@Test func muteCountdownUsesLongestApplicableMuteAndCompactLabels() throws {
    let now = Date(timeIntervalSince1970: 10000)
    var snapshot = SessionSnapshot()
    snapshot.mutedUntil = ["": now.addingTimeInterval(7200), "general": now.addingTimeInterval(3600), "thread": now.addingTimeInterval(120)]
    #expect(RoomMuteCountdown.active(snapshot: snapshot, room: "thread", parent: "general", now: now)?.label == "2h")
    snapshot.mutedUntil[""] = nil
    #expect(RoomMuteCountdown.active(snapshot: snapshot, room: "thread", parent: "general", now: now)?.label == "1h")
    #expect(RoomMuteCountdown.active(snapshot: snapshot, room: "other", parent: nil, now: now) == nil)
    for (seconds, label) in [(10.0, "1m"), (3600, "1h"), (28800, "8h"), (86400, "1d")] {
        let value = RoomMuteCountdown(end: now.addingTimeInterval(seconds), scope: "general", now: now)
        #expect(value.label == label)
    }
}

@MainActor @Test func untitledPrivateRoomsAreNamedAfterTheOtherParticipants() {
    let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
    server.snapshot.you = ["user_id": .string("ada")]
    var store = RecordStore()
    for (id, name) in [("ada", "Ada"), ("bob", "Bob"), ("cy", "Cy")] {
        store.mergeUser(["user_id": .string(id), "name": .string(name)], complete: true)
    }
    store.rooms["group"] = ["room_id": .string("group"), "private": .bool(true)]
    store.rooms["empty"] = ["room_id": .string("empty"), "private": .bool(true), "title": .string("")]
    store.rooms["solo"] = ["room_id": .string("solo"), "private": .bool(true)]
    store.rooms["named"] = ["room_id": .string("named"), "private": .bool(true), "title": .string("Plans")]
    store.rooms["public"] = ["room_id": .string("public")]
    store.rooms["unloaded"] = ["room_id": .string("unloaded"), "private": .bool(true)]
    store.members = ["group": ["cy", "ada", "bob"], "empty": ["ada", "bob"], "solo": ["ada"],
                     "named": ["ada", "bob"], "public": ["ada", "bob"]]
    server.snapshot.store = store
    #expect(server.title("group") == "Bob, Cy")
    #expect(server.participants("group")?.map(\.id) == ["bob", "cy"])
    #expect(server.title("empty") == "Bob")
    #expect(server.title("solo") == "Ada")
    #expect(server.title("named") == "Plans" && server.participants("named") == nil)
    #expect(server.title("public") == "public" && server.participants("public") == nil)
    #expect(server.title("unloaded") == "unloaded" && server.participants("unloaded") == nil)
}
