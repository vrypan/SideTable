import Foundation
import AppKit
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

@Test func arrivalCountsPreserveReadingPositionAndIgnoreUnchangedTotals() {
    var arrivals = ConversationArrivals()
    let scroll1 = arrivals.receive(total: 20, followingLatest: false)
    #expect(!scroll1) // Opening has no backlog badge.
    #expect(arrivals.unread == 0)
    let scroll2 = arrivals.receive(total: 23, followingLatest: false)
    #expect(!scroll2) // Coalesced arrivals.
    #expect(arrivals.label == "3 new messages")
    let scroll3 = arrivals.receive(total: 23, followingLatest: false)
    #expect(!scroll3) // History/edit/reaction.
    #expect(arrivals.unread == 3)
    arrivals.reachedLatest()
    #expect(arrivals.label == "Latest")
    let scroll4 = arrivals.receive(total: 24, followingLatest: true)
    #expect(scroll4)
    #expect(arrivals.unread == 0)
    let scroll5 = arrivals.receive(total: 25, followingLatest: false)
    #expect(!scroll5)
    #expect(arrivals.label == "1 new message")
    let scroll6 = arrivals.receive(total: 0, followingLatest: false)
    #expect(!scroll6) // Account reset.
    #expect(arrivals.unread == 0)
}

@Test func arrivalCountsAreIndependentForEachConversationPane() {
    var reading = ConversationArrivals(), following = ConversationArrivals()
    _ = reading.receive(total: 0, followingLatest: false)
    _ = following.receive(total: 0, followingLatest: true)
    let scroll7 = reading.receive(total: 2, followingLatest: false)
    #expect(!scroll7)
    let scroll8 = following.receive(total: 2, followingLatest: true)
    #expect(scroll8)
    following.reachedLatest()
    #expect(reading.unread == 2)
    #expect(following.unread == 0)
}

@MainActor @Test func acceptedSendRequestsScrollingButEmptyAndBlockedSendsDoNot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root))
    let server = sampleServer()
    #expect(!model.send(server: server, room: "general"))
    model.setDraft(SavedDraft(text: "   \n"), server: server, room: "general")
    #expect(!model.send(server: server, room: "general"))
    model.setDraft(SavedDraft(text: "Hello"), server: server, room: "general")
    server.snapshot.phase = .disconnected
    #expect(!model.send(server: server, room: "general"))
    #expect(server.pending.isEmpty)
    server.snapshot.phase = .ready
    #expect(model.send(server: server, room: "general"))
    #expect(server.pending.count == 1)
    #expect(model.draft(server, room: "general").text.isEmpty)
    model.incoming(sampleMessage("101"), server: server)
    #expect(server.liveMessageCounts["general"] == 1)
    #expect(server.liveMessageCounts["thread"] == nil)
}

@MainActor @Test func dockBadgeTracksAllServersAndClearsWithoutAWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    model.notificationsEnabled = false
    var badge: String?
    var authorizationRequests = 0
    let controller = DockBadgeController(model: model, setBadge: { badge = $0 }, authorizeBadge: {
        authorizationRequests += 1
        return true
    })
    #expect(badge == nil)
    let first = sampleServer(), second = sampleServer(account: "ben")
    first.unread = ["general": 2, "thread": 3]
    second.unread = ["general": 4]
    model.servers = [first, second]
    // Let the observer's MainActor task run after each mutation.
    try await Task.sleep(for: .milliseconds(20))
    #expect(badge == "9")
    #expect(authorizationRequests == 1)
    model.updateAttention(UUID(), server: first, room: "general", readingLatest: true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(badge == "7")
    model.incoming(sampleMessage("101"), server: second)
    try await Task.sleep(for: .milliseconds(20))
    #expect(badge == "8")
    model.servers.removeAll { $0.id == first.id }
    try await Task.sleep(for: .milliseconds(20))
    #expect(badge == "5")
    second.unread = [:]
    try await Task.sleep(for: .milliseconds(20))
    #expect(badge == nil)
    #expect(authorizationRequests == 1)
    withExtendedLifetime(controller) {}
}

@MainActor @Test func dockBadgeUsesLatestCountWhenPermissionFinishes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    let server = sampleServer()
    model.servers = [server]
    server.unread["general"] = 7
    var badge: String?
    var permission: CheckedContinuation<Bool, Never>?
    let controller = DockBadgeController(model: model, setBadge: { badge = $0 }, authorizeBadge: {
        await withCheckedContinuation { permission = $0 }
    })
    try await Task.sleep(for: .milliseconds(20))
    #expect(badge == "7")
    model.updateAttention(UUID(), server: server, room: "general", readingLatest: true)
    permission?.resume(returning: true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(badge == nil)
    withExtendedLifetime(controller) {}
}

@MainActor private final class FlippedTranscriptDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor @Test func latestTracksDocumentGrowthUntilUserScrollsAway() async throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let document = FlippedTranscriptDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
    scroll.documentView = document
    let probe = TranscriptScrollObserver.Probe(frame: .zero)
    document.addSubview(probe)
    defer { probe.stop() }
    var atEnd = false
    probe.changed = { atEnd = $0 }
    probe.update(UUID())
    try await Task.sleep(for: .milliseconds(30))
    #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 1)
    #expect(atEnd)
    document.setFrameSize(NSSize(width: 400, height: 1300))
    try await Task.sleep(for: .milliseconds(30))
    #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 1)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    document.setFrameSize(NSSize(width: 400, height: 1500))
    try await Task.sleep(for: .milliseconds(30))
    #expect(abs(scroll.documentVisibleRect.minY - 100) <= 1)
    #expect(!atEnd)
}


@Test func unreadDividerUsesReadCursorAndSkipsOwnMessagesAndTombstones() {
    var own = sampleMessage("110"); own["from"] = .object(["user_id": .string("ada")])
    var deleted = sampleMessage("120"); deleted["deleted"] = .bool(true)
    let messages = [sampleMessage("100"), own, deleted, sampleMessage("130"), sampleMessage("140")]
    let boundary = ConversationUnreadBoundary(readMarker: "100", messages: messages, unreadCount: 2)
    #expect(boundary.firstUnread(in: messages, account: "ada") == "130")
    // The captured boundary remains even after the live read marker advances.
    let reopened = ConversationUnreadBoundary(readMarker: "140", messages: messages, unreadCount: 0)
    #expect(reopened.firstUnread(in: messages, account: "ada") == nil)
    #expect(boundary.firstUnread(in: messages, account: "ada") == "130")
}

@Test func unreadDividerDoesNotTreatLoadedHistoryAsNewWithoutUnreadState() {
    let messages = [sampleMessage("100"), sampleMessage("200")]
    let boundary = ConversationUnreadBoundary(readMarker: nil, messages: messages, unreadCount: 0)
    #expect(boundary.firstUnread(in: messages, account: "ada") == nil)
    #expect(boundary.firstUnread(in: messages + [sampleMessage("300")], account: "ada") == "300")
    let unread = ConversationUnreadBoundary(readMarker: nil, messages: messages, unreadCount: 2)
    #expect(unread.firstUnread(in: messages, account: "ada") == "100")
}

@Test func unreadDividerUsesNumericOrderAndFollowsEarlierUnreadHistoryPages() {
    let boundary = ConversationUnreadBoundary(readMarker: "9", messages: [sampleMessage("20")], unreadCount: 1)
    #expect(boundary.firstUnread(in: [sampleMessage("20")], account: "ada") == "20")
    #expect(boundary.firstUnread(in: [sampleMessage("8"), sampleMessage("10"), sampleMessage("20")], account: "ada") == "10")
}

@Test func unreadDividerClearsAtLatestAndTracksSubsequentUnreadMessages() {
    let messages = [sampleMessage("100"), sampleMessage("200")]
    var boundary = ConversationUnreadBoundary(readMarker: "100", messages: messages, unreadCount: 1)
    #expect(boundary.firstUnread(in: messages, account: "ada") == "200")
    boundary.reachedLatest("200")
    #expect(boundary.firstUnread(in: messages, account: "ada") == nil)
    boundary.reachedLatest("100")
    boundary.reachedLatest(nil)
    #expect(boundary.firstUnread(in: messages, account: "ada") == nil)
    let arrivals = messages + [sampleMessage("300")]
    #expect(boundary.firstUnread(in: arrivals, account: "ada") == "300")
    boundary.reachedLatest("300")
    #expect(boundary.firstUnread(in: arrivals, account: "ada") == nil)
}
