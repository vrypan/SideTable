import Foundation
import Testing
import ApronCore
@testable import Sidetable

@MainActor @Test func transcriptFollowsLiveArrivalsOnlyWhileReadingLatest() {
    let state = ConversationTranscriptState()
    state.setWindowActive(true)
    state.positionedLatest = true
    state.atBottom = true
    state.receiveArrivals(total: 10, loadingHistory: false, searching: false)
    #expect(state.scrollRequest == nil)
    state.receiveArrivals(total: 11, loadingHistory: false, searching: false)
    #expect(state.scrollRequest != nil && state.arrivals.unread == 0)
    let request = state.scrollRequest
    state.beginHistory(messages: [["message_id": .string("100")]])
    state.receiveArrivals(total: 12, loadingHistory: true, searching: false)
    #expect(state.scrollRequest == request && state.arrivals.unread == 1)
    #expect(state.historyAnchor == "100")
    state.requestLatest()
    #expect(state.historyAnchor == nil && state.scrollRequest != request)
    // A requested scroll is not proof that the viewport reached the end.
    #expect(state.arrivals.unread == 1 && !state.atBottom)
    state.clearArrivals()
    #expect(state.arrivals.unread == 0)
    state.setWindowActive(false)
    state.atBottom = true
    let latestRequest = state.scrollRequest
    state.receiveArrivals(total: 13, loadingHistory: false, searching: false)
    #expect(state.arrivals.unread == 1 && state.scrollRequest == latestRequest)
}

@MainActor @Test func transcriptKeepsUnreadDividerUntilUserNavigationReachesLatest() {
    let state = ConversationTranscriptState()
    state.captureUnreadBoundary(readMarker: "100", messages: [], unreadCount: 1)
    state.reachedLatest("200", eligible: true)
    #expect(state.unreadBoundary?.readThrough == 100)
    state.userScrolled()
    state.reachedLatest("200", eligible: false)
    #expect(state.unreadBoundary?.readThrough == 100)
    state.reachedLatest("200", eligible: true)
    #expect(state.unreadBoundary?.readThrough == 200)
    state.setWindowActive(true)
    state.reachedLatest("300", eligible: true)
    #expect(state.unreadBoundary?.readThrough == 200)
    state.requestLatest()
    state.reachedLatest("300", eligible: true)
    #expect(state.unreadBoundary?.readThrough == 300)
}

@MainActor @Test func revealingTranscriptHistoryPreservesAnchorAndLinkedMessagesCancelLatestScroll() {
    let state = ConversationTranscriptState()
    let messages: [JSONObject] = (1...400).map { ["message_id": .string(String($0))] }
    #expect(state.revealEarlier(messages: messages) == "371")
    #expect(state.visibleCount == 180 && !state.atBottom)
    state.scrollPosition = "275"
    #expect(state.revealEarlier(messages: messages) == "275")
    state.beginHistory(messages: messages)
    #expect(state.historyAnchor == "275")
    state.requestLatest()
    state.revealLinkedMessage(messageCount: 600)
    #expect(state.visibleCount == 600 && state.scrollRequest == nil && !state.atBottom)
    state.changeRoom()
    #expect(state.visibleCount == 30 && state.scrollPosition == nil && state.historyAnchor == nil)
    #expect(!state.positionedLatest && !state.userNavigated)
}

@MainActor @Test func completingAnOldEditDoesNotCloseTheCurrentEditor() throws {
    let state = ConversationComposerState(preview: true)
    state.beginEditing(["message_id": .string("100")], previews: [], account: "ada")
    let old = try #require(state.editingMessage)
    state.beginEditing(["message_id": .string("200")], previews: [], account: "ada")
    state.finishEditing(old.id)
    #expect(state.editingMessage?.message.string("message_id") == "200")
    #expect(!state.restoreFocus)
    state.finishEditing(try #require(state.editingMessage).id)
    #expect(state.editingMessage == nil && state.restoreFocus)
    state.changeRoom()
    #expect(!state.restoreFocus)
}

@MainActor @Test func composerPreviewRequestsRespectCommandsExclusionsAndConversationIdentity() {
    let state = ConversationComposerState(preview: true)
    let key = DraftKey(server: UUID(), account: "ada", room: "general")
    var draft = SavedDraft(text: "https://first.example/ https://second.example/")
    draft.excludedPreviewURLs = ["https://first.example/"]
    let request = state.linkRequest(draft: draft, key: key, commands: true)
    #expect(request.key == key)
    #expect(request.links.map(\.id) == ["https://second.example/"])
    draft.text = "/topic https://second.example/"
    #expect(state.linkRequest(draft: draft, key: key, commands: true).links.isEmpty)
    #expect(state.linkRequest(draft: draft, key: key, commands: false).links.count == 1)
    state.beginEditing(["message_id": .string("100")], previews: [], account: "ada")
    state.cancelEditing()
    #expect(state.linkRequest(draft: draft, key: key, commands: false).links.count == 1)
}

@MainActor @Test func delayedDropCannotStageFilesOrErrorsIntoAnotherAccount() async throws {
    let server = ServerModel(ServerProfile(address: "wss://example.com/", accountID: "ada"))
    let state = ConversationComposerState(preview: true)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
    try Data("attachment".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = StagedFile(url: url)
    await state.stageDrop(server: server, room: "general", category: "upload") {
        await Task.yield()
        server.profile.accountID = "ben"
        return [file]
    }.value
    #expect(server.files.isEmpty && server.error == nil)
    await state.stageDrop(server: server, room: "general", category: "upload") {
        await Task.yield()
        server.profile.accountID = "ada"
        throw ClientError.disconnected
    }.value
    #expect(server.files.isEmpty && server.error == nil)
    await state.stageDrop(server: server, room: "general", category: "upload") {
        await Task.yield()
        return [file]
    }.value
    #expect(server.files["general"]?.map(\.id) == [file.id])
}

@MainActor @Test func restoringRecentPositionsDoesNotExpandTheWholeHistory() {
    let state = ConversationTranscriptState()
    let messages: [JSONObject] = (0..<600).map { ["message_id": .string(String($0))] }
    state.revealSavedMessage("599", messages: messages)
    #expect(state.visibleCount == 30)
    state.revealSavedMessage("300", messages: messages)
    #expect(state.visibleCount == 300)
    state.revealSavedMessage("missing", messages: messages)
    #expect(state.visibleCount == 300)
    state.revealSavedMessage("0", messages: messages)
    #expect(state.visibleCount == 600)
}

@MainActor @Test func roomShortcutsFollowSidebarOrderAndWrap() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    server.snapshot.store.installRoom(["room_id": .string("private"), "title": .string("A private room"), "private": .bool(true)])
    server.snapshot.store.joined.insert("private")
    model.selectRoom("design", server: server)
    #expect(model.adjacentRoom(forward: false) == "private")
    model.selectAdjacentRoom(forward: true)
    #expect(model.activePanel?.room == "development")
    model.selectAdjacentRoom(forward: true)
    #expect(model.activePanel?.room == "general")
    model.selectRoom("release", server: server, asThread: true)
    model.selectAdjacentRoom(forward: true)
    #expect(model.activePanel?.room == "private")
    #expect(model.activePanel?.isThread == false)
    model.selectAdjacentRoom(forward: true)
    #expect(model.activePanel?.room == "design")
    server.snapshot.store.joined = ["general"]
    #expect(model.adjacentRoom(forward: true) == "general")
    model.selectAdjacentRoom(forward: true)
    #expect(model.adjacentRoom(forward: true) == nil)
    server.snapshot.store.joined = []
    #expect(model.adjacentRoom(forward: false) == nil)
}

@MainActor @Test func threadShortcutsStayInActiveRoomAndWrap() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    server.snapshot.store.installRoom(["room_id": .string("new-thread"), "parent_room_id": .string("general"), "latest_log_id": .string("2000000000000")])
    server.snapshot.store.installRoom(["room_id": .string("other-thread"), "parent_room_id": .string("design")])
    model.selectRoom("general", server: server)
    #expect(model.adjacentThread(forward: true) == "new-thread")
    #expect(model.adjacentThread(forward: false) == "release")
    model.selectAdjacentThread(forward: true)
    #expect(model.activePanel?.room == "new-thread")
    #expect(model.activePanel?.isThread == true)
    #expect(server.selectedRoom == "general")
    model.selectAdjacentThread(forward: true)
    #expect(model.activePanel?.room == "release")
    model.selectAdjacentThread(forward: true)
    #expect(model.activePanel?.room == "new-thread")
    model.selectAdjacentThread(forward: false)
    #expect(model.activePanel?.room == "release")
    // Browsing a different server must not change which room's threads are navigated.
    let other = ServerModel(ServerProfile(address: "wss://other.example/"))
    model.servers.append(other)
    model.selectedServer = other.id
    model.selectAdjacentThread(forward: true)
    #expect(model.activePanel?.room == "new-thread")
    #expect(model.selectedServer == server.id)
    model.selectRoom("design", server: server)
    model.selectAdjacentThread(forward: true)
    #expect(model.activePanel?.room == "other-thread")
    #expect(model.adjacentThread(forward: true) == nil)
    model.selectRoom("development", server: server)
    #expect(model.adjacentThread(forward: false) == nil)
}

@MainActor @Test func threadShortcutsReachOlderThreadsWithoutRepeatingRevealedThreads() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    for index in 0..<7 {
        server.snapshot.store.installRoom(["room_id": .string("thread-\(index)"), "parent_room_id": .string("design"),
                                           "latest_log_id": .string(String(2000000000000 - index))])
    }
    model.selectRoom("design", server: server)
    for index in 0..<7 {
        model.selectAdjacentThread(forward: true)
        #expect(model.activePanel?.room == "thread-\(index)")
    }
    model.selectAdjacentThread(forward: true)
    #expect(model.activePanel?.room == "thread-0")
    model.selectAdjacentThread(forward: false)
    #expect(model.activePanel?.room == "thread-6")
}
