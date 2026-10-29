import AppKit
import ApronCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Sidetable

private let emojiEndpoint = URL(string: "wss://chat.example/")!
private func emojiServer(_ catalog: String = "https://chat.example/catalog.json") -> JSONObject {
    ["capabilities": .array([.string("ext:emoji")]), "ext": .object(["emoji": .object(["catalog_url": .string(catalog)])])]
}
private func emojiJSON(_ entries: JSONObject) throws -> Data { try JSONEncoder().encode(entries) }
private func emojiFields(_ url: String = "https://chat.example/a.png") -> JSONValue { .object(["url": .string(url)]) }
private func emojiPixel(_ red: UInt8 = 255) throws -> CGImage {
    let data = Data([red, 40, 160, 255])
    let provider = try #require(CGDataProvider(data: data as CFData))
    return try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}
private func emojiBitmap() throws -> CustomEmojiBitmap { CustomEmojiBitmap(frames: [try emojiPixel()], durations: [0.1]) }
@MainActor private func waitForEmoji(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition(), "Timed out waiting for emoji state")
}

@Test func customEmojiCatalogValidatesKeysTypesAndDimensions() throws {
    let data = try emojiJSON([
        ":Ship-it+1:": .object(["url": .string("https://chat.example/a.png"), "width": .number(64), "height": .number(32),
                              "alt": .string("Squirrel"), "category": .string("Animals"), "tags": .array([.string("ship"), .number(1)]), "hidden": .bool(true)]),
        ":square:": .object(["url": .string("https://chat.example/s.png"), "width": .number(64), "hidden": .string("true")]),
        ":bad key:": emojiFields(), ":é:": emojiFields(), "::": emojiFields(), "missing": emojiFields(), ":no_url:": .object([:]), ":bad_type:": .number(1)])
    let catalog = try CustomEmojiLoader.parse(data)
    #expect(Set(catalog.keys) == [":Ship-it+1:", ":square:"])
    #expect(catalog[":Ship-it+1:"]?.aspectRatio == 2 && catalog[":Ship-it+1:"]?.hidden == true)
    #expect(catalog[":Ship-it+1:"]?.matches("SHIP") == true && catalog[":Ship-it+1:"]?.tags == ["ship"])
    #expect(catalog[":square:"]?.aspectRatio == 1 && catalog[":square:"]?.hidden == false && catalog[":square:"]?.alt == ":square:")
    #expect(catalog[":ship-it+1:"] == nil)
    #expect(throws: (any Error).self) { try CustomEmojiLoader.parse(Data("[]".utf8)) }
    #expect(throws: (any Error).self) { try CustomEmojiLoader.parse(Data(repeating: 32, count: CustomEmojiLoader.maximumCatalogBytes + 1)) }
}

@Test func customEmojiCatalogSourcesExcludeCredentialsRemoteHTTPAndWrongDataTypes() throws {
    for source in ["https://cdn.example/catalog.json?private=token", "http://127.0.0.1:9999/catalog", "http://[::1]/catalog"] {
        #expect(CustomEmojiLoader.catalogURL(source) != nil)
    }
    for source in ["http://remote.example/catalog", "https://user:secret@cdn.example/catalog", "file:///tmp/catalog", "javascript:alert(1)"] {
        #expect(CustomEmojiLoader.catalogURL(source) == nil)
    }
    let data = try emojiJSON([":a:": emojiFields()])
    #expect(CustomEmojiLoader.inlineCatalog("data:application/json;base64," + data.base64EncodedString()) == data)
    #expect(CustomEmojiLoader.inlineCatalog("data:application/json;charset=utf-8,%7B%7D") == Data("{}".utf8))
    #expect(CustomEmojiLoader.inlineCatalog("data:text/html;base64," + data.base64EncodedString()) == nil)
    #expect(CustomEmojiLoader.inlineCatalog("data:application/json;base64,!!") == nil)
}

@Test func customEmojiScanHandlesOverlappingColonsAdjacentKeysAndCase() {
    let keys: Set<String> = [":party:", ":left:", ":right:"]
    let matches = CustomEmojiText.matches("12:30:party: :left::right: :Party: :missing:", keys: keys)
    #expect(matches.map(\.key) == [":party:", ":left:", ":right:"])
    #expect(CustomEmojiText.matches(":party::party:", keys: keys).count == 2)
    #expect(CustomEmojiText.insertion(":party:", into: "@ada", range: NSRange(location: 4, length: 0)) == " :party: ")
    #expect(CustomEmojiText.insertion(":party:", into: "@ada ", range: NSRange(location: 5, length: 0)) == ":party: ")
    #expect(CustomEmojiText.insertion("👍", into: "@ada", range: NSRange(location: 4, length: 0)) == "👍")
}

@Test func customEmojiBitmapsBoundRasterFormatsAndAnimateGIFFrames() throws {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
    for color: UInt8 in [255, 0] {
        CGImageDestinationAddImage(destination, try emojiPixel(color), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    let bitmap = try CustomEmojiLoader.bitmap(data as Data)
    #expect(bitmap.frames.count == 2 && bitmap.cost > 0)
    #expect(bitmap.index(at: Date(timeIntervalSinceReferenceDate: 0.15), reduceMotion: false) == 1)
    #expect(bitmap.index(at: Date(timeIntervalSinceReferenceDate: 0.15), reduceMotion: true) == 0)
    #expect(throws: (any Error).self) { try CustomEmojiLoader.bitmap(Data("<svg/>".utf8)) }
    #expect(throws: (any Error).self) { try CustomEmojiLoader.bitmap(Data(repeating: 0, count: AvatarLoader.maximumBytes + 1)) }
}

private actor EmojiLoads {
    var catalogs = 0
    var images: [String] = []
    func catalog(_ data: Data) async -> Data { catalogs += 1; try? await Task.sleep(for: .milliseconds(10)); return data }
    func image(_ source: String, bitmap: CustomEmojiBitmap) -> CustomEmojiBitmap { images.append(source); return bitmap }
}

@MainActor @Test func customEmojiCacheIsLazySharedAndClearedByIdentityOrCapability() async throws {
    let data = try emojiJSON([":a:": emojiFields(), ":b:": emojiFields()]), bitmap = try emojiBitmap()
    let calls = EmojiLoads()
    let store = CustomEmojiStore(catalogLoader: { _ in await calls.catalog(data) }, imageLoader: { source, _ in await calls.image(source, bitmap: bitmap) })
    store.configure(server: emojiServer(), account: "ada", endpoint: emojiEndpoint)
    #expect(await calls.catalogs == 0 && store.catalog.isEmpty)
    async let first: Void = store.prepare(keys: [":a:"], reduceMotion: false)
    async let second: Void = store.prepare(keys: [":b:"], reduceMotion: false)
    _ = await (first, second)
    try await waitForEmoji { store.images.count == 1 }
    #expect(await calls.catalogs == 1)
    #expect(await calls.images.count == 1)
    let generation = store.generation
    store.configure(server: emojiServer(), account: "ada", endpoint: emojiEndpoint)
    #expect(store.generation == generation && store.catalog.count == 2)
    store.configure(server: emojiServer(), account: "bob", endpoint: emojiEndpoint)
    #expect(store.catalog.isEmpty && store.images.isEmpty && store.generation != generation)
    await store.loadCatalog()
    #expect(await calls.catalogs == 2)
    store.configure(server: [:], account: "bob", endpoint: emojiEndpoint)
    #expect(!store.enabled && store.catalog.isEmpty && store.images.isEmpty)
}

@MainActor @Test func hiddenEmojiRenderButDoNotAppearInPickerAndReducedMotionUsesStaticURL() async throws {
    let bitmap = try emojiBitmap(), calls = EmojiLoads()
    let data = try emojiJSON([":old:": .object(["url": .string("https://chat.example/a.gif"), "static_url": .string("https://chat.example/still.png"), "hidden": .bool(true)]), ":new:": emojiFields()])
    let store = CustomEmojiStore(catalogLoader: { _ in data }, imageLoader: { source, _ in await calls.image(source, bitmap: bitmap) })
    store.configure(server: emojiServer(), account: "ada", endpoint: emojiEndpoint)
    await store.prepare(keys: [":old:"], reduceMotion: true)
    try await waitForEmoji { store.bitmap(for: ":old:", reduceMotion: true) != nil }
    #expect(store.offered.map(\.id) == [":new:"])
    #expect(await calls.images == ["https://chat.example/still.png"])
    store.configure(server: emojiServer("https://chat.example/catalog-v2"), account: "ada", endpoint: emojiEndpoint)
    #expect(store.catalog.isEmpty && store.images.isEmpty)
}

@MainActor @Test func customEmojiAttachmentsPreserveCodeLinksCopyAndSelection() throws {
    let entry = try #require(CustomEmoji(key: ":party:", fields: ["url": .string("https://chat.example/p.png"), "alt": .string("Party time"), "width": .number(64), "height": .number(32)]))
    let frame = CustomEmojiRender(entry: entry, bitmapID: UUID(), frame: 0, image: NSImage(cgImage: try emojiPixel(), size: .zero))
    let frames = [entry.id: frame]
    let parsed = MessageMarkdown("Hello :party::party: `:party:` [celebrate :party:](https://example.com)\n\n```\n:party:\n```\n")
    let paragraph = try #require(parsed.blocks.first?.text)
    let rendered = MessageTextStyle(size: 14).attributed(paragraph, emojis: frames)
    #expect(rendered.string == "Hello \u{FFFC}\u{FFFC} :party: celebrate \u{FFFC}")
    #expect(CustomEmojiAttachment.plainText(rendered) == "Hello :party::party: :party: celebrate :party:")
    // Catalog matching must not change while an earlier overlapping key's image is still loading.
    #expect(MessageTextStyle(size: 14).attributed(AttributedString(":12:party:"), emojis: frames, emojiKeys: [":12:", ":party:"]).string == ":12:party:")
    let linkRange = (rendered.string as NSString).range(of: "celebrate")
    #expect(rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    #expect(rendered.attribute(.toolTip, at: 6, effectiveRange: nil) as? String == "Party time")
    let attachment = try #require(rendered.attribute(.attachment, at: 6, effectiveRange: nil) as? NSTextAttachment)
    #expect(attachment.bounds.width / attachment.bounds.height == 2)
    let block = try #require(parsed.blocks.last?.text)
    #expect(MessageTextStyle(size: 14, code: true).attributed(block, emojis: frames).string == ":party:\n")
    let view = MessageTextView()
    view.show(paragraph, style: MessageTextStyle(size: 14))
    view.setSelectedRange(NSRange(location: 6, length: 14))
    view.show(paragraph, style: MessageTextStyle(size: 14), emojis: frames)
    #expect(view.selectedRange() == NSRange(location: 6, length: 2))
    #expect(CustomEmojiAttachment.accessibleText(rendered).contains("Party timeParty time"))
    let size = view.measuredSize(width: 400)
    let attachmentBeforeAnimation = view.textStorage?.attribute(.attachment, at: 6, effectiveRange: nil) as? NSTextAttachment
    let next = CustomEmojiRender(entry: entry, bitmapID: frame.bitmapID, frame: 1, image: frame.image)
    view.show(paragraph, style: MessageTextStyle(size: 14), emojis: [entry.id: next])
    #expect(view.selectedRange() == NSRange(location: 6, length: 2))
    #expect(view.measuredSize(width: 400) == size)
    #expect(view.textStorage?.attribute(.attachment, at: 6, effectiveRange: nil) as? NSTextAttachment === attachmentBeforeAnimation)
}

@Test func customEmojiAutocompleteUsesServerKeysAndTags() {
    let query = ComposerCompletion.Query(range: NSRange(location: 0, length: 4), marker: ":", text: "cele")
    let candidates = [ComposerSuggestion(insertion: ":party:", label: "Party", search: "party celebrate")]
    #expect(ComposerCompletion.suggestions(for: query, candidates: candidates).first?.insertion == ":party:")
}

private actor EmojiGate {
    var waiters: [CheckedContinuation<Void, Never>] = []
    var started = 0
    var maximumActive = 0
    var active = 0
    func wait() async {
        started += 1; active += 1; maximumActive = max(maximumActive, active)
        await withCheckedContinuation { waiters.append($0) }
        active -= 1
    }
    func release() { let previous = waiters; waiters = []; previous.forEach { $0.resume() } }
}

@MainActor @Test func obsoleteCatalogAndImageLoadsCannotRepopulateAnotherAccount() async throws {
    let oldData = try emojiJSON([":old:": emojiFields()]), newData = try emojiJSON([":new:": emojiFields()])
    let gate = EmojiGate()
    let store = CustomEmojiStore(catalogLoader: { source in
        if source.hasSuffix("old") { await gate.wait(); return oldData }
        return newData
    })
    store.configure(server: emojiServer("https://chat.example/old"), account: "ada", endpoint: emojiEndpoint)
    let pending = Task { await store.loadCatalog() }
    for _ in 0..<100 { if await gate.started > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
    store.configure(server: emojiServer("https://chat.example/new"), account: "bob", endpoint: emojiEndpoint)
    await store.loadCatalog()
    await gate.release(); await pending.value
    #expect(Set(store.catalog.keys) == [":new:"] && !store.loading)

    let imageGate = EmojiGate(), bitmap = try emojiBitmap()
    let images = CustomEmojiStore(catalogLoader: { _ in oldData }, imageLoader: { _, _ in await imageGate.wait(); return bitmap })
    images.configure(server: emojiServer(), account: "ada", endpoint: emojiEndpoint)
    await images.prepare(keys: [":old:"], reduceMotion: false)
    for _ in 0..<100 { if await imageGate.started > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
    images.configure(server: [:], account: nil, endpoint: emojiEndpoint)
    await imageGate.release()
    try await Task.sleep(for: .milliseconds(10))
    #expect(images.images.isEmpty && images.catalog.isEmpty && !images.enabled)
}

@MainActor @Test func imageFetchConcurrencyAndCacheMemoryAreBounded() async throws {
    let gate = EmojiGate(), bitmap = try emojiBitmap()
    let fields = Dictionary(uniqueKeysWithValues: (0..<10).map { (":e\($0):", emojiFields("https://chat.example/\($0).png")) })
    let data = try emojiJSON(fields)
    let store = CustomEmojiStore(byteLimit: bitmap.cost * 2, catalogLoader: { _ in data }, imageLoader: { _, _ in await gate.wait(); return bitmap })
    store.configure(server: emojiServer(), account: "ada", endpoint: emojiEndpoint)
    await store.prepare(keys: Set(fields.keys), reduceMotion: false)
    for _ in 0..<100 { if await gate.started == 4 { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(await gate.started == 4)
    for _ in 0..<20 {
        await gate.release()
        try await Task.sleep(for: .milliseconds(2))
        if await gate.started == 10 { break }
    }
    await gate.release()
    try await Task.sleep(for: .milliseconds(10))
    #expect(await gate.maximumActive <= 4)
    #expect(store.images.count <= 2 && store.images.values.reduce(0) { $0 + $1.cost } <= store.byteLimit)
    store.reset()
}

@MainActor @Test func visibleEmojiSurviveCompetingLoadsAndDeferredDemandResumesOnRelease() async throws {
    let bitmap = try emojiBitmap()
    let data = try emojiJSON([":a:": emojiFields("https://chat.example/a.png"),
                              ":b:": emojiFields("https://chat.example/b.png")])
    let store = CustomEmojiStore(byteLimit: bitmap.cost, catalogLoader: { _ in data }, imageLoader: { _, _ in bitmap })
    store.configure(server: emojiServer(), account: "ada", endpoint: emojiEndpoint)
    let first = UUID(), shared = UUID(), second = UUID()
    await store.prepare(keys: [":a:"], reduceMotion: false, consumer: first)
    for _ in 0..<100 {
        if store.bitmap(for: ":a:", reduceMotion: false) != nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(store.bitmap(for: ":a:", reduceMotion: false) != nil)
    await store.prepare(keys: [":a:"], reduceMotion: false, consumer: shared)
    await store.prepare(keys: [":b:"], reduceMotion: false, consumer: second)
    try await Task.sleep(for: .milliseconds(20))
    #expect(store.bitmap(for: ":a:", reduceMotion: false) != nil)
    #expect(store.bitmap(for: ":b:", reduceMotion: false) == nil)
    store.release(first)
    try await Task.sleep(for: .milliseconds(20))
    #expect(store.bitmap(for: ":a:", reduceMotion: false) != nil)
    #expect(store.images.values.reduce(0) { $0 + $1.cost } <= store.byteLimit)
    store.release(shared)
    for _ in 0..<100 {
        if store.bitmap(for: ":b:", reduceMotion: false) != nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(store.bitmap(for: ":b:", reduceMotion: false) != nil)
    #expect(store.images.count == 1)
    store.reset()
    #expect(store.images.isEmpty)
}
