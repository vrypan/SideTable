import Foundation
import AppKit
import Observation
import os
import Testing
import ApronCore
@testable import Sidetable

@MainActor @Test func workspaceChangesInvalidateAppModelObservation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    model.servers = [server]
    let selectionChanged = OSAllocatedUnfairLock(initialState: false)
    let panelsChanged = OSAllocatedUnfairLock(initialState: false)
    let searchChanged = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
        _ = model.selectedServer
    } onChange: {
        selectionChanged.withLock { $0 = true }
    }
    withObservationTracking {
        _ = model.panels
    } onChange: {
        panelsChanged.withLock { $0 = true }
    }
    model.workspace.selectRoom("general", server: server, servers: model.servers)
    #expect(selectionChanged.withLock { $0 })
    #expect(panelsChanged.withLock { $0 })
    withObservationTracking {
        _ = model.findText
    } onChange: {
        searchChanged.withLock { $0 = true }
    }
    let panel = try #require(model.workspace.activePanel)
    panel.findText = "search"
    #expect(searchChanged.withLock { $0 })
    #expect(model.findText == "search")
}

@MainActor @Test func workspaceNavigationClearsLinkPresentationWithoutMovingBrowsedPanels() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    let first = ServerModel(ServerProfile(address: "wss://first.example/", accountID: "ada"))
    let second = ServerModel(ServerProfile(address: "wss://second.example/", accountID: "ben"))
    model.servers = [first, second]
    model.selectRoom("general", server: first)
    model.linkedMessage = AppModel.LinkMessage(server: first.id, room: "general", message: "100")
    model.linkedUser = "ada"
    model.selectRoom("design", server: first)
    #expect(model.linkedMessage == nil && model.linkedUser == "ada")
    let panel = try #require(model.activePanel)
    model.linkedMessage = AppModel.LinkMessage(server: first.id, room: "design", message: "200")
    model.selectedServer = second.id
    #expect(model.linkedMessage == nil && model.linkedUser == nil)
    #expect(model.activePanelID == panel.id && model.activePanel?.serverID == first.id)
    model.focusPanel(panel.id)
    #expect(model.selectedServer == first.id)
}

@MainActor @Test func roomNavigationAlwaysShowsOneConversation() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.ensureInitialPanel()
    for room in ["development", "design", "general", "general"] {
        model.selectRoom(room, server: server)
        #expect(model.panels.count == 1 && model.activePanel?.room == room)
    }
    model.findText = "kept"
    model.selectRoom("general", server: server)
    #expect(model.findText == "kept")
    model.selectRoom("development", server: server)
    #expect(model.findText.isEmpty)
}

@MainActor @Test func selectingAConversationOnAnotherServerReplacesTheCurrentConversation() throws {
    let model = AppModel(preview: true)
    let first = try #require(model.current)
    model.ensureInitialPanel()
    let other = ServerModel(ServerProfile(address: "wss://other.example/", accountID: "other"))
    model.servers.append(other)
    model.selectRoom("general", server: other)
    #expect(model.panels.count == 1 && model.activePanel?.serverID == other.id)
    #expect(model.selectedServer == other.id)
    model.selectRoom("general", server: first)
    #expect(model.panels.count == 1 && model.activePanel?.serverID == first.id)
}

@MainActor @Test func switchingConversationsPreservesDraftRepliesAndReadingPositions() async throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.selectRoom("general", server: server)
    model.setDraft(SavedDraft(text: "First draft", replyTo: "100"), server: server, room: "general")
    server.snapshot.store.installMessage(["message_id": .string("100"), "log_id": .string("100"), "room_id": .string("general"), "from": .object(["user_id": .string("ada")])])
    model.saveViewedMessage("100", server: server, room: "general")
    model.selectRoom("development", server: server)
    model.setDraft(SavedDraft(text: "Second draft", replyTo: "200"), server: server, room: "development")
    server.snapshot.store.installMessage(["message_id": .string("200"), "log_id": .string("200"), "room_id": .string("development"), "from": .object(["user_id": .string("ada")])])
    model.saveViewedMessage("200", server: server, room: "development")
    model.selectRoom("general", server: server)
    #expect(model.draft(server, room: "general") == SavedDraft(text: "First draft", replyTo: "100"))
    #expect(model.draft(server, room: "development") == SavedDraft(text: "Second draft", replyTo: "200"))
    #expect(model.viewedMessages[DraftKey(server: server.id, account: server.account, room: "general")] == "100")
    #expect(model.viewedMessages[DraftKey(server: server.id, account: server.account, room: "development")] == "200")
    #expect(await model.restoreViewedMessage(server: server, room: "general") == "100")
    #expect(await model.restoreViewedMessage(server: server, room: "development") == "200")
}

@MainActor @Test func threadsReplaceTheConversationAndReturnToTheirParent() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.selectRoom("release", server: server, asThread: true)
    #expect(model.panels.count == 1 && model.activePanel?.room == "release" && model.thread == "release")
    model.closeThreadPanel(server: server, room: "release")
    #expect(model.panels.count == 1 && model.activePanel?.room == "general" && model.thread == nil)
}

@MainActor @Test func unavailableRoomsAndAccountChangesRemoveTheirPanels() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.ensureInitialPanel()
    model.selectRoom("development", server: server)
    server.snapshot.store.rooms["development"] = nil
    model.reconcilePanels(for: server)
    #expect(model.panels.count <= 1 && model.panels.allSatisfy { server.snapshot.store.rooms[$0.room] != nil })
    let oldKey = try #require(model.activePanel).key
    server.snapshot.you = ["user_id": .string("different")]
    model.reconcilePanels(for: server)
    #expect(model.panels.allSatisfy { $0.account == "different" && $0.key != oldKey })
}

@MainActor @Test func horizontallyHiddenPanelsDoNotQualifyAsVisibleReaders() {
    let viewport = CGRect(x: 0, y: 0, width: 700, height: 600)
    #expect(ConversationPanel.isFullyVisible(frame: CGRect(x: 0, y: 0, width: 340, height: 600), viewport: viewport))
    #expect(!ConversationPanel.isFullyVisible(frame: CGRect(x: 680, y: 0, width: 340, height: 600), viewport: viewport))
    #expect(!ConversationPanel.isFullyVisible(frame: CGRect(x: -100, y: 0, width: 340, height: 600), viewport: viewport))
    #expect(!ConversationPanel.isFullyVisible(frame: .zero, viewport: viewport))
}

@MainActor @Test func nativePanelVisibilityTracksHorizontalClipping() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 300))
    let probe = PanelVisibilityReader.Probe(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
    var visible = false
    probe.changed = { visible = $0 }
    document.addSubview(probe)
    scroll.documentView = document
    window.contentView = scroll
    scroll.contentView.postsBoundsChangedNotifications = true
    probe.refresh()
    try await Task.sleep(for: .milliseconds(30))
    #expect(visible)
    scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
    try await Task.sleep(for: .milliseconds(30))
    #expect(!visible)
    scroll.contentView.scroll(to: NSPoint(x: 340, y: 0))
    try await Task.sleep(for: .milliseconds(30))
    #expect(!visible)
    scroll.contentView.scroll(to: .zero)
    try await Task.sleep(for: .milliseconds(30))
    #expect(visible)
    probe.stop()
}

@MainActor @Test func legacyMultiPanelLayoutRestoresOnlyTheActiveConversation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let a = ServerProfile(address: "wss://a.example/", accountID: "ada")
    let b = ServerProfile(address: "wss://b.example/", accountID: "ben")
    try storage.write([a, b], to: "servers-v1.json")
    let first = SavedPanelLayout.Panel(id: UUID(), server: a.id, account: "ada", room: "general", isThread: false)
    let active = SavedPanelLayout.Panel(id: UUID(), server: a.id, account: "ada", room: "discussion", isThread: true)
    let last = SavedPanelLayout.Panel(id: UUID(), server: b.id, account: "ben", room: "general", isThread: false)
    try storage.write(SavedPanelLayout(panels: [first, active, last], activePanel: active.id, selectedServer: a.id), to: "panels-v1.json")
    let restored = AppModel(storage: storage, connectOnLaunch: false)
    #expect(restored.panels.map(\.id) == [active.id])
    #expect(restored.activePanel?.isThread == true)
    restored.savePanelLayout()
    #expect(AppModel(storage: storage, connectOnLaunch: false).panels.map(\.id) == [active.id])
    restored.servers[0].snapshot.phase = .ready
    restored.reconcilePanels(for: restored.servers[0])
    #expect(restored.activePanelID == active.id)
    restored.closePanel(active.id)
    let empty = AppModel(storage: storage, connectOnLaunch: false)
    empty.servers[0].selectedRoom = "general"
    empty.ensureInitialPanel()
    #expect(empty.panels.isEmpty)
}

@MainActor @Test func panelRestorationRejectsOtherAccountsAndMissingServers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let server = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([server], to: "servers-v1.json")
    let good = SavedPanelLayout.Panel(id: UUID(), server: server.id, account: "ada", room: "general", isThread: false)
    let wrong = SavedPanelLayout.Panel(id: UUID(), server: server.id, account: "ben", room: "private", isThread: false)
    let removed = SavedPanelLayout.Panel(id: UUID(), server: UUID(), account: "ada", room: "general", isThread: false)
    try storage.write(SavedPanelLayout(panels: [wrong, good, good, removed], activePanel: wrong.id, selectedServer: removed.server), to: "panels-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    #expect(model.panels.map(\.id) == [good.id])
    #expect(model.activePanelID == good.id)
    model.servers[0].snapshot.you = ["user_id": .string("changed")]
    model.reconcilePanels(for: model.servers[0])
    #expect(model.panels.allSatisfy { $0.account == "changed" })
    #expect(storage.read("panels-v1.json", as: SavedPanelLayout.self)?.panels.allSatisfy { $0.account == "changed" } == true)
}





@MainActor @Test func restoredMissingConversationClosesOnceTheServerAnswers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let profile = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([profile], to: "servers-v1.json")
    let thread = SavedPanelLayout.Panel(id: UUID(), server: profile.id, account: "ada", room: "deleted-thread", isThread: true)
    try storage.write(SavedPanelLayout(panels: [thread], activePanel: thread.id, selectedServer: profile.id), to: "panels-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = model.servers[0]
    server.snapshot.phase = .ready
    model.reconcilePanels(for: server)
    #expect(model.activePanelID == thread.id)
    model.settleRestoredPanels("deleted-thread", server: server, exists: false)
    #expect(model.panels.isEmpty)
}
