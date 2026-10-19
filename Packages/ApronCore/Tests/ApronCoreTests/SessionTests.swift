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
    var holdClose = false
    var closing = false
    private var closeContinuation: CheckedContinuation<Void, Never>?
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
    func close() async {
        closed = true; receiver?.resume(throwing: ClientError.disconnected); receiver = nil
        closing = true
        if holdClose { await withCheckedContinuation { closeContinuation = $0 } }
    }
    func pauseClose() { holdClose = true }
    func finishClose() { holdClose = false; closeContinuation?.resume(); closeContinuation = nil }
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

@Test func repeatedAvatarURLPatchesEmitRefreshEvents() async throws {
    let socket = ScriptedTransport()
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    let source = "https://cdn.example/avatar.png"
    let patch = WireFrame(method: "user", params: ["new": .object([
        "user_id": .string("ada"), "avatar": .string(source)
    ])])
    await socket.push(patch); await socket.push(patch)
    try await Task.sleep(for: .milliseconds(30))
    await session.stop()
    var refreshes: [String] = []
    for await event in session.events {
        if case .avatarChanged(let value) = event { refreshes.append(value) }
        if case .snapshot(let snapshot) = event, snapshot.phase == .disconnected { break }
    }
    #expect(refreshes == [source, source])
}

private actor TransportSequence {
    var sockets: [ScriptedTransport]
    var count = 0
    init(_ sockets: [ScriptedTransport]) { self.sockets = sockets }
    func next() -> ScriptedTransport {
        count += 1
        return sockets.isEmpty ? ScriptedTransport() : sockets.removeFirst()
    }
}

private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ClientError.timeout
}

@Test func oldSocketShutdownCannotOverwriteNewConnectionOrReplaySend() async throws {
    let first = ScriptedTransport(), second = ScriptedTransport()
    await first.pauseClose()
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await first.ignoreMethod("message")
    let send = Task { try await session.perform("message", params: [:], id: "uncertain-send") }
    try await eventually { await first.sent.contains { $0.id == "uncertain-send" } }
    let stop = Task { await session.stop() }
    try await eventually { await first.closing }
    // Requests complete even while transport shutdown is still blocked.
    await #expect(throws: ClientError.self) { try await send.value }
    await session.start(); try await waitUntil(session, .ready)
    await first.finishClose(); await stop.value
    #expect(await session.snapshot().phase == .ready)
    #expect(await second.sent.allSatisfy { $0.method != "message" })
    _ = try await session.perform("me", params: [:]) // New transport remains installed.
    await session.stop()
}

@Test func unavailableConnectionsPauseAndResumeOnceWithoutRestartingStoppedSessions() async throws {
    let first = ScriptedTransport(), second = ScriptedTransport()
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.setConnectionAvailable(false)
    await session.start()
    #expect(await session.snapshot().phase == .suspended)
    #expect(await sockets.count == 0)
    await session.setConnectionAvailable(true)
    await session.setConnectionAvailable(true)
    try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await session.setConnectionAvailable(false)
    #expect(await session.snapshot().phase == .suspended)
    #expect(await first.closed)
    await session.setConnectionAvailable(true)
    try await waitUntil(session, .ready)
    #expect(await sockets.count == 2)
    await session.stop()
    await session.setConnectionAvailable(false); await session.setConnectionAvailable(true)
    #expect(await session.snapshot().phase == .disconnected)
    #expect(await sockets.count == 2)
}

@Test func interruptedAutomaticAuthenticationDoesNotChangeStoppedState() async throws {
    let first = ScriptedTransport(), second = ScriptedTransport()
    await second.ignoreMethod("auth")
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await session.reconnect()
    try await eventually { await second.sent.contains { $0.method == "auth" } }
    await session.stop()
    // Drain the failed automatic sign-in continuation before checking the phase.
    try await Task.sleep(for: .milliseconds(20))
    #expect(await session.snapshot().phase == .disconnected)
    #expect(await session.snapshot().error == nil)
}

@Test func deniedConnectionsStayStoppedAndManualReconnectHonorsRetryDelay() async throws {
    let first = ScriptedTransport(), second = ScriptedTransport()
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    await first.push(WireFrame(error: RPCError(code: -32001, message: "Try later",
        data: .object(["retry_after": .number(0.2)]))))
    try await waitUntil(session, .disconnected)
    await session.setConnectionAvailable(false); await session.setConnectionAvailable(true)
    #expect(await sockets.count == 1)
    await session.reconnect()
    #expect(await session.snapshot().phase == .reconnecting)
    #expect(await sockets.count == 1)
    try await waitUntil(session, .signIn)
    #expect(await sockets.count == 2)
    await session.stop()
}

@Test func concurrentSignInDoesNotReplaceInFlightAuthentication() async throws {
    let socket = ScriptedTransport()
    await socket.ignoreMethod("auth")
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    let first = Task { try await session.authenticate(scheme: "guest", fields: [:]) }
    try await eventually { await socket.sent.contains { $0.method == "auth" } }
    await #expect(throws: ClientError.self) { try await session.authenticate(scheme: "guest", fields: [:]) }
    #expect(await socket.sent.filter { $0.method == "auth" }.count == 1)
    await session.stop()
    await #expect(throws: ClientError.self) { try await first.value }
}
