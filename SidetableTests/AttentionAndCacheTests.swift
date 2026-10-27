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
    await model.writeConversationCaches()
    #expect(model.cacheUsage.count == 2 && model.conversationCacheBytes > 0)
    model.scheduleCache()
    model.clearSavedConversations(server: first.id)
    try await Task.sleep(for: .milliseconds(60))
    await model.writeConversationCaches() // Later activity also cannot recreate cleared copies.
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
    await model.writeConversationCaches()
    #expect(try storage.conversationCacheUsage().isEmpty)
    // Suppression is intentionally limited to this launch.
    let nextLaunch = AppModel(storage: storage)
    nextLaunch.servers = [first]; await nextLaunch.writeConversationCaches()
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

@MainActor private final class CountingTranscriptClip: NSClipView {
    var scrollWrites = 0
    override func scroll(to newOrigin: NSPoint) {
        scrollWrites += 1
        super.scroll(to: newOrigin)
    }
}

@MainActor @Test func latestDoesNotRewriteAnUnchangedScrollPosition() async throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let clip = CountingTranscriptClip(frame: scroll.bounds)
    scroll.contentView = clip
    let document = FlippedTranscriptDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
    scroll.documentView = document
    let probe = TranscriptScrollObserver.Probe(frame: .zero)
    document.addSubview(probe)
    defer { probe.stop() }
    let request = UUID()
    probe.update(request)
    try await Task.sleep(for: .milliseconds(30))
    #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 1)
    clip.scrollWrites = 0
    for _ in 0..<5 {
        probe.update(request)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(clip.scrollWrites == 0)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    for y in [700.25, 640.5, 520.75] {
        clip.scroll(to: NSPoint(x: 0, y: y))
        let writes = clip.scrollWrites
        probe.update(request)
        try await Task.sleep(for: .milliseconds(10))
        #expect(abs(clip.bounds.origin.y - y) < 0.01)
        #expect(clip.scrollWrites == writes)
    }
}

@MainActor @Test func readingPositionObservationDoesNotMoveTheTranscript() async throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let document = FlippedTranscriptDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
    scroll.documentView = document
    for index in 0..<5 {
        let anchor = TranscriptMessageAnchor.Anchor(frame: NSRect(x: 0, y: index * 200, width: 400, height: 200))
        anchor.messageID = String(index)
        document.addSubview(anchor)
    }
    let probe = TranscriptScrollObserver.Probe(frame: .zero)
    document.addSubview(probe)
    defer { probe.stop() }
    var position: String?
    probe.positionChanged = { position = $0 }
    probe.update(nil)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
    try await Task.sleep(for: .milliseconds(220))
    #expect(position == "1")
    #expect(scroll.contentView.bounds.origin.y == 250)
    probe.update(UUID())
    try await Task.sleep(for: .milliseconds(220))
    #expect(position == "bottom")
    #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 1)
    // Simulate the SwiftUI redraw triggered by saving the observed position.
    probe.update(nil)
    try await Task.sleep(for: .milliseconds(220))
    #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 1)
}

@MainActor @Test func settlingLayoutKeepsAnEndPositionAtTheEnd() async throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let document = FlippedTranscriptDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
    scroll.documentView = document
    let probe = TranscriptScrollObserver.Probe(frame: .zero)
    document.addSubview(probe)
    defer { probe.stop() }
    probe.update(nil)
    // The user scrolls to the end; lazy rows then shrink the document (AppKit
    // clamps the offset) and regrow it as the scroll settles.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
    document.setFrameSize(NSSize(width: 400, height: 760))
    scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(scroll.contentView.bounds).origin)
    document.setFrameSize(NSSize(width: 400, height: 1150))
    #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 1)
    // Away from the end, layout changes leave the reading position alone.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
    document.setFrameSize(NSSize(width: 400, height: 1300))
    try await Task.sleep(for: .milliseconds(30))
    #expect(scroll.contentView.bounds.origin.y == 300)
}

@MainActor @Test func onlyUserScrollingReportsNavigation() async throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let document = FlippedTranscriptDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
    scroll.documentView = document
    let probe = TranscriptScrollObserver.Probe(frame: .zero)
    document.addSubview(probe)
    defer { probe.stop() }
    var scrolled = 0
    probe.userScrolled = { scrolled += 1 }
    probe.update(UUID()) // A programmatic jump to Latest is not user navigation.
    try await Task.sleep(for: .milliseconds(30))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    #expect(scrolled == 0)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    #expect(scrolled == 1)
}

@MainActor @Test func attachmentRenderCacheIsScopedAndClearable() {
    let cache = AttachmentRenderCache()
    let url = URL(string: "https://media.example/cat.png")!
    let server = UUID()
    let key = AttachmentRenderCache.key(url, server: server, account: "ada")
    cache.store(image: NSImage(size: NSSize(width: 40, height: 30)), key)
    cache.store(metadata: ["title": .string("Cat")], key)
    #expect(cache.image(key)?.size == NSSize(width: 40, height: 30))
    #expect(cache.metadata(key)?.string("title") == "Cat")
    #expect(cache.image(AttachmentRenderCache.key(url, server: server, account: "ben")) == nil)
    #expect(cache.image(AttachmentRenderCache.key(url, server: UUID(), account: "ada")) == nil)
    cache.clear()
    #expect(cache.image(key) == nil && cache.metadata(key) == nil)
}

private actor HistoryTransport: ChatTransport {
    var frames = [WireFrame(method: "server", params: ["apron": .number(9), "auth": .array([.string("guest")]), "capabilities": .array([.string("rooms"), .string("history")])])]
    var receiver: CheckedContinuation<WireFrame, any Error>?
    func send(_ frame: WireFrame) async throws {
        guard let id = frame.id else { return }
        let result: JSONObject
        switch frame.method {
        case "auth": result = ["you": .object(["user_id": .string("ada")])]
        case "room_list": result = ["joined": .array([.object(["room_id": .string("general"), "log_id": .string("1")])])]
        case "history": result = ["latest_log_id": .string("102"), "history_log_id": .string("1"), "more": .bool(false),
                                  "first_log_id": .string("100"), "last_log_id": .string("102"),
                                  "messages": .array(["100", "101", "102"].map { .object(sampleMessage($0)) })]
        default: result = [:]
        }
        let response = WireFrame(id: id, result: result)
        if let receiver { self.receiver = nil; receiver.resume(returning: response) } else { frames.append(response) }
    }
    func receive() async throws -> WireFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { receiver?.resume(throwing: ClientError.disconnected); receiver = nil }
}

@MainActor @Test func savedHistorySeedsTheNextLaunchAndClearsWithSavedConversations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let profile = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([profile], to: "servers-v1.json")
    let session = ApronSession(transportFactory: { HistoryTransport() })
    await session.start()
    for _ in 0..<200 where await session.snapshot().phase != .signIn { try await Task.sleep(for: .milliseconds(5)) }
    try await session.authenticate(scheme: "guest", fields: [:])
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = model.servers[0]
    server.session = session; server.snapshot = await session.snapshot()
    await model.writeConversationCaches()
    await session.stop()
    let saved = try #require(storage.read("cache-\(profile.id).json", as: CachedView.self))
    #expect(saved.messages.isEmpty)
    #expect(saved.history?.streams["general"]?.checkpoint == 102)
    #expect(saved.history?.messages.count == 3)
    let relaunch = AppModel(storage: storage, connectOnLaunch: false)
    let restored = relaunch.servers[0]
    #expect(restored.cached && restored.snapshot.store.timeline("general").count == 3)
    #expect(restored.historySeed?.account == "ada")
    relaunch.clearSavedConversations(server: restored.id)
    #expect(restored.historySeed == nil)
}
