import ApronCore
import AppKit
import Observation
import UserNotifications

@MainActor @Observable
final class AppModel {
    var servers: [ServerModel] = []
    let workspace: ConversationWorkspace
    var panels: [ConversationPanel] { workspace.panels }
    var activePanelID: UUID? { workspace.activePanelID }
    var showMembers = false {
        didSet { if showMembers != oldValue { saveMembersPanel() } }
    }
    static let membersWidthRange: ClosedRange<CGFloat> = 220...400
    static let defaultMembersWidth: CGFloat = 250
    /// The expanded members panel's width; its divider reports the end of a resize.
    var membersWidth = AppModel.defaultMembersWidth
    var panelDrag: PanelDrag? {
        get { workspace.panelDrag }
        set { workspace.panelDrag = newValue }
    }
    var showServerSignIn = false
    var activePanel: ConversationPanel? { workspace.activePanel }
    private var directMessageOperations: Set<UUID> = []
    var selectedServer: UUID? {
        get { workspace.selectedServer }
        set { workspace.selectServer(newValue, servers: servers) }
    }
    var showAddServer = false
    /// The Settings tab to show; menus set it before opening Settings.
    var settingsTab = ProcessInfo.processInfo.arguments.contains("--preview-servers") ? 2 : ProcessInfo.processInfo.arguments.contains("--preview-storage") ? 1 : 0
    var showOpenLink = false
    var openLinkText = ""
    var linkedUser: String?
    var linkedMessage: LinkMessage?
    struct LinkMessage: Equatable {
        let id = UUID()
        let server: UUID
        let room: String
        let message: String
    }
    @ObservationIgnored private var pendingLink: (server: UUID, link: ApronLink, tokenSent: Bool)?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    var showJump = false
    var findText: String {
        get { workspace.findText }
        set { workspace.findText = newValue }
    }
    var showFind: Bool {
        get { workspace.showFind }
        set { workspace.showFind = newValue }
    }
    var thread: String? {
        get { workspace.thread }
        set { workspace.setThread(newValue, servers: servers) }
    }
    var globalError: String?
    var preview = false
    var drafts: [DraftKey: SavedDraft] = [:]
    var readMarkers: [DraftKey: String] = [:]
    var viewedMessages: [DraftKey: String] = [:]
    let attention = ConversationAttention()
    let linkPreviews: LinkPreviewPreferences
    var cacheUsage: [UUID: Int64] = [:]
    var cacheError: String?
    var notificationsEnabled = false
    var messageSize = 14.0
    static let savedMessagesRange = 100...5000
    static let recoveryPagesRange = 1...50
    /// Messages saved per conversation for the next launch to continue from.
    var savedMessagesPerRoom = 500 {
        didSet {
            UserDefaults.standard.set(savedMessagesPerRoom, forKey: "savedMessagesPerRoom")
            savedCacheRevisions = [:]
            scheduleCache()
        }
    }
    /// Pages of new activity (up to 200 entries each) a launch fetches per conversation
    /// before replacing an outdated saved copy with recent messages.
    var recoveryPageLimit = 5 {
        didSet {
            UserDefaults.standard.set(recoveryPageLimit, forKey: "recoveryPageLimit")
            let limit = recoveryPageLimit
            for session in servers.compactMap(\.session) { Task { await session.setRecoveryPageLimit(limit) } }
        }
    }
    @ObservationIgnored let storage: LocalStorage
    @ObservationIgnored let credentials: any CredentialStore
    @ObservationIgnored private var connectionAvailable = true
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var seenNotifications: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let stateSaveDelay: Duration
    @ObservationIgnored private var savedDrafts: [DraftKey: SavedDraft] = [:]
    @ObservationIgnored private var savedReadMarkers: [DraftKey: String] = [:]
    @ObservationIgnored private var savedViewedMessages: [DraftKey: String] = [:]
    @ObservationIgnored private var cacheSuppressedServers: Set<UUID> = []
    @ObservationIgnored private var cacheGeneration = UUID()
    @ObservationIgnored private let cacheDelay: Duration
    @ObservationIgnored private let cacheInterval: Duration
    @ObservationIgnored private var lastCacheWrite: ContinuousClock.Instant?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var savedCacheRevisions: [UUID: UUID] = [:]
    @ObservationIgnored private var writingCaches = false

    init(storage: LocalStorage = LocalStorage(), preview: Bool = false, cacheDelay: Duration = .seconds(3), cacheInterval: Duration = .seconds(60),
         connectOnLaunch: Bool = true, stateSaveDelay: Duration = .milliseconds(250), credentials: (any CredentialStore)? = nil) {
        self.workspace = ConversationWorkspace(storage: storage, preview: preview)
        self.linkPreviews = LinkPreviewPreferences(storage: storage)
        self.storage = storage; self.preview = preview; self.cacheDelay = cacheDelay; self.cacheInterval = cacheInterval
        self.stateSaveDelay = stateSaveDelay
        if let credentials { self.credentials = credentials }
        else if preview || AppRuntime.isTesting { self.credentials = MemoryCredentialStore() }
        else { self.credentials = KeychainCredentialStore() }
        workspace.onServerSelectionChanged = { [weak self] in
            self?.pendingLink = nil; self?.linkTask?.cancel(); self?.linkedMessage = nil; self?.linkedUser = nil
        }
        workspace.onConversationNavigation = { [weak self] in
            self?.pendingLink = nil; self?.linkTask?.cancel(); self?.linkedMessage = nil
        }
        workspace.onError = { [weak self] in self?.globalError = $0 }
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        messageSize = UserDefaults.standard.object(forKey: "messageSize") as? Double ?? 14
        // Panels no longer use an autosaved split view; drop its per-arrangement keys.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView Subview Frames SideTable-panels-") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let saved = UserDefaults.standard.object(forKey: "savedMessagesPerRoom") as? Int {
            savedMessagesPerRoom = saved.clamped(to: Self.savedMessagesRange)
        }
        if let pages = UserDefaults.standard.object(forKey: "recoveryPageLimit") as? Int {
            recoveryPageLimit = pages.clamped(to: Self.recoveryPagesRange)
        }
        if preview { PreviewData.populate(self); return }
        if let saved = storage.read("members-panel-v1.json", as: SavedMembersPanel.self) {
            // Width first: setting `showMembers` saves both values.
            membersWidth = saved.width.map { CGFloat($0).clamped(to: Self.membersWidthRange) } ?? Self.defaultMembersWidth
            showMembers = saved.expanded
        }
        drafts = storage.read("drafts-v1.json", as: [DraftKey: SavedDraft].self) ?? [:]
        readMarkers = storage.read("read-markers-v1.json", as: [DraftKey: String].self) ?? [:]
        viewedMessages = storage.read("viewed-messages-v1.json", as: [DraftKey: String].self) ?? [:]
        savedDrafts = drafts; savedReadMarkers = readMarkers; savedViewedMessages = viewedMessages
        servers = (storage.read("servers-v1.json", as: [ServerProfile].self) ?? []).map(ServerModel.init)
        workspace.restoreSelection(servers: servers)
        for server in servers {
            restoreCache(server)
            if connectOnLaunch { connect(server) }
        }
        workspace.restorePanelLayout(servers: servers)
        workspace.finishRestoring()
        refreshCacheUsage()
    }
    var unreadMessageCount: Int { servers.reduce(0) { $0 + $1.unread.values.reduce(0, +) } }
    var current: ServerModel? { servers.first { $0.id == selectedServer } }
    func draft(_ server: ServerModel, room: String) -> SavedDraft { drafts[key(server, room)] ?? SavedDraft() }
    private func key(_ server: ServerModel, _ room: String) -> DraftKey { DraftKey(server: server.id, account: server.account, room: room) }
    func setDraft(_ value: SavedDraft, server: ServerModel, room: String) {
        var value = value
        value.excludedPreviewURLs.formIntersection(ComposerLinkDiscovery.shared.links(in: value.text).map(\.id))
        drafts[key(server, room)] = value
        scheduleStateSave()
        if !value.text.isEmpty, Date().timeIntervalSince(server.lastTyping[room] ?? .distantPast) >= 12 {
            server.lastTyping[room] = Date()
            Task { await server.session?.activity(room: room, fields: ["typing": .number(15)]) }
        }
    }
    func saveDrafts() {
        savePanelLayout()
        // Also used synchronously at shutdown: cancel the pending batch and flush
        // the latest in-memory values before the process exits.
        saveTask?.cancel(); saveTask = nil
        guard !preview else { return }
        do {
            if drafts != savedDrafts {
                try storage.write(drafts, to: "drafts-v1.json")
                savedDrafts = drafts
            }
            if readMarkers != savedReadMarkers {
                try storage.write(readMarkers, to: "read-markers-v1.json")
                savedReadMarkers = readMarkers
            }
            if viewedMessages != savedViewedMessages {
                try storage.write(viewedMessages, to: "viewed-messages-v1.json")
                savedViewedMessages = viewedMessages
            }
        } catch { globalError = "Local conversation state could not be saved: \(error.localizedDescription)" }
    }
    private func scheduleStateSave() {
        guard !preview, saveTask == nil else { return }
        // A fixed batching window, rather than a trailing debounce, ensures busy
        // conversations continue saving even while messages arrive continuously.
        let delay = stateSaveDelay
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.saveDrafts()
        }
    }
    func saveViewedMessage(_ message: String, server: ServerModel, room: String) {
        guard server.snapshot.store.messages[message]?.string("room_id") == room else { return }
        let key = key(server, room)
        guard viewedMessages[key] != message else { return }
        viewedMessages[key] = message
        scheduleStateSave()
    }
    func restoreViewedMessage(server: ServerModel, room: String) async -> String? {
        guard let saved = viewedMessages[key(server, room)] ?? readMarkers[key(server, room)] else { return nil }
        let account = server.account
        if let session = server.session {
            while server.snapshot.store.messages[saved] == nil,
                  server.snapshot.roomHistory(room)?.hasOlder == true {
                let before = server.snapshot.roomHistory(room)?.before
                do { try await session.loadOlderHistory(room) }
                catch { break }
                guard !Task.isCancelled, server.session === session, server.account == account else { return nil }
                server.snapshot = await session.snapshot()
                guard !Task.isCancelled, server.session === session, server.account == account else { return nil }
                if server.snapshot.roomHistory(room)?.before == before { break }
                // A deleted message may no longer exist: stop once history has
                // reached its ID, then use the nearest retained message.
                if let first = server.snapshot.store.timeline(room).first?.logID("message_id"),
                   first <= (UInt64(saved) ?? 0) { break }
            }
        }
        let timeline = server.snapshot.store.timeline(room)
        if timeline.contains(where: { $0.string("message_id") == saved }) { return saved }
        return timeline.first { ($0.logID("message_id") ?? 0) >= (UInt64(saved) ?? 0) }?.string("message_id")
            ?? timeline.last?.string("message_id")
    }
    func updateAttention(_ view: UUID, server: ServerModel, room: String, readingLatest: Bool) {
        let eligible = readingLatest && !server.cached && server.snapshot.phase == .ready
        attention.update(view, key: key(server, room), readingLatest: eligible)
        if eligible, let last = server.snapshot.store.timeline(room).last?.string("message_id") {
            // The native scroll position remains "bottom" while messages arrive.
            // Persist the actual message whenever an eligible reader follows it.
            saveViewedMessage(last, server: server, room: room)
            markRead(last, server: server, room: room)
        }
    }
    func markRead(_ message: String, server: ServerModel, room: String) {
        let key = key(server, room)
        guard !server.cached, server.snapshot.phase == .ready, attention.contains(key) else { return }
        server.unread[room] = 0
        if let old = readMarkers[key], (UInt64(old) ?? 0) >= (UInt64(message) ?? 0) { return }
        readMarkers[key] = message; scheduleStateSave()
        let settings = server.snapshot.server.object("ext").object("settings")
        if server.snapshot.supports("ext:settings"), settings["read_cursors"] == .bool(false) { return }
        let session = server.session
        Task { await session?.activity(room: room, fields: ["read_message_id": .string(message)]) }
    }
    func saveProfiles() {
        guard !preview else { return }
        do { try storage.write(servers.map(\.profile), to: "servers-v1.json") } catch { globalError = error.localizedDescription }
    }
    func addServer(_ address: String) throws {
        let url = try ServerAddress.normalize(address)
        if let existing = servers.first(where: { (try? ServerAddress.normalize($0.profile.address)) == url }) { selectedServer = existing.id; return }
        let server = ServerModel(ServerProfile(address: url.absoluteString))
        servers.append(server); selectedServer = server.id
        saveProfiles(); connect(server)
    }
    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination); saveProfiles()
    }
    /// Selects the server at a list position, for ⌥⌘1–9.
    func selectServer(at index: Int) {
        if servers.indices.contains(index) { selectedServer = servers[index].id }
    }
    struct AddressInUse: LocalizedError {
        var errorDescription: String? { "Another server in the list already uses this address." }
    }
    /// Changes a server's address and reconnects. Saved sign-ins move with it when
    /// only the path changes; a token is never sent to a different host, so changing
    /// the host signs out and deletes them. Returns whether the sign-in was kept.
    @discardableResult
    func changeAddress(_ server: ServerModel, to address: String) throws -> Bool {
        let url = try ServerAddress.normalize(address)
        let oldAddress = server.profile.address
        let old = try? ServerAddress.normalize(oldAddress)
        guard url != old else { return true }
        if servers.contains(where: { $0 !== server && (try? ServerAddress.normalize($0.profile.address)) == url }) { throw AddressInUse() }
        let sameHost = old?.scheme == url.scheme && old?.host == url.host && old?.port == url.port
        if sameHost {
            let accounts = Set(server.profile.savedAccounts + [server.profile.accountID].compactMap { $0 })
            // Keep the old endpoint usable if any credential copy fails. Copies
            // already written to the new endpoint are safe to retry.
            for account in accounts {
                guard let token = credentials.read(endpoint: oldAddress, account: account) else { continue }
                try credentials.save(token, endpoint: url.absoluteString, account: account)
            }
            var migrated = server.profile
            migrated.address = url.absoluteString
            try storage.write(servers.map { $0 === server ? migrated : $0.profile }, to: "servers-v1.json")
            server.profile = migrated
            for account in accounts { try? credentials.delete(endpoint: oldAddress, account: account) }
            connect(server)
            return true
        }
        signOut(server)
        for account in server.profile.savedAccounts { try? credentials.delete(endpoint: oldAddress, account: account) }
        server.profile.savedAccounts = []
        server.profile.address = url.absoluteString; saveProfiles(); connect(server, useToken: false)
        return false
    }
    func setConnectionAvailable(_ available: Bool) {
        guard !preview, available != connectionAvailable else { return }
        connectionAvailable = available
        availabilityTask?.cancel()
        let sessions = servers.compactMap(\.session)
        availabilityTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for session in sessions {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        await session.setConnectionAvailable(available)
                    }
                }
            }
        }
    }
    func connect(_ server: ServerModel, useToken: Bool = true) {
        guard let url = URL(string: server.profile.address), !preview else { return }
        let token = useToken ? server.profile.accountID.flatMap { credentials.read(endpoint: server.profile.address, account: $0) } : nil
        let seed = server.historySeed
        server.historySeed = nil
        server.connection.connect(url: url, token: token, seed: seed, pageLimit: recoveryPageLimit,
            available: { [weak self] in self?.connectionAvailable ?? true },
            receive: { [weak self, weak server] event in
                guard let self, let server else { return }
                self.receive(event, server: server)
            })
    }

    private func receive(_ event: SessionEvent, server: ServerModel) {
        switch event {
        case .snapshot(let value):
            let priorPhase = server.snapshot.phase
            if let new = value.you.string("user_id") {
                if (server.connectedAccount ?? server.profile.accountID) != new {
                    server.emojiEdits.reset(); server.uploads.reset(); server.avatars.reset(); server.emojis.reset(); self.attention.remove(server: server.id); server.files = [:]; server.roomLoads = [:]; server.unread = [:]; server.liveMessageCounts = [:]
                }
                server.connectedAccount = new
            }
            if server.cached && value.you.isEmpty && [.connecting, .signIn, .authenticating, .reconnecting, .suspended].contains(value.phase) {
                server.snapshot.phase = value.phase; server.snapshot.server = value.server; server.snapshot.error = value.error; server.snapshot.pendingSignIn = value.pendingSignIn
            } else {
                server.cached = false; server.snapshot = value
                server.uploads.reconcile(value.store)
            }
            if value.phase == .ready {
                server.reconcileConversationCounts()
                if priorPhase != .ready {
                    for room in value.store.joined {
                        let timeline = value.store.timeline(room)
                        let key = self.key(server, room)
                        let marker = self.readMarkers[key].flatMap(UInt64.init) ?? 0
                        server.unread[room] = timeline.filter { ($0.logID("message_id") ?? 0) > marker && $0.object("from").string("user_id") != server.account && !$0.bool("deleted") }.count
                    }
                }
                if server.selectedRoom == nil || value.store.rooms[server.selectedRoom!] == nil {
                    server.selectedRoom = server.rooms.first?.string("room_id")
                }
                self.restoreLocation(server: server)
                self.reconcilePanels(for: server)
                self.saveLocation()
                self.scheduleCache()
            }
            if value.phase == .reconnecting { server.roomLoads = [:] }
            self.resumeLink(server: server)
        case .token(let token, let account):
            do {
                try self.credentials.save(token, endpoint: server.profile.address, account: account)
                server.profile.savedAccounts.removeAll { $0 == account }
                server.profile.accountID = account; self.saveProfiles()
            } catch { server.error = "Could not save the session in Keychain: \(error.localizedDescription)" }
        case .avatarChanged(let source): server.avatars.invalidate(source: source)
        case .incoming(let message): self.incoming(message, server: server)
        }
    }
    func receiveLink(_ url: URL) {
        receiveLink(url, from: current)
    }
    func receiveLink(_ url: URL, from source: ServerModel?) {
        do {
            let link = try ApronLink(url.absoluteString, relativeTo: source?.profile.address)
            if link.token == nil, let source, servers.contains(where: { $0 === source }),
               (try? ServerAddress.normalize(source.profile.address)) == link.server {
                showOpenLink = false
                openLinkText = ""
                beginLink(link, server: source)
            } else {
                openLinkText = MessageNavigation.resolvedLink(url, relativeTo: source?.profile.address)?.absoluteString ?? url.absoluteString
                showOpenLink = true
            }
        } catch { globalError = error.localizedDescription }
    }
    /// Opens a destination after review; same-server navigation can begin directly.
    func openLink(_ link: ApronLink) throws {
        let existing = servers.first { (try? ServerAddress.normalize($0.profile.address)) == link.server }
        if link.token != nil, let existing, !existing.snapshot.you.isEmpty {
            throw LinkOpenError("This server is already signed in. Sign out before using an invite or sign-in link.")
        }
        try addServer(link.server.absoluteString)
        guard let server = current else { return }
        beginLink(link, server: server)
    }

    private func beginLink(_ link: ApronLink, server: ServerModel) {
        selectedServer = server.id
        workspace.cancelLocationRestoration(); linkTask?.cancel(); linkedMessage = nil; linkedUser = nil
        pendingLink = (server.id, link, false)
        // A link token must not race saved-account authentication.
        if link.token != nil { connect(server, useToken: false); return }
        resumeLink(server: server)
    }

    struct LinkOpenError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func resumeLink(server: ServerModel) {
        guard let pending = pendingLink, pending.server == server.id, selectedServer == server.id else { return }
        if let token = pending.link.token, !pending.tokenSent, server.snapshot.phase == .signIn {
            // The Open Link dialog explicitly authorizes this sign-in. SideTable
            // does not make state-bearing callback proposals, so use scheme token.
            pendingLink = (server.id, pending.link, true)
            signIn(server, scheme: "token", fields: ["token": .string(token)])
            return
        }
        guard server.snapshot.phase == .ready, pending.link.token == nil || pending.tokenSent else { return }
        pendingLink = nil
        let link = pending.link
        linkTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                if let room = link.room {
                    guard let session = server.session else { throw LinkOpenError("This server is not connected.") }
                    try await session.loadRoom(room)
                    try Task.checkCancellation()
                    guard server.session === session, self.selectedServer == server.id else { return }
                    let snapshot = await session.snapshot()
                    try Task.checkCancellation()
                    server.snapshot = snapshot
                    guard let record = server.snapshot.store.rooms[room] else {
                        throw LinkOpenError("The room is unavailable or you do not have access to it.")
                    }
                    self.selectRoom(room, server: server, asThread: record.string("parent_room_id") != nil, fromLink: true)
                    self.findText = ""
                    if let message = link.message {
                        // `before` is the last unvisited log ID, including compacted
                        // records. Once it precedes the message's creation ID, older
                        // pages cannot supply that message (even if it was moved/deleted).
                        while server.snapshot.store.messages[message] == nil,
                              let beforeID = server.snapshot.roomHistory(room)?.before,
                              beforeID >= (UInt64(message) ?? 0) {
                            let before = server.snapshot.roomHistory(room)?.before
                            try await session.loadOlderHistory(room)
                            try Task.checkCancellation()
                            guard server.session === session, self.selectedServer == server.id else { return }
                            server.snapshot = await session.snapshot()
                            if server.snapshot.roomHistory(room)?.before == before { break }
                        }
                        guard server.snapshot.store.messages[message]?.string("room_id") == room else {
                            throw LinkOpenError("The message is not available in this room’s retained history.")
                        }
                        self.linkedMessage = LinkMessage(server: server.id, room: room, message: message)
                    }
                }
                self.linkedUser = link.user
            } catch is CancellationError {
            } catch { server.error = error.localizedDescription }
        }
    }

    func canStartDirectMessage(to user: String, server: ServerModel) -> Bool {
        !user.isEmpty && user != server.account && !user.hasPrefix("~") && !server.cached
            && server.snapshot.phase == .ready && !server.snapshot.readOnly
            && server.snapshot.supports("rooms") && server.session != nil
            && !directMessageOperations.contains(server.id)
    }

    /// Reuse only private top-level rooms with exactly these two participants.
    static func isDirectRoom(_ room: JSONObject, account: String, recipient: String) -> Bool {
        let members = Set(room.objects("members").compactMap { $0.string("user_id") })
        return room.bool("private") && room.string("parent_room_id") == nil
            && room.string("room_id") != nil && members == Set([account, recipient])
            && (room["member_count"] == nil || room["member_count"]?.number == 2)
    }

    func openDirectMessage(to recipient: String, server: ServerModel) async throws {
        guard canStartDirectMessage(to: recipient, server: server), let session = server.session else {
            throw ClientError.notReady
        }
        let account = server.account
        directMessageOperations.insert(server.id)
        defer { directMessageOperations.remove(server.id) }
        func checkContext() throws {
            try Task.checkCancellation()
            guard server.session === session, server.account == account, !server.cached,
                  server.snapshot.phase == .ready, !server.snapshot.readOnly else { throw ClientError.disconnected }
        }
        let listing = try await session.perform("room_list", params: ["filter": .string("joined"), "members": .bool(true)])
        try checkContext()
        let room: String
        if let existing = listing.objects("joined").first(where: { Self.isDirectRoom($0, account: account, recipient: recipient) }) {
            room = existing.string("room_id")!
        } else {
            // Untitled private rooms are shown by their participants.
            let response = try await session.perform("room_set", params: ["private": .bool(true)])
            try checkContext()
            guard let created = response.string("room_id") else { throw ClientError.invalidHistory }
            let createdState = await session.snapshot()
            try checkContext()
            guard createdState.store.joined.contains(created), createdState.store.rooms[created]?.bool("private") == true else {
                throw LinkOpenError("The server did not confirm privacy. This room has not been opened.")
            }
            room = created
            do {
                _ = try await session.perform("room_join", params: ["room_id": .string(room), "user_id": .string(recipient)])
            } catch {
                try checkContext()
                throw LinkOpenError("The private room was created, but the server could not add this person: " + error.localizedDescription)
            }
            try checkContext()
        }
        // Creation needs one membership confirmation. Reused rooms were just listed above.
        if !listing.objects("joined").contains(where: { $0.string("room_id") == room }) {
            let confirmation = try await session.perform("room_list", params: ["room_id": .string(room), "members": .bool(true)])
            try checkContext()
            guard confirmation.objects("joined").contains(where: {
                $0.string("room_id") == room && Self.isDirectRoom($0, account: account, recipient: recipient)
            }) else { throw LinkOpenError("The server did not confirm a private conversation with just you and this person.") }
        }
        try await session.loadRoom(room)
        try checkContext()
        let latest = await session.snapshot()
        try checkContext()
        guard latest.store.joined.contains(room), var currentRoom = latest.store.rooms[room] else {
            throw LinkOpenError("This private conversation is no longer available.")
        }
        currentRoom["members"] = .array((latest.store.members[room] ?? []).map { .object(["user_id": .string($0)]) })
        guard Self.isDirectRoom(currentRoom, account: account, recipient: recipient) else {
            throw LinkOpenError("The private conversation's membership changed. Please try again.")
        }
        server.snapshot = latest
        selectedServer = server.id
        selectRoom(room, server: server)
    }

    func selectRoom(_ room: String, server: ServerModel, asThread: Bool = false, fromLink: Bool = false) {
        workspace.selectRoom(room, server: server, servers: servers, asThread: asThread, fromLink: fromLink)
    }
    func openInNewPanel(_ room: String, server: ServerModel, isThread: Bool = false) {
        workspace.openInNewPanel(room, server: server, servers: servers, isThread: isThread)
    }
    func focusPanel(_ id: UUID) { workspace.focusPanel(id, servers: servers) }
    func closePanel(_ id: UUID) { workspace.closePanel(id, servers: servers) }
    func movePanel(_ id: UUID, to index: Int) { workspace.movePanel(id, to: index) }
    func closeThreadPanel(server: ServerModel, room: String) {
        workspace.closeThreadPanel(server: server, room: room, servers: servers)
    }
    func ensureInitialPanel() { workspace.ensureInitialPanel(servers: servers) }
    func reconcilePanels(for server: ServerModel) { workspace.reconcilePanels(for: server, servers: servers) }
    func settleRestoredPanels(_ room: String, server: ServerModel, exists: Bool) {
        workspace.settleRestoredPanels(room, server: server, exists: exists, servers: servers)
    }
    func savePanelLayout() { workspace.savePanelLayout() }
    func saveLocation() { workspace.saveLocation(servers: servers) }
    func restoreLocation(server: ServerModel, finishedListing: Bool = false) {
        workspace.restoreLocation(server: server, servers: servers, finishedListing: finishedListing)
    }

    func saveMembersPanel() {
        guard !preview else { return }
        try? storage.write(SavedMembersPanel(expanded: showMembers, width: Double(membersWidth)), to: "members-panel-v1.json")
    }

    func loadConversation(_ room: String, server: ServerModel) async {
        guard !preview, server.snapshot.phase == .ready, let session = server.session,
              server.roomLoads[room] == nil else { return }
        let operation = UUID(), account = server.account
        server.roomLoads[room] = operation
        defer { if server.roomLoads[room] == operation { server.roomLoads[room] = nil } }
        do {
            try await session.loadRoom(room)
            guard server.session === session, server.account == account, !Task.isCancelled else { return }
            // Read the authoritative result rather than waiting for the event listener.
            let latest = await session.snapshot()
            guard server.session === session, server.account == account else { return }
            workspace.confirmRestoredRooms(in: latest.store, server: server.id)
            settleRestoredPanels(room, server: server, exists: latest.store.rooms[room] != nil)
            if workspace.isRestoringLocation(server: server.id, room: room) {
                server.snapshot = latest
                restoreLocation(server: server, finishedListing: true)
            }
        } catch {
            guard server.session === session, server.account == account, !Task.isCancelled else { return }
            // A rejected room (not a rate limit or connection failure) no longer exists for this account.
            if let rejection = error as? RPCError, rejection.retryAfter == nil {
                settleRestoredPanels(room, server: server, exists: false)
            }
            server.error = error.localizedDescription
        }
    }
    func loadOlderHistory(_ room: String, server: ServerModel) async {
        guard !preview, let session = server.session else { return }
        do { try await session.loadOlderHistory(room) }
        catch {
            // The per-room history state owns retryable errors. Do not show an
            // alert for cancellation or a session replaced during the request.
            guard server.session === session else { return }
        }
    }
    func signIn(_ server: ServerModel, scheme: String, fields: JSONObject) {
        server.connection.signIn(scheme: scheme, fields: fields, reportError: { [weak server] in server?.error = $0 })
    }
    func requestEmail(_ email: String, server: ServerModel) {
        server.connection.requestEmail(email, reportError: { [weak server] in server?.error = $0 })
    }
    func requestExternalSignIn(server: ServerModel) {
        server.connection.requestExternalSignIn(reportError: { [weak server] in server?.error = $0 })
    }
    func signOut(_ server: ServerModel) {
        guard !preview else { return }
        workspace.cancelLocationRestoration(server: server.id)
        server.connection.stop()
        // Keep the token so the sign-in screen can offer to continue as this
        // account. Guest identities are not kept.
        if let account = server.profile.accountID {
            if !server.snapshot.isGuest, credentials.read(endpoint: server.profile.address, account: account) != nil {
                server.profile.savedAccounts = [account] + server.profile.savedAccounts.filter { $0 != account }
            } else if !server.profile.savedAccounts.contains(account) {
                try? credentials.delete(endpoint: server.profile.address, account: account)
            }
        }
        MessageMarkdownCache.shared.clear()
        AttachmentRenderCache.shared.clear()
        GitHubPreviewCache.shared.clear()
        ComposerLinkDiscovery.shared.clear()
        NotificationCenter.default.post(name: .mediaCacheCleared, object: server.id)
        Task {
            do { try await MediaCache.shared.clear(server: server.id) }
            catch { globalError = "Could not clear downloaded media: \(error.localizedDescription)" }
        }
        do { try linkPreviews.clear(server: server.id) }
        catch { globalError = "Could not clear link preview preferences: \(error.localizedDescription)" }
        drafts = drafts.filter { $0.key.server != server.id }
        readMarkers = readMarkers.filter { $0.key.server != server.id }
        viewedMessages = viewedMessages.filter { $0.key.server != server.id }; saveDrafts()
        do { try storage.removeConversationCache(server.id); refreshCacheUsage() }
        catch { globalError = "Could not clear saved conversations: \(error.localizedDescription)" }
        workspace.removePanels(for: server, servers: servers)
        server.connectedAccount = nil; server.profile.accountID = nil; server.snapshot = SessionSnapshot(); server.emojiEdits.reset(); server.uploads.reset(); server.avatars.reset(); server.emojis.reset(); self.attention.remove(server: server.id); server.files = [:]
        server.roomLoads = [:]; server.selectedRoom = nil; server.cached = false; server.liveMessageCounts = [:]; server.unread = [:]
        server.historySeed = nil
        thread = nil; saveProfiles(); connect(server, useToken: false)
    }
    /// Signs in again with a token kept at sign-out.
    func continueAs(_ account: String, server: ServerModel) {
        guard server.profile.savedAccounts.contains(account), !preview else { return }
        server.profile.accountID = account // Remove the saved entry only after receiving an accepted token.
        saveProfiles(); connect(server)
    }
    func forgetSavedAccount(_ account: String, server: ServerModel) {
        do { try credentials.delete(endpoint: server.profile.address, account: account) }
        catch { globalError = "Could not remove the saved credential: \(error.localizedDescription)"; return }
        server.profile.savedAccounts.removeAll { $0 == account }; saveProfiles()
    }
    /// Saved accounts whose tokens are still in Keychain.
    func savedAccounts(_ server: ServerModel) -> [String] {
        server.profile.savedAccounts.filter { credentials.read(endpoint: server.profile.address, account: $0) != nil }
    }

    func remove(_ server: ServerModel) {
        for account in Set(server.profile.savedAccounts + [server.profile.accountID].compactMap { $0 }) {
            do { try credentials.delete(endpoint: server.profile.address, account: account) }
            catch { globalError = "Could not remove the saved credential: \(error.localizedDescription)" }
        }
        signOut(server)
        server.connection.stop()
        servers.removeAll { $0.id == server.id }; selectedServer = servers.first?.id; saveProfiles()
    }

    @discardableResult
    func send(server: ServerModel, room: String, linkMetadata: [String: JSONObject] = [:]) -> Bool {
        guard !preview, server.snapshot.phase == .ready else { return false }
        let draft = draft(server, room: room)
        let files = server.files[room] ?? []
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return false }
        let composed = ComposedText(draft.text, commands: server.snapshot.supports("command"))
        let isCommand = composed.isCommand, text = composed.text
        guard !server.snapshot.readOnly || isCommand else { return false }
        guard server.snapshot.cooldown(for: isCommand ? "command" : "message", hasUploads: !files.isEmpty) == nil else { return false }
        let category = UploadMediaPolicy.category(text: text, commands: server.snapshot.supports("command"))
        do { try UploadMediaPolicy.validate(files, snapshot: server.snapshot, category: category) }
        catch { server.error = error.localizedDescription; return false }
        var body: JSONObject = ["text": .string(text), "format": .string("markdown")]
        let ids = Set(server.snapshot.store.users.keys).union(server.snapshot.store.members[room] ?? [])
        let mentions = MessageMentions.userIDs(in: text, version: server.snapshot.server["apron"]?.number ?? 9).intersection(ids).sorted()
        if !mentions.isEmpty { body["mentions"] = .array(mentions.map(JSONValue.string)) }
        let links = isCommand ? [] : ComposerLinkDiscovery.shared.links(in: text)
            .filter { !draft.excludedPreviewURLs.contains($0.id) }
        let linkEmbeds = links.map { $0.embed(metadata: linkMetadata[$0.id]) }
        let uploads: [JSONObject] = files.map { ["kind": .string("upload"), "title": .string($0.name)] }
        if !uploads.isEmpty || !linkEmbeds.isEmpty { body["embeds"] = .array((uploads + linkEmbeds).map(JSONValue.object)) }
        var params: JSONObject = ["body": .object(body)]
        if server.snapshot.supports("rooms") { params["room_id"] = .string(room) }
        if let reply = draft.replyTo { params["reply_to"] = .object(["message_id": .string(reply)]) }
        // Do not regenerate previews the sender omitted when the message comes
        // back from the server. This local preference follows the acknowledged ID.
        let hidden = isCommand ? [] : GitHubPreviewCache.shared.missingEmbeds(in: text, existing: linkEmbeds, markdown: true)
        let hiddenURLs = Set(hidden.compactMap { $0.string("url") })
        let message = PendingMessage(id: UUID().uuidString, room: room, account: server.account, params: params, text: text,
                                     files: files, isCommand: isCommand, hiddenPreviewURLs: hiddenURLs)
        server.uploads.messages.append(message)
        setDraft(SavedDraft(), server: server, room: room); server.files[room] = []
        deliver(message, server: server)
        return true
    }
    @discardableResult
    func manageServer(_ command: String, files: [StagedFile] = [], server: ServerModel) -> PendingMessage? {
        guard !preview, !server.cached, server.snapshot.phase == .ready,
              server.snapshot.supports("command"), server.session != nil,
              server.snapshot.cooldown(for: "command", hasUploads: !files.isEmpty) == nil else { return nil }
        do { try UploadMediaPolicy.validate(files, snapshot: server.snapshot,
            category: UploadMediaPolicy.category(text: command, commands: true)) }
        catch { server.error = error.localizedDescription; return nil }
        let message = PendingMessage(id: UUID().uuidString, room: "", account: server.account,
            params: ServerManagementCommand.parameters(command, files: files), text: command,
            files: files, isCommand: true, isManagement: true)
        server.uploads.messages.append(message)
        deliver(message, server: server)
        return message
    }
    func saveEmojiChanges(server: ServerModel) {
        guard !preview, let session = server.session else { return }
        let account = server.account
        server.emojiEdits.save { change in
            guard server.session === session, server.account == account, server.snapshot.phase == .ready else {
                throw UploadFailure(message: "Wait until this account is connected, then save again.", mayHaveConsumedURL: false)
            }
            if let file = change.file {
                try UploadMediaPolicy.validate([file], snapshot: server.snapshot, category: "emoji")
            }
            guard server.snapshot.cooldown(for: "command", hasUploads: change.file != nil) == nil else {
                throw UploadFailure(message: "Wait for the cooldown, then save again.", mayHaveConsumedURL: false)
            }
            if let operation = change.operation {
                if !operation.acknowledged { self.retry(operation, server: server) }
                else {
                    for upload in operation.uploads where upload.phase != .complete {
                        guard upload.canRetry, let endpoint = URL(string: server.profile.address) else {
                            throw UploadFailure(message: "The upload did not finish. Check the server, then choose the image again before saving.", mayHaveConsumedURL: true)
                        }
                        server.uploads.start(upload, message: operation, endpoint: endpoint)
                    }
                }
            } else {
                change.operation = self.manageServer(change.command, files: change.file.map { [$0] } ?? [], server: server)
            }
            guard let operation = change.operation else {
                throw UploadFailure(message: server.error ?? "This change could not be submitted.", mayHaveConsumedURL: false)
            }
            while operation.sending || operation.acknowledged && operation.uploads.contains(where: { [.waiting, .uploading].contains($0.phase) }) {
                try await Task.sleep(for: .milliseconds(100))
                guard server.session === session, server.account == account else { throw CancellationError() }
            }
            if let error = operation.error { throw UploadFailure(message: error, mayHaveConsumedURL: false) }
            guard operation.acknowledged else { throw CancellationError() }
            if let failed = operation.uploads.first(where: { $0.phase != .complete }) {
                throw UploadFailure(message: failed.error ?? "Upload did not complete. Choose the image again before saving.", mayHaveConsumedURL: failed.attempted)
            }
        } finished: {
            if server.session === session, server.account == account { await server.emojis.refreshCatalog() }
        }
    }
    func retry(_ message: PendingMessage, server: ServerModel) {
        guard message.account == server.account, server.snapshot.phase == .ready, !server.snapshot.readOnly || message.isCommand else { return }
        guard server.snapshot.cooldown(for: message.isCommand ? "command" : "message", hasUploads: !message.uploads.isEmpty) == nil else { return }
        deliver(message, server: server)
    }
    private func deliver(_ message: PendingMessage, server: ServerModel) {
        guard let session = server.session, let endpoint = URL(string: server.profile.address) else { return }
        server.uploads.submit(message, endpoint: endpoint) { method, params, id in
            let result = try await session.perform(method, params: params, id: id)
            if server.session === session, server.account == message.account,
               let messageID = result.string("message_id"), !message.hiddenPreviewURLs.isEmpty {
                do {
                    try self.linkPreviews.hide(message.hiddenPreviewURLs, server: server.id, account: message.account, message: messageID)
                } catch { self.globalError = "Could not save hidden link previews: \(error.localizedDescription)" }
            }
            return result
        }
    }
    func reattach(_ upload: PendingUpload, message: PendingMessage, server: ServerModel) {
        guard message.account == server.account, let file = upload.file else { return }
        server.files[message.room, default: []].append(file)
        upload.file = nil; upload.writeURL = nil
        upload.error = "File returned to the composer. Send it when ready."
        selectRoom(message.room, server: server)
    }
    func perform(_ method: String, params: JSONObject, server: ServerModel, completed: (@MainActor (JSONObject) -> Void)? = nil) {
        guard !preview else { return }
        if server.snapshot.readOnly && ["message", "reactions", "room_set", "room_join", "room_leave"].contains(method) {
            server.error = "This account does not have permission to write on this server."; return
        }
        Task {
            do { let result = try await server.session?.perform(method, params: params) ?? [:]; completed?(result) }
            catch { server.error = error.localizedDescription }
        }
    }
    func react(_ emoji: String, message: JSONObject, server: ServerModel) {
        guard let id = message.string("message_id") else { return }
        let previous = server.snapshot.store.reactions[RecordKey(id, server.account)]?.strings("emojis") ?? []
        let entries = ReactionEntry.toggled(emoji, in: previous)
        if entries.count > previous.count { RecentEmojis().record(emoji) }
        perform("reactions", params: ["message_id": .string(id), "emojis": .array(entries.map(JSONValue.string))], server: server)
    }
    func applyMessageEdit(_ edit: MessageEdit, params: JSONObject, server: ServerModel) async throws {
        guard !preview, server.snapshot.phase == .ready, !server.cached, !server.snapshot.readOnly,
              server.snapshot.supports("edit"), let session = server.session else { throw MessageEdit.EditError.unavailable }
        let account = server.account
        let id = edit.original.string("message_id") ?? ""
        try MessageEdit.validate(original: edit.original, current: server.snapshot.store.messages[id], account: account)
        if edit.remoteChanged { _ = try await session.perform("message", params: params) }
        guard server.account == account, server.session === session else { throw MessageEdit.EditError.unavailable }
        do { try linkPreviews.hide(edit.hiddenPreviewURLs, server: server.id, account: account, message: id) }
        catch { globalError = "The edit was saved, but local preview preferences could not be saved: \(error.localizedDescription)" }
    }
    func saveMessage(_ message: JSONObject, deleted: Bool = false, destination: String? = nil, server: ServerModel) {
        var params = message.filter { ["message_id", "room_id", "body", "reply_to"].contains($0.key) }
        if deleted { params["deleted"] = .bool(true); params.removeValue(forKey: "body") }
        if let destination {
            guard server.snapshot.canMove(message) else { server.error = "This account cannot move that message."; return }
            params["room_id"] = .string(destination)
        }
        perform("message", params: params, server: server)
    }
    func enableNotifications(_ enabled: Bool) {
        if !enabled { notificationsEnabled = false; UserDefaults.standard.set(false, forKey: "notificationsEnabled"); return }
        Task {
            do {
                notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            } catch { globalError = error.localizedDescription }
        }
    }
    func incoming(_ message: JSONObject, server: ServerModel) {
        guard let id = message.string("message_id"), let room = message.string("room_id") else { return }
        server.liveMessageCounts[room, default: 0] += 1
        guard message.object("from").string("user_id") != server.account else { return }
        let visible = attention.contains(self.key(server, room))
        if !visible { server.unread[room, default: 0] += 1 }
        let mentions = message.object("body").strings("mentions").contains(server.account)
        let reply = message.object("reply_to").string("message_id").flatMap { server.snapshot.store.messages[$0] }?.object("from").string("user_id") == server.account
        let key = "\(server.id)/\(server.account)/\(id)"
        let parent = server.snapshot.store.rooms[room]?.string("parent_room_id") ?? room
        let muted = ["", room, parent].contains { (server.snapshot.mutedUntil[$0] ?? .distantPast) > Date() }
        guard notificationsEnabled, !visible, !muted, mentions || reply, server.snapshot.you.string("status") != "dnd", seenNotifications.insert(key).inserted else { return }
        if seenNotifications.count > 5000 { seenNotifications = [key] }
        let content = UNMutableNotificationContent()
        content.title = UserText.isolated(server.title(room)) + " · " + UserText.isolated(server.displayTitle)
        content.body = UserText.isolated(server.snapshot.store.displayName(message.object("from"))) + " sent you a message."
        content.sound = .default
        content.userInfo = ["server": server.id.uuidString, "room": room]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
    var conversationCacheBytes: Int64 { cacheUsage.values.reduce(0, +) }
    func refreshCacheUsage() {
        guard !preview else { return }
        do { cacheUsage = try storage.conversationCacheUsage() }
        catch { cacheError = "Could not inspect saved conversations: \(error.localizedDescription)" }
    }
    func clearSavedConversations(server id: UUID? = nil) {
        guard !preview else { return }
        MessageMarkdownCache.shared.clear()
        cacheTask?.cancel(); cacheTask = nil; cacheGeneration = UUID()
        cacheError = nil
        do {
            let usage = try storage.conversationCacheUsage()
            let ids = id.map { Set([$0]) } ?? Set(usage.keys).union(servers.map(\.id))
            // Suppression lasts for this launch. A pending write or an unrelated
            // snapshot must not immediately recreate what the user just cleared.
            cacheSuppressedServers.formUnion(ids)
            for id in ids {
                try storage.removeConversationCache(id)
                servers.first(where: { $0.id == id })?.historySeed = nil
                if let server = servers.first(where: { $0.id == id }), server.cached {
                    attention.remove(server: id)
                    server.snapshot.store = RecordStore(); server.snapshot.history = [:]
                    server.cached = false; server.selectedRoom = nil; server.unread = [:]
                }
            }
        } catch { cacheError = "Could not clear all saved conversations: \(error.localizedDescription)" }
        refreshCacheUsage()
    }
    func scheduleCache() {
        guard !preview, cacheTask == nil else { return }
        let generation = cacheGeneration
        // Every live event produces a ready snapshot, and each save re-exports and
        // rewrites the whole saved history. Save the first change promptly, then at
        // most once per interval; the next launch recovers anything newer.
        var delay = cacheDelay
        if let lastCacheWrite { delay = max(delay, cacheInterval - lastCacheWrite.duration(to: .now)) }
        cacheTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.cacheGeneration == generation else { return }
            await self.writeConversationCaches()
            guard self.cacheGeneration == generation else { return }
            self.lastCacheWrite = .now
            self.cacheTask = nil
            if self.servers.contains(where: { self.needsCacheWrite($0) }) { self.scheduleCache() }
        }
    }
    private func needsCacheWrite(_ server: ServerModel) -> Bool {
        !cacheSuppressedServers.contains(server.id) && server.profile.accountID == server.account
            && server.snapshot.phase == .ready && savedCacheRevisions[server.id] != server.cacheRevision
    }
    func writeConversationCaches() async {
        guard !preview, !writingCaches else { return }
        writingCaches = true
        defer { writingCaches = false }
        let generation = cacheGeneration
        for server in servers where needsCacheWrite(server) {
            let account = server.account
            let revision = server.cacheRevision, session = server.session
            let messageLimit = savedMessagesPerRoom
            let seed = await session?.exportHistory(maxMessages: messageLimit)
            // Clearing or signing out while the session exported must not recreate the copy.
            guard cacheGeneration == generation, !cacheSuppressedServers.contains(server.id),
                  server.profile.accountID == account, server.account == account,
                  seed.map({ $0.account == account }) ?? true else { continue }
            let store = server.snapshot.store
            let messages = seed == nil ? store.joined.flatMap { Array(store.timeline($0).suffix(150)) } : []
            let view = CachedView(account: account, date: Date(), rooms: Array(store.rooms.values), messages: messages,
                                  users: Array(store.users.values), joined: Array(store.joined), history: seed)
            do {
                let prepared = try await storage.prepareConversationCache(view, server: server.id)
                defer { prepared.discard() }
                guard !Task.isCancelled, cacheGeneration == generation, !cacheSuppressedServers.contains(server.id),
                      servers.contains(where: { $0 === server }), server.session === session,
                      server.profile.accountID == account, server.account == account else { continue }
                try prepared.commit()
                if savedMessagesPerRoom == messageLimit { savedCacheRevisions[server.id] = revision }
            }
            catch is CancellationError { continue }
            catch { cacheError = "Could not save recent conversations: \(error.localizedDescription)" }
        }
        refreshCacheUsage()
    }
    private func restoreCache(_ server: ServerModel) {
        guard let cache = storage.read("cache-\(server.id).json", as: CachedView.self), cache.account == server.profile.accountID,
              Date().timeIntervalSince(cache.date) < 7 * 86400 else { return }
        // Build the store locally: each change to `snapshot` notifies observers.
        var store = server.snapshot.store
        for room in cache.rooms { store.installRoom(room) }
        for message in cache.messages + (cache.history?.messages ?? []) { store.installMessage(message) }
        for reaction in cache.history?.reactions ?? [] {
            store.reactions[RecordKey(reaction.message, reaction.user)] = reaction.record
        }
        if let seed = cache.history, seed.account == cache.account { server.historySeed = seed }
        for user in cache.users { store.mergeUser(user, complete: true) }
        store.joined = Set(cache.joined)
        server.snapshot.store = store; server.cached = true
        server.selectedRoom = server.rooms.first?.string("room_id")
    }

}

/// Composer text starting with `/` is a command; `//` escapes it as a message that
/// begins with `/` (§4.1). Without command support, text is sent unchanged.
struct ComposedText: Equatable {
    let text: String
    let isCommand: Bool
    init(_ draft: String, commands: Bool) {
        let escaped = commands && draft.hasPrefix("//")
        text = escaped ? String(draft.dropFirst()) : draft
        isCommand = commands && !escaped && draft.hasPrefix("/")
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
