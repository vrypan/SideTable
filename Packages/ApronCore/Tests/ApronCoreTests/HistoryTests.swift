import Foundation
import Testing
@testable import ApronCore

private func message(_ id: String, version: String? = nil, deleted: Bool = false) -> JSONObject {
    ["message_id": .string(id), "log_id": .string(version ?? id), "room_id": .string("general"),
     "from": .object(["user_id": .string("other")]), "body": .object(["text": .string("Message " + id)]), "deleted": .bool(deleted)]
}
private func page(_ first: String?, _ last: String?, head: String = "1000", lower: JSONValue = .string("1"), more: Bool, messages: [JSONObject] = []) -> JSONObject {
    var value: JSONObject = ["latest_log_id": .string(head), "history_log_id": lower, "more": .bool(more), "messages": .array(messages.map(JSONValue.object))]
    if let first { value["first_log_id"] = .string(first) }
    if let last { value["last_log_id"] = .string(last) }
    return value
}
private func ready(_ socket: ScriptedTransport) async throws -> ApronSession {
    let session = ApronSession(transportFactory: { socket })
    await session.start()
    try await until { await session.snapshot().phase == .signIn }
    try await session.authenticate(scheme: "guest", fields: [:])
    return session
}
private func until(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ClientError.timeout
}

@Test func backwardCursorUsesSliceBoundsAndRejectsNonProgressingPages() throws {
    let compacted = page("501", "900", more: true, messages: [message("850")])
    #expect(try BackwardHistoryPage(compacted).nextBefore == 500)
    #expect(try BackwardHistoryPage(page("401", "450", more: true), before: 500).nextBefore == 400)
    #expect(try BackwardHistoryPage(page(nil, nil, lower: .null, more: false)).nextBefore == nil)
    #expect(throws: ClientError.self) { try BackwardHistoryPage(compacted, before: 500) }
    #expect(throws: ClientError.self) { try BackwardHistoryPage(page(nil, nil, more: true)) }
    #expect(throws: ClientError.self) { try BackwardHistoryPage(page("1", "50", more: true)) }
    #expect(throws: ClientError.self) { try BackwardHistoryPage(page("500", "400", more: false)) }
}

@Test func startupLoadsOneRecentPageAndOlderHistoryUsesInclusiveSliceBoundary() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [
        page("501", "1000", more: true, messages: [message("900")]),
        page("301", "500", more: true), // Compacted slice with no message objects.
        page("1", "300", more: false, messages: [message("100")])
    ])
    let session = try await ready(socket)
    var historyRequests = await socket.sent.filter { $0.method == "history" }
    #expect(historyRequests.count == 1)
    #expect(historyRequests[0].params?["after"] == nil && historyRequests[0].params?["before"] == nil)
    #expect(await session.snapshot().roomHistory("general")?.before == 500)
    try await session.loadOlderHistory("general")
    #expect(await session.snapshot().roomHistory("general")?.before == 300)
    try await session.loadOlderHistory("general")
    #expect(await session.snapshot().roomHistory("general")?.hasOlder == false)
    #expect(await session.snapshot().store.timeline("general").count == 2)
    try await session.loadOlderHistory("general")
    historyRequests = await socket.sent.filter { $0.method == "history" }
    #expect(historyRequests.count == 3)
    #expect(historyRequests[1].params?.string("before") == "500")
    #expect(historyRequests[2].params?.string("before") == "300")
    #expect(historyRequests.allSatisfy { $0.params?["after"] == nil })
    await session.stop()
}

@Test func backwardPagesCannotResurrectDeletesOrAdvanceForwardCheckpoint() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [
        page("501", "1000", more: true, messages: [message("100", version: "900", deleted: true)]),
        page("1", "500", more: false, messages: [message("100")]),
        page("1001", "1100", head: "1100", more: false, messages: [message("1050")])
    ])
    let session = try await ready(socket)
    try await session.loadOlderHistory("general")
    #expect(await session.snapshot().store.messages["100"]?.bool("deleted") == true)
    try await session.loadRoom("general", trigger: .refresh)
    let recovery = await socket.sent.last { $0.method == "history" }
    #expect(recovery?.params?.string("after") == "1001")
    #expect(await session.snapshot().store.messages["1050"] != nil)
    await session.stop()
}

@Test func retentionDuringBackwardLoadRebuildsRecentWindow() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [
        page("501", "1000", more: true, messages: [message("600")]),
        page(nil, nil, head: "1200", lower: .string("1100"), more: false),
        page("1100", "1200", head: "1200", lower: .string("1100"), more: false, messages: [message("1150")])
    ])
    let session = try await ready(socket)
    try await session.loadOlderHistory("general")
    #expect(await session.snapshot().store.messages["600"] == nil)
    #expect(await session.snapshot().store.messages["1150"] != nil)
    #expect(await session.snapshot().roomHistory("general")?.hasOlder == false)
    let last = await socket.sent.last { $0.method == "history" }
    #expect(last?.params?["before"] == nil && last?.params?["after"] == nil)
    await session.stop()
}

@Test func duplicateOlderLoadsShareOperationAndFailureCanBeRetried() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true)])
    let session = try await ready(socket)
    await socket.ignoreMethod("history")
    let first = Task { try await session.loadOlderHistory("general") }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 2 }
    let second = Task { try await session.loadOlderHistory("general") }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await socket.sent.filter { $0.method == "history" }.count == 2)
    let request = try #require(await socket.sent.last)
    await socket.push(WireFrame(id: request.id, error: RPCError(code: -32002, message: "Please retry")))
    await #expect(throws: RPCError.self) { try await first.value }
    await #expect(throws: RPCError.self) { try await second.value }
    #expect(await session.snapshot().roomHistory("general")?.before == 500)
    #expect(await session.snapshot().roomHistory("general")?.error == "Please retry")
    #expect(await session.snapshot().roomHistory("general")?.isLoading == false)
    let retry = Task { try await session.loadOlderHistory("general") }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 3 }
    let retryRequest = try #require(await socket.sent.last)
    await socket.push(WireFrame(id: retryRequest.id, result: page("1", "500", more: false)))
    try await retry.value
    #expect(await session.snapshot().roomHistory("general")?.error == nil)
    #expect(await session.snapshot().roomHistory("general")?.hasOlder == false)
    await session.stop()
}

@Test func leavingRoomDuringOlderLoadRejectsLatePrivateHistory() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true)])
    let session = try await ready(socket)
    await socket.ignoreMethod("history")
    let load = Task { try await session.loadOlderHistory("general") }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 2 }
    let request = try #require(await socket.sent.last)
    await socket.push(WireFrame(method: "room_update", params: ["left": .array([.object(["room_id": .string("general")])])]))
    try await until { await session.snapshot().store.joined.isEmpty }
    await socket.push(WireFrame(id: request.id, result: page("1", "500", more: false, messages: [message("100")])))
    await #expect(throws: ClientError.self) { try await load.value }
    #expect(await session.snapshot().store.messages["100"] == nil)
    #expect(await session.snapshot().roomHistory("general") == nil)
    await session.stop()
}

@Test func defaultRoomHistoryUsesSharedCursorWithoutRoomCapability() async throws {
    let socket = ScriptedTransport(capabilities: ["history"], pages: [
        page("501", "1000", more: true, messages: [message("900")]),
        page("1", "500", more: false, messages: [message("100")])
    ])
    let session = try await ready(socket)
    #expect(await session.snapshot().roomHistory("general")?.before == 500)
    try await session.loadOlderHistory("general")
    #expect(await socket.sent.filter { $0.method == "history" }.allSatisfy { $0.params?["room_id"] == nil })
    #expect(await session.snapshot().store.timeline("general").count == 2)
    await session.stop()
}

@Test func disconnectedOlderRequestCannotInstallLateResults() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true)])
    let session = try await ready(socket)
    await socket.ignoreMethod("history")
    let load = Task { try await session.loadOlderHistory("general") }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 2 }
    let request = try #require(await socket.sent.last)
    let joined = Task { try await session.loadOlderHistory("general") }
    try await Task.sleep(for: .milliseconds(20))
    await session.stop()
    await socket.push(WireFrame(id: request.id, result: page("1", "500", more: false, messages: [message("100")])))
    await #expect(throws: ClientError.self) { try await load.value }
    await #expect(throws: ClientError.self) { try await joined.value }
    #expect(await session.snapshot().roomHistory("general")?.isLoading == false)
    #expect(await session.snapshot().roomHistory("general")?.before == 500)
    #expect(await session.snapshot().store.messages["100"] == nil)
}

@Test func failedRetentionRebuildRemainsRetryable() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true)])
    let session = try await ready(socket)
    await socket.ignoreMethod("history")
    let load = Task { try await session.loadOlderHistory("general") }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 2 }
    let request = try #require(await socket.sent.last)
    await socket.push(WireFrame(id: request.id, result: page(nil, nil, head: "1200", lower: .string("1100"), more: false)))
    try await until { await socket.sent.filter { $0.method == "history" }.count == 3 }
    let rebuild = try #require(await socket.sent.last)
    await socket.push(WireFrame(id: rebuild.id, error: RPCError(code: -32002, message: "Retry rebuild")))
    await #expect(throws: RPCError.self) { try await load.value }
    #expect(await session.snapshot().roomHistory("general")?.error == "Retry rebuild")
    #expect(await session.snapshot().roomHistory("general")?.hasOlder == true)
    let retry = Task { try await session.loadOlderHistory("general") }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 4 }
    let retryRequest = try #require(await socket.sent.last)
    #expect(retryRequest.params?["before"] == nil)
    await socket.push(WireFrame(id: retryRequest.id, result: page("1100", "1200", head: "1200", lower: .string("1100"), more: false, messages: [message("1150")])))
    try await retry.value
    #expect(await session.snapshot().store.messages["1150"] != nil)
    #expect(await session.snapshot().roomHistory("general")?.error == nil)
    await session.stop()
}

private actor HistoryTransports {
    var sockets: [ScriptedTransport]
    init(_ sockets: [ScriptedTransport]) { self.sockets = sockets }
    func next() -> ScriptedTransport { sockets.removeFirst() }
}

@Test func reconnectRecoversNewChangesAndPreservesBackwardCursor() async throws {
    let first = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true, messages: [message("900")])])
    let second = ScriptedTransport(capabilities: ["rooms", "history"], pages: [
        page("1001", "1100", head: "1200", more: true, messages: [message("900", version: "1050", deleted: true)]),
        page("1101", "1200", head: "1300", more: false),
        page("1", "500", head: "1300", more: false, messages: [message("100")])
    ])
    let sockets = HistoryTransports([first, second])
    let session = ApronSession(transportFactory: { await sockets.next() })
    await session.start(); try await until { await session.snapshot().phase == .signIn }
    try await session.authenticate(scheme: "guest", fields: [:])
    await session.reconnect(); try await until { await session.snapshot().phase == .ready }
    let requests = await second.sent.filter { $0.method == "history" }
    #expect(requests.count == 2)
    #expect(requests[0].params?.string("after") == "1001")
    #expect(requests[1].params?.string("after") == "1101")
    #expect(requests[1].params?.string("before") == "1200")
    #expect(await session.snapshot().store.messages["900"]?.bool("deleted") == true)
    #expect(await session.snapshot().roomHistory("general")?.before == 500)
    try await session.loadOlderHistory("general")
    #expect(await session.snapshot().store.messages["100"] != nil)
    await session.stop()
}

@Test func historyUsesPageBoundsAndPreservesLiveRoomDelivery() async throws {
    var recent = page("501", "1000", more: true)
    recent["rooms"] = .array([.object([
        "room_id": .string("general"), "log_id": .string("600"), "title": .string("Recent"),
        "latest_log_id": .string("700"), "history_log_id": .null, "member_count": .number(99)])])
    var older = page("1", "500", head: "1100", more: false)
    older["rooms"] = .array([.object([
        "room_id": .string("general"), "log_id": .string("200"), "title": .string("Old"),
        "latest_log_id": .string("300"), "history_log_id": .string("100"), "member_count": .number(1)])])
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [recent, older])
    let session = try await ready(socket)
    let initial = await session.snapshot()
    #expect(initial.store.rooms["general"]?.string("latest_log_id") == "1000")
    #expect(initial.store.rooms["general"]?.string("history_log_id") == "1")
    #expect(initial.store.rooms["general"]?["member_count"] == nil)
    await socket.push(WireFrame(method: "room_update", params: ["updated": .array([.object([
        "room_id": .string("general"), "log_id": .string("600"), "member_count": .number(12)])])]))
    try await until { await session.snapshot().store.rooms["general"]?["member_count"] == .number(12) }
    try await session.loadOlderHistory("general")
    let loaded = await session.snapshot()
    #expect(loaded.store.rooms["general"]?.string("title") == "Recent")
    #expect(loaded.store.rooms["general"]?.string("latest_log_id") == "1100")
    #expect(loaded.store.rooms["general"]?.string("history_log_id") == "1")
    #expect(loaded.store.rooms["general"]?["member_count"] == .number(12))
    #expect(loaded.roomHistory("general")?.hasOlder == false)
    await session.stop()
}

@Test func cancelledHistoryJoinerDoesNotCancelSharedRoomRecovery() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true)])
    let session = try await ready(socket)
    await socket.ignoreMethod("history")
    let original = Task { try await session.loadRoom("general", trigger: .refresh) }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 2 }
    let cancelled = Task { try await session.loadRoom("general", trigger: .refresh) }
    let joined = Task { try await session.loadRoom("general", trigger: .refresh) }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await socket.sent.filter { $0.method == "history" }.count == 2)
    let request = try #require(await socket.sent.last { $0.method == "history" })
    await socket.push(WireFrame(id: request.id, result: page("1001", "1100", head: "1100", more: false, messages: [message("1050")])))
    try await original.value
    try await joined.value
    #expect(await session.snapshot().store.messages["1050"] != nil)
    #expect(await socket.sent.filter { $0.method == "history" }.count == 2)
    await session.stop()
}

@Test func olderLoadWaitsForRoomRecoveryThenLoadsBackwardPage() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true)])
    let session = try await ready(socket)
    await socket.ignoreMethod("history")
    let recovery = Task { try await session.loadRoom("general", trigger: .refresh) }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 2 }
    let older = Task { try await session.loadOlderHistory("general") }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await socket.sent.filter { $0.method == "history" }.count == 2)
    let request = try #require(await socket.sent.last { $0.method == "history" })
    await socket.push(WireFrame(id: request.id, result: page("1001", "1100", head: "1100", more: false)))
    try await recovery.value
    try await until { await socket.sent.filter { $0.method == "history" }.count == 3 }
    let backward = try #require(await socket.sent.last { $0.method == "history" })
    #expect(backward.params?.string("before") == "500")
    await socket.push(WireFrame(id: backward.id, result: page("1", "500", head: "1100", more: false, messages: [message("100")])))
    try await older.value
    #expect(await session.snapshot().store.messages["100"] != nil)
    await session.stop()
}

@Test func disconnectReleasesOriginalAndJoinedHistoryLoads() async throws {
    let socket = ScriptedTransport(capabilities: ["rooms", "history"], pages: [page("501", "1000", more: true)])
    let session = try await ready(socket)
    await socket.ignoreMethod("history")
    let original = Task { try await session.loadRoom("general", trigger: .refresh) }
    try await until { await socket.sent.filter { $0.method == "history" }.count == 2 }
    let joined = Task { try await session.loadRoom("general", trigger: .refresh) }
    let older = Task { try await session.loadOlderHistory("general") }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await socket.sent.filter { $0.method == "history" }.count == 2)
    await session.stop()
    await #expect(throws: ClientError.self) { try await original.value }
    await #expect(throws: ClientError.self) { try await joined.value }
    await #expect(throws: ClientError.self) { try await older.value }
    #expect(await session.snapshot().recoveringRooms.isEmpty)
    #expect(await session.snapshot().roomHistory("general")?.isLoading == false)
}
