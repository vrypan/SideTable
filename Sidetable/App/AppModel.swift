import ApronCore
import AppKit
import Observation
import UserNotifications

@MainActor @Observable
final class ServerModel: Identifiable {
    let id: UUID
    var profile: ServerProfile
    var snapshot = SessionSnapshot()
    var selectedRoom: String?
    let uploads = UploadCoordinator()
    let avatars = AvatarCache()
    var pending: [PendingMessage] { uploads.messages }
    var unread: [String: Int] = [:]
    var files: [String: [StagedFile]] = [:]
    var error: String?
    var busy = false
    var emailPending = false
    var cached = false
    @ObservationIgnored var authenticationOperation = UUID()
    @ObservationIgnored var connectedAccount: String?
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
    let attention = ConversationAttention()
    var cacheUsage: [UUID: Int64] = [:]
    var cacheError: String?
    var notificationsEnabled = false
    var messageSize = 14.0
    @ObservationIgnored let storage: LocalStorage
    @ObservationIgnored private var connectionAvailable = true
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var seenNotifications: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cacheSuppressedServers: Set<UUID> = []
    @ObservationIgnored private var cacheGeneration = UUID()
    @ObservationIgnored private let cacheDelay: Duration
    @ObservationIgnored private var cacheTask: Task<Void, Never>?

    init(storage: LocalStorage = LocalStorage(), preview: Bool = false, cacheDelay: Duration = .seconds(3)) {
        self.storage = storage; self.preview = preview; self.cacheDelay = cacheDelay
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        messageSize = UserDefaults.standard.object(forKey: "messageSize") as? Double ?? 14
        if preview { seedPreview(); return }
        drafts = storage.read("drafts-v1.json", as: [DraftKey: SavedDraft].self) ?? [:]
        readMarkers = storage.read("read-markers-v1.json", as: [DraftKey: String].self) ?? [:]
        servers = (storage.read("servers-v1.json", as: [ServerProfile].self) ?? []).map(ServerModel.init)
        selectedServer = servers.first?.id
        for server in servers { restoreCache(server); connect(server) }
        refreshCacheUsage()
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
    func updateAttention(_ view: UUID, server: ServerModel, room: String, readingLatest: Bool) {
        let eligible = readingLatest && !server.cached && server.snapshot.phase == .ready
        attention.update(view, key: key(server, room), readingLatest: eligible)
        if eligible, let last = server.snapshot.store.timeline(room).last?.string("message_id") {
            markRead(last, server: server, room: room)
        }
    }
    func markRead(_ message: String, server: ServerModel, room: String) {
        let key = key(server, room)
        guard !server.cached, server.snapshot.phase == .ready, attention.contains(key) else { return }
        server.unread[room] = 0
        if let old = readMarkers[key], (UInt64(old) ?? 0) >= (UInt64(message) ?? 0) { return }
        readMarkers[key] = message; saveDrafts()
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
        if let existing = servers.first(where: { $0.profile.address == url.absoluteString }) { selectedServer = existing.id; return }
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
        let token = useToken ? server.profile.accountID.flatMap { CredentialVault.read(endpoint: server.profile.address, account: $0) } : nil
        let old = server.session
        server.authenticationOperation = UUID(); server.busy = false; server.emailPending = false
        server.listener?.cancel()
        let session = ApronSession(url: url, token: token)
        server.session = session
        server.listener = Task { [weak self, weak server] in
            await old?.stop()
            guard !Task.isCancelled else { await session.stop(); return }
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
                            server.uploads.reset(); server.avatars.reset(); self.attention.remove(server: server.id); server.files = [:]; server.loadedRooms = []; server.unread = [:]
                        }
                        server.connectedAccount = new
                    }
                    if server.emailPending && [.reconnecting, .suspended, .disconnected].contains(value.phase) { server.emailPending = false }
                    if server.cached && value.you.isEmpty && [.connecting, .signIn, .authenticating, .reconnecting, .suspended].contains(value.phase) {
                        server.snapshot.phase = value.phase; server.snapshot.server = value.server; server.snapshot.error = value.error
                    } else {
                        server.cached = false; server.snapshot = value
                        server.uploads.reconcile(value.store)
                    }
                    if value.phase == .ready {
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
                        self.scheduleCache()
                    }
                    if value.phase == .reconnecting { server.loadedRooms = [] }
                case .token(let token, let account):
                    do {
                        try CredentialVault.save(token, endpoint: server.profile.address, account: account)
                        server.profile.accountID = account; self.saveProfiles()
                    } catch { server.error = "Could not save the session in Keychain: \(error.localizedDescription)" }
                case .avatarChanged(let source): server.avatars.invalidate(source: source)
                case .incoming(let message): self.incoming(message, server: server)
                }
            }
        }
    }
    func selectRoom(_ room: String, server: ServerModel, asThread: Bool = false) {
        if asThread { thread = room; showMembers = false }
        else { server.selectedRoom = room; thread = nil }
        guard !preview, !server.loadedRooms.contains(room) else { return }
        server.loadedRooms.insert(room)
        Task {
            do { try await server.session?.loadRoom(room) }
            catch { server.loadedRooms.remove(room); server.error = error.localizedDescription }
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
                guard server.authenticationOperation == operation else { return }
                server.emailPending = false
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
                guard server.authenticationOperation == operation else { return }
                server.emailPending = true
            } catch {
                guard server.authenticationOperation == operation else { return }
                server.error = error.localizedDescription
            }
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
        do { try storage.removeConversationCache(server.id); refreshCacheUsage() }
        catch { globalError = "Could not clear saved conversations: \(error.localizedDescription)" }
        server.connectedAccount = nil; server.profile.accountID = nil; server.snapshot = SessionSnapshot(); server.uploads.reset(); server.avatars.reset(); self.attention.remove(server: server.id); server.files = [:]
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
        let message = PendingMessage(id: UUID().uuidString, room: room, account: server.account, params: params, text: draft.text, files: files, isCommand: draft.text.hasPrefix("/") && server.snapshot.supports("command"))
        server.uploads.messages.append(message)
        setDraft(SavedDraft(), server: server, room: room); server.files[room] = []
        deliver(message, server: server)
    }
    func retry(_ message: PendingMessage, server: ServerModel) {
        guard message.account == server.account, server.snapshot.phase == .ready, !server.snapshot.readOnly else { return }
        deliver(message, server: server)
    }
    private func deliver(_ message: PendingMessage, server: ServerModel) {
        guard let session = server.session, let endpoint = URL(string: server.profile.address) else { return }
        server.uploads.submit(message, endpoint: endpoint) { method, params, id in
            try await session.perform(method, params: params, id: id)
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
    func incoming(_ message: JSONObject, server: ServerModel) {
        guard let id = message.string("message_id"), let room = message.string("room_id"), message.object("from").string("user_id") != server.account else { return }
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
        content.title = "\(server.title(room)) · \(server.profile.title)"
        content.body = "\(server.snapshot.store.displayName(message.object("from"))) sent you a message."
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
            self.cacheTask = nil
            self.writeConversationCaches()
        }
    }
    func writeConversationCaches() {
        guard !preview else { return }
        for server in servers where !cacheSuppressedServers.contains(server.id)
            && server.profile.accountID == server.account && server.snapshot.phase == .ready {
            let store = server.snapshot.store
            let messages = store.joined.flatMap { Array(store.timeline($0).suffix(150)) }
            let view = CachedView(account: server.account, date: Date(), rooms: Array(store.rooms.values), messages: messages, users: Array(store.users.values), joined: Array(store.joined))
            do { try storage.write(view, to: "cache-\(server.id).json") }
            catch { cacheError = "Could not save recent conversations: \(error.localizedDescription)" }
        }
        refreshCacheUsage()
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
        let samples = [("maya", "Morning, everyone! The first native build is ready to explore."), ("ben", "Love how quiet this feels. Rooms on the left, conversation in the middle — exactly what we need."), ("ada", "A small place for good conversations.\n\nToday’s focus: reliable reconnects, keyboard navigation, and the little details."), ("maya", "I’ve started a thread for the release checklist. Let’s keep feedback there. ✨")]
        for (index, item) in samples.enumerated() {
            let id = String(1_792_348_000_000 + index * 90_000)
            server.snapshot.store.installMessage(["message_id": .string(id), "log_id": .string(id), "room_id": .string("general"), "from": .object(["user_id": .string(item.0)]), "body": .object(["text": .string(item.1), "format": .string("markdown")])])
        }
        server.snapshot.store.installMessage(["message_id": .string("1792348500000"), "log_id": .string("1792348500000"),
            "room_id": .string("development"), "from": .object(["user_id": .string("ada")]),
            "body": .object(["format": .string("markdown"), "text": .string("""
            ## A readable conversation

            **Native Markdown**, *emphasis*, and [safe links](https://example.com). Καλημέρα 👋

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
        servers = [server]; selectedServer = server.id
    }
}
