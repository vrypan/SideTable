import Foundation

/// Only read-request metadata. Never includes wire parameters, results, or error text.
public struct SessionDiagnostic: Sendable {
    public enum Trigger: String, Sendable { case roomOpen, refresh, link, olderHistory, bootstrap, reconnect, operation }
    public enum Event: String, Sendable { case started, succeeded, failed, cooldown, cached, coalesced }
    public let date: Date
    public let scope: String
    public let method: String
    public let event: Event
    public let trigger: Trigger
    /// The consumer must anonymize this before persisting or displaying it.
    public let room: String?
    public let request: UUID?
    public let milliseconds: Double?
    public let errorCode: Int?
    public let retryAfter: Double?

    init(method: String, scope: String, event: Event, trigger: Trigger, room: String?, request: UUID? = nil,
         milliseconds: Double? = nil, errorCode: Int? = nil, retryAfter: Double? = nil) {
        date = Date(); self.scope = scope; self.method = method; self.event = event; self.trigger = trigger
        self.room = room; self.request = request; self.milliseconds = milliseconds
        self.errorCode = errorCode; self.retryAfter = retryAfter
    }
}

enum DiagnosticContext {
    @TaskLocal static var trigger: SessionDiagnostic.Trigger = .operation
}
