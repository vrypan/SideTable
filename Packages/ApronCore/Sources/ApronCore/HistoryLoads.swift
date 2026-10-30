import Foundation

/// Actor-confined ownership of in-flight loads and their joiners, keyed by
/// history stream (the empty key represents a server's combined log).
struct HistoryLoads {
    struct Operation {
        let id: UUID
        let older: Bool
    }
    private struct Load {
        let operation: Operation
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }
    private var loads: [String: Load] = [:]

    subscript(_ key: String) -> Operation? { loads[key]?.operation }

    mutating func begin(_ key: String, older: Bool) -> UUID {
        precondition(loads[key] == nil, "History loads for a stream must be serialized")
        let id = UUID()
        loads[key] = Load(operation: Operation(id: id, older: older))
        return id
    }

    mutating func join(_ key: String, id: UUID, waiter: UUID, continuation: CheckedContinuation<Void, any Error>) {
        guard loads[key]?.operation.id == id else { continuation.resume(); return }
        loads[key]?.waiters[waiter] = continuation
    }

    mutating func cancelWaiter(_ key: String, id: UUID, waiter: UUID) {
        guard loads[key]?.operation.id == id else { return }
        loads[key]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }

    mutating func finish(_ key: String, id: UUID, result: Result<Void, any Error>) {
        guard loads[key]?.operation.id == id, let load = loads.removeValue(forKey: key) else { return }
        for waiter in load.waiters.values { waiter.resume(with: result) }
    }

    mutating func failAll(_ error: any Error) {
        let waiting = loads
        loads.removeAll()
        for load in waiting.values {
            for waiter in load.waiters.values { waiter.resume(throwing: error) }
        }
    }
}
