import AppKit
import Testing
import ApronCore
@testable import Sidetable

@Test func profilesUseCurrentFieldsAndRespectExplicitClears() {
    let recorded: JSONObject = ["user_id": .string("ada"), "name": .string("Old name"), "avatar": .string("https://old.example/a.png"), "roles": .array([.string("admin")]), "status": .string("online")]
    var store = RecordStore()
    let historical = UserProfile(recorded: recorded, store: store)
    #expect(historical.name == "Old name" && historical.status == nil && !historical.hasCurrentIdentity)
    store.mergeUser(["user_id": .string("ada"), "name": .string("Ada"), "avatar": .string(""), "roles": .array([]), "status": .string("away")], complete: true)
    let current = UserProfile(recorded: recorded, store: store)
    #expect(current.name == "Ada" && current.avatar == nil && current.roles.isEmpty && current.status == "away")
    store.mergeUser(["user_id": .string("ada"), "name": .null, "avatar": .null])
    #expect(UserProfile(recorded: recorded, store: store).name == "ada")
    #expect(UserProfile(recorded: recorded, store: store).avatar == nil)
    #expect(recorded.string("name") == "Old name")
}

@Test func profilesFollowAliasesWithoutMixingServers() {
    var first = RecordStore()
    first.aliases["guest"] = "ada"
    first.mergeUser(["user_id": .string("ada"), "name": .string("Ada"), "roles": .array([.string("member")])])
    let recorded: JSONObject = ["user_id": .string("guest"), "avatar": .string("data:image/png;base64,abc")]
    let profile = UserProfile(recorded: recorded, store: first)
    #expect(profile.id == "ada" && profile.name == "Ada")
    #expect(profile.avatar == recorded.string("avatar"))
    #expect(UserProfile(recorded: recorded, store: RecordStore()).id == "guest")
    first.aliases["ada"] = "guest"
    #expect(!UserProfile(recorded: recorded, store: first).id.isEmpty) // Cycles terminate.
}

@Test func avatarSourcesAutomaticallyAllowExternalHTTPS() {
    let endpoint = URL(string: "wss://chat.example/ws")!
    #expect(AvatarLoader.remoteURL("https://chat.example/a.png", endpoint: endpoint) != nil)
    #expect(AvatarLoader.remoteURL("https://cdn.example/a.png", endpoint: endpoint) != nil)
    for source in ["http://cdn.example/a.png", "file:///tmp/a.png", "javascript:alert(1)", "https://user:password@cdn.example/a.png"] {
        #expect(AvatarLoader.remoteURL(source, endpoint: endpoint) == nil)
    }
    #expect(AvatarLoader.inlineData("data:text/html;base64,PGgxPg==") == nil)
    #expect(AvatarLoader.inlineData("data:image/svg+xml;base64,PHN2Zz4=") == nil)
    #expect(AvatarLoader.inlineData("data:image/png;base64,!!!") == nil)
    #expect(AvatarLoader.inlineData("data:image/png;base64," + String(repeating: "A", count: AvatarLoader.maximumBytes * 2)) == nil)
}

@MainActor @Test func avatarsDecodeRasterDataAndRejectNonImages() throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<8 { for y in 0..<8 { bitmap.setColor(NSColor(deviceRed: 0, green: 0.4, blue: 1, alpha: 1), atX: x, y: y) } }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let uri = "data:image/png;base64," + data.base64EncodedString()
    #expect(AvatarLoader.inlineData(uri) == data)
    #expect(AvatarLoader.image(data) != nil)
    #expect(AvatarLoader.image(Data("<svg><script>not an avatar</script></svg>".utf8)) == nil)
    #expect(AvatarLoader.image(Data(repeating: 0, count: AvatarLoader.maximumBytes + 1)) == nil)
}

private actor AvatarRequests {
    var requests: [CheckedContinuation<Data, any Error>] = []
    func load() async throws -> Data {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    var count: Int { requests.count }
    func complete(_ index: Int, with data: Data) { requests[index].resume(returning: data) }
}

@MainActor @Test func avatarCacheSharesRefreshesAndRejectsObsoleteLoads() async throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let requests = AvatarRequests()
    let cache = AvatarCache { _, _ in try await requests.load() }
    let endpoint = URL(string: "wss://chat.example/ws")!
    let source = "https://cdn.example/avatar.png"
    let conversation = cache.entry(source: source, endpoint: endpoint)
    let profile = cache.entry(source: source, endpoint: endpoint)
    #expect(conversation === profile)
    while await requests.count < 1 { await Task.yield() }
    #expect(await requests.count == 1)
    await requests.complete(0, with: data)
    await conversation.waitUntilLoaded()
    let original = try #require(profile.image)
    #expect(cache.entry(source: source, endpoint: endpoint).image === original)

    cache.invalidate(source: source)
    #expect(conversation.image == nil && profile.image == nil)
    while await requests.count < 2 { await Task.yield() }
    cache.invalidate(source: source)
    while await requests.count < 3 { await Task.yield() }
    await requests.complete(2, with: data)
    await profile.waitUntilLoaded()
    let refreshed = try #require(profile.image)
    #expect(refreshed !== original && conversation.image === refreshed)
    await requests.complete(1, with: Data()) // A late, cancelled request cannot erase the refreshed image.
    await Task.yield()
    #expect(profile.image === refreshed)

    let generation = cache.generation
    cache.reset()
    #expect(profile.image == nil && cache.generation != generation)
    let replacement = cache.entry(source: source, endpoint: endpoint)
    #expect(replacement !== profile)
    while await requests.count < 4 { await Task.yield() }
    cache.reset()
    await requests.complete(3, with: data)
    await Task.yield()
    #expect(replacement.image == nil)
}

@Test func memberListSortsActiveMembersFirstAndSearchesProfiles() {
    var store = RecordStore()
    store.members["room"] = ["ada", "zoe", "bob", "missing"]
    store.mergeUser(["user_id": .string("ada"), "name": .string("Ada"), "status": .string("away")])
    store.mergeUser(["user_id": .string("zoe"), "name": .string("Zoe"), "status": .string("online"),
        "roles": .array([.string("admin")]), "ext": .object(["bio": .string("Builds things")])])
    store.mergeUser(["user_id": .string("bob"), "name": .string("Bob"), "status": .string("online")])
    let members = MemberListEntry.members(in: "room", store: store, presenceAvailable: true)
    #expect(members.map(\.id) == ["bob", "zoe", "ada", "missing"])
    #expect(members.filter(\.isActive).count == 2)
    #expect(MemberListEntry.matching(members, query: " ").map(\.id) == members.map(\.id))
    #expect(MemberListEntry.matching(members, query: "o").map(\.id) == ["bob", "zoe"])
    #expect(members[1].hoverText.contains("admin") && members[1].hoverText.contains("Builds things"))
    for query in [" ZOE ", "@zoe", "ADMIN"] {
        #expect(MemberListEntry.members(in: "room", store: store, presenceAvailable: true, query: query).map(\.id) == ["zoe"])
    }
    #expect(MemberListEntry.members(in: "room", store: store, presenceAvailable: true, query: "nobody").isEmpty)
    let saved = MemberListEntry.members(in: "room", store: store, presenceAvailable: false)
    #expect(saved.map(\.id) == ["ada", "bob", "missing", "zoe"])
    #expect(saved.allSatisfy { !$0.isActive && $0.status == "Presence unavailable" })
}

@Test func memberListUsesMembershipProfilesWithoutInventingCurrentPresence() throws {
    var store = RecordStore()
    let recorded: JSONObject = ["user_id": .string("ada"), "name": .string("Ada Lovelace"),
                               "avatar": .string("https://chat.example/ada.png"), "status": .string("online")]
    store.installMembership(["room_id": .string("room"), "log_id": .string("100"),
                             "members": .array([.object(["user": .object(recorded), "joined": .bool(true)])])])
    let members = MemberListEntry.members(in: "room", store: store, presenceAvailable: true, query: "Lovelace")
    let member = try #require(members.first)
    #expect(member.profile.name == "Ada Lovelace")
    #expect(member.profile.avatar == "https://chat.example/ada.png")
    #expect(!member.isActive && member.profile.status == nil)
    #expect(store.users["ada"] == nil)
    store.mergeUser(["user_id": .string("ada"), "name": .string("Current name"), "avatar": .string(""), "status": .string("away")])
    let current = try #require(MemberListEntry.members(in: "room", store: store, presenceAvailable: true).first)
    #expect(current.profile.name == "Current name" && current.profile.avatar == nil)
    #expect(current.status == "Away")
    #expect(MemberListEntry.members(in: "room", store: store, presenceAvailable: true, query: "Lovelace").isEmpty)
}

@Test func memberListUsesCurrentAliasIdentityAndStableNameTies() {
    var store = RecordStore()
    store.members["room"] = ["old", "b"]
    store.aliases["old"] = "a"
    for id in ["a", "b"] {
        store.mergeUser(["user_id": .string(id), "name": .string("Same"), "status": .string("dnd")])
    }
    let members = MemberListEntry.members(in: "room", store: store, presenceAvailable: true)
    #expect(members.map(\.id) == ["b", "old"])
    #expect(members.allSatisfy { !$0.isActive && $0.status == "Do Not Disturb" })
    #expect(MemberListEntry.members(in: "room", store: store, presenceAvailable: true, query: "@a").first?.id == "old")
}

@Test func lastSeenUsesOnlyCurrentShownOfflinePresence() {
    var store = RecordStore()
    let recorded: JSONObject = ["user_id": .string("ada"), "status": .string("offline"), "seen": .string("1724803600000")]
    #expect(UserProfile(recorded: recorded, store: store).lastSeen == nil)
    store.mergeUser(recorded, complete: true)
    #expect(UserProfile(recorded: recorded, store: store).lastSeen == Date(timeIntervalSince1970: 1724803600))
    store.mergeUser(["user_id": .string("ada"), "name": .string("Ada")])
    #expect(UserProfile(recorded: recorded, store: store).lastSeen != nil)
    store.mergeUser(["user_id": .string("ada"), "status": .string("online")])
    #expect(UserProfile(recorded: recorded, store: store).lastSeen == nil)
    store.mergeUser(["user_id": .string("ada"), "status": .string("offline")])
    #expect(UserProfile(recorded: recorded, store: store).lastSeen == nil)
    for invalid in ["0", "-1", "garbage", "9007199254740992"] {
        store.mergeUser(["user_id": .string("ada"), "status": .string("offline"), "seen": .string(invalid)])
        #expect(UserProfile(recorded: recorded, store: store).lastSeen == nil)
    }
    store.ownID = "ada"
    store.mergeUser(recorded, complete: true)
    #expect(UserProfile(recorded: recorded, store: store).lastSeen == nil)
}

private actor DirectMessageTransport: ChatTransport {
    var frames = [WireFrame(method: "server", params: ["apron": .number(9), "auth": .array([.string("guest")]), "capabilities": .array([.string("rooms")])])]
    var receiver: CheckedContinuation<WireFrame, any Error>?
    var rooms: [JSONObject] = []
    var requests: [WireFrame] = []
    var confirmPrivacy = true
    var denyJoin = false
    var holdListing = false
    var heldListing: WireFrame?
    var changeMembersDuringLoad = false

    func configure(rooms: [JSONObject] = [], confirmPrivacy: Bool = true, denyJoin: Bool = false, holdListing: Bool = false) {
        self.rooms = rooms; self.confirmPrivacy = confirmPrivacy; self.denyJoin = denyJoin
        self.holdListing = holdListing; requests = []
    }
    func enqueue(_ frame: WireFrame) {
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { frames.append(frame) }
    }
    func changeMembersOnLoad() { changeMembersDuringLoad = true }
    func releaseListing() {
        holdListing = false
        if let heldListing { self.heldListing = nil; enqueue(heldListing) }
    }
    func send(_ frame: WireFrame) async throws {
        requests.append(frame)
        guard let id = frame.id else { return }
        var result: JSONObject = [:]
        switch frame.method {
        case "auth": result = ["you": .object(["user_id": .string("ada"), "name": .string("Ada")])]
        case "room_list":
            if changeMembersDuringLoad && frame.params?.string("parent_room_id") != nil {
                for index in rooms.indices {
                    rooms[index]["members"] = .array(rooms[index]["members"]!.array + [.object(["user_id": .string("third")])])
                }
                enqueue(WireFrame(method: "room_update", params: ["updated": .array(rooms.map(JSONValue.object))]))
            }
            let selected = frame.params?.string("parent_room_id") != nil ? [] : rooms.filter {
                frame.params?.string("room_id") == nil || $0.string("room_id") == frame.params?.string("room_id")
            }
            result = ["joined": .array(selected.map(JSONValue.object))]
            if holdListing { heldListing = WireFrame(id: id, result: result); return }
        case "room_set":
            var room: JSONObject = ["room_id": .string("100"), "log_id": .string("100"), "private": .bool(confirmPrivacy),
                                    "members": .array([.object(["user_id": .string("ada")])])]
            room["title"] = frame.params?["title"]
            rooms.append(room)
            enqueue(WireFrame(method: "room_update", params: ["joined": .array([.object(room)])]))
            result = ["room_id": .string("100")]
        case "room_join":
            if denyJoin { enqueue(WireFrame(id: id, error: RPCError(code: 403, message: "Cannot add this user"))); return }
            let target = frame.params?.string("user_id") ?? "missing"
            let room = frame.params?.string("room_id")
            for index in rooms.indices where rooms[index].string("room_id") == room {
                rooms[index]["members"] = .array([.object(["user_id": .string("ada")]), .object(["user_id": .string(target)])])
            }
        default: break
        }
        enqueue(WireFrame(id: id, result: result))
    }
    func receive() async throws -> WireFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { receiver?.resume(throwing: ClientError.disconnected); receiver = nil }
}

@MainActor private func directMessageContext() async throws -> (AppModel, ServerModel, ApronSession, DirectMessageTransport) {
    let transport = DirectMessageTransport()
    let session = ApronSession(transportFactory: { transport })
    await session.start()
    for _ in 0..<200 {
        if await session.snapshot().phase == .signIn { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try await session.authenticate(scheme: "guest", fields: [:])
    let model = AppModel(preview: true)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
    server.session = session; server.snapshot = await session.snapshot()
    server.snapshot.store.mergeUser(["user_id": .string("bob"), "name": .string("Bob")])
    model.servers = [server]; model.selectedServer = server.id
    return (model, server, session, transport)
}

@MainActor @Test func messageButtonCreatesPrivateRoomAddsRecipientAndOpensIt() async throws {
    let (model, server, session, transport) = try await directMessageContext()
    await transport.configure()
    try await model.openDirectMessage(to: "bob", server: server)
    let requests = await transport.requests
    let create = try #require(requests.first { $0.method == "room_set" })
    #expect(create.params?.bool("private") == true)
    #expect(create.params?["title"] == nil)
    #expect(requests.first { $0.method == "room_join" }?.params == ["room_id": .string("100"), "user_id": .string("bob")])
    #expect(!requests.contains { $0.method == "message" })
    #expect(server.selectedRoom == "100" && model.thread == nil)
    #expect(server.snapshot.store.members["100"] == ["ada", "bob"])
    #expect(server.participants("100")?.map(\.id) == ["bob"])
    #expect(requests.filter { $0.method == "room_list" && $0.params?.string("room_id") == "100" }.count == 1)
    // A second click reuses the same room rather than creating another.
    try await model.openDirectMessage(to: "bob", server: server)
    #expect(await transport.requests.filter { $0.method == "room_set" }.count == 1)
    await session.stop()
}

@MainActor @Test func messageButtonRejectsUnconfirmedPrivacyAndMembershipFailures() async throws {
    for privacy in [false, true] {
        let (model, server, session, transport) = try await directMessageContext()
        await transport.configure(confirmPrivacy: privacy, denyJoin: true)
        await #expect(throws: (any Error).self) { try await model.openDirectMessage(to: "bob", server: server) }
        #expect(server.selectedRoom == nil)
        #expect(await transport.requests.filter { $0.method == "room_join" }.count == (privacy ? 1 : 0))
        #expect(model.canStartDirectMessage(to: "bob", server: server))
        await session.stop()
    }
}

@MainActor @Test func directRoomMatchingExcludesPublicGroupsThreadsAndTruncatedLists() {
    let room: JSONObject = ["room_id": .string("100"), "private": .bool(true),
                            "members": .array([.object(["user_id": .string("ada")]), .object(["user_id": .string("bob")])])]
    #expect(AppModel.isDirectRoom(room, account: "ada", recipient: "bob"))
    for patch: JSONObject in [["private": .bool(false)], ["parent_room_id": .string("general")], ["member_count": .number(3)],
                              ["members": .array([.object(["user_id": .string("ada")])])]] {
        #expect(!AppModel.isDirectRoom(room.merging(patch) { _, new in new }, account: "ada", recipient: "bob"))
    }
}

@MainActor @Test func messageButtonBlocksDuplicateRequestsAndAccountChanges() async throws {
    let (model, server, session, transport) = try await directMessageContext()
    #expect(!model.canStartDirectMessage(to: "ada", server: server))
    #expect(!model.canStartDirectMessage(to: "~server", server: server))
    server.cached = true
    #expect(!model.canStartDirectMessage(to: "bob", server: server))
    server.cached = false
    await transport.configure(holdListing: true)
    let task = Task { try await model.openDirectMessage(to: "bob", server: server) }
    for _ in 0..<200 {
        if await transport.heldListing != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await transport.heldListing != nil)
    #expect(!model.canStartDirectMessage(to: "bob", server: server))
    server.snapshot.you = ["user_id": .string("other")]
    await transport.releaseListing()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(await transport.requests.allSatisfy { $0.method == "room_list" })
    #expect(server.selectedRoom == nil)
    await session.stop()
}

@MainActor @Test func messageButtonDoesNotOpenConversationWhoseMembershipChangesWhileLoading() async throws {
    let (model, server, session, transport) = try await directMessageContext()
    await transport.configure()
    await transport.changeMembersOnLoad()
    await #expect(throws: (any Error).self) { try await model.openDirectMessage(to: "bob", server: server) }
    #expect(server.selectedRoom == nil)
    await session.stop()
}

@MainActor @Test func cancellingMessageButtonStopsBeforeCreatingRoom() async throws {
    let (model, server, session, transport) = try await directMessageContext()
    await transport.configure(holdListing: true)
    let task = Task { try await model.openDirectMessage(to: "bob", server: server) }
    for _ in 0..<200 {
        if await transport.heldListing != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await transport.heldListing != nil)
    task.cancel()
    await transport.releaseListing()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(await transport.requests.allSatisfy { $0.method == "room_list" })
    #expect(server.selectedRoom == nil)
    await session.stop()
}
