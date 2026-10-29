import AppKit
import ApronCore
import ImageIO
import Observation
import UniformTypeIdentifiers

struct CustomEmoji: Identifiable, Equatable, Sendable {
    let id: String
    let url: String
    let staticURL: String?
    let alt: String
    let category: String
    let tags: [String]
    let hidden: Bool
    let aspectRatio: Double

    static func validKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return bytes.count >= 3 && bytes.count <= 258 && bytes.first == 58 && bytes.last == 58
            && bytes.dropFirst().dropLast().allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [95, 43, 45].contains($0) }
    }
    init?(key: String, fields: JSONObject) {
        guard Self.validKey(key), let url = fields.string("url"), !url.isEmpty else { return nil }
        id = key; self.url = url; staticURL = fields.string("static_url")
        alt = fields.string("alt") ?? key; category = fields.string("category") ?? "Server emoji"
        tags = fields.strings("tags"); hidden = fields.bool("hidden")
        if let width = fields["width"]?.number, let height = fields["height"]?.number,
           width.isFinite, height.isFinite, width > 0, height > 0, (1.0 / 32...32).contains(width / height) {
            aspectRatio = width / height
        } else { aspectRatio = 1 }
    }
    func source(reduceMotion: Bool) -> String { reduceMotion ? staticURL ?? url : url }
    func matches(_ query: String) -> Bool {
        query.isEmpty || ([id, alt, category] + tags).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// The protocol's next-colon scan, rather than a regex that consumes overlapping keys.
enum CustomEmojiText {
    struct Match: Equatable { let range: NSRange; let key: String }
    static func matches(_ text: String, keys: Set<String>? = nil) -> [Match] {
        var matches: [Match] = []
        var cursor = text.startIndex
        while let start = text[cursor...].firstIndex(of: ":") {
            guard let end = text[text.index(after: start)...].firstIndex(of: ":") else { break }
            let range = start...end, key = String(text[range])
            if CustomEmoji.validKey(key), keys == nil || keys!.contains(key) {
                matches.append(Match(range: NSRange(range, in: text), key: key))
                cursor = text.index(after: end)
            } else { cursor = end }
        }
        return matches
    }
    static func keys(in text: AttributedString, known: Set<String>? = nil) -> Set<String> {
        Set(text.runs.filter { !($0.inlinePresentationIntent ?? []).contains(.code) && $0.link?.scheme != "sidetable-mention" }
            .flatMap { matches(String(text[$0.range].characters), keys: known).map(\.key) })
    }
    /// Always separate inserted custom keys from a preceding mention, including at a selected caret.
    static func insertion(_ key: String, into text: String, range: NSRange) -> String {
        guard CustomEmoji.validKey(key), range.location > 0, range.location <= (text as NSString).length else { return key }
        let before = (text as NSString).substring(to: range.location)
        return (before.last?.isWhitespace == false ? " " : "") + key + " "
    }
}

/// Immutable Core Graphics bitmaps can cross the loader boundary. AppKit images stay on the main actor.
struct CustomEmojiBitmap: @unchecked Sendable {
    let id = UUID()
    let frames: [CGImage]
    let durations: [Double]
    var cost: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
    func index(at date: Date, reduceMotion: Bool) -> Int {
        guard !reduceMotion, frames.count > 1 else { return 0 }
        var time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: durations.reduce(0, +))
        for (i, duration) in durations.enumerated() { if time < duration { return i }; time -= duration }
        return 0
    }
}

enum CustomEmojiLoader {
    static let maximumCatalogBytes = 1024 * 1024
    static let maximumEntries = 4096

    static func catalogURL(_ source: String) -> URL? {
        guard let url = URL(string: source), url.user == nil, url.password == nil,
              url.host != nil, url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")) else { return nil }
        return url
    }
    static func inlineCatalog(_ source: String) -> Data? {
        guard source.utf8.count <= maximumCatalogBytes * 3 + 128, let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[..<comma].lowercased().split(separator: ";").map(String.init)
        guard header.first == "data:application/json", header.dropFirst().allSatisfy({ $0 == "base64" || $0 == "charset=utf-8" }) else { return nil }
        let body = String(source[source.index(after: comma)...])
        let data = header.contains("base64") ? Data(base64Encoded: body) : body.removingPercentEncoding?.data(using: .utf8)
        return data.flatMap { $0.count <= maximumCatalogBytes ? $0 : nil }
    }
    static func parse(_ data: Data) throws -> [String: CustomEmoji] {
        guard data.count <= maximumCatalogBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let object = try JSONDecoder().decode(JSONObject.self, from: data)
        guard object.count <= maximumEntries else { throw URLError(.dataLengthExceedsMaximum) }
        return object.reduce(into: [:]) { result, pair in
            if let fields = pair.value.object, let emoji = CustomEmoji(key: pair.key, fields: fields) { result[pair.key] = emoji }
        }
    }
    static func catalog(_ source: String) async throws -> Data {
        if source.lowercased().hasPrefix("data:") {
            guard let data = inlineCatalog(source) else { throw URLError(.cannotDecodeContentData) }
            return data
        }
        guard let url = catalogURL(source) else { throw URLError(.unsupportedURL) }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData); request.timeoutInterval = 20
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              response.expectedContentLength <= maximumCatalogBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumCatalogBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
    static func bitmap(_ data: Data) throws -> CustomEmojiBitmap {
        guard data.count <= AvatarLoader.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier].contains(type) else { throw URLError(.cannotDecodeContentData) }
        var frames: [CGImage] = [], durations: [Double] = [], cost = 0
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw URLError(.cannotDecodeContentData) }
        // Oversized animations fall back to a still, instead of retaining unbounded frames.
        let frameCount = count <= 120 ? count : 1
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= AvatarLoader.maximumPixels / height,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
            cost += image.bytesPerRow * image.height
            if cost > 8 * 1024 * 1024 { break }
            frames.append(image)
            let animation: [CFString: Any]?
            let unclamped: CFString, clamped: CFString
            if type == UTType.png.identifier {
                animation = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                unclamped = kCGImagePropertyAPNGUnclampedDelayTime; clamped = kCGImagePropertyAPNGDelayTime
            } else if type == UTType.webP.identifier {
                animation = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                unclamped = kCGImagePropertyWebPUnclampedDelayTime; clamped = kCGImagePropertyWebPDelayTime
            } else {
                animation = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                unclamped = kCGImagePropertyGIFUnclampedDelayTime; clamped = kCGImagePropertyGIFDelayTime
            }
            let delay = (animation?[unclamped] as? Double) ?? (animation?[clamped] as? Double) ?? 0.1
            durations.append(delay.isFinite ? min(10, max(0.04, delay)) : 0.1)
        }
        guard !frames.isEmpty else { throw URLError(.cannotDecodeContentData) }
        return CustomEmojiBitmap(frames: frames, durations: durations)
    }
    static func image(_ source: String, endpoint: URL) async throws -> CustomEmojiBitmap {
        let data = try await AvatarLoader.load(source, endpoint: endpoint)
        return try bitmap(data)
    }
}

/// A separate, bounded in-memory cache owned by one ServerModel. Nothing is written to disk.
@MainActor @Observable final class CustomEmojiStore {
    typealias CatalogLoader = @Sendable (String) async throws -> Data
    typealias ImageLoader = @Sendable (String, URL) async throws -> CustomEmojiBitmap
    private(set) var catalog: [String: CustomEmoji] = [:]
    private(set) var keys: Set<String> = []
    private(set) var images: [String: CustomEmojiBitmap] = [:]
    private(set) var generation = UUID()
    private(set) var loading = false
    private(set) var failed = false
    private(set) var failedImages = false
    private(set) var enabled = false
    @ObservationIgnored private var identity: Identity?
    private struct Identity: Equatable { let endpoint: URL; let account: String?; let catalog: String }
    @ObservationIgnored private let catalogLoader: CatalogLoader
    @ObservationIgnored private let imageLoader: ImageLoader
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var active: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var imageOrder: [String] = []
    @ObservationIgnored private var loadedCatalog = false
    let byteLimit: Int

    init(byteLimit: Int = 32 * 1024 * 1024, catalogLoader: @escaping CatalogLoader = CustomEmojiLoader.catalog,
         imageLoader: @escaping ImageLoader = CustomEmojiLoader.image) {
        self.byteLimit = byteLimit; self.catalogLoader = catalogLoader; self.imageLoader = imageLoader
    }
    func configure(server: JSONObject, account: String?, endpoint: URL) {
        let next = server.strings("capabilities").contains("ext:emoji")
            ? server.object("ext").object("emoji").string("catalog_url").map { Identity(endpoint: endpoint, account: account, catalog: $0) } : nil
        guard next != identity else { return }
        reset(); identity = next; enabled = next != nil
    }
    func reset() {
        generation = UUID(); catalogTask?.cancel(); catalogTask = nil
        active.values.forEach { $0.cancel() }; active = [:]; queue = []; attempted = []; imageOrder = []
        catalog = [:]; keys = []; images = [:]; identity = nil; enabled = false; loading = false; failed = false; failedImages = false; loadedCatalog = false
    }
    func loadCatalog() async {
        guard let identity, !loadedCatalog else { return }
        if let catalogTask { await catalogTask.value; return }
        let epoch = generation, loader = catalogLoader
        loading = true
        let task = Task { [weak self] in
            do {
                let data = try await loader(identity.catalog)
                let entries = try CustomEmojiLoader.parse(data)
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.catalog = entries; self.keys = Set(entries.keys); self.loadedCatalog = true; self.failed = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.failed = true; self.loadedCatalog = true
            }
            guard let self, self.generation == epoch else { return }
            self.loading = false; self.catalogTask = nil
        }
        catalogTask = task; await task.value
    }
    func prepare(keys: Set<String>, reduceMotion: Bool) async {
        guard !keys.isEmpty else { return }
        await loadCatalog()
        guard !Task.isCancelled else { return }
        for key in keys.sorted().prefix(128) {
            guard let entry = catalog[key] else { continue }
            let source = entry.source(reduceMotion: reduceMotion)
            if images[source] != nil { imageOrder.removeAll { $0 == source }; imageOrder.append(source); continue }
            guard attempted.insert(source).inserted else { continue }
            queue.append(source)
        }
        pump()
    }
    private func pump() {
        guard let identity else { return }
        while active.count < 4, !queue.isEmpty {
            let source = queue.removeFirst(), epoch = generation, loader = imageLoader
            active[source] = Task { [weak self] in
                let image = try? await loader(source, identity.endpoint)
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                if let image, image.cost <= self.byteLimit {
                    var cost = self.images.values.reduce(0) { $0 + $1.cost }
                    while cost + image.cost > self.byteLimit || self.images.count >= 256 {
                        guard !self.imageOrder.isEmpty else { break }
                        let oldest = self.imageOrder.removeFirst()
                        cost -= self.images.removeValue(forKey: oldest)?.cost ?? 0
                        self.attempted.remove(oldest)
                    }
                    self.images[source] = image; self.imageOrder.append(source)
                }
                if image == nil {
                    self.failedImages = true
                    // A failed still URL can use the first frame of the original instead.
                    for entry in self.catalog.values where entry.staticURL == source && entry.url != source {
                        if self.attempted.insert(entry.url).inserted { self.queue.append(entry.url) }
                    }
                }
                self.active[source] = nil; self.pump()
            }
        }
    }
    func refreshCatalog() async {
        let previous = identity
        reset(); identity = previous; enabled = previous != nil
        await loadCatalog()
    }
    func retry() {
        if failed { loadedCatalog = false; failed = false }
        failedImages = false
        generation = UUID()
        // Cancel prior generation tasks before retrying; loaded images remain reusable.
        catalogTask?.cancel(); catalogTask = nil; loading = false
        active.values.forEach { $0.cancel() }; active = [:]; queue = []; attempted = Set(images.keys)
    }
    var offered: [CustomEmoji] { catalog.values.filter { !$0.hidden }.sorted { $0.id < $1.id } }
    func bitmap(for key: String, reduceMotion: Bool) -> CustomEmojiBitmap? {
        catalog[key].flatMap { images[$0.source(reduceMotion: reduceMotion)] ?? (reduceMotion ? images[$0.url] : nil) }
    }
    deinit { catalogTask?.cancel(); active.values.forEach { $0.cancel() } }
}
