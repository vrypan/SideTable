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

@Test func roomMemberSummaryUsesTotalCountAndDistinguishesUnknownMembership() {
    #expect(RoomDetails.memberSummary(room: [:], members: nil) == "Members not loaded")
    #expect(RoomDetails.memberSummary(room: [:], members: []) == "0 members")
    #expect(RoomDetails.memberSummary(room: [:], members: ["ada"]) == "1 member")
    #expect(RoomDetails.memberSummary(room: ["member_count": .number(20)], members: ["ada", "bob"]) == "20 members")
    #expect(RoomDetails.memberSummary(room: ["member_count": .number(1)], members: ["ada", "bob"]) == "2 members")
}
