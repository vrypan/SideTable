import AppKit
import Observation

/// One observable resource is shared by every view displaying the same source.
@MainActor @Observable
final class AvatarEntry {
    let source: String
    let endpoint: URL
    private(set) var image: NSImage?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    init(source: String, endpoint: URL) { self.source = source; self.endpoint = endpoint }

    func refresh(using loader: @escaping AvatarCache.Loader) {
        clear()
        let revision = revision
        task = Task { [weak self, source, endpoint] in
            guard let data = try? await loader(source, endpoint), !Task.isCancelled,
                  let self, self.revision == revision else { return }
            self.image = AvatarLoader.image(data)
        }
    }

    func clear() {
        task?.cancel(); task = nil; revision = UUID(); image = nil
    }

    func waitUntilLoaded() async { await task?.value }
    deinit { task?.cancel() }
}

/// Retains up to 128 decoded thumbnails; visible views retain their own entries.
/// Weak references keep those entries discoverable even after cache eviction.
@MainActor @Observable
final class AvatarCache {
    typealias Loader = @Sendable (String, URL) async throws -> Data
    private(set) var generation = UUID()
    @ObservationIgnored private let retained = NSCache<NSString, AvatarEntry>()
    @ObservationIgnored private var entries: [String: WeakEntry] = [:]
    @ObservationIgnored private let loader: Loader
    private struct WeakEntry { weak var value: AvatarEntry? }
    /// Released entries are pruned when the table doubles, not on every lookup.
    @ObservationIgnored private var pruneThreshold = 256

    init(loader: @escaping Loader = { try await AvatarLoader.load($0, endpoint: $1) }) {
        self.loader = loader
        retained.countLimit = 128
    }

    func entry(source: String, endpoint: URL) -> AvatarEntry {
        let key = endpoint.absoluteString + "\n" + source
        if entries.count >= pruneThreshold {
            entries = entries.filter { $0.value.value != nil }
            pruneThreshold = max(256, entries.count * 2)
        }
        if let entry = entries[key]?.value {
            retained.setObject(entry, forKey: key as NSString)
            return entry
        }
        let entry = AvatarEntry(source: source, endpoint: endpoint)
        entries[key] = WeakEntry(value: entry)
        retained.setObject(entry, forKey: key as NSString)
        entry.refresh(using: loader)
        return entry
    }

    func invalidate(source: String) {
        for entry in entries.values.compactMap(\.value) where entry.source == source {
            entry.refresh(using: loader)
        }
    }

    func reset() {
        for entry in entries.values.compactMap(\.value) { entry.clear() }
        entries.removeAll(); retained.removeAllObjects(); generation = UUID(); pruneThreshold = 256
    }
}
