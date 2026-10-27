import Foundation
import Testing
import ApronCore
@testable import Sidetable

@Test func messageLinksUseStandardFragmentAndThreadRoom() throws {
    let message: JSONObject = ["message_id": .string("100"), "room_id": .string("thread+one&two")]
    let rooms: [String: JSONObject] = ["thread+one&two": ["parent_room_id": .string("general")]]
    let url = try #require(MessageLink.url(endpoint: "wss://chat.example:8443/ws", message: message, rooms: rooms))
    #expect(url.absoluteString == "https://link.apron.chat/#server=wss://chat.example:8443/ws&room=thread%2Bone%26two&message=100")
    let parsed = try ApronLink(url.absoluteString)
    #expect(parsed.room == "thread+one&two")
    #expect(parsed.message == "100")
    #expect(parsed.server.absoluteString == "wss://chat.example:8443/ws")
}

@Test func messageLinksNeverIncludeEndpointCredentials() {
    let message: JSONObject = ["message_id": .string("100"), "room_id": .string("general")]
    for endpoint in ["wss://user:secret@chat.example/", "wss://chat.example/?token=secret", "javascript:alert(1)", "ws://chat.example/"] {
        #expect(MessageLink.url(endpoint: endpoint, message: message, rooms: [:]) == nil)
    }
    #expect(MessageLink.url(endpoint: "wss://chat.example/", message: [:], rooms: [:]) == nil)
}

@Test func apronLinksDecodeFormsAndUseFirstRepeatedKey() throws {
    let link = try ApronLink("apron:?server=wss://chat.example/ws&server=wss://other.example/&room=a%2Bb&room=other&user=ada%40example.com&unknown=ok")
    #expect(link.server.host == "chat.example")
    #expect(link.room == "a+b")
    #expect(link.user == "ada@example.com")
    let invite = try ApronLink("https://link.apron.chat/#server=wss://chat.example/&token=a+b%2Bc&state=ignored")
    #expect(invite.token == "a b+c")
    #expect(try ApronLink("apron:?room=ops", relativeTo: "wss://chat.example/").room == "ops")
    #expect(try ApronLink("apron:?server=ws://127.0.0.1:8080/ws").server.scheme == "ws")
}

@Test func apronLinksRejectUnsafeServersAndMalformedDestinations() {
    for text in [
        "https://evil.example/#server=wss://chat.example/",
        "https://link.apron.chat/elsewhere#server=wss://chat.example/",
        "apron:?server=file:///tmp/test", "apron:?server=javascript:alert(1)",
        "apron:?server=chat.example", "apron:?server=ws://chat.example/",
        "apron:?server=wss://user:secret@chat.example/", "apron:?room=ops",
        "apron:?server=wss://chat.example/&room=", "apron:?server=wss://chat.example/&room=a+b",
        "apron:?server=wss://chat.example/&message=100",
        "apron:?server=wss://chat.example/&room=ops&message=invalid",
        "apron:?server=wss://chat.example/&token=secret",
        "apron:?server=&server=wss://chat.example/"
    ] {
        #expect(throws: (any Error).self) { try ApronLink(text) }
    }
}

private actor LinkTransport: ChatTransport {
    var frames = [WireFrame(method: "server", params: ["apron": .number(9), "auth": .array([.string("guest")]), "capabilities": .array([.string("rooms"), .string("history")])])]
    var receiver: CheckedContinuation<WireFrame, any Error>?
    var methods: [String] = []
    var historyRequests: [JSONObject] = []
    var holdHistory = false
    var olderHasMore = false
    var heldResponses: [WireFrame] = []
    func configureHistory(hold: Bool = false, olderHasMore: Bool = false) {
        holdHistory = hold; self.olderHasMore = olderHasMore
    }
    func releaseHistory() {
        holdHistory = false
        for response in heldResponses {
            if let receiver { self.receiver = nil; receiver.resume(returning: response) }
            else { frames.append(response) }
        }
        heldResponses = []
    }
    func send(_ frame: WireFrame) async throws {
        methods.append(frame.method ?? "")
        guard let id = frame.id else { return }
        let result: JSONObject
        switch frame.method {
        case "auth": result = ["you": .object(["user_id": .string("ada")])]
        case "room_list": result = ["joined": .array([.object(["room_id": .string("general"), "log_id": .string("1")])])]
        case "history":
            historyRequests.append(frame.params ?? [:])
            let room = frame.params?.string("room_id") ?? "general"
            let older = frame.params?.string("before") == "149"
            // Message IDs are server-global. The bootstrap room must not reuse
            // the discussion fixture's ID at the same version.
            let messageID = room == "general" ? (older ? "90" : "140") : (older ? "100" : "150")
            let message: JSONObject = ["message_id": .string(messageID), "log_id": .string(older ? "100" : "150"), "room_id": .string(room), "from": .object(["user_id": .string("ada")])]
            result = ["latest_log_id": .string("200"), "history_log_id": .string("1"), "more": .bool(!older || olderHasMore),
                      "first_log_id": .string(older ? "100" : "150"), "last_log_id": .string(older ? "100" : "150"),
                      "rooms": .array([.object(["room_id": .string(room), "parent_room_id": .string("general"), "log_id": .string("1")])]),
                      "messages": .array([.object(message)])]
        default: result = [:]
        }
        let response = WireFrame(id: id, result: result)
        if frame.method == "history", holdHistory { heldResponses.append(response); return }
        if let receiver { self.receiver = nil; receiver.resume(returning: response) }
        else { frames.append(response) }
    }
    func receive() async throws -> WireFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { receiver?.resume(throwing: ClientError.disconnected); receiver = nil }
}

@MainActor @Test func openingThreadMessageLoadsOlderHistoryWithoutJoining() async throws {
    let transport = LinkTransport()
    let session = ApronSession(transportFactory: { transport })
    await session.start()
    for _ in 0..<100 {
        if await session.snapshot().phase == .signIn { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try await session.authenticate(scheme: "guest", fields: [:])
    let model = AppModel(preview: true)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
    server.session = session; server.snapshot = await session.snapshot()
    model.servers = [server]; model.selectedServer = server.id
    model.receiveLink(try #require(URL(string: "apron:?server=wss://CHAT.example&room=discussion&message=100")))
    #expect(!model.showOpenLink)
    for _ in 0..<100 {
        if model.linkedMessage != nil || server.error != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.error == nil)
    #expect(server.selectedRoom == "general")
    #expect(model.thread == "discussion")
    #expect(model.linkedMessage?.message == "100")
    #expect(await transport.methods.contains("room_join") == false)
    #expect(throws: AppModel.LinkOpenError.self) {
        try model.openLink(ApronLink("https://link.apron.chat/#server=wss://chat.example/&token=invite"))
    }
    model.selectRoom("general", server: server)
    #expect(model.linkedMessage == nil)
    await session.stop()
}

@Test func sideTableLinksUseStandardFieldsAndRejectCustomSchemeTokens() throws {
    let link = try ApronLink("sidetable://open?server=wss://chat.example/ws&room=a%2Bb&message=100")
    #expect(link == (try ApronLink("apron:?server=wss://chat.example/ws&room=a%2Bb&message=100")))
    for text in ["sidetable://other?server=wss://chat.example/", "sidetable://open/path?server=wss://chat.example/",
                 "sidetable://open?server=wss://chat.example/&token=secret", "sidetable://open?server=ws://remote.example/"] {
        #expect(throws: (any Error).self) { try ApronLink(text) }
    }
}

@MainActor @Test func externalLinksWaitForReviewBeforeConnecting() throws {
    let model = AppModel(preview: true)
    let existing = model.servers.map(\.id)
    let url = try #require(URL(string: "sidetable://open?server=wss://new.example/&room=general"))
    model.receiveLink(url)
    #expect(model.showOpenLink)
    #expect(model.openLinkText == url.absoluteString)
    #expect(model.servers.map(\.id) == existing)
    model.showOpenLink = false
    model.receiveLink(try #require(URL(string: "sidetable://other?server=wss://new.example/")))
    #expect(!model.showOpenLink)
    #expect(model.globalError != nil)
}

@MainActor @Test func restoringViewedMessageLoadsOlderHistory() async throws {
    let transport = LinkTransport()
    let session = ApronSession(transportFactory: { transport })
    await session.start()
    for _ in 0..<100 {
        if await session.snapshot().phase == .signIn { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try await session.authenticate(scheme: "guest", fields: [:])
    try await session.loadRoom("discussion")
    let model = AppModel(preview: true)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
    server.session = session; server.snapshot = await session.snapshot()
    model.viewedMessages[DraftKey(server: server.id, account: server.account, room: "discussion")] = "100"
    #expect(server.snapshot.store.messages["100"] == nil)
    #expect(await model.restoreViewedMessage(server: server, room: "discussion") == "100")
    #expect(server.snapshot.store.messages["100"] != nil)
    #expect(await transport.methods.contains("room_join") == false)
    await session.stop()
}

@MainActor @Test func openingMessageWaitsForExistingRoomLoad() async throws {
    let transport = LinkTransport()
    let session = ApronSession(transportFactory: { transport })
    await session.start()
    try await waitForLinkCondition { await session.snapshot().phase == .signIn }
    try await session.authenticate(scheme: "guest", fields: [:])
    let model = AppModel(preview: true)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
    server.session = session; server.snapshot = await session.snapshot()
    model.servers = [server]; model.selectedServer = server.id
    await transport.configureHistory(hold: true)
    let loading = Task { try await session.loadRoom("discussion") }
    try await waitForLinkCondition { await transport.heldResponses.count == 1 }
    try model.openLink(ApronLink("apron:?server=wss://chat.example/&room=discussion&message=150"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(server.error == nil && model.linkedMessage == nil)
    await transport.releaseHistory()
    try await loading.value
    try await waitForLinkCondition { model.linkedMessage != nil || server.error != nil }
    #expect(server.error == nil)
    #expect(model.linkedMessage?.message == "150")
    #expect(await transport.historyRequests.filter { $0.string("room_id") == "discussion" }.count == 1)
    await session.stop()
}

@MainActor @Test func missingMessageLinkStopsAfterCoveredLogSlice() async throws {
    for target in ["175", "125"] {
        let transport = LinkTransport()
        let session = ApronSession(transportFactory: { transport })
        await session.start()
        try await waitForLinkCondition { await session.snapshot().phase == .signIn }
        try await session.authenticate(scheme: "guest", fields: [:])
        await transport.configureHistory(olderHasMore: true)
        let model = AppModel(preview: true)
        let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
        server.session = session; server.snapshot = await session.snapshot()
        model.servers = [server]; model.selectedServer = server.id
        try model.openLink(ApronLink("apron:?server=wss://chat.example/&room=discussion&message=\(target)"))
        try await waitForLinkCondition { server.error != nil }
        #expect(server.error == "The message is not available in this room’s retained history.")
        let requests = await transport.historyRequests.filter { $0.string("room_id") == "discussion" }
        #expect(requests.count == (target == "175" ? 1 : 2))
        #expect(model.linkedMessage == nil)
        await session.stop()
    }
}

@MainActor private func waitForLinkCondition(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ClientError.timeout
}

@MainActor @Test func sameServerLinksUseTheirSourcePanelRatherThanBrowsedServer() async throws {
    let model = AppModel(preview: true)
    let source = try #require(model.current)
    let other = ServerModel(ServerProfile(address: "wss://other.example/"))
    model.servers.append(other)
    model.selectedServer = other.id
    model.receiveLink(try #require(URL(string: "apron:?user=maya")), from: source)
    try await waitForLinkCondition { model.linkedUser == "maya" }
    #expect(!model.showOpenLink)
    #expect(model.current === source)
    #expect(model.servers.count == 2)
}

@MainActor @Test func otherEndpointsAndSameServerInvitesStillRequireReview() throws {
    let model = AppModel(preview: true)
    let source = try #require(model.current)
    source.profile.address = "wss://chat.example/ws"
    let addresses = [
        "https://link.apron.chat/#server=wss://chat.example/ws&token=invite",
        "apron:?server=wss://chat.example/other&user=maya",
        "apron:?server=wss://chat.example:8443/ws&user=maya",
        "apron:?server=wss://different.example/ws&user=maya"
    ]
    for address in addresses {
        model.showOpenLink = false
        model.receiveLink(try #require(URL(string: address)), from: source)
        #expect(model.showOpenLink)
        #expect(model.linkedUser == nil)
        #expect(model.servers.count == 1)
    }
}
