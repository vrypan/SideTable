import Foundation
import Testing
import ApronCore
@testable import Sidetable

@MainActor private func sampleServer(account: String = "ada") -> ServerModel {
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: account))
    server.snapshot.phase = .ready
    server.snapshot.you = ["user_id": .string(account)]
    server.snapshot.store.joined = ["general"]
    server.snapshot.store.installRoom(["room_id": .string("general"), "title": .string("General")])
    server.snapshot.store.installMessage(sampleMessage("100"))
    return server
}
private func sampleMessage(_ id: String) -> JSONObject {
    ["message_id": .string(id), "log_id": .string(id), "room_id": .string("general"),
     "from": .object(["user_id": .string("other")]), "body": .object(["text": .string("Hello")])]
}

@MainActor @Test func attentionRegistrationsSurviveOtherWindowClosureAndStayAccountScoped() {
    let attention = ConversationAttention()
    let key = DraftKey(server: UUID(), account: "ada", room: "general")
    let first = UUID(), second = UUID()
    attention.update(first, key: key, readingLatest: true)
    attention.update(second, key: key, readingLatest: true)
    attention.remove(first)
    #expect(attention.contains(key))
    attention.update(second, key: key, readingLatest: false)
    #expect(!attention.contains(key))
    attention.update(second, key: key, readingLatest: true)
    #expect(!attention.contains(DraftKey(server: key.server, account: "ben", room: key.room)))
    #expect(!attention.contains(DraftKey(server: UUID(), account: key.account, room: key.room)))
    #expect(!attention.contains(DraftKey(server: key.server, account: key.account, room: "thread")))
    attention.remove(server: key.server)
    #expect(!attention.contains(key))
}

@MainActor @Test func onlyAttendedLatestConversationClearsUnreadAndAdvancesReadMarker() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root))
    model.notificationsEnabled = false
    let server = sampleServer()
    model.servers = [server]; model.selectedServer = server.id
    let key = DraftKey(server: server.id, account: server.account, room: "general")
    server.unread["general"] = 3
    model.selectRoom("general", server: server)
    #expect(server.unread["general"] == 3) // Navigation alone is not reading.
    model.markRead("100", server: server, room: "general")
    #expect(model.readMarkers[key] == nil)
    let first = UUID(), second = UUID()
    model.updateAttention(first, server: server, room: "general", readingLatest: false)
    model.incoming(sampleMessage("101"), server: server)
    #expect(server.unread["general"] == 4)
    server.snapshot.store.installMessage(sampleMessage("101"))
    model.updateAttention(first, server: server, room: "general", readingLatest: true)
    #expect(server.unread["general"] == 0 && model.readMarkers[key] == "101")
    model.updateAttention(second, server: server, room: "general", readingLatest: true)
    model.attention.remove(first)
    model.incoming(sampleMessage("102"), server: server)
    #expect(server.unread["general"] == 0)
    model.updateAttention(second, server: server, room: "general", readingLatest: false)
    model.incoming(sampleMessage("103"), server: server)
    #expect(server.unread["general"] == 1)
    #expect(model.readMarkers[key] == "101")
    server.cached = true
    model.updateAttention(second, server: server, room: "general", readingLatest: true)
    #expect(server.unread["general"] == 1)
    #expect(!model.attention.contains(key))
    server.cached = false; server.snapshot.phase = .reconnecting
    model.updateAttention(second, server: server, room: "general", readingLatest: true)
    #expect(!model.attention.contains(key))
}

@MainActor @Test func cacheUsageAndDeletionOnlyTouchConversationFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let first = UUID(), second = UUID(), linked = UUID()
    try storage.write(["message": "one"], to: "cache-\(first).json")
    try storage.write(["message": "two"], to: "cache-\(second).json")
    try storage.write(["draft": "keep"], to: "drafts-v1.json")
    try storage.write(["unknown": "keep"], to: "cache-unrecognized.json")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cache-\(linked).json"), withDestinationURL: root.appendingPathComponent("drafts-v1.json"))
    let usage = try storage.conversationCacheUsage()
    #expect(Set(usage.keys) == [first, second])
    #expect(usage[first] == Int64(try Data(contentsOf: root.appendingPathComponent("cache-\(first).json")).count))
    try storage.removeConversationCache(first)
    try storage.removeConversationCache(first) // Clearing an absent cache is harmless.
    #expect(Set(try storage.conversationCacheUsage().keys) == [second])
    #expect(storage.read("drafts-v1.json", as: [String: String].self) == ["draft": "keep"])
    #expect(storage.read("cache-unrecognized.json", as: [String: String].self) != nil)
}

@MainActor @Test func clearingSavedConversationsPreservesLiveStateAndPreventsRecreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let model = AppModel(storage: storage, cacheDelay: .milliseconds(20))
    let first = sampleServer(), second = sampleServer(account: "ben")
    model.servers = [first, second]
    let key = DraftKey(server: first.id, account: first.account, room: "general")
    model.drafts[key] = SavedDraft(text: "Keep my draft")
    model.readMarkers[key] = "100"; model.saveDrafts()
    model.writeConversationCaches()
    #expect(model.cacheUsage.count == 2 && model.conversationCacheBytes > 0)
    model.scheduleCache()
    model.clearSavedConversations(server: first.id)
    try await Task.sleep(for: .milliseconds(60))
    model.writeConversationCaches() // Later activity also cannot recreate cleared copies.
    #expect(Set(model.cacheUsage.keys) == [second.id])
    #expect(first.snapshot.store.messages["100"] != nil)
    #expect(first.profile.accountID == "ada" && first.snapshot.phase == .ready)
    #expect(model.readMarkers[key] == "100" && model.drafts[key]?.text == "Keep my draft")
    #expect(storage.read("drafts-v1.json", as: [DraftKey: SavedDraft].self)?[key]?.text == "Keep my draft")
    #expect(model.cacheError == nil)
    let orphan = UUID()
    try storage.write(["orphan": "cached"], to: "cache-\(orphan).json")
    second.cached = true
    model.clearSavedConversations()
    #expect(model.conversationCacheBytes == 0)
    #expect(second.snapshot.store.messages.isEmpty && !second.cached)
    #expect(first.snapshot.store.messages["100"] != nil)
    #expect(second.profile.accountID == "ben")
    model.writeConversationCaches()
    #expect(try storage.conversationCacheUsage().isEmpty)
    // Suppression is intentionally limited to this launch.
    let nextLaunch = AppModel(storage: storage)
    nextLaunch.servers = [first]; nextLaunch.writeConversationCaches()
    #expect(nextLaunch.conversationCacheBytes > 0)
}

@MainActor @Test func cacheInspectionFailureIsReportedWithoutChangingDrafts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not a directory".utf8).write(to: root)
    let model = AppModel(storage: LocalStorage(directory: root))
    let server = sampleServer()
    model.servers = [server]
    let key = DraftKey(server: server.id, account: server.account, room: "general")
    model.drafts[key] = SavedDraft(text: "Keep this")
    model.clearSavedConversations()
    #expect(model.cacheError != nil)
    #expect(model.drafts[key]?.text == "Keep this")
    #expect(server.snapshot.store.messages["100"] != nil)
}
