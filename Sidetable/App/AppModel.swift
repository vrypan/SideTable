import ApronCore
import AppKit
import Observation
import UserNotifications

struct PendingMessage: Identifiable {
    let id: String
    let room: String
    let account: String
    let params: JSONObject
    var text: String
    var error: String?
    var sending = true
}

struct StagedFile: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

@MainActor @Observable
final class ServerModel: Identifiable {
    let id: UUID
    var profile: ServerProfile
    var snapshot = SessionSnapshot()
    var selectedRoom: String?
    var pending: [PendingMessage] = []
    var unread: [String: Int] = [:]
    var attendedRooms: Set<String> = []
    var files: [String: [StagedFile]] = [:]
    var error: String?
    var busy = false
    var emailPending = false
    var cached = false
    @ObservationIgnored var session: ApronSession?
    @ObservationIgnored var listener: Task<Void, Never>?
    @ObservationIgnored var loadedRooms: Set<String> = []
    @ObservationIgnored var lastTyping: [String: Date] = [:]
    init(_ profile: ServerProfile) { self.profile = profile; id = profile.id }
    var account: String { snapshot.you.string("user_id") ?? profile.accountID ?? "signed-out" }
    var rooms: [JSONObject] {
        snapshot.store.rooms.values.filter { snapshot.store.joined.contains($0.string("room_id") ?? "") || $0.string("parent_room_id") != nil }
            .sorted { ($0.string("title") ?? $0.string("room_id") ?? "").localizedStandardCompare($1.string("title") ?? $1.string("room_id") ?? "") == .orderedAscending }
    }
    func title(_ room: String) -> String {
        let name = snapshot.store.rooms[room]?.string("title")
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? (room.isEmpty ? "Conversation" : room)
    }
}

struct CachedView: Codable {
    let account: String
    let date: Date
    let rooms: [JSONObject]
    let messages: [JSONObject]
    let users: [JSONObject]
    let joined: [String]
}

@MainActor @Observable
final class AppModel {
    var servers: [ServerModel] = []
    var selectedServer: UUID?
    var showAddServer = false
    var showJump = false
    var showMembers = false
    var findText = ""
    var showFind = false
    var thread: String?
    var globalError: String?
    var preview = false
    var drafts: [DraftKey: SavedDraft] = [:]
    var readMarkers: [DraftKey: String] = [:]
    var notificationsEnabled = false
    var messageSize = 14.0
    @ObservationIgnored let storage: LocalStorage
    @ObservationIgnored private var seenNotifications: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?

    init(storage: LocalStorage = LocalStorage(), preview: Bool = false) {
        self.storage = storage; self.preview = preview
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        messageSize = UserDefaults.standard.object(forKey: "messageSize") as? Double ?? 14
        if preview { seedPreview(); return }
        drafts = storage.read("drafts-v1.json", as: [DraftKey: SavedDraft].self) ?? [:]
        readMarkers = storage.read("read-markers-v1.json", as: [DraftKey: String].self) ?? [:]
        servers = (storage.read("servers-v1.json", as: [ServerProfile].self) ?? []).map(ServerModel.init)
        selectedServer = servers.first?.id
        for server in servers { restoreCache(server); connect(server) }
    }
    var current: ServerModel? { servers.first { $0.id == selectedServer } }
    func draft(_ server: ServerModel, room: String) -> SavedDraft { drafts[key(server, room)] ?? SavedDraft() }
    private func key(_ server: ServerModel, _ room: String) -> DraftKey { DraftKey(server: server.id, account: server.account, room: room) }
    func setDraft(_ value: SavedDraft, server: ServerModel, room: String) {
        drafts[key(server, room)] = value
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.saveDrafts()
        }
        if !value.text.isEmpty, Date().timeIntervalSince(server.lastTyping[room] ?? .distantPast) >= 12 {
            server.lastTyping[room] = Date()
            Task { await server.session?.activity(room: room, fields: ["typing": .number(15)]) }
        }
    }
    func saveDrafts() {
        guard !preview else { return }
        do {
            try storage.write(drafts, to: "drafts-v1.json")
            try storage.write(readMarkers, to: "read-markers-v1.json")
        } catch { globalError = "Local conversation state could not be saved: \(error.localizedDescription)" }
    }
    func markRead(_ message: String, server: ServerModel, room: String) {
        let key = key(server, room)
        if let old = readMarkers[key], (UInt64(old) ?? 0) >= (UInt64(message) ?? 0) { return }
        readMarkers[key] = message; server.unread[room] = 0; saveDrafts()
    }
    func saveProfiles() {
        guard !preview else { return }
        do { try storage.write(servers.map(\.profile), to: "servers-v1.json") } catch { globalError = error.localizedDescription }
    }
    func addServer(_ address: String) throws {
        let url = try ServerAddress.normalize(address)
        if let existing = servers.first(where: { $0.profile.address == url.absoluteString }) { selectedServer = existing.id; return }
        let server = ServerModel(ServerProfile(address: url.absoluteString))
        servers.append(server); selectedServer = server.id
        saveProfiles(); connect(server)
    }
    func connect(_ server: ServerModel, useToken: Bool = true) {
        guard let url = URL(string: server.profile.address), !preview else { return }
        let token = useToken ? server.profile.accountID.flatMap { CredentialVault.read(endpoint: server.profile.address, account: $0) } : nil
        let old = server.session
        server.listener?.cancel()
        let session = ApronSession(url: url, token: token)
        server.session = session
        server.listener = Task { [weak self, weak server] in
            await old?.stop()
            guard !Task.isCancelled else { await session.stop(); return }
            await session.start()
            guard !Task.isCancelled else { await session.stop(); return }
            for await event in session.events {
                guard !Task.isCancelled, let self, let server else { break }
                switch event {
                case .snapshot(let value):
                    let priorPhase = server.snapshot.phase
                    if let old = server.snapshot.you.string("user_id"), let new = value.you.string("user_id"), old != new {
                        server.pending = []; server.files = [:]; server.loadedRooms = []; server.unread = [:]
                    }
                    if server.emailPending && value.phase == .reconnecting { server.emailPending = false }
                    if server.cached && value.you.isEmpty && [.connecting, .signIn, .authenticating, .reconnecting].contains(value.phase) {
                        server.snapshot.phase = value.phase; server.snapshot.server = value.server; server.snapshot.error = value.error
                    } else {
                        server.cached = false; server.snapshot = value
                    }
                    if value.phase == .ready {
                        if priorPhase != .ready {
                            for room in value.store.joined {
                                let timeline = value.store.timeline(room)
                                let key = self.key(server, room)
                                if let marker = self.readMarkers[key].flatMap(UInt64.init) {
                                    server.unread[room] = timeline.filter { ($0.logID("message_id") ?? 0) > marker && $0.object("from").string("user_id") != server.account && !$0.bool("deleted") }.count
                                } else if let last = timeline.last?.string("message_id") { self.readMarkers[key] = last }
                            }
                        }
                        if server.selectedRoom == nil || value.store.rooms[server.selectedRoom!] == nil {
                            server.selectedRoom = server.rooms.first?.string("room_id")
                        }
                        self.scheduleCache()
                    }
                    if value.phase == .reconnecting { server.loadedRooms = [] }
                case .token(let token, let account):
                    do {
                        try CredentialVault.save(token, endpoint: server.profile.address, account: account)
                        server.profile.accountID = account; self.saveProfiles()
                    } catch { server.error = "Could not save the session in Keychain: \(error.localizedDescription)" }
                case .incoming(let message): self.incoming(message, server: server)
                }
            }
        }
    }
    func selectRoom(_ room: String, server: ServerModel, asThread: Bool = false) {
        if asThread { thread = room; showMembers = false }
        else { server.selectedRoom = room; thread = nil }
        server.unread[room] = 0
        guard !preview, !server.loadedRooms.contains(room) else { return }
        server.loadedRooms.insert(room)
        Task {
            do { try await server.session?.loadRoom(room) }
            catch { server.loadedRooms.remove(room); server.error = error.localizedDescription }
        }
    }
    func signIn(_ server: ServerModel, scheme: String, fields: JSONObject) {
        server.busy = true; server.error = nil
        Task {
            defer { server.busy = false }
            do { try await server.session?.authenticate(scheme: scheme, fields: fields); server.emailPending = false }
            catch { server.error = error.localizedDescription }
        }
    }
    func requestEmail(_ email: String, server: ServerModel) {
        server.busy = true; server.error = nil
        Task {
            defer { server.busy = false }
            do { try await server.session?.requestEmail(email); server.emailPending = true }
            catch { server.error = error.localizedDescription }
        }
    }
    func signOut(_ server: ServerModel) {
        guard !preview else { return }
        server.listener?.cancel()
        let old = server.session
        Task { await old?.stop() }
        if let account = server.profile.accountID {
            do { try CredentialVault.delete(endpoint: server.profile.address, account: account) }
            catch { globalError = "Could not remove the saved credential: \(error.localizedDescription)" }
        }
        drafts = drafts.filter { $0.key.server != server.id }; saveDrafts()
        readMarkers = readMarkers.filter { $0.key.server != server.id }; saveDrafts()
        try? storage.write(Optional<CachedView>.none, to: "cache-\(server.id).json")
        server.profile.accountID = nil; server.snapshot = SessionSnapshot(); server.pending = []; server.files = [:]
        server.loadedRooms = []; server.selectedRoom = nil; server.cached = false; server.emailPending = false
        thread = nil; saveProfiles(); connect(server, useToken: false)
    }
    func remove(_ server: ServerModel) {
        signOut(server)
        server.listener?.cancel(); let session = server.session
        Task { await session?.stop() }
        servers.removeAll { $0.id == server.id }; selectedServer = servers.first?.id; saveProfiles()
    }

    func send(server: ServerModel, room: String) {
        guard !preview, server.snapshot.phase == .ready, !server.snapshot.readOnly else { return }
        let draft = draft(server, room: room)
        let files = server.files[room] ?? []
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        var body: JSONObject = ["text": .string(draft.text), "format": .string("markdown")]
        let ids = Set(server.snapshot.store.users.keys).union(server.snapshot.store.members[room] ?? [])
        let mentions = ids.filter { draft.text.contains("@" + $0) }.sorted()
        if !mentions.isEmpty { body["mentions"] = .array(mentions.map(JSONValue.string)) }
        if !files.isEmpty { body["embeds"] = .array(files.map { .object(["kind": .string("upload"), "title": .string($0.name)]) }) }
        var params: JSONObject = ["body": .object(body)]
        if server.snapshot.supports("rooms") { params["room_id"] = .string(room) }
        if let reply = draft.replyTo { params["reply_to"] = .object(["message_id": .string(reply)]) }
        let message = PendingMessage(id: UUID().uuidString, room: room, account: server.account, params: params, text: draft.text)
        server.pending.append(message)
        setDraft(SavedDraft(), server: server, room: room); server.files[room] = []
        deliver(message, files: files, server: server)
    }
    func retry(_ message: PendingMessage, server: ServerModel) {
        guard message.account == server.account else { return }
        deliver(message, files: [], server: server)
    }
    private func deliver(_ message: PendingMessage, files: [StagedFile], server: ServerModel) {
        guard let session = server.session else { return }
        if let i = server.pending.firstIndex(where: { $0.id == message.id }) { server.pending[i].sending = true; server.pending[i].error = nil }
        let isCommand = message.text.hasPrefix("/") && server.snapshot.supports("command")
        Task {
            do {
                let result = try await session.perform(isCommand ? "command" : "message", params: message.params, id: message.id)
                server.pending.removeAll { $0.id == message.id }
                for (index, embed) in result.objects("embeds").enumerated() where index < files.count {
                    guard let address = embed.string("write_url"), let url = URL(string: address) else { continue }
                    try await upload(files[index].url, to: url, server: server)
                }
            } catch {
                if let i = server.pending.firstIndex(where: { $0.id == message.id }) {
                    server.pending[i].sending = false; server.pending[i].error = error.localizedDescription
                } else { server.error = "Attachment upload failed. The server will remove the pending attachment. \(error.localizedDescription)" }
            }
        }
    }
    private func upload(_ file: URL, to url: URL, server: ServerModel) async throws {
        guard let endpoint = URL(string: server.profile.address), MediaPolicy.allows(url, endpoint: endpoint) else {
            throw NSError(domain: "Sidetable", code: 1, userInfo: [NSLocalizedDescriptionKey: "The upload URL is not on this server's trusted origin."])
        }
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 120
        let (_, response) = try await session.upload(for: request, fromFile: file)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
    }
    func perform(_ method: String, params: JSONObject, server: ServerModel, completed: (@MainActor (JSONObject) -> Void)? = nil) {
        guard !preview else { return }
        if server.snapshot.readOnly && ["message", "reactions", "command", "room_set", "room_join", "room_leave"].contains(method) {
            server.error = "This server requires a registered account for that action."; return
        }
        Task {
            do { let result = try await server.session?.perform(method, params: params) ?? [:]; completed?(result) }
            catch { server.error = error.localizedDescription }
        }
    }
    func react(_ emoji: String, message: JSONObject, server: ServerModel) {
        guard let id = message.string("message_id") else { return }
        var set = Set(server.snapshot.store.reactions[RecordKey(id, server.account)]?.strings("emojis") ?? [])
        if set.contains(emoji) { set.remove(emoji) } else { set.insert(emoji) }
        perform("reactions", params: ["message_id": .string(id), "emojis": .array(set.sorted().map(JSONValue.string))], server: server)
    }
    func saveMessage(_ message: JSONObject, text: String? = nil, deleted: Bool = false, destination: String? = nil, server: ServerModel) {
        var params = message.filter { ["message_id", "room_id", "body", "reply_to"].contains($0.key) }
        if let text { var body = params.object("body"); body["text"] = .string(text); params["body"] = .object(body) }
        if deleted { params["deleted"] = .bool(true); params.removeValue(forKey: "body") }
        if let destination { params["room_id"] = .string(destination) }
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
    private func incoming(_ message: JSONObject, server: ServerModel) {
        guard let id = message.string("message_id"), let room = message.string("room_id"), message.object("from").string("user_id") != server.account else { return }
        let visible = selectedServer == server.id && server.attendedRooms.contains(room) && NSApp.isActive
        if !visible { server.unread[room, default: 0] += 1 }
        let mentions = message.object("body").strings("mentions").contains(server.account)
        let reply = message.object("reply_to").string("message_id").flatMap { server.snapshot.store.messages[$0] }?.object("from").string("user_id") == server.account
        let key = "\(server.id)/\(server.account)/\(id)"
        let parent = server.snapshot.store.rooms[room]?.string("parent_room_id") ?? room
        let muted = ["", room, parent].contains { (server.snapshot.mutedUntil[$0] ?? .distantPast) > Date() }
        guard notificationsEnabled, !visible, !muted, mentions || reply, server.snapshot.you.string("status") != "dnd", seenNotifications.insert(key).inserted else { return }
        if seenNotifications.count > 5000 { seenNotifications = [key] }
        let content = UNMutableNotificationContent()
        content.title = "\(server.title(room)) · \(server.profile.title)"
        content.body = "\(server.snapshot.store.displayName(message.object("from"))) sent you a message."
        content.sound = .default
        content.userInfo = ["server": server.id.uuidString, "room": room]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
    func scheduleCache() {
        guard cacheTask == nil else { return }
        cacheTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.cacheTask = nil
            for server in self.servers where server.profile.accountID == server.account && server.snapshot.phase == .ready {
                let store = server.snapshot.store
                let messages = store.joined.flatMap { Array(store.timeline($0).suffix(150)) }
                let view = CachedView(account: server.account, date: Date(), rooms: Array(store.rooms.values), messages: messages, users: Array(store.users.values), joined: Array(store.joined))
                try? self.storage.write(view, to: "cache-\(server.id).json")
            }
        }
    }
    private func restoreCache(_ server: ServerModel) {
        guard let cache = storage.read("cache-\(server.id).json", as: CachedView.self), cache.account == server.profile.accountID,
              Date().timeIntervalSince(cache.date) < 7 * 86400 else { return }
        for room in cache.rooms { server.snapshot.store.installRoom(room) }
        for message in cache.messages { server.snapshot.store.installMessage(message) }
        for user in cache.users { server.snapshot.store.mergeUser(user, complete: true) }
        server.snapshot.store.joined = Set(cache.joined); server.cached = true
        server.selectedRoom = server.rooms.first?.string("room_id")
    }
    private func seedPreview() {
        let server = ServerModel(ServerProfile(address: "wss://studio.example/"))
        server.snapshot.phase = .ready
        server.snapshot.server = ["capabilities": .array(["rooms", "history", "edit", "reactions", "activity", "status", "embed:upload"].map(JSONValue.string))]
        server.snapshot.you = ["user_id": .string("ada"), "name": .string("Ada Lovelace")]
        server.snapshot.store.ownID = "ada"
        for (id, name) in [("ada", "Ada Lovelace"), ("ben", "Ben Carter"), ("maya", "Maya Chen")] {
            server.snapshot.store.mergeUser(["user_id": .string(id), "name": .string(name), "status": .string("online")], complete: true)
        }
        for (id, title, description) in [("general", "General", "A place for the whole team."), ("development", "Development", "Building something thoughtful."), ("design", "Design", "Details make the difference.")] {
            server.snapshot.store.installRoom(["room_id": .string(id), "title": .string(title), "description": .string(description)])
            server.snapshot.store.joined.insert(id); server.snapshot.store.members[id] = ["ada", "ben", "maya"]
        }
        server.snapshot.store.installRoom(["room_id": .string("release"), "title": .string("The first release"), "parent_room_id": .string("general")])
        let samples = [("maya", "Morning, everyone! The first native build is ready to explore."), ("ben", "Love how quiet this feels. Rooms on the left, conversation in the middle — exactly what we need."), ("ada", "A small place for good conversations.\n\nToday’s focus: reliable reconnects, keyboard navigation, and the little details."), ("maya", "I’ve started a thread for the release checklist. Let’s keep feedback there. ✨")]
        for (index, item) in samples.enumerated() {
            let id = String(1_792_348_000_000 + index * 90_000)
            server.snapshot.store.installMessage(["message_id": .string(id), "log_id": .string(id), "room_id": .string("general"), "from": .object(["user_id": .string(item.0)]), "body": .object(["text": .string(item.1), "format": .string("markdown")])])
        }
        server.selectedRoom = "general"; servers = [server]; selectedServer = server.id
    }
}
