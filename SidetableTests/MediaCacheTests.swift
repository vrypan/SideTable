import Foundation
import AppKit
import Testing
import ImageIO
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

@MainActor @Test func cachedGitHubFallbackNeverReplacesAuthoritativeMetadata() throws {
    let link = try #require(GitHubPreview("https://github.com/apron-chat/apron-web/issues/114"))
    let cache = AttachmentRenderCache()
    let key = AttachmentRenderCache.key(link.url, server: UUID(), account: "ada")
    cache.store(metadata: ["title": .string("Client fallback"), "description": .string("Open")], key)
    #expect(AttachmentPresentation(embed: link.embed, fallbackMetadata: cache.metadata(key)).linkTitle == "Client fallback")
    var authoritative = link.embed
    authoritative["og"] = .object(["title": .string("Server title"), "description": .string("Closed")])
    let updated = AttachmentPresentation(embed: authoritative, fallbackMetadata: cache.metadata(key))
    #expect(updated.linkTitle == "Server title" && updated.linkDescription == "Closed")
    #expect(AttachmentPresentation.githubFallback(for: authoritative) == nil)
    authoritative["kind"] = .string("upload")
    authoritative["og"] = nil
    #expect(AttachmentPresentation.githubFallback(for: authoritative) == nil)
}

@MainActor @Test func renderMetadataExpiresAndPreservesTheDiskExpiration() {
    var now = Date(timeIntervalSince1970: 1000)
    let cache = AttachmentRenderCache(now: { now })
    cache.store(metadata: ["title": .string("Original")], "fresh")
    cache.store(metadata: ["title": .string("Disk hit")], "disk", expiresAt: now.addingTimeInterval(10))
    now = now.addingTimeInterval(10)
    #expect(cache.metadata("disk") == nil)
    #expect(cache.metadata("fresh")?.string("title") == "Original")
    now = now.addingTimeInterval(3590)
    #expect(cache.metadata("fresh") == nil)
    cache.store(metadata: ["title": .string("Updated")], "fresh")
    #expect(cache.metadata("fresh")?.string("title") == "Updated")
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

@MainActor @Test func previewExtractionReusesContentButInvalidatesEditsFormatsAndEmbeds() throws {
    var extractions = 0
    let cache = GitHubPreviewCache(capacity: 3) { input in
        extractions += 1
        return GitHubPreview.missingEmbeds(in: input.source, existing: input.existing, markdown: input.markdown)
    }
    let address = "https://github.com/apron-chat/apron-web/issues/114"
    let source = "```\n\(address)\n```"
    for _ in 0..<10 { #expect(cache.missingEmbeds(in: source, existing: [], markdown: true).isEmpty) }
    #expect(extractions == 1) // Even empty results are cached.
    let plain = cache.missingEmbeds(in: source, existing: [], markdown: false)
    #expect(plain.count == 1 && extractions == 2)
    #expect(cache.missingEmbeds(in: address, existing: [], markdown: true).count == 1)
    #expect(extractions == 3)
    #expect(cache.missingEmbeds(in: address, existing: plain, markdown: true).isEmpty)
    #expect(extractions == 4) // An authoritative embed suppresses the generated card.
    #expect(cache.missingEmbeds(in: source, existing: [], markdown: true).isEmpty)
    #expect(extractions == 5) // Oldest entry was evicted at capacity.
    cache.clear()
    #expect(cache.missingEmbeds(in: source, existing: [], markdown: true).isEmpty)
    #expect(extractions == 6)
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

/// A photo-sized JPEG with enough detail to compress like a real camera image.
func samplePhoto(width: Int = 4032, height: Int = 3024, seed: Int = 0) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var value = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
    for _ in 0..<4000 {
        value = value &* 1_664_525 &+ 1_013_904_223
        context.setFillColor(red: CGFloat(value & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat((value >> 16) & 0xff) / 255, alpha: 1)
        context.fill(CGRect(x: Int(value % UInt32(width)), y: Int((value >> 7) % UInt32(height)), width: 40 + Int(value % 300), height: 30 + Int(value % 200)))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Test func mediaCachePersistsDownsampledThumbnailsAcrossInstances() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = samplePhoto(width: 1600, height: 1200)
    let cache = MediaCache(directory: root, downloader: { _, _ in photo })
    let url = URL(string: "https://chat.example/photo.jpg")!, server = UUID()
    let first = try await cache.thumbnail(for: url, server: server, account: "ada", limit: photo.count)
    #expect(first.originalSize == photo.count && max(first.image.width, first.image.height) == 840)
    #expect(cache.thumbnailPixelSize(for: url, server: server, account: "ada") == CGSize(width: 840, height: 630))
    #expect(cache.thumbnailPixelSize(for: url, server: server, account: "ben") == nil)

    // A relaunch neither downloads nor decodes the original again.
    let reopened = MediaCache(directory: root, downloader: { _, _ in throw URLError(.notConnectedToInternet) })
    try FileManager.default.removeItem(at: cache.thumbnailFile(for: url, server: server, account: "ada").deletingPathExtension())
    let second = try await reopened.thumbnail(for: url, server: server, account: "ada", limit: photo.count)
    #expect(second.originalSize == nil && second.image.width == 840)

    try await reopened.clear(server: server)
    #expect(reopened.thumbnailPixelSize(for: url, server: server, account: "ada") == nil)
}

@MainActor @Test func decodedImageBudgetRejectsLargeImagesButRemembersTheirSize() throws {
    let bitmap = try #require(MediaCache.downsample(samplePhoto(width: 64, height: 64)))
    let image = NSImage(cgImage: bitmap, size: NSSize(width: 32, height: 32))
    let cost = bitmap.bytesPerRow * bitmap.height
    let small = AttachmentRenderCache(imageByteLimit: cost - 1)
    small.store(image: image, "photo")
    #expect(small.image("photo") == nil)
    #expect(small.imageSize("photo", lookup: { Issue.record("Size should survive image eviction"); return nil }) == image.size)
    let fitting = AttachmentRenderCache(imageByteLimit: cost)
    fitting.store(image: image, "photo")
    #expect(fitting.image("photo") === image)
    fitting.clear()
    #expect(fitting.image("photo") == nil)
}

@Test func mediaCacheAmortizesScansAcrossSmallWritesAndReopens() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = UUID()
    let cache = MediaCache(directory: root, capacity: 400, downloader: { _, _ in Data(repeating: 1, count: 4) })
    for index in 0..<100 {
        _ = try await cache.data(for: URL(string: "https://chat.example/\(index)")!, server: server, account: "ada", limit: 8)
    }
    #expect(await cache.accountingScanCount == 1) // Initial accounting only; no scan per write.
    for index in 100..<200 {
        _ = try await cache.data(for: URL(string: "https://chat.example/\(index)")!, server: server, account: "ada", limit: 8)
    }
    #expect(await cache.accountingScanCount <= 11) // Batch eviction also amortizes a full cache.
    #expect(await cache.usage() <= 400)
    let reopened = MediaCache(directory: root, capacity: 400, downloader: { _, _ in Data(repeating: 2, count: 80) })
    _ = try await reopened.data(for: URL(string: "https://chat.example/new")!, server: server, account: "ada", limit: 100)
    #expect(await reopened.usage() <= 400) // Existing files are included before the first new write.
}

@Test func mediaCacheAccountsForReplacementSizeAndFailedWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = UUID(), url = URL(string: "https://chat.example/a")!
    let cache = MediaCache(directory: root, capacity: 20, downloader: { _, limit in Data(repeating: 1, count: limit) })
    _ = try await cache.data(for: url, server: server, account: "ada", limit: 4)
    _ = try await cache.data(for: url, server: server, account: "ada", limit: 8, maxAge: 0)
    #expect(await cache.accountingScanCount == 1)
    #expect(await cache.usage() == 8)
    try await cache.clear(server: server)
    #expect(await cache.usage() == 0)
    // A regular file cannot serve as the cache directory. Failed writes must not
    // accrue phantom usage or prevent the downloaded bytes from being displayed.
    try FileManager.default.removeItem(at: root)
    try Data().write(to: root)
    let unavailable = MediaCache(directory: root, downloader: { _, _ in Data([1, 2, 3]) })
    #expect(try await unavailable.data(for: url, server: server, account: "ada", limit: 8) == Data([1, 2, 3]))
    #expect(await unavailable.usage() == 0)
}
