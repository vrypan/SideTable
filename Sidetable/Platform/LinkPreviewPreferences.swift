import Foundation
import Observation

/// Suppression applies only to previews synthesized on this Mac, never to server-supplied embeds.
@MainActor @Observable final class LinkPreviewPreferences {
    struct Key: Codable, Hashable { let server: UUID; let account: String; let message: String }
    struct Entry: Codable { var urls: Set<String>; var updated: Date }
    private var entries: [Key: Entry]
    private let storage: LocalStorage
    init(storage: LocalStorage) {
        self.storage = storage
        entries = storage.read("hidden-link-previews-v1.json", as: [Key: Entry].self) ?? [:]
    }
    func hidden(server: UUID, account: String, message: String) -> Set<String> {
        entries[Key(server: server, account: account, message: message)]?.urls ?? []
    }
    func hide(_ urls: Set<String>, server: UUID, account: String, message: String) throws {
        guard !urls.isEmpty else { return }
        var next = entries
        let key = Key(server: server, account: account, message: message)
        next[key] = Entry(urls: (next[key]?.urls ?? []).union(urls), updated: Date())
        if next.count > 1000 {
            for key in next.sorted(by: { $0.value.updated < $1.value.updated }).prefix(next.count - 1000).map(\.key) { next[key] = nil }
        }
        try storage.write(next, to: "hidden-link-previews-v1.json")
        entries = next
    }
    func clear(server: UUID) throws {
        let next = entries.filter { $0.key.server != server }
        try storage.write(next, to: "hidden-link-previews-v1.json")
        entries = next
    }
}
