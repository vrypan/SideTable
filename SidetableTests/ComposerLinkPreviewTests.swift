import Foundation
import AppKit
import Testing
import ApronCore
@testable import Sidetable

@MainActor @Test func composerDiscoversWebLinksInOrderWithoutCodeImagesOrDuplicates() {
    let discovery = ComposerLinkDiscovery()
    let source = """
    `https://code.example/`
    ```
    https://block.example/
    ```
    ![image](https://image.example/a.png)
    [Unsafe](javascript:alert) [Credentials](https://user:pass@example.com/)
    https://first.example/article
    [Second](https://second.example/page?x=1#section)
    https://first.example/article
    <http://third.example/>
    https://fourth.example/
    """
    #expect(discovery.links(in: source).map(\.id) == [
        "https://first.example/article", "https://second.example/page?x=1#section", "http://third.example/"
    ])
    #expect(discovery.links(in: String(repeating: "x", count: 65_537)).isEmpty)
}

@MainActor @Test func previewExclusionsPersistAndOldDraftsStillDecode() throws {
    let legacy = Data(#"{"text":"old draft","replyTo":"100"}"#.utf8)
    #expect(try JSONDecoder().decode(SavedDraft.self, from: legacy) == SavedDraft(text: "old draft", replyTo: "100"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    let url = "https://example.com/article"
    model.setDraft(SavedDraft(text: url, excludedPreviewURLs: [url]), server: server, room: "general")
    model.saveDrafts()
    let reopened = AppModel(storage: storage, connectOnLaunch: false)
    #expect(reopened.draft(server, room: "general").excludedPreviewURLs == [url])
    #expect(reopened.draft(server, room: "other").excludedPreviewURLs.isEmpty)
    var edited = reopened.draft(server, room: "general")
    edited.text = "No link now"
    reopened.setDraft(edited, server: server, room: "general")
    #expect(reopened.draft(server, room: "general").excludedPreviewURLs.isEmpty)
    server.profile.accountID = "ben"
    #expect(reopened.draft(server, room: "general").text.isEmpty)
}

@MainActor @Test func sendingFreezesSelectedLinkEmbedsAlongsideUploadsWithoutWaitingForMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    server.snapshot.phase = .ready
    let selected = "https://example.com/article", excluded = "https://github.com/shazow/apron"
    let text = selected + " " + excluded
    model.setDraft(SavedDraft(text: text, replyTo: "100", excludedPreviewURLs: [excluded]), server: server, room: "general")
    server.files["general"] = [StagedFile(url: URL(fileURLWithPath: "/tmp/report.txt"))]
    #expect(model.send(server: server, room: "general"))
    let pending = try #require(server.pending.first)
    #expect(pending.params.object("body").string("text") == text)
    #expect(pending.params.object("reply_to").string("message_id") == "100")
    #expect(pending.params.object("body").objects("embeds") == [
        ["kind": .string("upload"), "title": .string("report.txt")],
        ["kind": .string("link"), "url": .string(selected)]
    ])
    #expect(pending.hiddenPreviewURLs == [excluded])
    #expect(model.draft(server, room: "general") == SavedDraft())
    #expect(server.files["general"]?.isEmpty == true)

    model.setDraft(SavedDraft(text: selected), server: server, room: "general")
    #expect(model.send(server: server, room: "general", linkMetadata: [selected: [
        "title": .string("Ready metadata"), "image": .object(["url": .string("https://external.example/image")])
    ]]))
    let enriched = try #require(server.pending.last).params.object("body").objects("embeds")
    #expect(enriched.first?.object("og") == ["title": .string("Ready metadata"),
        "image": .object(["url": .string("https://external.example/image")])])
    #expect(pending.params.object("body").objects("embeds").last?["og"] == nil)
}

@MainActor @Test func commandsDoNotAcquireAutomaticLinkArguments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    server.snapshot.phase = .ready
    server.snapshot.server = ["capabilities": .array([.string("command")])]
    model.setDraft(SavedDraft(text: "/help https://example.com/"), server: server, room: "general")
    #expect(model.send(server: server, room: "general"))
    let message = try #require(server.pending.first)
    #expect(message.isCommand && message.params.object("body")["embeds"] == nil)
}

private actor PreviewFetchGate {
    var started = false
    private var continuation: CheckedContinuation<GitHubPreviewMetadata?, Never>?
    func load() async -> GitHubPreviewMetadata? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: GitHubPreviewMetadata(value: ["title": .string("Late title")], expiresAt: .distantFuture))
        continuation = nil
    }
}

@MainActor @Test func composerIgnoresLateMetadataAfterSwitchingDrafts() async throws {
    let gate = PreviewFetchGate()
    let loader = ComposerLinkPreviewLoader(delay: .zero, fetch: { _, _, _ in await gate.load() }, webFetch: { _ in nil })
    let first = ComposerLinkPreviewLoader.Request(key: DraftKey(server: UUID(), account: "ada", room: "general"),
        links: [ComposerLink(url: URL(string: "https://github.com/shazow/apron")!)])
    let old = Task { await loader.refresh(first) }
    for _ in 0..<200 {
        if await gate.started { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.started)
    #expect(loader.metadata(for: first).isEmpty) // Sending can use URL-only embeds immediately.
    let second = ComposerLinkPreviewLoader.Request(key: DraftKey(server: first.key.server, account: "ben", room: "other"), links: [])
    await loader.refresh(second)
    await gate.finish(); await old.value
    #expect(loader.metadata(for: first).isEmpty && loader.metadata(for: second).isEmpty)
}

@MainActor @Test func composerMetadataIsOptionalScopedAndExpires() async {
    let expires = Date().addingTimeInterval(60)
    let loader = ComposerLinkPreviewLoader(delay: .zero, fetch: { _, _, _ in
        GitHubPreviewMetadata(value: ["title": .string("Ready")], expiresAt: expires)
    }, webFetch: { _ in nil })
    let link = ComposerLink(url: URL(string: "https://github.com/shazow/apron")!)
    let request = ComposerLinkPreviewLoader.Request(key: DraftKey(server: UUID(), account: "ada", room: "general"), links: [link])
    await loader.refresh(request)
    #expect(loader.metadata(for: request)[link.id]?.string("title") == "Ready")
    #expect(loader.metadata(for: request, now: expires).isEmpty)
    let failed = ComposerLinkPreviewLoader(delay: .zero, fetch: { _, _, _ in nil }, webFetch: { _ in nil })
    await failed.refresh(request)
    #expect(failed.metadata(for: request).isEmpty)
    #expect(link.embed(metadata: failed.metadata(for: request)[link.id]) == ["kind": .string("link"), "url": .string(link.id)])
}

@MainActor @Test func retriedMessagesKeepTheOriginalSelectedPreviews() async throws {
    let coordinator = UploadCoordinator()
    let params: JSONObject = ["body": .object(["text": .string("https://example.com/"),
        "embeds": .array([.object(["kind": .string("link"), "url": .string("https://example.com/"), "og": .object(["title": .string("Original"), "image": .object(["url": .string("https://example.com/original.png")])])])])])]
    let message = PendingMessage(id: "same-operation", room: "general", account: "ada", params: params, text: "https://example.com/")
    coordinator.messages = [message]
    var attempts: [(String, JSONObject)] = []
    coordinator.submit(message, endpoint: URL(string: "wss://chat.example/")!) { _, sent, id in
        attempts.append((id, sent)); throw ClientError.timeout
    }
    for _ in 0..<200 where message.sending { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!message.sending && message.error != nil)
    coordinator.submit(message, endpoint: URL(string: "wss://chat.example/")!) { _, sent, id in
        attempts.append((id, sent)); return ["message_id": .string("100")]
    }
    for _ in 0..<200 where message.sending { try await Task.sleep(for: .milliseconds(5)) }
    #expect(attempts.count == 2 && attempts.allSatisfy { $0.0 == "same-operation" && $0.1 == params })
    #expect(message.acknowledged && coordinator.messages.isEmpty)
}

private actor ComposerMessageTransport: ChatTransport {
    private var frames = [WireFrame(method: "server", params: ["apron": .number(9), "auth": .array([.string("guest")])])]
    private var receiver: CheckedContinuation<WireFrame, any Error>?
    var posted: [WireFrame] = []
    func send(_ frame: WireFrame) async throws {
        guard let id = frame.id else { return }
        let result: JSONObject
        if frame.method == "auth" { result = ["you": .object(["user_id": .string("ada")])] }
        else if frame.method == "message" { posted.append(frame); result = ["message_id": .string("100")] }
        else { result = [:] }
        let reply = WireFrame(id: id, result: result)
        if let receiver { self.receiver = nil; receiver.resume(returning: reply) }
        else { frames.append(reply) }
    }
    func receive() async throws -> WireFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { receiver?.resume(throwing: ClientError.disconnected); receiver = nil }
}

@MainActor @Test func acknowledgedMessagesRememberPreviewsOmittedByTheSender() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ComposerMessageTransport()
    let session = ApronSession(transportFactory: { transport })
    await session.start()
    for _ in 0..<200 {
        if await session.snapshot().phase == .signIn { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try await session.authenticate(scheme: "guest", fields: [:])
    let storage = LocalStorage(directory: root)
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    server.session = session; server.snapshot = await session.snapshot()
    let hidden = "https://github.com/shazow/apron", included = "https://example.com/article"
    model.setDraft(SavedDraft(text: hidden + " " + included, excludedPreviewURLs: [hidden]), server: server, room: "")
    let og: JSONObject = ["title": .string("An article"), "image": .object([
        "url": .string("https://example.com/thumbnail.jpg"), "width": .number(1200), "height": .number(630)
    ])]
    #expect(model.send(server: server, room: "", linkMetadata: [included: og]))
    for _ in 0..<200 {
        if model.linkPreviews.hidden(server: server.id, account: "ada", message: "100") == [hidden] { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let posts = await transport.posted
    #expect(posts.count == 1)
    #expect(posts.first?.params?.object("body").objects("embeds") == [["kind": .string("link"), "url": .string(included), "og": .object(og)]])
    #expect(model.linkPreviews.hidden(server: server.id, account: "ada", message: "100") == [hidden])
    #expect(LinkPreviewPreferences(storage: storage).hidden(server: server.id, account: "ada", message: "100") == [hidden])
    #expect(model.linkPreviews.hidden(server: server.id, account: "ben", message: "100").isEmpty)
    await session.stop()
}

private actor ComposerWebFetchGate {
    var started = false
    var calls = 0
    private var result: ComposerWebPreview?
    private var continuation: CheckedContinuation<ComposerWebPreview?, Never>?
    func load() async -> ComposerWebPreview? {
        calls += 1
        if let result { return result }
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ preview: ComposerWebPreview) {
        result = preview
        continuation?.resume(returning: preview); continuation = nil
    }
}

@MainActor private func composerTestImage() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<32 { for y in 0..<16 { bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.4, blue: 0.8, alpha: 1), atX: x, y: y) } }
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor @Test func composerLoadsWebsiteImageAndReusesItWhileEditingTheSameDraft() async throws {
    let data = try composerTestImage()
    let gate = ComposerWebFetchGate()
    let loader = ComposerLinkPreviewLoader(delay: .zero, fetch: { _, _, _ in nil }, webFetch: { _ in await gate.load() })
    let link = ComposerLink(url: URL(string: "https://statusbar.vrypan.net/")!)
    let request = ComposerLinkPreviewLoader.Request(key: DraftKey(server: UUID(), account: "ada", room: "general"), links: [link])
    let pending = Task { await loader.refresh(request) }
    for _ in 0..<200 {
        if await gate.started { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.started)
    #expect(loader.metadata(for: request).isEmpty && loader.images(for: request).isEmpty)
    // Sending remains synchronous while the image request is still pending.
    #expect(link.embed(metadata: loader.metadata(for: request)[link.id])["og"] == nil)
    await gate.finish(ComposerWebPreview(metadata: ["title": .string("statusbar")], imageData: data))
    await pending.value
    let image = try #require(loader.images(for: request)[link.id])
    #expect(image.size.width > image.size.height)
    #expect(loader.metadata(for: request)[link.id]?.string("title") == "statusbar")
    #expect(link.embed(metadata: loader.metadata(for: request)[link.id]).object("og")["image"] == nil)
    await loader.refresh(request)
    #expect(await gate.calls == 1)
    #expect(loader.images(for: request)[link.id] === image)
    #expect(loader.images(for: request, now: .distantFuture).isEmpty)
    #expect(loader.metadata(for: request, now: .distantFuture).isEmpty)
    await loader.refresh(.init(key: request.key, links: []))
    #expect(loader.images(for: request).isEmpty)
}

@MainActor @Test func composerRejectsLateImagesAfterSwitchingAccounts() async throws {
    let gate = ComposerWebFetchGate()
    let loader = ComposerLinkPreviewLoader(delay: .zero, fetch: { _, _, _ in nil }, webFetch: { _ in await gate.load() })
    let link = ComposerLink(url: URL(string: "https://example.com/")!)
    let first = ComposerLinkPreviewLoader.Request(key: DraftKey(server: UUID(), account: "ada", room: "general"), links: [link])
    let pending = Task { await loader.refresh(first) }
    for _ in 0..<200 {
        if await gate.started { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.started)
    let next = ComposerLinkPreviewLoader.Request(key: DraftKey(server: first.key.server, account: "ben", room: "general"), links: [])
    await loader.refresh(next)
    await gate.finish(ComposerWebPreview(metadata: ["title": .string("Late")], imageData: try composerTestImage()))
    await pending.value
    #expect(loader.images(for: first).isEmpty && loader.images(for: next).isEmpty)
    #expect(loader.metadata(for: next).isEmpty)
}

@MainActor @Test func composerKeepsTextWhenImageCannotBeDecoded() async {
    let loader = ComposerLinkPreviewLoader(delay: .zero, webFetch: { _ in
        ComposerWebPreview(metadata: ["title": .string("Text remains")], imageData: Data("not an image".utf8))
    })
    let link = ComposerLink(url: URL(string: "https://example.com/")!)
    let request = ComposerLinkPreviewLoader.Request(key: DraftKey(server: UUID(), account: "ada", room: "general"), links: [link])
    await loader.refresh(request)
    #expect(loader.images(for: request).isEmpty)
    #expect(loader.metadata(for: request)[link.id]?.string("title") == "Text remains")
}

@MainActor @Test func composerCancelsWebsitePreviewWithoutShowingItsImage() async throws {
    let gate = ComposerWebFetchGate()
    let loader = ComposerLinkPreviewLoader(delay: .zero, webFetch: { _ in await gate.load() })
    let link = ComposerLink(url: URL(string: "https://example.com/")!)
    let request = ComposerLinkPreviewLoader.Request(key: DraftKey(server: UUID(), account: "ada", room: "general"), links: [link])
    let pending = Task { await loader.refresh(request) }
    for _ in 0..<200 {
        if await gate.started { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.started)
    pending.cancel()
    await gate.finish(ComposerWebPreview(imageData: try composerTestImage()))
    await pending.value
    #expect(loader.images(for: request).isEmpty)
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDETABLE_LIVE_LINK_PREVIEW"] == "1"))
func liveStatusbarComposerPreviewIncludesImage() async throws {
    let result = try #require(await ComposerWebPreviewFetcher().load(URL(string: "https://statusbar.vrypan.net/")!))
    #expect(result.metadata.string("title")?.contains("statusbar") == true)
    #expect(result.metadata.object("image").string("url") == "https://statusbar.vrypan.net/og-image.png")
    #expect(result.metadata.object("image")["width"]?.number == 1200)
    #expect(result.metadata.object("image")["height"]?.number == 630)
    let embed = ComposerLink(url: URL(string: "https://statusbar.vrypan.net/")!).embed(metadata: result.metadata)
    #expect(embed.object("og").object("image") == result.metadata.object("image"))
    let data = try #require(result.imageData)
    let image = try #require(AttachmentPresentation.thumbnail(data))
    #expect(image.size.width > image.size.height)
}

@Test func outgoingComposerImageMetadataPreservesOnlyValidProtocolFields() {
    let link = ComposerLink(url: URL(string: "https://example.com/article")!)
    let og: JSONObject = ["title": .string("Article"), "image": .object([
        "url": .string("https://example.com/image.png"), "type": .string("image/png"),
        "alt": .string("A diagram"), "width": .number(1200), "height": .number(630), "private": .string("omit")
    ])]
    let sent = link.embed(metadata: og).object("og")
    #expect(sent.object("image").string("url") == "https://example.com/image.png")
    #expect(sent.object("image").string("type") == "image/png")
    #expect(sent.object("image").string("alt") == "A diagram")
    #expect(sent.object("image")["width"]?.number == 1200 && sent.object("image")["height"]?.number == 630)
    #expect(sent.object("image")["private"] == nil)
    for address in ["file:///tmp/thumbnail.png", "data:image/png;base64,AAAA", "javascript:alert(1)",
                    "https://user:password@example.com/a.png", "/relative.png", "https://"] {
        #expect(link.embed(metadata: ["image": .object(["url": .string(address)])])["og"] == nil)
    }
    let invalidSize = link.embed(metadata: ["image": .object(["url": .string("https://example.com/image.png"),
        "width": .number(-1), "height": .number(1.5)])]).object("og").object("image")
    #expect(invalidSize["width"] == nil && invalidSize["height"] == nil)
}

@Test func openGraphParsesRealHeadElementsEntitiesAndImageDimensions() {
    let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <!-- <meta property="og:image" content="https://wrong.example/comment.png"> -->
    <script>const example = '<meta property="og:image" content="https://wrong.example/script.png">';</script>
    <META content='An article &amp; résumé' PROPERTY='og:title'>
    <meta property="og:site_name" content="Example">
    <meta property="og:description" content="A &quot;short&quot; summary.">
    <meta content='/og-image.png?a=1&amp;b=2' property='og:image'>
    <meta property="og:image:width" content="1200">
    <meta property="og:image:height" content="630">
    <meta property="og:image:type" content="image/png">
    <meta property="og:image:alt" content="A terminal">
    </head><body><meta property="og:image" content="https://wrong.example/body.png"></body></html>
    """
    let og = ComposerOpenGraph.parse(Data(html.utf8), url: URL(string: "https://example.com/article")!)
    #expect(og.string("title") == "An article & résumé")
    #expect(og.string("site_name") == "Example")
    #expect(og.string("description") == "A \"short\" summary.")
    #expect(og.object("image") == ["url": .string("https://example.com/og-image.png?a=1&b=2"),
        "width": .number(1200), "height": .number(630), "type": .string("image/png"), "alt": .string("A terminal")])
}

@Test func openGraphResolvesImageAgainstDocumentBaseAndKeepsFirstImagePropertiesTogether() {
    let html = """
    <head><base href="/assets/">
    <meta property="og:image" content="first.png">
    <meta property="og:image:secure_url" content="//cdn.example/secure.png">
    <meta property="og:image:width" content="400">
    <meta property="og:image" content="second.png">
    <meta property="og:image:height" content="999">
    </head>
    """
    let url = URL(string: "https://example.com/redirected/article")!
    let og = ComposerOpenGraph.parse(Data(html.utf8), url: url)
    #expect(og.object("image") == ["url": .string("https://cdn.example/secure.png"), "width": .number(400)])
    let relative = "<head><base href='/assets/'><meta name='og:image:url' content='first.png'></head>"
    #expect(ComposerOpenGraph.parse(Data(relative.utf8), url: url).object("image").string("url") == "https://example.com/assets/first.png")
}

@Test func openGraphIgnoresUnsafeImagesAndBoundsHTMLInput() {
    let url = URL(string: "https://example.com/")!
    for address in ["file:///tmp/a.png", "data:image/png;base64,AAAA", "javascript:alert(1)",
                    "https://user:secret@example.com/image.png", "   "] {
        let html = "<head><meta property='og:title' content='Text only'><meta property='og:image' content='\(address)'></head>"
        let og = ComposerOpenGraph.parse(Data(html.utf8), url: url)
        #expect(og.string("title") == "Text only" && og["image"] == nil)
    }
    #expect(ComposerOpenGraph.parse(Data(repeating: 65, count: ComposerOpenGraph.maximumHTMLBytes + 1), url: url).isEmpty)
    #expect(ComposerOpenGraph.parse(Data(), url: url).isEmpty)
}
