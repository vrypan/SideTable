import Foundation

/// Confined to ApronSession's actor. Each request owns its timeout, so every
/// completion path removes both before resuming the caller, exactly once.
struct PendingRequests {
    private struct Entry {
        let continuation: CheckedContinuation<JSONObject, any Error>
        let timer: Task<Void, Never>
    }
    private var entries: [String: Entry] = [:]

    func contains(_ id: String) -> Bool { entries[id] != nil }

    mutating func insert(_ id: String, continuation: CheckedContinuation<JSONObject, any Error>, timer: Task<Void, Never>) {
        precondition(entries[id] == nil, "Request IDs must be unique while pending")
        entries[id] = Entry(continuation: continuation, timer: timer)
    }

    mutating func complete(_ id: String, with result: Result<JSONObject, any Error>) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(with: result)
    }

    mutating func failAll(_ error: any Error) {
        let waiting = entries
        entries.removeAll()
        for entry in waiting.values { entry.timer.cancel() }
        for entry in waiting.values { entry.continuation.resume(throwing: error) }
    }
}
