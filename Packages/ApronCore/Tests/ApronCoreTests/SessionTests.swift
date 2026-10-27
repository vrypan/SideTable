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
    var authResults: [JSONObject] = []
    var listingError: RPCError?
    var holdClose = false
    var closing = false
    private var closeContinuation: CheckedContinuation<Void, Never>?
    init(capabilities: [String] = [], pages: [JSONObject] = [], version: Double = 9, auth: [String] = ["guest"], authResults: [JSONObject] = []) {
        self.authResults = authResults
        self.pages = pages
        queued.append(WireFrame(method: "server", params: ["apron": .number(version), "auth": .array(auth.map(JSONValue.string)), "capabilities": .array(capabilities.map(JSONValue.string))]))
    }
    func send(_ frame: WireFrame) async throws {
        sent.append(frame)
        guard let id = frame.id, !ignore.contains(frame.method ?? "") else { return }
        if frame.method == "room_list", let error = listingError {
            listingError = nil; push(WireFrame(id: id, error: error)); return
        }
        let result: JSONObject
        switch frame.method {
        case "auth": result = authResults.isEmpty ? ["you": .object(["user_id": .string("ada")])] : authResults.removeFirst()
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
    func failNextListing(after seconds: Double) {
        listingError = RPCError(code: -32002, message: "Room listing limited", data: .object(["retry_after": .number(seconds)]))
    }
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
        ["latest_log_id": .string("100"), "history_log_id": .string("100"), "more": .bool(false)],
        ["latest_log_id": .string("200"), "history_log_id": .string("100"), "more": .bool(true), "first_log_id": .string("101"), "last_log_id": .string("175"), "messages": .array([.object(message)])],
        ["latest_log_id": .string("250"), "history_log_id": .string("100"), "more": .bool(false), "first_log_id": .string("200"), "last_log_id": .string("200")]
    ]
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: pages)
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    try await session.loadRoom("general")
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

@Test(arguments: [8.0, 9.0]) func reviewedProtocolVersionsAuthenticate(version: Double) async throws {
    let socket = ScriptedTransport(version: version)
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    #expect(await session.snapshot().phase == .ready)
    await session.stop()
}

@Test(arguments: [7.0, 10.0, 9.5]) func unreviewedVersionsCloseWithoutAuthentication(version: Double) async throws {
    let socket = ScriptedTransport(version: version)
    let session = ApronSession(transportFactory: { socket })
    await session.start()
    try await eventually { await socket.closed }
    #expect(await session.snapshot().error == ClientError.unsupportedVersion.localizedDescription)
    #expect(await socket.sent.isEmpty)
    await session.stop()
}

@Test func externalCodeSignInAndTokenResume() async throws {
    let first = ScriptedTransport(auth: ["external", "token"], authResults: [
        ["url": .string("https://chat.example/login?p=opaque")],
        ["you": .object(["user_id": .string("ada@example.com")]), "token": .string("resume-token")]
    ])
    let second = ScriptedTransport(auth: ["external", "token"])
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    #expect(try await session.requestExternalSignIn().host == "chat.example")
    #expect(await session.snapshot().pendingSignIn == "external")
    #expect(await session.snapshot().you.isEmpty)
    let proposal = try #require(await first.sent.first)
    #expect(proposal.params?.string("scheme") == "external")
    #expect(proposal.params?["return_url"] == nil)
    #expect(proposal.params?["token"] == nil)
    try await session.authenticate(scheme: "external", fields: ["token": .string("123456")])
    #expect(await session.snapshot().phase == .ready)
    #expect(await session.snapshot().pendingSignIn == nil)
    #expect(await session.snapshot().you.string("user_id") == "ada@example.com")
    #expect(await first.sent.last?.params?.string("token") == "123456")
    await session.reconnect(); try await waitUntil(session, .ready)
    #expect(await second.sent.first?.params?.string("scheme") == "token")
    #expect(await second.sent.first?.params?.string("token") == "resume-token")
    await session.stop()
}

@Test func proposalsReplaceEachOtherAndDisconnectClearsCodeEntry() async throws {
    let socket = ScriptedTransport(auth: ["external", "email", "token"], authResults: [
        ["url": .string("https://chat.example/login")], [:],
        ["url": .string("javascript:alert(1)")]
    ])
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    _ = try await session.requestExternalSignIn()
    try await session.requestEmail("ada@example.com")
    #expect(await session.snapshot().pendingSignIn == "email")
    await #expect(throws: ClientError.self) { try await session.requestExternalSignIn() }
    #expect(await session.snapshot().pendingSignIn == nil)
    #expect(await session.snapshot().phase == .signIn)
    try await session.requestEmail("ada@example.com")
    await session.setConnectionAvailable(false)
    #expect(await session.snapshot().pendingSignIn == nil)
    #expect(await session.snapshot().phase == .suspended)
    await session.stop()
}

@Test(arguments: ["email", "external"])
func rejectedResumeTokenAllowsNewSignIn(scheme: String) async throws {
    let first = ScriptedTransport(auth: ["token"], authResults: [
        ["you": .object(["user_id": .string("ada")]), "token": .string("expired-token")]
    ])
    let second = ScriptedTransport(auth: ["token", scheme])
    await second.ignoreMethod("auth")
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "token", fields: ["token": .string("original-token")])
    await session.reconnect()
    try await eventually { await second.sent.count == 1 }
    let resume = try #require(await second.sent.last)
    await second.push(WireFrame(id: resume.id, error: RPCError(code: -32001, message: "Expired token")))
    try await waitUntil(session, .signIn)
    #expect(await session.snapshot().you.string("user_id") == "ada")
    let proposal = Task {
        if scheme == "email" { try await session.requestEmail("ada@example.com") }
        else { _ = try await session.requestExternalSignIn() }
    }
    try await eventually { await second.sent.count == 2 }
    let request = try #require(await second.sent.last)
    #expect(request.params?.string("scheme") == scheme)
    await second.push(WireFrame(id: request.id, result: ["url": .string("https://chat.example/login")]))
    try await proposal.value
    #expect(await session.snapshot().pendingSignIn == scheme)
    await session.stop()
}

@Test func failedAuthenticatedBootstrapReconnectsInsteadOfOfferingSignIn() async throws {
    let first = ScriptedTransport(capabilities: ["rooms"])
    await first.failNextListing(after: 0)
    let second = ScriptedTransport()
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    await #expect(throws: RoomListingLimited.self) { try await session.authenticate(scheme: "guest", fields: [:]) }
    #expect(await session.snapshot().phase == .reconnecting)
    #expect(await first.closed)
    await session.stop()
}

@Test func disconnectedProposalCannotOpenPageOrReplaceNewState() async throws {
    let first = ScriptedTransport(auth: ["external", "token"])
    await first.ignoreMethod("auth")
    let second = ScriptedTransport(auth: ["external", "token"])
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    let proposal = Task { try await session.requestExternalSignIn() }
    try await eventually { await first.sent.count == 1 }
    await #expect(throws: ClientError.self) { try await session.requestEmail("ada@example.com") }
    await session.reconnect()
    await #expect(throws: ClientError.self) { try await proposal.value }
    try await waitUntil(session, .signIn)
    #expect(await session.snapshot().pendingSignIn == nil)
    #expect(await second.sent.isEmpty)
    await session.stop()
}

@Test func failedCodeCanBeRetriedWithoutCreatingAnotherProposal() async throws {
    let socket = ScriptedTransport(auth: ["external", "token"], authResults: [["url": .string("https://chat.example/login")]])
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    _ = try await session.requestExternalSignIn()
    await socket.ignoreMethod("auth")
    let approval = Task { try await session.authenticate(scheme: "external", fields: ["token": .string("wrong")]) }
    try await eventually { await socket.sent.count == 2 }
    let request = try #require(await socket.sent.last)
    await socket.push(WireFrame(id: request.id, error: RPCError(code: -32001, message: "Invalid code")))
    await #expect(throws: RPCError.self) { try await approval.value }
    #expect(await session.snapshot().phase == .signIn)
    #expect(await session.snapshot().pendingSignIn == "external")
    let retry = Task { try await session.authenticate(scheme: "external", fields: ["token": .string("correct")]) }
    try await eventually { await socket.sent.count == 3 }
    let retried = try #require(await socket.sent.last)
    await socket.push(WireFrame(id: retried.id, result: ["you": .object(["user_id": .string("ada")]), "token": .string("resume")]))
    try await retry.value
    #expect(await session.snapshot().phase == .ready)
    #expect(await session.snapshot().pendingSignIn == nil)
    await session.stop()
}

@Test func externalSignInRequiresAdvertisedV9Scheme() async throws {
    for socket in [ScriptedTransport(version: 8, auth: ["external"]), ScriptedTransport(version: 9)] {
        let session = ApronSession(transportFactory: { socket })
        await session.start(); try await waitUntil(session, .signIn)
        await #expect(throws: ClientError.self) { try await session.requestExternalSignIn() }
        #expect(await socket.sent.isEmpty)
        await session.stop()
    }
}

@Test func reconnectReplacesTransientNoticesAndPreservesMessages() async throws {
    let first = ScriptedTransport(), second = ScriptedTransport()
    let sockets = TransportSequence([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    let welcome = WireFrame(method: "message", params: [
        "from": .object(["user_id": .string("~private")]),
        "body": .object(["text": .string("Welcome. Guests can read.")])
    ])
    await first.push(welcome)
    await first.push(WireFrame(method: "message", params: [
        "message_id": .string("100"), "log_id": .string("100"), "room_id": .string("general"),
        "from": .object(["user_id": .string("other")]), "body": .object(["text": .string("Keep this message")])
    ]))
    try await eventually { await session.snapshot().store.messages["100"] != nil }
    #expect(await session.snapshot().store.notices.count == 1)
    await session.reconnect(); try await waitUntil(session, .ready)
    #expect(await session.snapshot().store.notices.isEmpty)
    #expect(await session.snapshot().store.messages["100"] != nil)
    await second.push(welcome)
    try await eventually { await session.snapshot().store.notices.count == 1 }
    // Repeated command output on the same connection remains distinct.
    await second.push(welcome)
    try await eventually { await session.snapshot().store.notices.count == 2 }
    await session.stop()
}

@Test func threadRepliesLoadWithoutListingsAndRefreshOnReopen() async throws {
    let reply: JSONObject = ["message_id": .string("150"), "log_id": .string("150"), "room_id": .string("thread"),
                            "from": .object(["user_id": .string("other")]), "body": .object(["text": .string("First reply")])]
    var newer = reply
    newer["message_id"] = .string("250"); newer["log_id"] = .string("250")
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [
        ["latest_log_id": .string("100"), "history_log_id": .string("100"), "more": .bool(false)],
        ["latest_log_id": .string("200"), "history_log_id": .string("100"), "first_log_id": .string("100"), "last_log_id": .string("200"), "messages": .array([.object(reply)]), "more": .bool(false)],
        ["latest_log_id": .string("300"), "history_log_id": .string("100"), "first_log_id": .string("250"), "last_log_id": .string("250"), "messages": .array([.object(newer)]), "more": .bool(false)]
    ])
    let session = ApronSession(transportFactory: { socket }, requestTimeout: .milliseconds(50))
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await socket.push(WireFrame(method: "room_update", params: ["updated": .array([.object([
        "room_id": .string("thread"), "parent_room_id": .string("general"), "log_id": .string("100")
    ])])]))
    try await eventually { await session.snapshot().store.rooms["thread"] != nil }
    // Any extra room listing would time out, just as a rate-limited server can reject it.
    await socket.ignoreMethod("room_list")
    try await session.loadRoom("thread")
    #expect(await session.snapshot().store.timeline("thread").count == 1)
    try await session.loadRoom("thread")
    #expect(await session.snapshot().store.timeline("thread").count == 2)
    #expect(await session.snapshot().store.joined.contains("thread") == false)
    let sent = await socket.sent
    #expect(sent.filter { $0.method == "room_list" }.count == 1)
    #expect(sent.allSatisfy { $0.method != "room_join" })
    #expect(sent.last?.params?.string("after") == "201")
    await session.stop()
}

@Test func roomListCooldownBlocksRequestsButKeepsHistoryAvailableAndExpires() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"])
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await socket.failNextListing(after: 0.15)
    try await session.loadRoom("general")
    #expect(await session.snapshot().phase == .ready)
    #expect(await session.snapshot().roomListingRetryAt != nil)
    let listings = await socket.sent.filter { $0.method == "room_list" }.count
    let histories = await socket.sent.filter { $0.method == "history" }.count
    do {
        _ = try await session.perform("room_list", params: ["filter": .string("all")])
        Issue.record("Expected cooldown")
    } catch let error as RoomListingLimited {
        #expect(error.localizedDescription.contains("room and member"))
        #expect(error.localizedDescription.contains("seconds"))
    }
    try await session.loadRoom("general")
    #expect(await socket.sent.filter { $0.method == "room_list" }.count == listings)
    #expect(await socket.sent.filter { $0.method == "history" }.count > histories)
    try await Task.sleep(for: .milliseconds(180))
    _ = try await session.perform("room_list", params: ["filter": .string("all")])
    #expect(await socket.sent.filter { $0.method == "room_list" }.count == listings + 1)
    await session.stop()
}

@Test func identicalRoomListingsShareRequestAndRecentMetadataIsReused() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms"])
    let session = ApronSession(transportFactory: { socket })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await socket.ignoreMethod("room_list")
    let params: JSONObject = ["room_id": .string("general"), "members": .bool(true)]
    let first = Task { try await session.perform("room_list", params: params) }
    let second = Task { try await session.perform("room_list", params: params) }
    try await eventually { await socket.sent.filter { $0.method == "room_list" }.count == 2 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await socket.sent.filter { $0.method == "room_list" }.count == 2)
    let request = try #require(await socket.sent.last)
    let result: JSONObject = ["joined": .array([.object(["room_id": .string("general"), "log_id": .string("100"),
        "members": .array([.object(["user_id": .string("ada")])])])])]
    await socket.push(WireFrame(id: request.id, result: result))
    #expect(try await first.value == result)
    #expect(try await second.value == result)
    let load = Task { try await session.loadRoom("general") }
    try await eventually { await socket.sent.filter { $0.method == "room_list" }.count == 3 }
    let threads = try #require(await socket.sent.last)
    #expect(threads.params?.string("parent_room_id") == "general")
    await socket.push(WireFrame(id: threads.id, result: ["joined": .array([]), "not_joined": .array([])]))
    try await load.value
    try await session.loadRoom("general")
    #expect(await socket.sent.filter { $0.method == "room_list" }.count == 3)
    #expect(await session.snapshot().store.members["general"] == ["ada"])
    await session.stop()
}

@Test func listingCooldownSurvivesReconnectForSameAccount() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms"])
    let next = ScriptedTransport(capabilities: ["rooms"])
    let factory = TransportSequence([socket, next])
    let session = ApronSession(transportFactory: { await factory.next() })
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    await socket.failNextListing(after: 0.2)
    await #expect(throws: RoomListingLimited.self) { try await session.perform("room_list", params: [:]) }
    await session.reconnect()
    try await waitUntil(session, .recovering)
    #expect(await next.sent.allSatisfy { $0.method != "room_list" })
    try await waitUntil(session, .ready)
    #expect(await next.sent.filter { $0.method == "room_list" }.count == 1)
    await session.stop()
}

private func seedMessage(_ id: String, log: String? = nil, text: String) -> JSONObject {
    ["message_id": .string(id), "log_id": .string(log ?? id), "room_id": .string("general"),
     "from": .object(["user_id": .string("ben")]), "body": .object(["text": .string(text)])]
}

private func savedGeneral(account: String = "ada") -> HistorySeed {
    HistorySeed(account: account, streams: ["general": .init(checkpoint: 150, lowerBound: 100, before: 120)],
                rooms: [["room_id": .string("general"), "log_id": .string("100")]], joined: ["general"], users: [],
                messages: [seedMessage("120", text: "old"), seedMessage("150", text: "edit me")],
                reactions: [.init(message: "150", user: "ben", record: ["log_id": .string("150"), "from": .object(["user_id": .string("ben")]), "emojis": .array([.string("👍")]), "room_id": .string("general")])])
}

@Test func restoredHistoryBackfillsOnlyEntriesAfterItsCheckpoint() async throws {
    let gap: JSONObject = ["latest_log_id": .string("200"), "history_log_id": .string("100"), "more": .bool(false),
                           "first_log_id": .string("151"), "last_log_id": .string("180"),
                           "messages": .array([.object(seedMessage("150", log: "170", text: "edited")), .object(seedMessage("180", text: "new"))])]
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [gap])
    let session = ApronSession(transportFactory: { socket })
    await session.restore(savedGeneral())
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    let requests = await socket.sent.filter { $0.method == "history" }
    #expect(requests.count == 1)
    #expect(requests.first?.params?.string("after") == "151")
    let store = await session.snapshot().store
    #expect(store.messages["120"]?.object("body").string("text") == "old")
    #expect(store.messages["150"]?.object("body").string("text") == "edited")
    #expect(store.messages["180"] != nil)
    #expect(store.reactionSummary("150") == ["👍": ["ben"]])
    #expect(await session.snapshot().roomHistory("general")?.before == 120)
    // Saving again keeps the newest log positions and pages back to the rest.
    let trimmed = try #require(await session.exportHistory(maxMessages: 2))
    #expect(Set(trimmed.messages.compactMap { $0.string("message_id") }) == ["150", "180"])
    #expect(trimmed.streams["general"] == .init(checkpoint: 200, lowerBound: 100, before: 120))
    #expect(trimmed.reactions.map(\.message) == ["150"])
    let all = try #require(await session.exportHistory(maxMessages: 10))
    #expect(all.messages.count == 3 && all.streams["general"]?.before == 120)
    await session.stop()
}

@Test func restoredHistoryIsDiscardedForAnotherAccount() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], authResults: [["you": .object(["user_id": .string("ben")])]])
    let session = ApronSession(transportFactory: { socket })
    await session.restore(savedGeneral(account: "ada"))
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    #expect(await session.snapshot().store.messages.isEmpty)
    #expect(await socket.sent.filter { $0.method == "history" }.allSatisfy { $0.params?["after"] == nil })
    await session.stop()
}

@Test(arguments: [false, true])
func trimmedHistoryReloadsNewerReactionsAndRemovals(removed: Bool) async throws {
    let record: JSONObject = ["log_id": .string("400"), "room_id": .string("general"),
        "from": .object(["user_id": .string("ben")]), "emojis": .array(removed ? [] : [.string("👍")])]
    let seed = HistorySeed(account: "ada", streams: ["general": .init(checkpoint: 500, lowerBound: 100, before: nil)],
        rooms: [["room_id": .string("general")]], joined: ["general"], users: [],
        messages: [seedMessage("100", text: "older"), seedMessage("200", text: "newer")],
        reactions: [.init(message: "100", user: "ben", record: record)])
    let empty: JSONObject = ["latest_log_id": .string("500"), "history_log_id": .string("100"), "more": .bool(false)]
    let first = ScriptedTransport(capabilities: ["rooms", "history"], pages: [empty])
    let original = ApronSession(transportFactory: { first })
    await original.restore(seed); await original.start(); try await waitUntil(original, .signIn)
    try await original.authenticate(scheme: "guest", fields: [:])
    let trimmed = try #require(await original.exportHistory(maxMessages: 1))
    #expect(trimmed.messages.compactMap { $0.string("message_id") } == ["200"])
    #expect(trimmed.streams["general"]?.before == 400)
    await original.stop()

    func reaction(_ log: String, _ emojis: [JSONValue]) -> JSONValue {
        .object(["message_id": .string("100"), "log_id": .string(log), "room_id": .string("general"),
            "reactions": .array([.object(["from": .object(["user_id": .string("ben")]), "emojis": .array(emojis)])])])
    }
    let second = ScriptedTransport(capabilities: ["rooms", "history"], pages: [empty,
        ["latest_log_id": .string("500"), "history_log_id": .string("100"), "more": .bool(true),
         "first_log_id": .string("400"), "last_log_id": .string("400"),
         "reactions": .array([reaction("400", removed ? [] : [.string("👍")])])],
        ["latest_log_id": .string("500"), "history_log_id": .string("100"), "more": .bool(false),
         "first_log_id": .string("100"), "last_log_id": .string("300"),
         "messages": .array([.object(seedMessage("100", text: "older"))]),
         "reactions": .array([reaction("300", [.string("👎")])])]
    ])
    let restored = ApronSession(transportFactory: { second })
    await restored.restore(trimmed); await restored.start(); try await waitUntil(restored, .signIn)
    try await restored.authenticate(scheme: "guest", fields: [:])
    try await restored.loadOlderHistory("general")
    try await restored.loadOlderHistory("general")
    let requests = await second.sent.filter { $0.method == "history" }
    #expect(requests[0].params?.string("after") == "501")
    #expect(requests[1].params?.string("before") == "400")
    #expect(requests[2].params?.string("before") == "399")
    #expect(await restored.snapshot().store.messages["100"] != nil)
    #expect(await restored.snapshot().store.reactionSummary("100") == (removed ? [:] : ["👍": ["ben"]]))
    await restored.stop()
}

@Test func longRecoveryGapFallsBackToRecentHistory() async throws {
    let first: JSONObject = ["latest_log_id": .string("900"), "history_log_id": .string("100"), "more": .bool(true),
                             "first_log_id": .string("151"), "last_log_id": .string("350"),
                             "messages": .array([.object(seedMessage("300", text: "middle of the gap"))])]
    let recent: JSONObject = ["latest_log_id": .string("900"), "history_log_id": .string("100"), "more": .bool(true),
                              "first_log_id": .string("850"), "last_log_id": .string("900"),
                              "messages": .array([.object(seedMessage("900", text: "latest"))])]
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [first, recent])
    let session = ApronSession(transportFactory: { socket })
    await session.setRecoveryPageLimit(1)
    await session.restore(savedGeneral())
    await session.start(); try await waitUntil(session, .signIn)
    try await session.authenticate(scheme: "guest", fields: [:])
    let requests = await socket.sent.filter { $0.method == "history" }
    #expect(requests.count == 2)
    #expect(requests.last?.params?["after"] == nil)
    let snapshot = await session.snapshot()
    #expect(snapshot.store.messages.keys.sorted() == ["900"])
    #expect(snapshot.roomHistory("general")?.before == 849)
    await session.stop()
}
