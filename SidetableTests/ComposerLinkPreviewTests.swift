import Foundation
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
    #expect(enriched.first?.object("og") == ["title": .string("Ready metadata")])
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
    let loader = ComposerLinkPreviewLoader(delay: .zero, fetch: { _, _, _ in await gate.load() })
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
    })
    let link = ComposerLink(url: URL(string: "https://github.com/shazow/apron")!)
    let request = ComposerLinkPreviewLoader.Request(key: DraftKey(server: UUID(), account: "ada", room: "general"), links: [link])
    await loader.refresh(request)
    #expect(loader.metadata(for: request)[link.id]?.string("title") == "Ready")
    #expect(loader.metadata(for: request, now: expires).isEmpty)
    let failed = ComposerLinkPreviewLoader(delay: .zero, fetch: { _, _, _ in nil })
    await failed.refresh(request)
    #expect(failed.metadata(for: request).isEmpty)
    #expect(link.embed(metadata: failed.metadata(for: request)[link.id]) == ["kind": .string("link"), "url": .string(link.id)])
}

@MainActor @Test func retriedMessagesKeepTheOriginalSelectedPreviews() async throws {
    let coordinator = UploadCoordinator()
    let params: JSONObject = ["body": .object(["text": .string("https://example.com/"),
        "embeds": .array([.object(["kind": .string("link"), "url": .string("https://example.com/"), "og": .object(["title": .string("Original")])])])])]
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
    #expect(model.send(server: server, room: ""))
    for _ in 0..<200 {
        if model.linkPreviews.hidden(server: server.id, account: "ada", message: "100") == [hidden] { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let posts = await transport.posted
    #expect(posts.count == 1)
    #expect(posts.first?.params?.object("body").objects("embeds") == [["kind": .string("link"), "url": .string(included)]])
    #expect(model.linkPreviews.hidden(server: server.id, account: "ada", message: "100") == [hidden])
    #expect(LinkPreviewPreferences(storage: storage).hidden(server: server.id, account: "ada", message: "100") == [hidden])
    #expect(model.linkPreviews.hidden(server: server.id, account: "ben", message: "100").isEmpty)
    await session.stop()
}
