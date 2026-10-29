import ApronCore
import AppKit
import Observation
import UserNotifications

@MainActor @Observable
final class ServerModel: Identifiable {
    let id: UUID
    var profile: ServerProfile
    var snapshot = SessionSnapshot() {
        didSet {
            cacheRevision = UUID()
            if let endpoint = URL(string: profile.address) {
                emojis.configure(server: snapshot.server, account: snapshot.you.string("user_id"), endpoint: endpoint)
            }
        }
    }
    let emojis = CustomEmojiStore()
    var selectedRoom: String?
    let uploads = UploadCoordinator()
    let emojiEdits: EmojiEditQueue
    let avatars = AvatarCache()
    var pending: [PendingMessage] { uploads.messages }
    var unread: [String: Int] = [:]
    var liveMessageCounts: [String: Int] = [:]
    var files: [String: [StagedFile]] = [:]
    var error: String?
    var busy = false
    var cached = false
    @ObservationIgnored var authenticationOperation = UUID()
    @ObservationIgnored var connectedAccount: String?
    @ObservationIgnored var session: ApronSession?
    @ObservationIgnored var listener: Task<Void, Never>?
    @ObservationIgnored private(set) var cacheRevision = UUID()
    @ObservationIgnored var roomLoads: [String: UUID] = [:]
    /// Saved history handed to the next session this server starts, then discarded.
    @ObservationIgnored var historySeed: HistorySeed?
    @ObservationIgnored var lastTyping: [String: Date] = [:]
    /// Room-less notices dismissed in this app session, by sender and text.
    var dismissedNotices: Set<String> = []
    static func noticeKey(_ notice: Notice) -> String {
        (notice.record.object("from").string("user_id") ?? "") + "\n" + (notice.record.object("body").string("text") ?? "")
    }
    init(_ profile: ServerProfile) { self.profile = profile; id = profile.id; emojiEdits = EmojiEditQueue(uploads: uploads) }
    var displayTitle: String { snapshot.server.string("title") ?? profile.address }
    var serverDescription: String? { snapshot.server.string("description") }
    var serverAvatar: String? { snapshot.server.string("avatar") }
    var account: String { snapshot.you.string("user_id") ?? profile.accountID ?? "signed-out" }
    var rooms: [JSONObject] {
        snapshot.store.rooms.values.filter { snapshot.store.joined.contains($0.string("room_id") ?? "") || $0.string("parent_room_id") != nil }
            .map { (title($0.string("room_id") ?? ""), $0) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map(\.1)
    }
    var composerReferenceNames: [String: String] {
        var names = Dictionary(uniqueKeysWithValues: Set(snapshot.store.users.keys).union(snapshot.store.aliases.keys).map {
            ("@" + $0, snapshot.store.displayName(["user_id": .string($0)]))
        })
        if snapshot.supports("rooms") {
            for id in snapshot.store.rooms.keys { names["#" + id] = title(id) }
        }
        return names
    }
    func roomReferenceNames(in text: String) -> [String: String] {
        guard snapshot.supports("rooms") else { return [:] }
        return Dictionary(uniqueKeysWithValues: RoomReferenceDisplay.ids(in: text).compactMap { id in
            snapshot.store.rooms[id] == nil ? nil : (id, title(id))
        })
    }
    func title(_ room: String) -> String {
        let name = snapshot.store.rooms[room]?.string("title")
        if let name, !name.isEmpty { return name }
        if let participants = participants(room) { return participants.map(\.name).joined(separator: ", ") }
        return room.isEmpty ? "Conversation" : room
    }
    /// An untitled private room is named after its other members; a room with
    /// only the current account falls back to that account.
    func participants(_ room: String) -> [UserProfile]? {
        let store = snapshot.store
        guard let record = store.rooms[room], record.bool("private"), record.string("title")?.isEmpty != false,
              let members = store.members[room], !members.isEmpty else { return nil }
        let others = members.filter { $0 != account }
        return (others.isEmpty ? members : others)
            .map { UserProfile(recorded: ["user_id": .string($0)], store: store) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }
    func reconcileConversationCounts() {
        guard snapshot.phase == .ready, !cached else { return }
        let store = snapshot.store
        let available = Set(store.rooms.keys.filter { room in
            if store.joined.contains(room) { return true }
            // Threads can be loaded without joining them, but disappear with
            // their parent when access to that conversation is removed.
            return store.rooms[room]?.string("parent_room_id").map { store.rooms[$0] != nil } ?? false
        })
        unread = unread.filter { available.contains($0.key) }
        liveMessageCounts = liveMessageCounts.filter { available.contains($0.key) }
    }
}

struct CachedView: Codable, Sendable {
    let account: String
    let date: Date
    let rooms: [JSONObject]
    let messages: [JSONObject]
    let users: [JSONObject]
    let joined: [String]
    /// Contiguous history the next session continues from; `messages` is then empty.
    var history: HistorySeed?
}

@MainActor @Observable
final class AppModel {
    var servers: [ServerModel] = []
    var panels: [ConversationPanel] = []
    var activePanelID: UUID?
    var showMembers = false {
        didSet { if showMembers != oldValue { saveMembersPanel() } }
    }
    static let membersWidthRange: ClosedRange<CGFloat> = 220...400
    static let defaultMembersWidth: CGFloat = 250
    /// The expanded members panel's width; its divider reports the end of a resize.
    var membersWidth = AppModel.defaultMembersWidth
    var panelDrag: PanelDrag?
    private var hasOpenedPanels = false
    var showServerSignIn = false
    var activePanel: ConversationPanel? { panels.first { $0.id == activePanelID } }
    private var directMessageOperations: Set<UUID> = []
    var selectedServer: UUID? {
        didSet {
            guard navigationReady, selectedServer != oldValue else { return }
            pendingLink = nil; linkTask?.cancel(); linkedMessage = nil; linkedUser = nil
            pendingLocation = nil
            if panels.isEmpty { thread = nil; findText = "" }
            saveLocation()
        }
    }
    var showAddServer = false
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
    var thread: String? { didSet { saveLocation() } }
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
    @ObservationIgnored private var navigationReady = false
    @ObservationIgnored private var pendingLocation: SavedLocation?
    @ObservationIgnored private var lastSavedLocation: SavedLocation?
    @ObservationIgnored private var lastSavedPanelLayout: SavedPanelLayout?
    @ObservationIgnored private var restoringPanelIDs: Set<UUID> = []
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
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var savedCacheRevisions: [UUID: UUID] = [:]
    @ObservationIgnored private var writingCaches = false

    init(storage: LocalStorage = LocalStorage(), preview: Bool = false, cacheDelay: Duration = .seconds(3), connectOnLaunch: Bool = true,
         stateSaveDelay: Duration = .milliseconds(250), credentials: (any CredentialStore)? = nil) {
        self.linkPreviews = LinkPreviewPreferences(storage: storage)
        self.storage = storage; self.preview = preview; self.cacheDelay = cacheDelay
        self.stateSaveDelay = stateSaveDelay
        if let credentials { self.credentials = credentials }
        else if preview || AppRuntime.isTesting { self.credentials = MemoryCredentialStore() }
        else { self.credentials = KeychainCredentialStore() }
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
        if preview { seedPreview(); return }
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
        pendingLocation = storage.read("location-v1.json", as: SavedLocation.self)
        lastSavedLocation = pendingLocation
        selectedServer = servers.first { $0.id == pendingLocation?.server }?.id ?? servers.first?.id
        if selectedServer != pendingLocation?.server { pendingLocation = nil }
        for server in servers {
            restoreCache(server)
            if connectOnLaunch { connect(server) }
        }
        restorePanelLayout()
        navigationReady = true
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
        let old = server.session
        server.authenticationOperation = UUID(); server.busy = false
        server.listener?.cancel()
        let session = ApronSession(url: url, token: token)
        server.session = session
        let seed = server.historySeed, pageLimit = recoveryPageLimit
        server.historySeed = nil
        server.listener = Task { [weak self, weak server] in
            await old?.stop()
            guard !Task.isCancelled else { await session.stop(); return }
            await session.setRecoveryPageLimit(pageLimit)
            if let seed { await session.restore(seed) }
            await session.setConnectionAvailable(self?.connectionAvailable ?? true)
            guard !Task.isCancelled else { await session.stop(); return }
            await session.start()
            guard !Task.isCancelled else { await session.stop(); return }
            for await event in session.events {
                guard !Task.isCancelled, let self, let server else { break }
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
                        server.profile.accountID = account; self.saveProfiles()
                    } catch { server.error = "Could not save the session in Keychain: \(error.localizedDescription)" }
                case .avatarChanged(let source): server.avatars.invalidate(source: source)
                case .incoming(let message): self.incoming(message, server: server)
                }
            }
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
        pendingLocation = nil; linkTask?.cancel(); linkedMessage = nil; linkedUser = nil
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

    /// Rooms and threads replace the active panel's conversation; ⌘-click and
    /// Open in New Panel (`openInNewPanel`) open one beside it.
    func selectRoom(_ room: String, server: ServerModel, asThread: Bool = false, fromLink: Bool = false) {
        navigatePanel(room, server: server, isThread: asThread, newPanel: false, fromLink: fromLink)
    }

    func openInNewPanel(_ room: String, server: ServerModel, isThread: Bool = false) {
        ensureInitialPanel()
        navigatePanel(room, server: server, isThread: isThread, newPanel: true)
    }

    private func navigatePanel(_ room: String, server: ServerModel, isThread: Bool, newPanel: Bool, fromLink: Bool = false) {
        if !fromLink { pendingLink = nil; linkTask?.cancel(); linkedMessage = nil }
        pendingLocation = nil
        if let existing = panels.first(where: { $0.serverID == server.id && $0.account == server.account && $0.room == room }) {
            focusPanel(existing.id)
            return
        }
        // Replacing the active panel's conversation keeps its width.
        let width = newPanel ? ConversationPanel.defaultWidth : activePanel?.width ?? ConversationPanel.defaultWidth
        let panel = ConversationPanel(id: !newPanel ? activePanelID ?? UUID() : UUID(), server: server, room: room, isThread: isThread, width: width)
        if !newPanel, let index = panels.firstIndex(where: { $0.id == activePanelID }) {
            panels[index] = panel
        } else if let index = panels.firstIndex(where: { $0.id == activePanelID }) {
            panels.insert(panel, at: index + 1)
        } else { panels.append(panel) }
        hasOpenedPanels = true
        focusPanel(panel.id)
    }

    func focusPanel(_ id: UUID) {
        guard let panel = panels.first(where: { $0.id == id }),
              let server = servers.first(where: { $0.id == panel.serverID }), server.account == panel.account else { return }
        activePanelID = id
        selectedServer = server.id
        if panel.isThread {
            if let parent = server.snapshot.store.rooms[panel.room]?.string("parent_room_id") { server.selectedRoom = parent }
            thread = panel.room
        } else { server.selectedRoom = panel.room; thread = nil }
        saveLocation()
    }

    func closePanel(_ id: UUID) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        panels.remove(at: index)
        restoringPanelIDs.remove(id)
        if activePanelID == id {
            activePanelID = nil; thread = nil
            if !panels.isEmpty { focusPanel(panels[min(index, panels.count - 1)].id) }
        }
        savePanelLayout()
    }

    func movePanel(_ id: UUID, to index: Int) {
        guard let from = panels.firstIndex(where: { $0.id == id }) else { return }
        let panel = panels.remove(at: from)
        panels.insert(panel, at: min(max(0, index), panels.count))
        savePanelLayout()
    }

    func closeThreadPanel(server: ServerModel, room: String) {
        if let panel = panels.first(where: { $0.serverID == server.id && $0.room == room }) { closePanel(panel.id) }
        else if thread == room { thread = nil }
    }

    func ensureInitialPanel() {
        guard panels.isEmpty, !hasOpenedPanels, let server = current, let room = server.selectedRoom else { return }
        let restoredThread = thread
        let panel = ConversationPanel(server: server, room: room, isThread: false)
        panels = [panel]; activePanelID = panel.id; hasOpenedPanels = true
        if let restoredThread { navigatePanel(restoredThread, server: server, isThread: true, newPanel: true) }
        savePanelLayout()
    }

    func reconcilePanels(for server: ServerModel) {
        let removed = panels.filter {
            $0.serverID == server.id && ($0.account != server.account ||
                (server.snapshot.phase == .ready && !server.cached && !restoringPanelIDs.contains($0.id) && server.snapshot.store.rooms[$0.room] == nil))
        }.map(\.id)
        for id in removed { closePanel(id) }
        if !removed.isEmpty && panels.isEmpty { hasOpenedPanels = false }
        ensureInitialPanel()
    }

    private func restorePanelLayout() {
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
            return ConversationPanel(id: item.id, server: server, room: item.room, isThread: item.isThread,
                                     width: item.width.map { CGFloat($0) } ?? ConversationPanel.defaultWidth)
        }
        restoringPanelIDs = Set(panels.map(\.id))
        activePanelID = panels.first(where: { $0.id == saved.activePanel })?.id ?? panels.first?.id
        for panel in panels {
            if let server = servers.first(where: { $0.id == panel.serverID }), server.selectedRoom == nil, !panel.isThread {
                server.selectedRoom = panel.room
            }
        }
        if let activePanel { focusPanel(activePanel.id) }
        if let browsed = saved.selectedServer, servers.contains(where: { $0.id == browsed }) { selectedServer = browsed }
    }

    /// Restored panels wait for their own room load, since a ready snapshot may
    /// precede discovery of unjoined threads. The server's answer then decides.
    func settleRestoredPanels(_ room: String, server: ServerModel, exists: Bool) {
        let settled = panels.filter { $0.serverID == server.id && $0.room == room && restoringPanelIDs.contains($0.id) }.map(\.id)
        restoringPanelIDs.subtract(settled)
        guard !exists, !settled.isEmpty else { return }
        for id in settled { closePanel(id) }
        if panels.isEmpty { hasOpenedPanels = false; ensureInitialPanel() }
    }

    func saveMembersPanel() {
        guard !preview else { return }
        try? storage.write(SavedMembersPanel(expanded: showMembers, width: Double(membersWidth)), to: "members-panel-v1.json")
    }

    func savePanelLayout() {
        guard navigationReady, !preview, pendingLocation == nil, hasOpenedPanels else { return }
        let saved = SavedPanelLayout(panels: panels.map {
            SavedPanelLayout.Panel(id: $0.id, server: $0.serverID, account: $0.account, room: $0.room, isThread: $0.isThread, width: Double($0.width))
        }, activePanel: activePanelID, selectedServer: selectedServer)
        guard saved != lastSavedPanelLayout else { return }
        do {
            try storage.write(saved, to: "panels-v1.json")
            lastSavedPanelLayout = saved
        } catch { globalError = "Could not save your conversation panels: \(error.localizedDescription)" }
    }

    func saveLocation() {
        savePanelLayout()
        guard navigationReady, !preview, pendingLocation == nil else { return }
        if let activePanel, activePanel.serverID != selectedServer { return }
        let location: SavedLocation?
        if let server = current, let room = server.selectedRoom,
           let account = server.snapshot.you.string("user_id") ?? server.profile.accountID {
            location = SavedLocation(server: server.id, account: account, room: room, thread: thread)
        } else { location = nil }
        guard location != lastSavedLocation else { return }
        do {
            try storage.write(location, to: "location-v1.json")
            lastSavedLocation = location
        }
        catch { globalError = "Could not save your last conversation: \(error.localizedDescription)" }
    }

    func restoreLocation(server: ServerModel, finishedListing: Bool = false) {
        guard let saved = pendingLocation, saved.server == server.id,
              selectedServer == server.id, server.snapshot.phase == .ready else { return }
        guard saved.account == server.account,
              server.snapshot.store.joined.contains(saved.room),
              server.snapshot.store.rooms[saved.room] != nil else {
            pendingLocation = nil; saveLocation(); return
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
            if panels.isEmpty { ensureInitialPanel() }
            else { navigatePanel(thread, server: server, isThread: true, newPanel: true, fromLink: true) }
        }
        saveLocation()
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
            for panel in panels where panel.serverID == server.id && latest.store.rooms[panel.room] != nil {
                restoringPanelIDs.remove(panel.id)
            }
            settleRestoredPanels(room, server: server, exists: latest.store.rooms[room] != nil)
            if let saved = pendingLocation, saved.server == server.id, saved.room == room {
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
        guard let session = server.session, !server.busy else { return }
        let operation = UUID(); server.authenticationOperation = operation
        server.busy = true; server.error = nil
        Task {
            defer { if server.authenticationOperation == operation { server.busy = false } }
            do {
                try await session.authenticate(scheme: scheme, fields: fields)
            } catch {
                guard server.authenticationOperation == operation else { return }
                server.error = error.localizedDescription
            }
        }
    }
    func requestEmail(_ email: String, server: ServerModel) {
        guard let session = server.session, !server.busy else { return }
        let operation = UUID(); server.authenticationOperation = operation
        server.busy = true; server.error = nil
        Task {
            defer { if server.authenticationOperation == operation { server.busy = false } }
            do {
                try await session.requestEmail(email)
            } catch {
                guard server.authenticationOperation == operation else { return }
                server.error = error.localizedDescription
            }
        }
    }
    func requestExternalSignIn(server: ServerModel) {
        guard let session = server.session, !server.busy else { return }
        let operation = UUID(); server.authenticationOperation = operation
        server.busy = true; server.error = nil
        Task {
            defer { if server.authenticationOperation == operation { server.busy = false } }
            do {
                let url = try await session.requestExternalSignIn()
                guard server.authenticationOperation == operation, server.session === session,
                      await session.snapshot().pendingSignIn == "external" else { return }
                if !NSWorkspace.shared.open(url) {
                    server.error = "The sign-in page could not be opened. Check your default browser and try again."
                }
            } catch {
                guard server.authenticationOperation == operation else { return }
                server.error = error.localizedDescription
            }
        }
    }
    func signOut(_ server: ServerModel) {
        guard !preview else { return }
        if pendingLocation?.server == server.id { pendingLocation = nil }
        server.listener?.cancel()
        let old = server.session
        Task { await old?.stop() }
        if let account = server.profile.accountID {
            do { try credentials.delete(endpoint: server.profile.address, account: account) }
            catch { globalError = "Could not remove the saved credential: \(error.localizedDescription)" }
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
        for panel in panels.filter({ $0.serverID == server.id }) { closePanel(panel.id) }
        if panels.isEmpty { hasOpenedPanels = false }
        server.connectedAccount = nil; server.profile.accountID = nil; server.snapshot = SessionSnapshot(); server.emojiEdits.reset(); server.uploads.reset(); server.avatars.reset(); server.emojis.reset(); self.attention.remove(server: server.id); server.files = [:]
        server.roomLoads = [:]; server.selectedRoom = nil; server.cached = false; server.liveMessageCounts = [:]; server.unread = [:]
        server.historySeed = nil
        thread = nil; saveProfiles(); connect(server, useToken: false)
    }
    func remove(_ server: ServerModel) {
        signOut(server)
        server.listener?.cancel(); let session = server.session
        Task { await session?.stop() }
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
        let generation = cacheGeneration, delay = cacheDelay
        cacheTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.cacheGeneration == generation else { return }
            await self.writeConversationCaches()
            guard self.cacheGeneration == generation else { return }
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
        for room in cache.rooms { server.snapshot.store.installRoom(room) }
        for message in cache.messages + (cache.history?.messages ?? []) { server.snapshot.store.installMessage(message) }
        for reaction in cache.history?.reactions ?? [] {
            server.snapshot.store.reactions[RecordKey(reaction.message, reaction.user)] = reaction.record
        }
        if let seed = cache.history, seed.account == cache.account { server.historySeed = seed }
        for user in cache.users { server.snapshot.store.mergeUser(user, complete: true) }
        server.snapshot.store.joined = Set(cache.joined); server.cached = true
        server.selectedRoom = server.rooms.first?.string("room_id")
    }
    private func seedPreview() {
        let server = ServerModel(ServerProfile(address: "wss://studio.example/"))
        server.snapshot.phase = .ready
        server.snapshot.server = ["title": .string(server.profile.title), "capabilities": .array(["rooms", "history", "edit", "reactions", "activity", "status", "embed:upload", "ext:bio"].map(JSONValue.string))]
        server.snapshot.you = ["user_id": .string("ada"), "name": .string("Ada Lovelace")]
        server.snapshot.store.ownID = "ada"
        for (id, name) in [("ada", "Ada Lovelace"), ("ben", "Ben Carter"), ("maya", "Maya Chen")] {
            server.snapshot.store.mergeUser(["user_id": .string(id), "name": .string(name), "status": .string("online")], complete: true)
        }
        server.snapshot.store.mergeUser(["user_id": .string("ada"), "ext": .object(["bio": .string("Building thoughtful tools.\nhttps://example.com")])])
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            let foreground = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
            let background = NSColor(deviceRed: 0.32, green: 0.28, blue: 0.8, alpha: 1)
            for x in 0..<48 {
                for y in 0..<48 {
                    let head = (x - 24) * (x - 24) + (y - 16) * (y - 16) < 70
                    let shoulders = (x - 24) * (x - 24) + (y - 44) * (y - 44) < 300
                    bitmap.setColor(head || shoulders ? foreground : background, atX: x, y: y)
                }
            }
            if let data = bitmap.representation(using: .png, properties: [:]) {
                server.snapshot.store.mergeUser(["user_id": .string("ada"), "avatar": .string("data:image/png;base64," + data.base64EncodedString()), "roles": .array([.string("moderator")])])
            }
        }
        for (id, title, description) in [("general", "General", "A place for the whole team."), ("development", "Development", "Building something thoughtful."), ("design", "Design", "Details make the difference.")] {
            server.snapshot.store.installRoom(["room_id": .string(id), "title": .string(title), "description": .string(description)])
            server.snapshot.store.joined.insert(id); server.snapshot.store.members[id] = ["ada", "ben", "maya"]
        }
        server.snapshot.store.installRoom(["room_id": .string("release"), "title": .string("The first release"), "parent_room_id": .string("general")])
        if ProcessInfo.processInfo.arguments.contains("--preview-threads") {
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            for index in 0..<8 {
                server.snapshot.store.installRoom([
                    "room_id": .string("preview-thread-\(index)"), "parent_room_id": .string("general"),
                    "title": .string("Discussion \(index + 1)"),
                    "description": .string("A **summary** for discussion \(index + 1)."),
                    "log_id": .string(String(now - UInt64(index + 1) * 86_400_000)),
                    "latest_log_id": .string(String(now - UInt64(index) * 3_600_000))
                ])
            }
        }
        let samples = [("maya", "Morning, everyone! The first native build is ready to explore."), ("ben", "Love how quiet this feels. Rooms on the left, conversation in the middle — exactly what we need."), ("ada", "A small place for good conversations.\n\nToday’s focus: reliable reconnects, keyboard navigation, and the little details."), ("maya", "I’ve started a thread for the release checklist. Let’s keep feedback there. ✨")]
        for (index, item) in samples.enumerated() {
            let id = String(1_792_348_000_000 + index * 90_000)
            server.snapshot.store.installMessage(["message_id": .string(id), "log_id": .string(id), "room_id": .string("general"), "from": .object(["user_id": .string(item.0)]), "body": .object(["text": .string(item.1), "format": .string("markdown")])])
        }
        server.snapshot.store.installMessage(["message_id": .string("1792348500000"), "log_id": .string("1792348500000"),
            "room_id": .string("development"), "from": .object(["user_id": .string("ada")]),
            "body": .object(["format": .string("markdown"), "text": .string("""
            ## A readable conversation

            **Native Markdown**, *emphasis*, `inline code`, and [safe links](https://example.com). Καλημέρα 👋

            > A quote with context.

            1. Build the client
               - Keep the useful details
            2. Share a small example

            ```swift
            let greeting = "Hello, Apron!"
            print(greeting)
            ```

            ---

            Images stay explicit: ![sample image](https://example.com/image.png)
            <script>inert HTML</script>
            """)])])
        let previewDelivery = PendingMessage(id: "preview-upload", room: "design", account: "ada", params: [:], text: "", files: [
            StagedFile(url: URL(fileURLWithPath: "/preview/wireframes.pdf")),
            StagedFile(url: URL(fileURLWithPath: "/preview/illustration.png")),
            StagedFile(url: URL(fileURLWithPath: "/preview/notes.txt"))])
        previewDelivery.acknowledged = true
        previewDelivery.uploads[0].phase = .uploading; previewDelivery.uploads[0].bytes = 420_000; previewDelivery.uploads[0].total = 1_000_000
        previewDelivery.uploads[1].phase = .failed; previewDelivery.uploads[1].error = "Transfer interrupted. Reattach the file to try again."
        previewDelivery.uploads[2].phase = .confirming
        server.uploads.messages = [previewDelivery]
        server.selectedRoom = ProcessInfo.processInfo.arguments.contains("--preview-development") ? "development" : "general"
        if ProcessInfo.processInfo.arguments.contains("--preview-uploads") { server.selectedRoom = "design" }
        if ProcessInfo.processInfo.arguments.contains("--preview-history") {
            server.snapshot.history["general"] = RoomHistory(before: 100)
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-storage") { cacheUsage[server.id] = 256_000 }
        if ProcessInfo.processInfo.arguments.contains("--preview-apron-cards") {
            server.snapshot.store.installMessage([
                "message_id": .string("1792348800000"), "log_id": .string("1792348800000"), "room_id": .string("general"),
                "from": .object(["user_id": .string("ada")]),
                "body": .object(["format": .string("markdown"), "text": .string("See [the development room](apron:?room=development) and [Maya's profile](apron:?user=maya).")])
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-links") {
            drafts[DraftKey(server: server.id, account: server.account, room: "general")] = SavedDraft(
                text: "Two useful references:\nhttps://github.com/shazow/apron\nhttps://example.com/article")
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-latest") || ProcessInfo.processInfo.arguments.contains("--preview-arrivals") || ProcessInfo.processInfo.arguments.contains("--preview-restored") {
            for index in 0..<80 {
                let id = String(1_900_000_000_000 + index)
                server.snapshot.store.installMessage([
                    "message_id": .string(id), "log_id": .string(id), "room_id": .string("general"),
                    "from": .object(["user_id": .string("maya")]),
                    "body": .object([
                        "text": .string(index == 79 ? "Latest message — visible on opening." : "Earlier conversation message \(index + 1)." +
                            (ProcessInfo.processInfo.arguments.contains("--preview-hover-layout") && index < 77 && index % 3 == 0
                             ? "\n\n> A quoted reply with a different height.\n\n```swift\nlet message = \(index)\nprint(message)\n```\n\nMore context below the code." : "")),
                        "format": .string("markdown")])
                ])
            }
            server.snapshot.store.notices = [Notice(record: ["body": .object(["text": .string("Welcome to this conversation.")])])]
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-arrivals") {
            Task { @MainActor [weak self, weak server] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, let server else { return }
                for index in 0..<3 {
                    let id = String(1_900_000_000_080 + index)
                    let message: JSONObject = [
                        "message_id": .string(id), "log_id": .string(id), "room_id": .string("general"),
                        "from": .object(["user_id": .string("maya")]),
                        "body": .object(["text": .string("New live message \(index + 1)")])
                    ]
                    self.incoming(message, server: server)
                    server.snapshot.store.installMessage(message)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-sign-in") {
            server.snapshot = SessionSnapshot()
            server.snapshot.phase = .signIn
            server.snapshot.server = ["apron": .number(9), "title": .string("SideTable Team"), "description": .string("A **shared space** for the team."), "welcome": .string("Sign in to join the conversation."), "auth": .array(["external", "email", "token", "webauthn"].map(JSONValue.string))]
            server.snapshot.pendingSignIn = "external"
            server.selectedRoom = nil
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-thread-context") {
            server.snapshot.store.rooms["release"]?["description"] = .string("> Does it have a url? :D\n\nNot yet")
            server.snapshot.store.installMessage([
                "message_id": .string("1900000000100"), "log_id": .string("1900000000100"), "room_id": .string("release"),
                "from": .object(["user_id": .string("maya")]),
                "body": .object(["text": .string("The next reply in this thread.")])
            ])
            thread = "release"
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-restored") {
            viewedMessages[DraftKey(server: server.id, account: server.account, room: "general")] = "1900000000030"
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-unread-clear") {
            readMarkers[DraftKey(server: server.id, account: server.account, room: "general")] = "1900000000030"
            server.unread["general"] = 49
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-restored-short") {
            viewedMessages[DraftKey(server: server.id, account: server.account, room: "general")] = "1792348000000"
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-unread-recent") {
            readMarkers[DraftKey(server: server.id, account: server.account, room: "general")] = "1900000000077"
            server.unread["general"] = 2
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-members") {
            showMembers = true
            server.snapshot.store.members["general"] = ["ada", "maya"]
            server.snapshot.store.members["development"] = ["ada", "ben"]
        }
        servers = [server]; selectedServer = server.id
        if ProcessInfo.processInfo.arguments.contains("--preview-room-references") {
            server.snapshot.store.rooms["1791590929296"] = ["room_id": .string("1791590929296"), "parent_room_id": .string("general"), "title": .string("Release planning")]
            server.snapshot.store.installMessage([
                "message_id": .string("1900000000200"), "log_id": .string("1900000000200"), "room_id": .string("general"),
                "from": .object(["user_id": .string("maya")]),
                "body": .object(["format": .string("markdown"), "text": .string("Continue in #1791590929296 or ask in #development.\n\nUnknown: #missing · Literal code: `#1791590929296`")])
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-custom-emoji") || ProcessInfo.processInfo.arguments.contains("--preview-emoji-picker") {
            CustomEmojiPreview.install(on: server)
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-panels") {
            ensureInitialPanel()
            openInNewPanel("development", server: server)
        }
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
