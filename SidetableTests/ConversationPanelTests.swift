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

@MainActor @Test func normalNavigationReplacesOnlyActivePanelAndOpenExistingFocusesIt() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.ensureInitialPanel()
    let first = try #require(model.activePanel)
    first.findText = "kept"; first.showFind = true
    model.openInNewPanel("development", server: server)
    let second = try #require(model.activePanel)
    #expect(model.panels.count == 2 && second.id != first.id)
    model.selectRoom("design", server: server)
    #expect(model.panels.map(\.room) == ["general", "design"])
    #expect(model.activePanelID == second.id)
    model.openInNewPanel("general", server: server)
    #expect(model.panels.count == 2 && model.activePanelID == first.id)
    #expect(model.findText == "kept" && model.showFind)
    model.showFind = false
    #expect(!first.showFind && model.panels[1].findText.isEmpty)
}

@MainActor @Test func switchingSidebarServersPreservesPanelsAndPanelFocusFollowsServer() throws {
    let model = AppModel(preview: true)
    let firstServer = try #require(model.current)
    model.ensureInitialPanel()
    let first = try #require(model.activePanel)
    first.findText = "local search"
    let other = ServerModel(ServerProfile(address: "wss://other.example/", accountID: "other"))
    other.snapshot.phase = .ready
    other.snapshot.store.installRoom(["room_id": .string("general")])
    other.selectedRoom = "general"
    model.servers.append(other)
    model.selectedServer = other.id
    #expect(model.panels.count == 1 && model.activePanelID == first.id)
    #expect(first.findText == "local search")
    model.openInNewPanel("general", server: other)
    #expect(model.panels.count == 2 && model.activePanel?.serverID == other.id)
    model.focusPanel(first.id)
    #expect(model.selectedServer == firstServer.id && model.findText == "local search")
}

@MainActor @Test func panelsKeepDraftRepliesAndSearchSeparate() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.ensureInitialPanel()
    let first = try #require(model.activePanel)
    model.setDraft(SavedDraft(text: "First draft", replyTo: "100"), server: server, room: "general")
    model.openInNewPanel("development", server: server)
    model.setDraft(SavedDraft(text: "Second draft", replyTo: "200"), server: server, room: "development")
    model.findText = "second search"
    #expect(first.findText.isEmpty)
    model.focusPanel(first.id)
    #expect(model.draft(server, room: "general") == SavedDraft(text: "First draft", replyTo: "100"))
    #expect(model.draft(server, room: "development") == SavedDraft(text: "Second draft", replyTo: "200"))
}

@MainActor @Test func threadsReplaceTheActivePanelLikeRoomsAndOpenBesideOnRequest() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.ensureInitialPanel()
    let parent = try #require(model.activePanel)
    // A thread replaces the active panel's conversation, as a room does.
    model.selectRoom("release", server: server, asThread: true)
    let replaced = try #require(model.activePanel)
    #expect(replaced.isThread && replaced.id == parent.id && model.panels.count == 1 && model.thread == "release")
    #expect(server.selectedRoom == "general")
    model.selectRoom("general", server: server)
    #expect(model.panels.count == 1 && model.activePanel?.room == "general" && model.thread == nil)
    // Open in New Panel (or Command-click) keeps the parent beside the thread.
    model.openInNewPanel("release", server: server, isThread: true)
    let thread = try #require(model.activePanel)
    #expect(thread.isThread && model.panels.count == 2)
    model.focusPanel(parent.id)
    model.selectRoom("release", server: server, asThread: true)
    #expect(model.panels.count == 2 && model.activePanelID == thread.id) // An open thread is focused.
    model.closePanel(thread.id)
    #expect(model.activePanelID == parent.id && model.thread == nil)
    model.closePanel(parent.id)
    model.ensureInitialPanel()
    #expect(model.panels.isEmpty)
    model.selectRoom("design", server: server)
    #expect(model.panels.count == 1 && model.activePanel?.room == "design")
}

@MainActor @Test func unavailableRoomsAndAccountChangesRemoveTheirPanels() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.ensureInitialPanel()
    model.openInNewPanel("development", server: server)
    server.snapshot.store.rooms["development"] = nil
    model.reconcilePanels(for: server)
    #expect(model.panels.map(\.room) == ["general"])
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

@MainActor @Test func panelLayoutRestoresOrderFocusServersAndEmptyWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let a = ServerProfile(address: "wss://a.example/", accountID: "ada")
    let b = ServerProfile(address: "wss://b.example/", accountID: "ben")
    try storage.write([a, b], to: "servers-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let first = model.servers[0], second = model.servers[1]
    model.selectRoom("general", server: first)
    model.openInNewPanel("discussion", server: first, isThread: true)
    model.openInNewPanel("general", server: second)
    model.focusPanel(model.panels[1].id)
    model.selectedServer = second.id // Browsing the sidebar does not change the active panel.
    let restored = AppModel(storage: storage, connectOnLaunch: false)
    #expect(restored.panels.map(\.id) == model.panels.map(\.id))
    #expect(restored.panels.map(\.key) == model.panels.map(\.key))
    #expect(restored.activePanelID == model.activePanelID)
    #expect(restored.selectedServer == second.id)
    #expect(restored.panels[1].isThread)
    let originalIDs = restored.panels.map(\.id)
    // A ready snapshot may precede discovery of unjoined threads.
    restored.servers[0].snapshot.phase = .ready
    restored.reconcilePanels(for: restored.servers[0])
    #expect(restored.panels.map(\.id) == originalIDs)
    restored.closePanel(originalIDs[0]) // Closing a background panel must save immediately.
    let reopened = AppModel(storage: storage, connectOnLaunch: false)
    #expect(reopened.panels.map(\.id) == Array(originalIDs.dropFirst()))
    for id in reopened.panels.map(\.id) { reopened.closePanel(id) }
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

@MainActor @Test func lastPanelFillsLeftoverSpaceWithoutChangingSavedWidths() {
    #expect(ConversationPanel.displayedWidths([], viewport: 900).isEmpty)
    #expect(ConversationPanel.displayedWidths([430], viewport: 1200) == [1200])
    #expect(ConversationPanel.displayedWidths([430, 500], viewport: 1200) == [430, 770])
    // Wider than the window: every panel keeps its own width and the row scrolls.
    #expect(ConversationPanel.displayedWidths([430, 600, 430], viewport: 1200) == [430, 600, 430])
}

@MainActor @Test func panelWidthsPersistAndSurviveReplacingTheConversation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let profile = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([profile], to: "servers-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = model.servers[0]
    model.selectRoom("general", server: server)
    model.openInNewPanel("design", server: server)
    #expect(model.panels.map(\.width) == [ConversationPanel.defaultWidth, ConversationPanel.defaultWidth])
    model.panels[1].width = 620
    model.savePanelLayout()
    model.selectRoom("development", server: server) // Replaces the active (second) panel's conversation.
    #expect(model.panels[1].room == "development" && model.panels[1].width == 620)
    let restored = AppModel(storage: storage, connectOnLaunch: false)
    #expect(restored.panels.map(\.width) == [ConversationPanel.defaultWidth, 620])
    // Layouts saved before widths existed open at the default width.
    let legacy = SavedPanelLayout.Panel(id: UUID(), server: profile.id, account: "ada", room: "general", isThread: false)
    try storage.write(SavedPanelLayout(panels: [legacy], activePanel: legacy.id, selectedServer: profile.id), to: "panels-v1.json")
    #expect(AppModel(storage: storage, connectOnLaunch: false).panels.first?.width == ConversationPanel.defaultWidth)
}

@MainActor @Test func restoredPanelsForMissingRoomsCloseOnceTheServerAnswers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let profile = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([profile], to: "servers-v1.json")
    let thread = SavedPanelLayout.Panel(id: UUID(), server: profile.id, account: "ada", room: "deleted-thread", isThread: true)
    let live = SavedPanelLayout.Panel(id: UUID(), server: profile.id, account: "ada", room: "live-thread", isThread: true)
    try storage.write(SavedPanelLayout(panels: [thread, live], activePanel: thread.id, selectedServer: profile.id), to: "panels-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = model.servers[0]
    server.snapshot.phase = .ready
    // Before their rooms load, restored threads survive a ready snapshot.
    model.reconcilePanels(for: server)
    #expect(model.panels.map(\.id) == [thread.id, live.id])
    model.settleRestoredPanels("live-thread", server: server, exists: true)
    model.settleRestoredPanels("deleted-thread", server: server, exists: false)
    #expect(model.panels.map(\.id) == [live.id])
    #expect(model.activePanelID == live.id)
    #expect(storage.read("panels-v1.json", as: SavedPanelLayout.self)?.panels.map(\.id) == [live.id])
    // A settled panel is no longer exempt: losing its room closes it as usual.
    server.snapshot.store.rooms["general"] = ["room_id": .string("general")]
    model.reconcilePanels(for: server)
    #expect(!model.panels.contains { $0.id == live.id })
}

@MainActor @Test func draggedPanelLandsInTheSlotUnderThePointer() {
    let slots: [CGFloat] = [437, 437, 637]
    #expect(ConversationPanel.dropIndex(widths: [], pointer: 100) == 0)
    #expect(ConversationPanel.dropIndex(widths: slots, pointer: -50) == 0)
    #expect(ConversationPanel.dropIndex(widths: slots, pointer: 436) == 0)
    #expect(ConversationPanel.dropIndex(widths: slots, pointer: 437) == 1)
    #expect(ConversationPanel.dropIndex(widths: slots, pointer: 1000) == 2)
    #expect(ConversationPanel.dropIndex(widths: slots, pointer: 5000) == 2)
    // Panels between the start and the drop slot shift by the dragged panel's slot.
    let dragged = (index: 0, drag: PanelDrag(id: UUID(), offset: 500, pointer: 700))
    #expect(ConversationPanelsView.offset(index: 1, dragged: dragged, target: 1, slots: slots) == -437)
    #expect(ConversationPanelsView.offset(index: 2, dragged: dragged, target: 1, slots: slots) == 0)
    #expect(ConversationPanelsView.offset(index: 0, dragged: dragged, target: 1, slots: slots) == 500)
}

@MainActor @Test func movingAPanelReordersAndSavesTheLayout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let profile = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([profile], to: "servers-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = model.servers[0]
    model.selectRoom("general", server: server)
    model.openInNewPanel("design", server: server)
    model.openInNewPanel("development", server: server)
    let ids = model.panels.map(\.id)
    model.movePanel(ids[2], to: 0)
    #expect(model.panels.map(\.id) == [ids[2], ids[0], ids[1]])
    model.movePanel(ids[2], to: 99)
    #expect(model.panels.map(\.id) == [ids[0], ids[1], ids[2]])
    model.movePanel(ids[0], to: 1)
    #expect(AppModel(storage: storage, connectOnLaunch: false).panels.map(\.id) == [ids[1], ids[0], ids[2]])
}

@MainActor @Test func panelWidthsFollowViewportWithoutLosingPreferredSizes() {
    let preferred: [CGFloat] = [900, 430]
    #expect(ConversationPanel.displayedWidths(preferred, viewport: 700, handleWidth: 14) == [686, 430])
    #expect(ConversationPanel.displayedWidths(preferred, viewport: 300, handleWidth: 14) == [286, 286])
    #expect(ConversationPanel.displayedWidths(preferred, viewport: 1400, handleWidth: 14) == [900, 472])
    #expect(ConversationPanel.displayedWidths([900], viewport: 700, handleWidth: 14) == [686])
    #expect(ConversationPanel.displayedWidths([430, 430], viewport: 1000, handleWidth: 14) == [430, 542])
    #expect(ConversationPanel.displayedWidths(preferred, viewport: 0, handleWidth: 14) == [0, 0])
}
