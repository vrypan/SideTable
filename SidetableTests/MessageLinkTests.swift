import Foundation
import Testing
import ApronCore
@testable import Sidetable

@Test func messageLinksIdentifyRoomThreadAndStableMessage() throws {
    let message: JSONObject = ["message_id": .string("100"), "log_id": .string("200"), "room_id": .string("thread+one&two")]
    let rooms: [String: JSONObject] = ["thread+one&two": ["parent_room_id": .string("general@home")]]
    let url = try #require(MessageLink.url(endpoint: "wss://chat.example:8443/ws", message: message, rooms: rooms))
    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(parts.scheme == "https")
    #expect(parts.host == "web.apron.chat")
    #expect(parts.fragment == "message=100")
    let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query == ["server": "wss://chat.example:8443/ws", "room": "general@home", "thread": "thread+one&two"])
    #expect(parts.percentEncodedQuery?.contains("%2B") == true)
    let ordinary = try #require(MessageLink.url(endpoint: "wss://chat.example/", message: message, rooms: [:]))
    #expect(URLComponents(url: ordinary, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "thread" } == false)
}

@Test func messageLinksNeverIncludeEndpointCredentials() {
    let message: JSONObject = ["message_id": .string("100"), "room_id": .string("general")]
    for endpoint in ["wss://user:secret@chat.example/", "wss://chat.example/?token=secret", "javascript:alert(1)"] {
        #expect(MessageLink.url(endpoint: endpoint, message: message, rooms: [:]) == nil)
    }
    #expect(MessageLink.url(endpoint: "wss://chat.example/", message: [:], rooms: [:]) == nil)
}
