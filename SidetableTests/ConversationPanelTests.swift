import Foundation
import AppKit
import Testing
import ApronCore
@testable import Sidetable

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

@MainActor @Test func threadsUseOrdinaryPanelsAndClosingOnePreservesOthers() throws {
    let model = AppModel(preview: true)
    let server = try #require(model.current)
    model.ensureInitialPanel()
    let parent = try #require(model.activePanel)
    model.selectRoom("release", server: server, asThread: true)
    let thread = try #require(model.activePanel)
    #expect(thread.isThread && model.panels.count == 2 && model.thread == "release")
    #expect(server.selectedRoom == "general")
    model.selectRoom("release", server: server, asThread: true)
    #expect(model.panels.count == 2)
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

@MainActor @Test func panelDividerAutosaveUsesTheConversationSplit() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
    split.isVertical = true
    let left = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))
    split.addArrangedSubview(left)
    split.addArrangedSubview(NSView(frame: left.frame))
    let probe = PanelVisibilityReader.Probe(frame: left.bounds)
    let name = "test-panels-" + UUID().uuidString
    probe.layoutName = name
    left.addSubview(probe)
    window.contentView = split
    probe.refresh()
    try await Task.sleep(for: .milliseconds(30))
    #expect(split.autosaveName == name)
    probe.stop()
    split.autosaveName = nil
}
