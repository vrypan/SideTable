import Foundation
import Testing
@testable import ApronCore

actor ScriptedTransport: ChatTransport {
    var queued: [WireFrame] = []
    var receiver: CheckedContinuation<WireFrame, any Error>?
    var closed = false
    var sent: [WireFrame] = []
    var pages: [JSONObject] = []
    var ignore = Set<String>()
    init(capabilities: [String] = [], pages: [JSONObject] = []) {
        self.pages = pages
        queued.append(WireFrame(method: "server", params: ["apron": .number(8), "auth": .array([.string("guest")]), "capabilities": .array(capabilities.map(JSONValue.string))]))
    }
    func send(_ frame: WireFrame) async throws {
        sent.append(frame)
        guard let id = frame.id, !ignore.contains(frame.method ?? "") else { return }
        let result: JSONObject
        switch frame.method {
        case "auth": result = ["you": .object(["user_id": .string("ada")])]
        case "room_list": result = ["joined": .array([.object(["room_id": .string("general"), "log_id": .string("100"), "latest_log_id": .string("200"), "history_log_id": .string("100")])])]
        case "history": result = pages.isEmpty ? ["latest_log_id": .string("200"), "history_log_id": .string("100"), "more": .bool(false)] : pages.removeFirst()
        default: result = [:]
        }
        push(WireFrame(id: id, result: result))
    }
    func receive() async throws -> WireFrame {
        if closed { throw ClientError.disconnected }
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() { closed = true; receiver?.resume(throwing: ClientError.disconnected); receiver = nil }
    func push(_ frame: WireFrame) {
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { queued.append(frame) }
    }
    func ignoreMethod(_ method: String) { ignore.insert(method) }
}

private func waitUntil(_ session: ApronSession, _ phase: ConnectionPhase) async throws {
    for _ in 0..<100 {
        if await session.snapshot().phase == phase { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ClientError.timeout
}

@Test func sessionAuthenticatesMinimalServerAndTimesOutRequests() async throws {
    let socket = ScriptedTransport()
    let session = ApronSession(transportFactory: { socket }, requestTimeout: .milliseconds(30))
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    #expect(await session.snapshot().phase == .ready)
    #expect(await session.snapshot().store.joined == [""])
    await socket.ignoreMethod("message")
    await #expect(throws: ClientError.self) { try await session.perform("message", params: ["body": .object(["text": .string("test")])]) }
    await session.stop()
}

@Test func sessionRecoversThroughCompactedBounds() async throws {
    let message: JSONObject = ["message_id": .string("150"), "log_id": .string("150"), "room_id": .string("general"), "from": .object(["user_id": .string("u")]), "body": .object(["text": .string("history")])]
    let pages: [JSONObject] = [
        ["latest_log_id": .string("200"), "history_log_id": .string("100"), "more": .bool(true), "first_log_id": .string("100"), "last_log_id": .string("175"), "messages": .array([.object(message)])],
        ["latest_log_id": .string("200"), "history_log_id": .string("100"), "more": .bool(true), "first_log_id": .string("100"), "last_log_id": .string("175"), "messages": .array([.object(message)])],
        ["latest_log_id": .string("200"), "history_log_id": .string("100"), "more": .bool(false), "first_log_id": .string("200"), "last_log_id": .string("200")]
    ]
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: pages)
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    #expect(await session.snapshot().store.messages["150"]?.object("body").string("text") == "history")
    let requests = await socket.sent.filter { $0.method == "history" }
    #expect(requests.last?.params?.string("after") == "176")
    #expect(requests.last?.params?.string("before") == "200")
    await session.stop()
}

@Test func stopCompletesPendingRequests() async throws {
    let socket = ScriptedTransport()
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await socket.ignoreMethod("message")
    let send = Task { try await session.perform("message", params: [:]) }
    try await Task.sleep(for: .milliseconds(10))
    await session.stop()
    await #expect(throws: ClientError.self) { try await send.value }
}

@Test func minimalServerLiveRoomDoesNotRequireRoomsCapability() async throws {
    let socket = ScriptedTransport()
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await socket.push(WireFrame(method: "message", params: ["message_id": .string("100"), "log_id": .string("100"), "room_id": .string("lobby"), "from": .object(["user_id": .string("u")])]))
    try await Task.sleep(for: .milliseconds(30))
    #expect(await session.snapshot().store.joined.contains("lobby"))
    await session.stop()
}
