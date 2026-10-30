import Foundation

/// Lossless discrete events with replaceable steady-state snapshots. Keep the
/// first snapshot of each phase/account boundary: consumers use it to reconcile
/// unread counts and account state before processing subsequent incoming events.
/// Thereafter only the latest queued snapshot in that phase is retained. Moving
/// it to the queue tail keeps discrete events ordered before their resulting state.
final class SessionEventBuffer: @unchecked Sendable {
    private final class Node {
        let event: SessionEvent
        var next: Node?
        weak var previous: Node?
        init(_ event: SessionEvent) { self.event = event }
    }
    private struct Context: Equatable {
        let phase: ConnectionPhase
        let account: String?
    }
    private let lock = NSLock()
    private var head: Node?
    private var tail: Node?
    private var replaceable: Node?
    private var context: Context?
    private var waiter: CheckedContinuation<SessionEvent?, Never>?
    private var cancelled = false

    deinit { cancel() }

    func yield(_ event: SessionEvent) {
        lock.withLock {
            guard !cancelled else { return }
            let node = Node(event)
            if case .snapshot(let snapshot) = event {
                let nextContext = Context(phase: snapshot.phase, account: snapshot.you.string("user_id"))
                if context == nextContext {
                    if let replaceable { remove(replaceable) }
                    replaceable = node
                } else {
                    // Freeze the transition snapshot, even if no consumer is ready.
                    context = nextContext
                    replaceable = nil
                }
            }
            node.previous = tail
            if let tail { tail.next = node } else { head = node }
            tail = node
            if let waiter, let head {
                self.waiter = nil
                remove(head)
                waiter.resume(returning: head.event)
            }
        }
    }

    func next() async -> SessionEvent? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let head {
                    remove(head)
                    continuation.resume(returning: head.event)
                } else if cancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            while let head { remove(head) }
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    private func remove(_ node: Node) {
        if let previous = node.previous { previous.next = node.next } else { head = node.next }
        if let next = node.next { next.previous = node.previous } else { tail = node.previous }
        if replaceable === node { replaceable = nil }
        node.next = nil; node.previous = nil
    }
}
