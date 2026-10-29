import Foundation
import Observation

@MainActor @Observable final class EmojiEditQueue {
    @MainActor @Observable final class Change: Identifiable {
        let id = UUID()
        let key: String
        let file: StagedFile?
        var operation: PendingMessage?
        var error: String?
        var command: String { (file == nil ? "/emoji remove " : "/emoji add ") + key }
        init(key: String, file: StagedFile?) { self.key = key; self.file = file }
    }
    private(set) var changes: [Change] = []
    private(set) var saving = false
    private(set) var status: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let uploads: UploadCoordinator
    init(uploads: UploadCoordinator) { self.uploads = uploads }

    func add(_ key: String, file: StagedFile) {
        guard !saving, CustomEmoji.validKey(key) else { return }
        discard(key)
        changes.append(Change(key: key, file: file)); status = nil
    }
    func remove(_ key: String, exists: Bool) {
        guard !saving, CustomEmoji.validKey(key) else { return }
        discard(key)
        if exists { changes.append(Change(key: key, file: nil)) }
        status = nil
    }
    func discard(_ key: String) {
        guard !saving else { return }
        for change in changes where change.key == key {
            if let operation = change.operation { uploads.dismiss(operation) }
        }
        changes.removeAll { $0.key == key }; status = nil
    }
    func reset() {
        generation = UUID(); task?.cancel(); task = nil; saving = false
        for change in changes { if let operation = change.operation { uploads.dismiss(operation) } }
        changes = []; status = nil
    }
    func save(using submit: @escaping @MainActor (Change) async throws -> Void,
              finished: @escaping @MainActor () async -> Void = {}) {
        guard !saving, !changes.isEmpty else { return }
        saving = true; status = nil
        let epoch = generation, batch = changes
        task = Task {
            var completed = 0
            for change in batch {
                guard !Task.isCancelled, generation == epoch else { return }
                change.error = nil
                do {
                    try await submit(change)
                    guard !Task.isCancelled, generation == epoch else { return }
                    if let operation = change.operation { uploads.dismiss(operation) }
                    changes.removeAll { $0.id == change.id }; completed += 1
                } catch {
                    guard !Task.isCancelled, generation == epoch else { return }
                    change.error = error.localizedDescription
                    break
                }
            }
            guard !Task.isCancelled, generation == epoch else { return }
            status = changes.isEmpty ? "Saved all emoji changes." : "Saved \(completed) changes. \(changes.count) still pending."
            await finished()
            guard !Task.isCancelled, generation == epoch else { return }
            saving = false; task = nil
        }
    }
}
