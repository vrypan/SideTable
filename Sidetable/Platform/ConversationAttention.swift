import Foundation

/// Each transcript owns a registration; removing one cannot remove another
/// window's attention. Account and server identity are part of every key.
@MainActor
final class ConversationAttention {
    private var readers: [UUID: DraftKey] = [:]
    func update(_ view: UUID, key: DraftKey, readingLatest: Bool) {
        readers[view] = readingLatest ? key : nil
    }
    func remove(_ view: UUID) { readers.removeValue(forKey: view) }
    func remove(server: UUID) { readers = readers.filter { $0.value.server != server } }
    func contains(_ key: DraftKey) -> Bool { readers.values.contains(key) }
}
