import Foundation

public protocol ChatTransport: Sendable {
    func send(_ frame: WireFrame) async throws
    func receive() async throws -> WireFrame
    func close() async
}

public actor WebSocketTransport: ChatTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1_048_576
        socket.resume()
    }
    public func send(_ frame: WireFrame) async throws {
        let data = try encoder.encode(frame)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    public func receive() async throws -> WireFrame {
        let data: Data
        switch try await socket.receive() {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw ClientError.disconnected
        }
        return try decoder.decode(WireFrame.self, from: data)
    }
    public func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

public struct RecoveryCursor: Sendable {
    public var head: UInt64?
    public var next: UInt64?
    public var lowerBound: UInt64 = 0
    public init(checkpoint: UInt64? = nil) { next = checkpoint.map { $0 + 1 } }

    /// Returns true when retention invalidates the state already held for this room.
    public mutating func inspect(_ page: JSONObject) throws -> Bool {
        guard let latest = page.logID("latest_log_id"), page["history_log_id"] != nil else { throw ClientError.invalidHistory }
        let bound: UInt64
        if page["history_log_id"] == .null { bound = latest + 1 }
        else if let value = page.logID("history_log_id") { bound = value }
        else { throw ClientError.invalidHistory }
        lowerBound = max(lowerBound, bound)
        if head == nil { head = latest }
        let reset = next.map { lowerBound > $0 } ?? false
        if next == nil || reset { next = lowerBound }
        if reset { head = latest }
        return reset
    }
    public mutating func advance(_ page: JSONObject) throws -> Bool {
        if !page.bool("more") { return false }
        guard let last = page.logID("last_log_id"), let first = page.logID("first_log_id"),
              first <= last, last >= (next ?? 0), last <= (head ?? UInt64.max) else { throw ClientError.invalidHistory }
        next = last + 1
        return next! <= head!
    }
    public var params: JSONObject {
        var value: JSONObject = ["limit": .number(200)]
        if let head { value["before"] = .string(String(head)) }
        if let next { value["after"] = .string(String(next)) }
        return value
    }
}
