import Foundation

/// Account-scoped cooldowns. Refuse locally instead of silently replaying writes later.
struct RequestLimits {
    static let writes: Set<String> = ["message", "reactions", "room_join", "room_leave", "room_set"]
    private struct Key: Hashable { let account: String; let scope: String }
    private struct Limit { let until: Date; let error: RPCError }
    private var limits: [Key: Limit] = [:]

    private static func upload(_ method: String, _ params: JSONObject) -> Bool {
        ["message", "command"].contains(method) && params.object("body").objects("embeds").contains {
            $0.string("kind") == "upload" && $0.string("embed_id") == nil
        }
    }
    private static func scopes(_ method: String, _ params: JSONObject) -> [String] {
        ["method:" + method] + (writes.contains(method) ? ["write"] : []) + (upload(method, params) ? ["upload"] : [])
    }
    mutating func record(_ error: RPCError, method: String, params: JSONObject, account: String, extended: Bool, now: Date = Date()) {
        guard let delay = error.retryAfter, delay.isFinite, delay >= 0 else { return }
        let category = extended ? error.data?.object?.object("ext").string("limits") : nil
        let scope: String
        if category == "write", Self.writes.contains(method) { scope = "write" }
        else if category == "upload", Self.upload(method, params) { scope = "upload" }
        else { scope = "method:" + method }
        let key = Key(account: account, scope: scope)
        let until = now.addingTimeInterval(delay)
        if until > (limits[key]?.until ?? .distantPast) { limits[key] = Limit(until: until, error: error) }
    }
    func current(account: String, now: Date = Date()) -> [RequestCooldown] {
        limits.compactMap { key, limit in
            guard key.account == account, limit.until > now else { return nil }
            let scope: RequestCooldown.Scope = key.scope == "write" ? .write : key.scope == "upload" ? .upload : .method(String(key.scope.dropFirst(7)))
            return RequestCooldown(scope: scope, retryAt: limit.until)
        }.sorted { $0.retryAt < $1.retryAt }
    }
    mutating func check(method: String, params: JSONObject, account: String, now: Date = Date()) throws {
        limits = limits.filter { $0.value.until > now }
        let active = Self.scopes(method, params).compactMap { limits[Key(account: account, scope: $0)] }.max { $0.until < $1.until }
        if let active {
            var error = active.error
            var data = error.data?.object ?? [:]
            data["retry_after"] = .number(active.until.timeIntervalSince(now)); error.data = .object(data)
            throw error
        }
    }
}

/// Public timing only; error payloads and other accounts' limits stay inside the session.
public struct RequestCooldown: Sendable, Equatable {
    public enum Scope: Sendable, Equatable { case method(String), write, upload }
    public let scope: Scope
    public let retryAt: Date
    public init(scope: Scope, retryAt: Date) { self.scope = scope; self.retryAt = retryAt }
    public func matches(method: String, hasUploads: Bool) -> Bool {
        switch scope {
        case .method(let limited): return method == limited
        case .write: return RequestLimits.writes.contains(method)
        case .upload: return hasUploads && ["message", "command"].contains(method)
        }
    }
    public func remainingSeconds(at now: Date) -> Int {
        let remaining = retryAt.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(min(ceil(remaining), 31_536_000))
    }
}
