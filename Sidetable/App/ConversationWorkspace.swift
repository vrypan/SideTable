import Foundation
import Observation
import ApronCore

/// Owns a single conversation, search, and persisted navigation state.
/// The legacy panel storage format is retained to migrate the last active conversation.
/// Server browsing and the displayed conversation remain independent. Networking and
/// link resolution stay with the caller, which supplies the current server list.
@MainActor @Observable
final class ConversationWorkspace {
    private(set) var panels: [ConversationPanel] = []
    private(set) var activePanelID: UUID?
    private(set) var selectedServer: UUID?
    private(set) var thread: String?
    var activePanel: ConversationPanel? { panels.first { $0.id == activePanelID } }
    private var fallbackFindText = ""
    private var fallbackShowFind = false
    var findText: String {
        get { activePanel?.findText ?? fallbackFindText }
        set { if let activePanel { activePanel.findText = newValue } else { fallbackFindText = newValue } }
    }
    var showFind: Bool {
        get { activePanel?.showFind ?? fallbackShowFind }
        set { if let activePanel { activePanel.showFind = newValue } else { fallbackShowFind = newValue } }
    }

    // These synchronous effects do not give the workspace access to AppModel or sessions.
    @ObservationIgnored var onServerSelectionChanged: (() -> Void)?
    @ObservationIgnored var onConversationNavigation: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored private let storage: LocalStorage
    @ObservationIgnored private let preview: Bool
    @ObservationIgnored private var navigationReady = false
    @ObservationIgnored private var hasOpenedPanels = false
    @ObservationIgnored private var pendingLocation: SavedLocation?
    @ObservationIgnored private var lastSavedLocation: SavedLocation?
    @ObservationIgnored private var lastSavedPanelLayout: SavedPanelLayout?
    @ObservationIgnored private var restoringPanelIDs: Set<UUID> = []

    init(storage: LocalStorage, preview: Bool = false) {
        self.storage = storage; self.preview = preview
    }

    /// Load legacy selection before cached rooms are installed; panel restoration follows.
    func restoreSelection(servers: [ServerModel]) {
        pendingLocation = storage.read("location-v1.json", as: SavedLocation.self)
        lastSavedLocation = pendingLocation
        selectedServer = servers.first { $0.id == pendingLocation?.server }?.id ?? servers.first?.id
        if selectedServer != pendingLocation?.server { pendingLocation = nil }
    }
    func finishRestoring() { navigationReady = true }

    func selectServer(_ id: UUID?, servers: [ServerModel]) {
        guard selectedServer != id else { return }
        updateSelectedServer(id)
        saveLocation(servers: servers)
    }
    private func updateSelectedServer(_ id: UUID?) {
        guard selectedServer != id else { return }
        selectedServer = id
        guard navigationReady else { return }
        onServerSelectionChanged?()
        pendingLocation = nil
        if panels.isEmpty { thread = nil; findText = "" }
    }
    /// Retains the legacy location API for thread and saved-location restoration.
    func setThread(_ room: String?, servers: [ServerModel]) {
        thread = room
        saveLocation(servers: servers)
    }
    func cancelLocationRestoration(server: UUID? = nil) {
        if server == nil || pendingLocation?.server == server { pendingLocation = nil }
    }
    func isRestoringLocation(server: UUID, room: String) -> Bool {
        pendingLocation?.server == server && pendingLocation?.room == room
    }
    func confirmRestoredRooms(in store: RecordStore, server: UUID) {
        for panel in panels where panel.serverID == server && store.rooms[panel.room] != nil {
            restoringPanelIDs.remove(panel.id)
        }
    }
    func removePanels(for server: ServerModel, servers: [ServerModel]) {
        for panel in panels.filter({ $0.serverID == server.id }) { closePanel(panel.id, servers: servers) }
        if panels.isEmpty { hasOpenedPanels = false }
    }

    func selectRoom(_ room: String, server: ServerModel, servers: [ServerModel], asThread: Bool = false, fromLink: Bool = false) {
        navigatePanel(room, server: server, servers: servers, isThread: asThread, fromLink: fromLink)
    }

    private func navigatePanel(_ room: String, server: ServerModel, servers: [ServerModel], isThread: Bool, fromLink: Bool = false) {
        if !fromLink { onConversationNavigation?() }
        pendingLocation = nil
        if let current = activePanel, current.serverID == server.id, current.account == server.account, current.room == room {
            focusPanel(current.id, servers: servers)
            return
        }
        let panel = ConversationPanel(id: activePanelID ?? UUID(), server: server, room: room, isThread: isThread)
        panels = [panel]
        restoringPanelIDs = []
        hasOpenedPanels = true
        focusPanel(panel.id, servers: servers)
    }

    func focusPanel(_ id: UUID, servers: [ServerModel]) {
        guard let panel = panels.first(where: { $0.id == id }),
              let server = servers.first(where: { $0.id == panel.serverID }), server.account == panel.account else { return }
        activePanelID = id
        updateSelectedServer(server.id)
        if panel.isThread {
            if let parent = server.snapshot.store.rooms[panel.room]?.string("parent_room_id") { server.selectedRoom = parent }
            thread = panel.room
        } else { server.selectedRoom = panel.room; thread = nil }
        saveLocation(servers: servers)
    }

    func closePanel(_ id: UUID, servers: [ServerModel]) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        panels.remove(at: index)
        restoringPanelIDs.remove(id)
        if activePanelID == id {
            activePanelID = nil; thread = nil
            if !panels.isEmpty { focusPanel(panels[min(index, panels.count - 1)].id, servers: servers) }
            else { saveLocation(servers: servers) }
        }
        savePanelLayout()
    }

    func closeThreadPanel(server: ServerModel, room: String, servers: [ServerModel]) {
        if let parent = server.snapshot.store.rooms[room]?.string("parent_room_id"), server.snapshot.store.rooms[parent] != nil {
            selectRoom(parent, server: server, servers: servers)
        } else if let panel = activePanel, panel.serverID == server.id, panel.room == room {
            closePanel(panel.id, servers: servers)
        }
    }

    func ensureInitialPanel(servers: [ServerModel]) {
        guard panels.isEmpty, !hasOpenedPanels, let server = servers.first(where: { $0.id == selectedServer }), let room = server.selectedRoom else { return }
        let restoredThread = thread
        let panel = ConversationPanel(server: server, room: room, isThread: false)
        panels = [panel]; activePanelID = panel.id; hasOpenedPanels = true
        if let restoredThread { navigatePanel(restoredThread, server: server, servers: servers, isThread: true) }
        savePanelLayout()
    }

    func reconcilePanels(for server: ServerModel, servers: [ServerModel]) {
        let removed = panels.filter {
            $0.serverID == server.id && ($0.account != server.account ||
                (server.snapshot.phase == .ready && !server.cached && !restoringPanelIDs.contains($0.id) && server.snapshot.store.rooms[$0.room] == nil))
        }.map(\.id)
        for id in removed { closePanel(id, servers: servers) }
        if !removed.isEmpty && panels.isEmpty {
            hasOpenedPanels = false
            if let room = server.selectedRoom, server.snapshot.store.rooms[room] == nil {
                server.selectedRoom = server.rooms.first?.string("room_id")
            }
        }
        ensureInitialPanel(servers: servers)
    }

    func restorePanelLayout(servers: [ServerModel]) {
        guard let saved = storage.read("panels-v1.json", as: SavedPanelLayout.self) else { return }
        pendingLocation = nil
        lastSavedPanelLayout = saved
        hasOpenedPanels = true // An explicitly empty workspace also restores as empty.
        var seen = Set<DraftKey>()
        var ids = Set<UUID>()
        panels = saved.panels.compactMap { item in
            guard let server = servers.first(where: { $0.id == item.server }), server.account == item.account,
                  seen.insert(DraftKey(server: item.server, account: item.account, room: item.room)).inserted,
                  ids.insert(item.id).inserted else { return nil }
            return ConversationPanel(id: item.id, server: server, room: item.room, isThread: item.isThread)
        }
        // Migrate a former multi-panel workspace to its last active conversation.
        if let selected = panels.first(where: { $0.id == saved.activePanel }) ?? panels.first { panels = [selected] }
        restoringPanelIDs = Set(panels.map(\.id))
        activePanelID = panels.first(where: { $0.id == saved.activePanel })?.id ?? panels.first?.id
        for panel in panels {
            if let server = servers.first(where: { $0.id == panel.serverID }), server.selectedRoom == nil, !panel.isThread {
                server.selectedRoom = panel.room
            }
        }
        if let activePanel { focusPanel(activePanel.id, servers: servers) }
        if let browsed = saved.selectedServer, servers.contains(where: { $0.id == browsed }) { selectedServer = browsed }
    }

    /// Restored panels wait for their own room load, since a ready snapshot may
    /// precede discovery of unjoined threads. The server's answer then decides.
    func settleRestoredPanels(_ room: String, server: ServerModel, exists: Bool, servers: [ServerModel]) {
        let settled = panels.filter { $0.serverID == server.id && $0.room == room && restoringPanelIDs.contains($0.id) }.map(\.id)
        restoringPanelIDs.subtract(settled)
        guard !exists, !settled.isEmpty else { return }
        for id in settled { closePanel(id, servers: servers) }
        if panels.isEmpty { hasOpenedPanels = false; ensureInitialPanel(servers: servers) }
    }

    func savePanelLayout() {
        guard navigationReady, !preview, pendingLocation == nil, hasOpenedPanels else { return }
        let saved = SavedPanelLayout(panels: panels.map {
            SavedPanelLayout.Panel(id: $0.id, server: $0.serverID, account: $0.account, room: $0.room, isThread: $0.isThread)
        }, activePanel: activePanelID, selectedServer: selectedServer)
        guard saved != lastSavedPanelLayout else { return }
        do {
            try storage.write(saved, to: "panels-v1.json")
            lastSavedPanelLayout = saved
        } catch { onError?("Could not save your conversation: \(error.localizedDescription)") }
    }

    func saveLocation(servers: [ServerModel]) {
        savePanelLayout()
        guard navigationReady, !preview, pendingLocation == nil else { return }
        if let activePanel, activePanel.serverID != selectedServer { return }
        let location: SavedLocation?
        if let server = servers.first(where: { $0.id == selectedServer }), let room = server.selectedRoom,
           let account = server.snapshot.you.string("user_id") ?? server.profile.accountID {
            location = SavedLocation(server: server.id, account: account, room: room, thread: thread)
        } else { location = nil }
        guard location != lastSavedLocation else { return }
        do {
            try storage.write(location, to: "location-v1.json")
            lastSavedLocation = location
        }
        catch { onError?("Could not save your last conversation: \(error.localizedDescription)") }
    }

    func restoreLocation(server: ServerModel, servers: [ServerModel], finishedListing: Bool = false) {
        guard let saved = pendingLocation, saved.server == server.id,
              selectedServer == server.id, server.snapshot.phase == .ready else { return }
        guard saved.account == server.account,
              server.snapshot.store.joined.contains(saved.room),
              server.snapshot.store.rooms[saved.room] != nil else {
            pendingLocation = nil; saveLocation(servers: servers); return
        }
        server.selectedRoom = saved.room
        // Unjoined public threads are discovered when their parent is opened.
        // Wait for that listing before deciding whether a saved thread still exists.
        if let id = saved.thread, server.snapshot.store.rooms[id] == nil, !finishedListing { return }
        pendingLocation = nil
        if let id = saved.thread, server.snapshot.store.rooms[id]?.string("parent_room_id") == saved.room {
            thread = id
        } else { thread = nil }
        if let thread {
            if panels.isEmpty { ensureInitialPanel(servers: servers) }
            else { navigatePanel(thread, server: server, servers: servers, isThread: true, fromLink: true) }
        }
        saveLocation(servers: servers)
    }

}
