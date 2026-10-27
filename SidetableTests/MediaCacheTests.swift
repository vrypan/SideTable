import Foundation
import Testing
import ApronCore
@testable import Sidetable

private actor MediaRequests {
    var count = 0
    var fail = false
    func load(_ url: URL, limit: Int) async throws -> Data {
        count += 1
        try await Task.sleep(for: .milliseconds(20))
        if fail { throw URLError(.notConnectedToInternet) }
        return Data([1, 2, 3, 4])
    }
    func setFailure(_ value: Bool) { fail = value }
}

@Test func mediaCacheSharesTransfersAndPersistsAcrossInstances() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = MediaRequests()
    let cache = MediaCache(directory: root, downloader: { try await requests.load($0, limit: $1) })
    let url = URL(string: "https://chat.example/a.png")!, server = UUID()
    async let first = cache.data(for: url, server: server, account: "ada", limit: 8)
    async let second = cache.data(for: url, server: server, account: "ada", limit: 8)
    let pair = try await (first, second)
    #expect(pair.0 == pair.1)
    #expect(await requests.count == 1)
    let reopened = MediaCache(directory: root, downloader: { _, _ in throw URLError(.notConnectedToInternet) })
    // Automatic network limits must not prevent displaying an explicitly downloaded larger file.
    #expect(try await reopened.data(for: url, server: server, account: "ada", limit: 2) == pair.0)
    #expect(await reopened.usage() == 4)
}

@Test func mediaCacheIsolatesAccountsAndServersAndClearsSelectively() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = MediaRequests()
    let cache = MediaCache(directory: root, downloader: { try await requests.load($0, limit: $1) })
    let url = URL(string: "https://chat.example/a")!, first = UUID(), second = UUID()
    for (server, account) in [(first, "ada"), (first, "ben"), (second, "ada")] {
        _ = try await cache.data(for: url, server: server, account: account, limit: 8)
    }
    #expect(await requests.count == 3)
    try await cache.clear(server: first)
    #expect(await cache.usage() == 4)
    _ = try await cache.data(for: url, server: second, account: "ada", limit: 8)
    #expect(await requests.count == 3)
    try await cache.clear()
    #expect(await cache.usage() == 0)
}

@Test func mediaCacheEvictsOldFilesAndDoesNotCacheFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = MediaRequests()
    let cache = MediaCache(directory: root, capacity: 6, downloader: { try await requests.load($0, limit: $1) })
    let first = URL(string: "https://chat.example/a")!, second = URL(string: "https://chat.example/b")!, server = UUID()
    _ = try await cache.data(for: first, server: server, account: "ada", limit: 8)
    _ = try await cache.data(for: second, server: server, account: "ada", limit: 8)
    #expect(await cache.usage() == 4)
    await requests.setFailure(true)
    #expect(try await cache.data(for: second, server: server, account: "ada", limit: 8) == Data([1, 2, 3, 4]))
    await #expect(throws: URLError.self) { try await cache.data(for: first, server: server, account: "ada", limit: 8) }
    #expect(await cache.usage() == 4)
    await requests.setFailure(false)
    _ = try await cache.data(for: first, server: server, account: "ada", limit: 8)
    #expect(await requests.count == 4)
}

@Test func mediaCacheRejectsOversizedDownloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(directory: root, downloader: { _, _ in Data(repeating: 0, count: 10) })
    await #expect(throws: URLError.self) { try await cache.data(for: URL(string: "https://chat.example/a")!, server: UUID(), account: "ada", limit: 4) }
    #expect(await cache.usage() == 0)
}

@Test func previewFilesAreBoundedPinnedAndReleased() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([1, 2, 3, 4])
    let cache = MediaCache(directory: root, capacity: 8, downloader: { _, _ in bytes })
    let server = UUID(), url = URL(string: "https://chat.example/a")!
    for _ in 0..<3 {
        let file = try await cache.previewFile(for: url, server: server, account: "ada", filename: "../picture.png")
        #expect(file.lastPathComponent == "picture.png")
        #expect(try Data(contentsOf: file) == bytes)
        _ = try await cache.data(for: URL(string: "https://chat.example/b")!, server: server, account: "ada", limit: 8)
        #expect(await cache.usage() <= 8)
        #expect(try Data(contentsOf: file) == bytes) // Trimming cannot evict an open preview.
        await cache.releasePreview(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await cache.usage() <= 4)
    }
}

@Test func clearingPreviewsIsServerScopedAndStartupRemovesAbandonedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(directory: root, capacity: 8, downloader: { _, _ in Data([1, 2, 3, 4]) })
    let first = UUID(), second = UUID(), url = URL(string: "https://chat.example/a")!
    let a = try await cache.previewFile(for: url, server: first, account: "ada", filename: "a.txt")
    let b = try await cache.previewFile(for: url, server: second, account: "ben", filename: "b.txt")
    #expect(await cache.usage() == 8)
    await #expect(throws: URLError.self) {
        _ = try await cache.previewFile(for: url, server: first, account: "ada", filename: "third.txt")
    }
    #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    try await cache.clear(server: first)
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(FileManager.default.fileExists(atPath: b.path))
    #expect(await cache.usage() == 4)
    // Simulate a new process after an abandoned preview, without releasing its lease.
    let reopened = MediaCache(directory: root)
    #expect(await reopened.usage() == 0)
    #expect(!FileManager.default.fileExists(atPath: b.path))
}

@Test func clearingMediaDuringPreviewDownloadCannotCreateAFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = PausedMediaRequest()
    let cache = MediaCache(directory: root, downloader: { _, _ in await request.load() })
    let server = UUID()
    let preview = Task { try await cache.previewFile(for: URL(string: "https://chat.example/a")!, server: server, account: "ada", filename: "a.txt") }
    for _ in 0..<1000 {
        if await request.started { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await request.started)
    try await cache.clear(server: server)
    await request.release()
    await #expect(throws: CancellationError.self) { try await preview.value }
    #expect(await cache.usage() == 0)
}

@Test func linkCardsPreferOpenGraphMetadataAndFallBackToURL() {
    let url = "https://github.com/apron-chat/apron-web/pull/114"
    var embed: JSONObject = ["kind": .string("link"), "url": .string(url), "title": .string(url)]
    var card = AttachmentPresentation(embed: embed)
    #expect(card.isLink && card.linkSite == "github.com" && card.linkDescription == nil)
    embed["og"] = .object(["title": .string("A pull request"), "site_name": .string("GitHub"), "description": .string("A useful summary")])
    card = AttachmentPresentation(embed: embed)
    #expect(card.linkTitle == "A pull request" && card.linkSite == "GitHub" && card.linkDescription == "A useful summary")
    embed["og"] = .object(["title": .string(""), "description": .string("")])
    #expect(AttachmentPresentation(embed: embed).linkTitle == url)
    #expect(AttachmentPresentation(embed: embed).linkDescription == nil)
}

@Test func gitHubPreviewsRecognizeSupportedURLsAndSkipCodeAndDuplicates() throws {
    let address = "https://github.com/apron-chat/apron-web/pull/114"
    let link = try #require(GitHubPreview(address))
    #expect(link.apiURL.absoluteString == "https://api.github.com/repos/apron-chat/apron-web/issues/114")
    #expect(GitHubPreview("https://github.com/apron-chat/apron-web")?.category == "Repository")
    #expect(GitHubPreview("https://github.com/apron-chat/apron-web/commit/abcdef0")?.category == "Commit")
    for invalid in ["https://github.com.evil/apron-chat/apron-web/pull/114", "https://user@github.com/apron-chat/apron-web", "file:///apron-chat/apron-web", "https://github.com/apron-chat/apron-web/blob/main/readme.md"] {
        #expect(GitHubPreview(invalid) == nil)
    }
    #expect(GitHubPreview.missingEmbeds(in: address + " " + address, existing: [], markdown: true).count == 1)
    #expect(GitHubPreview.missingEmbeds(in: "[PR](\(address))", existing: [], markdown: true).count == 1)
    #expect(GitHubPreview.missingEmbeds(in: "`\(address)`\n\n```\n\(address)\n```", existing: [], markdown: true).isEmpty)
    #expect(GitHubPreview.missingEmbeds(in: address + "#discussion", existing: [link.embed], markdown: false).isEmpty)
    let many = (1...8).map { "https://github.com/apron-chat/apron-web/issues/\($0)" }.joined(separator: " ")
    #expect(GitHubPreview.missingEmbeds(in: many, existing: [], markdown: false).count == 3)
    let og = try #require(link.metadata(["title": .string("Useful change"), "state": .string("closed"), "body": .string("<!-- hidden --> Summary"), "user": .object(["login": .string("ada")])]))
    #expect(og.string("title") == "Useful change")
    #expect(og.string("description")?.contains("by ada") == true)
    #expect(og.string("description")?.contains("hidden") == false)
}

@Test func expiringMetadataRefreshesWithoutDiscardingPersistentMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = MediaRequests()
    let cache = MediaCache(directory: root, downloader: { try await requests.load($0, limit: $1) })
    let url = URL(string: "https://api.github.com/repos/apron-chat/apron-web")!, server = UUID()
    _ = try await cache.data(for: url, server: server, account: "ada", limit: 8)
    _ = try await cache.data(for: url, server: server, account: "ada", limit: 8, maxAge: 0)
    #expect(await requests.count == 2)
    _ = try await cache.data(for: url, server: server, account: "ada", limit: 8, maxAge: 3600)
    #expect(await requests.count == 2)
}

private actor PausedMediaRequest {
    var started = false
    var continuation: CheckedContinuation<Data, Never>?
    func load() async -> Data {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: Data([1, 2, 3])); continuation = nil }
}

@Test func clearingMediaCancelsTransfersAndPreventsRepopulation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = PausedMediaRequest()
    let cache = MediaCache(directory: root, downloader: { _, _ in await request.load() })
    let server = UUID()
    let transfer = Task { try await cache.data(for: URL(string: "https://chat.example/a")!, server: server, account: "ada", limit: 8) }
    for _ in 0..<1000 {
        if await request.started { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await request.started)
    try await cache.clear(server: server)
    await request.release()
    await #expect(throws: CancellationError.self) { try await transfer.value }
    #expect(await cache.usage() == 0)
}
