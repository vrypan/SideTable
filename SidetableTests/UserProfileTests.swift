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
