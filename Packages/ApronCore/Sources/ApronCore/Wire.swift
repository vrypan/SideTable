import Foundation

public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var object: JSONObject? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
}

public typealias JSONObject = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    public func string(_ key: String) -> String? { self[key]?.string }
    public func object(_ key: String) -> JSONObject { self[key]?.object ?? [:] }
    public func objects(_ key: String) -> [JSONObject] { self[key]?.array.compactMap(\.object) ?? [] }
    public func strings(_ key: String) -> [String] { self[key]?.array.compactMap(\.string) ?? [] }
    public func bool(_ key: String) -> Bool { self[key]?.bool == true }
    public func logID(_ key: String) -> UInt64? { string(key).flatMap(LogID.init)?.value }
    public var messageIdentity: String { string("message_id") ?? "" }
}

public struct LogID: Sendable, Equatable, Comparable {
    public let value: UInt64
    public init?(_ string: String) {
        guard !string.isEmpty, string.first != "0", string.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(string), number > 0, number < 9_007_199_254_740_992 else { return nil }
        value = number
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

public struct WireFrame: Codable, Sendable, Equatable {
    public var method: String?
    public var id: String?
    public var params: JSONObject?
    public var result: JSONObject?
    public var error: RPCError?
    public init(method: String? = nil, id: String? = nil, params: JSONObject? = nil, result: JSONObject? = nil, error: RPCError? = nil) {
        self.method = method; self.id = id; self.params = params; self.result = result; self.error = error
    }
}

public struct RPCError: Codable, Error, Sendable, Equatable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) { self.code = code; self.message = message; self.data = data }
    public var errorDescription: String? { message }
    public var retryAfter: Double? { data?.object?["retry_after"]?.number }
}

public enum ClientError: Error, LocalizedError, Sendable {
    case invalidURL, disconnected, timeout, unsupportedVersion, invalidHistory, notReady, insecureURL, invalidSignInURL
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid server hostname or WebSocket URL."
        case .disconnected: "The connection closed. Delivery may be uncertain."
        case .timeout: "The server did not reply. Delivery may be uncertain."
        case .unsupportedVersion: "This server uses an unsupported Apron version. SideTable supports versions 8 and 9."
        case .invalidSignInURL: "The server returned an invalid sign-in URL. Use HTTPS, or HTTP on localhost."
        case .invalidHistory: "The server returned inconsistent history. Please reconnect."
        case .notReady: "Wait until the conversation finishes connecting."
        case .insecureURL: "Use wss:// for remote servers. Unencrypted connections are limited to localhost."
        }
    }
}

public enum ServerAddress {
    public static func normalize(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var c = URLComponents(string: text.contains("://") ? text : "wss://" + text),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.fragment == nil,
              let scheme = c.scheme?.lowercased(), ["ws", "wss"].contains(scheme) else { throw ClientError.invalidURL }
        if scheme == "ws" && !["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()) { throw ClientError.insecureURL }
        c.scheme = scheme; c.host = host.lowercased()
        if c.path.isEmpty { c.path = "/" }
        guard let url = c.url else { throw ClientError.invalidURL }
        return url
    }
}

/// The reviewed wire versions; future versions require an explicit compatibility review.
public enum ApronProtocol {
    public static func supports(_ version: JSONValue?) -> Bool {
        version == .number(8) || version == .number(9)
    }
}

public enum ExternalSignIn {
    public static func url(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              let scheme = parts.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())),
              let url = parts.url else { throw ClientError.invalidSignInURL }
        return url
    }
}

public enum MessageMentions {
    /// Appendix A.3: match the complete ID, never a known user's prefix.
    public static func userIDs(in text: String, version: Double = 9) -> Set<String> {
        let pattern = version == 8
            ? #"(?<![\p{L}\p{N}])@([A-Za-z0-9_.-]*[A-Za-z0-9_])"#
            : #"(?<![\p{L}\p{N}])@([A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        return Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }
}

/// A room-list cooldown is independent of message delivery and history requests.
public struct RoomListingLimited: Error, LocalizedError, Sendable {
    public let retryAt: Date
    public var errorDescription: String? {
        let seconds = max(1, ceil(retryAt.timeIntervalSinceNow))
        return "The server paused room and member refreshes. Try again in \(seconds.formatted(.number.precision(.fractionLength(0)))) seconds."
    }
}
