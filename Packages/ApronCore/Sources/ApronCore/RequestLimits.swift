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
