import Testing
import ApronCore
@testable import Sidetable

@Test func apronCardsUseCurrentAccountDataAndDoNotExposeDeletedMessages() throws {
    var store = RecordStore()
    store.rooms["thread"] = ["room_id": .string("thread"), "parent_room_id": .string("general"), "title": .string("Release"), "description": .string("A **release** checklist")]
    let card = try #require(ApronLinkPreview(address: "apron:?room=thread", endpoint: "wss://chat.example/", store: store, serverTitle: "Chat"))
    #expect(card.title == "Release" && card.kind == "Thread" && card.detail == "A release checklist")
    store.users["ada"] = ["user_id": .string("ada"), "name": .string("Ada")]
    store.messages["100"] = ["message_id": .string("100"), "room_id": .string("thread"), "from": .object(["user_id": .string("ada")]), "body": .object(["text": .string("Ready **today**"), "format": .string("markdown")])]
    func messageCard(_ store: RecordStore) throws -> ApronLinkPreview {
        try #require(ApronLinkPreview(address: "apron:?room=thread&message=100", endpoint: "wss://chat.example/", store: store, serverTitle: "Chat"))
    }
    #expect(try messageCard(store).detail == "Ada: Ready today")
    #expect(try messageCard(RecordStore()).detail == "Open to view this message")
    store.messages["100"]?["deleted"] = .bool(true)
    #expect(try messageCard(store).detail == "Message deleted")
    store.messages["100"]?["room_id"] = .string("elsewhere")
    #expect(try messageCard(store).detail == "Open to view this message")
}

@MainActor @Test func apronCardDiscoveryDeduplicatesEmbedsAndSkipsCodeAndOtherServers() throws {
    let discovery = ApronLinkDiscovery()
    let endpoint = "wss://chat.example/"
    let text = """
    [Room](apron:?room=general)
    https://link.apron.chat/#room=general&server=wss://chat.example/
    `apron:?room=code`
    [Other](apron:?server=wss://other.example/&room=other)
    ![Image](apron:?room=image)
    [Invite](https://link.apron.chat/#server=wss://chat.example/&token=secret)
    """
    let embeds = discovery.missingEmbeds(in: text, markdown: true, endpoint: endpoint, existing: [])
    #expect(embeds.count == 1)
    #expect(embeds[0].string("url") == "https://link.apron.chat/#server=wss://chat.example/&room=general")
    #expect(discovery.missingEmbeds(in: text, markdown: true, endpoint: endpoint, existing: embeds).isEmpty)
    let onOtherServer = discovery.missingEmbeds(in: "apron:?room=general", markdown: false, endpoint: "wss://other.example/", existing: [])
    #expect(onOtherServer.first?.string("url")?.contains("server=wss://other.example/") == true)
    #expect(discovery.missingEmbeds(in: String(repeating: "a", count: 65_537), markdown: false, endpoint: endpoint, existing: []).isEmpty)
    let many = (0..<10).map { "apron:?room=room\($0)" }.joined(separator: " ")
    #expect(discovery.missingEmbeds(in: many, markdown: false, endpoint: endpoint, existing: []).count == 3)
}

@Test func apronCardsExcludeInvitesAndOtherEndpointsAndShowProfiles() throws {
    for address in ["https://link.apron.chat/#server=wss://chat.example/&token=secret", "apron:?server=wss://other.example/&room=general", "apron:?server=wss://chat.example/other&room=general"] {
        #expect(ApronLinkPreview(address: address, endpoint: "wss://chat.example/", store: RecordStore(), serverTitle: "Chat") == nil)
    }
    var store = RecordStore()
    store.users["ada"] = ["user_id": .string("ada"), "name": .string("Ada"), "ext": .object(["bio": .string("Hello")])]
    let card = try #require(ApronLinkPreview(address: "apron:?user=ada", endpoint: "wss://chat.example/", store: store, serverTitle: "Chat"))
    #expect(card.title == "Ada" && card.detail == "Hello" && card.kind == "Profile")
}

@MainActor @Test func apronLocalCardsCanBeHiddenWithoutSendingTheirMetadata() throws {
    let embeds = ApronLinkDiscovery().missingEmbeds(in: "apron:?room=general", markdown: false, endpoint: "wss://chat.example/", existing: [])
    var edit = MessageEdit(message: ["message_id": .string("100"), "body": .object(["text": .string("apron:?room=general")])], localPreviews: embeds)
    edit.remove(0)
    #expect(edit.hiddenPreviewURLs == Set(embeds.compactMap { $0.string("url") }))
    #expect(!edit.remoteChanged)
    #expect(try edit.parameters(knownUserIDs: []).object("body").objects("embeds").isEmpty)
}
