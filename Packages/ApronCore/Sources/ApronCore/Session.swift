import Foundation

public enum ConnectionPhase: String, Sendable {
    case disconnected = "Disconnected", connecting = "Connecting…", signIn = "Sign in", authenticating = "Signing in…"
    case suspended = "Waiting for connection…"
    case recovering = "Checking for new messages…", ready = "Connected", reconnecting = "Reconnecting…"
}

public struct SessionSnapshot: Sendable {
    public var phase: ConnectionPhase = .disconnected
    public var server: JSONObject = [:]
    public var you: JSONObject = [:]
    public var store = RecordStore()
    public var error: String?
    public var recoveringRooms: Set<String> = []
    public var history: [String: RoomHistory] = [:]
    public func historyKey(_ room: String) -> String { supports("rooms") ? room : "" }
    public func roomHistory(_ room: String) -> RoomHistory? { history[historyKey(room)] }
    public var typing: [String: [String: Date]] = [:]
    public var isGuest = false
    public var mutedUntil: [String: Date] = [:]
    public init() {}
    public func supports(_ feature: String) -> Bool { server.strings("capabilities").contains(feature) }
    public var readOnly: Bool {
        supports("ext:settings") && server.object("ext").object("settings")["guest_posting"] == .bool(false)
        && isGuest
    }
}

public enum SessionEvent: Sendable {
    case snapshot(SessionSnapshot)
    case token(String, String)
    case incoming(JSONObject)
    case avatarChanged(String)
}

public actor ApronSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    private let output: AsyncStream<SessionEvent>.Continuation
    private let factory: @Sendable () async -> any ChatTransport
    private var transport: (any ChatTransport)?
    private var reader: Task<Void, Never>?
    private var announcement: Task<Void, Never>?
    private var connectionAvailable = true
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = true
    private var state = SessionSnapshot()
    private var pending: [String: CheckedContinuation<JSONObject, any Error>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var token: String?
    private var guestName: String?
    private var attempts = 0
    private var awaitingPong = false
    private var checkpoints: [String: UInt64] = [:]
    private var roomEpochs: [String: UUID] = [:]
    private var historyBounds: [String: UInt64] = [:]
    private var buffered: [WireFrame] = []
    private var bootstrap = false
    private var roomBuffers: [String: [WireFrame]] = [:]
    private var retryNotBefore = Date.distantPast
    private let requestTimeout: Duration

    public init(url: URL, token: String? = nil, requestTimeout: Duration = .seconds(20)) {
        let stream = AsyncStream<SessionEvent>.makeStream()
        events = stream.stream; output = stream.continuation
        self.token = token; self.requestTimeout = requestTimeout
        factory = { WebSocketTransport(url: url) }
    }

    public init(transportFactory: @escaping @Sendable () async -> any ChatTransport, requestTimeout: Duration = .seconds(20)) {
        let stream = AsyncStream<SessionEvent>.makeStream()
        events = stream.stream; output = stream.continuation
        factory = transportFactory; self.requestTimeout = requestTimeout
    }

    public func snapshot() -> SessionSnapshot { state }
    private func publish() { output.yield(.snapshot(state)) }

    public func start() async {
        guard stopped else { return }
        stopped = false
        resumeWhenAvailable()
    }
    public func stop() async {
        stopped = true
        let old = invalidateConnection()
        state.phase = .disconnected; publish()
        await old?.close()
    }
    public func reconnect() async {
        // Explicit reconnect may restart a stopped session, but cannot bypass retry_after.
        let old = invalidateConnection()
        stopped = false
        resumeWhenAvailable()
        await old?.close()
    }
    public func setConnectionAvailable(_ available: Bool) async {
        guard connectionAvailable != available else { return }
        connectionAvailable = available
        if available {
            if !stopped { resumeWhenAvailable() }
        } else {
            let old = invalidateConnection()
            if !stopped { state.phase = .suspended; publish() }
            await old?.close()
        }
    }

    /// Detach all state before awaiting transport shutdown: closing an old socket
    /// must never clear tasks, requests, or state belonging to a newer connection.
    private func invalidateConnection() -> (any ChatTransport)? {
        generation = UUID()
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        announcement?.cancel(); announcement = nil
        reconnectTask?.cancel(); reconnectTask = nil
        let old = transport; transport = nil
        failPending(ClientError.disconnected)
        buffered = []; roomBuffers = [:]; bootstrap = false
        for room in state.history.keys { state.history[room]?.isLoading = false }
        state.recoveringRooms = []; state.typing = [:]; awaitingPong = false
        return old
    }
    private func resumeWhenAvailable() {
        guard connectionAvailable else { state.phase = .suspended; publish(); return }
        state.phase = .reconnecting; publish()
        scheduleConnection(after: max(0, retryNotBefore.timeIntervalSinceNow))
    }
    private func scheduleConnection(after delay: Double) {
        reconnectTask?.cancel()
        let epoch = generation
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.connect(ifCurrent: epoch)
        }
    }
    private func connect(ifCurrent epoch: UUID) async {
        guard epoch == generation, !Task.isCancelled else { return }
        await connect()
    }
    private func connect() async {
        guard !stopped, connectionAvailable else { return }
        let epoch = UUID(); generation = epoch
        state.phase = attempts == 0 ? .connecting : .reconnecting
        state.server = [:]; state.error = nil; state.recoveringRooms = []
        buffered = []; roomBuffers = [:]; bootstrap = false
        publish()
        let socket = await factory()
        guard epoch == generation, !stopped else { await socket.close(); return }
        transport = socket
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    await self?.receive(frame, epoch: epoch)
                }
            } catch { await self?.lost(epoch: epoch, reason: error.localizedDescription) }
        }
        announcement = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await self?.checkAnnouncement(epoch)
        }
    }
    private func checkAnnouncement(_ epoch: UUID) async {
        if epoch == generation && state.server.isEmpty { await lost(epoch: epoch) }
    }
    private func failPending(_ error: any Error) {
        let waiting = pending; pending.removeAll()
        for timer in timers.values { timer.cancel() }; timers.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
    private func lost(epoch: UUID, reason: String? = nil) async {
        guard epoch == generation, !stopped else { return }
        let old = invalidateConnection()
        state.phase = .reconnecting; state.error = reason; publish()
        let backoff = min(60.0, 0.5 * pow(2, Double(min(attempts, 7)))) * Double.random(in: 0.8...1.2)
        let delay = max(backoff, retryNotBefore.timeIntervalSinceNow)
        attempts += 1
        scheduleConnection(after: delay)
        await old?.close()
    }

    public func request(_ method: String, params: JSONObject = [:], id: String = UUID().uuidString) async throws -> JSONObject {
        try Task.checkCancellation()
        guard transport != nil, !stopped else { throw ClientError.disconnected }
        guard pending[id] == nil else { throw ClientError.notReady }
        let epoch = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                let timeout = requestTimeout
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id, epoch: epoch)
                }
                Task { [weak self] in
                    do { try await self?.sendRequest(WireFrame(method: method, id: id, params: params), epoch: epoch) }
                    catch { await self?.failRequest(id, epoch: epoch, error: error) }
                }
            }
        } onCancel: { Task { await self.failRequest(id, epoch: epoch, error: CancellationError()) } }
    }
    private func sendRequest(_ frame: WireFrame, epoch: UUID) async throws {
        guard epoch == generation, let id = frame.id, pending[id] != nil, let transport else { return }
        try await transport.send(frame)
    }
    private func expire(_ id: String, epoch: UUID) { failRequest(id, epoch: epoch, error: ClientError.timeout) }
    private func failRequest(_ id: String, epoch: UUID, error: any Error) {
        guard generation == epoch else { return }
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receive(_ frame: WireFrame, epoch: UUID) async {
        guard generation == epoch, !stopped else { return }
        if let id = frame.id {
            timers.removeValue(forKey: id)?.cancel()
            if let error = frame.error { pending.removeValue(forKey: id)?.resume(throwing: error) }
            else { pending.removeValue(forKey: id)?.resume(returning: frame.result ?? [:]) }
            return
        }
        if let error = frame.error {
            if let delay = error.retryAfter { retryNotBefore = Date().addingTimeInterval(max(0, delay)) }
            if error.code == -32001 {
                stopped = true
                let old = invalidateConnection()
                state.phase = .disconnected; state.error = error.message; publish()
                await old?.close()
            } else { await lost(epoch: epoch) }
            return
        }
        let params = frame.params ?? [:]
        if frame.method == "server" {
            guard params["apron"]?.number == 8 else {
                stopped = true
                let old = invalidateConnection()
                state.phase = .disconnected; state.error = ClientError.unsupportedVersion.localizedDescription; publish()
                await old?.close(); return
            }
            announcement?.cancel(); announcement = nil
            let first = state.server.isEmpty
            state.server = params; configureHeartbeat(params["ping"]?.number); publish()
            if first {
                if let token, params.strings("auth").contains("token") {
                    Task { await self.automaticSignIn(scheme: "token", params: ["token": .string(token)], epoch: epoch) }
                } else if let guestName, params.strings("auth").contains("guest") {
                    Task { await self.automaticSignIn(scheme: "guest", params: ["name": .string(guestName)], epoch: epoch) }
                } else { state.phase = .signIn; publish() }
            }
            return
        }
        if frame.method == "pong" { awaitingPong = false; return }
        if frame.method == "activity" {
            if let room = params.string("room_id"), let user = params.object("from").string("user_id") {
                let seconds = min(60, max(0, params["typing"]?.number ?? 0))
                state.typing[room, default: [:]][user] = Date().addingTimeInterval(seconds); publish()
            }
            return
        }
        if bootstrap {
            buffered.append(frame)
            if buffered.count > 10_000 { await lost(epoch: epoch) }
            return
        }
        if let id = params.string("room_id"), roomBuffers[state.historyKey(id)] != nil {
            let room = state.historyKey(id)
            roomBuffers[room, default: []].append(frame)
            if roomBuffers[room]!.count > 10_000 { await lost(epoch: epoch) }
            return
        }
        applyLive(frame)
        publish()
    }

    private func applyLive(_ frame: WireFrame, notify: Bool = true) {
        let p = frame.params ?? [:]
        if frame.method == "status", let mute = p["mute"] {
            let scope = p.string("room_id") ?? ""
            if mute == .bool(true) { state.mutedUntil[scope] = .distantFuture }
            else if let seconds = mute.number { state.mutedUntil[scope] = Date().addingTimeInterval(max(0, seconds)) }
            else if mute == .bool(false) { state.mutedUntil[scope] = nil }
        }
        if frame.method == "user", let id = p.object("you").string("user_id") {
            state.you = state.you.merging(p.object("you")) { _, new in new }
            state.store.ownID = id
        }
        let isNew = p.string("message_id").map { state.store.messages[$0] == nil } ?? false
        state.store.apply(frame)
        if frame.method == "room_update" {
            for record in p.objects("left") {
                if let room = record.string("room_id") {
                    clearHistoryRoom(room); roomEpochs[room] = UUID(); roomBuffers[room] = nil
                }
            }
        }
        if frame.method == "user" {
            // An explicit avatar patch may replace the bytes at an unchanged URL.
            let sources = [p.object("you").string("avatar"), p.object("new").string("avatar")]
            for source in Set(sources.compactMap { $0 }).filter({ !$0.isEmpty }) {
                output.yield(.avatarChanged(source))
            }
        }
        if frame.method == "message", let room = p.string("room_id") {
            if let user = p.object("from").string("user_id") { state.typing[room]?[user] = nil }
            if !state.supports("rooms"), state.store.rooms[room] == nil {
                if !room.isEmpty { state.store.rooms.removeValue(forKey: ""); state.store.joined.remove("") }
                state.store.rooms[room] = ["room_id": .string(room), "title": .string(room)]
                state.store.joined.insert(room)
            }
            if notify, isNew, !p.bool("deleted"), p.string("message_id") == p.string("log_id"),
               p.object("from").string("user_id") != "~private" { output.yield(.incoming(p)) }
        }
    }

    private func automaticSignIn(scheme: String, params: JSONObject, epoch: UUID) async {
        guard epoch == generation, !stopped else { return }
        // authenticate owns errors only for its generation. A stale failure is inert.
        try? await authenticate(scheme: scheme, fields: params)
    }

    public func authenticate(scheme: String, fields: JSONObject) async throws {
        guard !stopped, connectionAvailable, state.phase == .signIn || state.phase == .connecting || state.phase == .reconnecting else { throw ClientError.notReady }
        guard state.server.strings("auth").contains(scheme) || state.server.strings("signup").contains(scheme) else { throw ClientError.notReady }
        let epoch = generation
        state.phase = .authenticating; state.error = nil; bootstrap = true; buffered = []; publish()
        var params = fields; params["scheme"] = .string(scheme); params["agent"] = .string("sidetable/0.1")
        do {
            let response = try await request("auth", params: params)
            guard epoch == generation else { throw ClientError.disconnected }
            guard let user = response.object("you").string("user_id") else {
                bootstrap = false; state.phase = .signIn; publish(); return
            }
            if user != state.you.string("user_id") {
                state.store = RecordStore(); checkpoints = [:]; historyBounds = [:]; state.history = [:]; roomEpochs = [:]
            }
            state.mutedUntil = [:]
            for id in state.store.users.keys { state.store.users[id]?.removeValue(forKey: "status") }
            state.you = response.object("you")
            state.isGuest = scheme == "guest"
            state.store.ownID = user
            state.store.mergeUser(state.you, complete: true, own: true)
            if let newToken = response.string("token") { token = newToken; output.yield(.token(newToken, user)) }
            else if scheme == "token", let acceptedToken = fields.string("token") {
                token = acceptedToken; output.yield(.token(acceptedToken, user))
            }
            if scheme == "guest" { guestName = fields.string("name") ?? "" }
            state.phase = .recovering; publish()
            if state.supports("rooms") {
                let listing = try await request("room_list", params: ["filter": .string("joined"), "members": .bool(true)])
                guard epoch == generation else { throw ClientError.disconnected }
                let prior = state.store.joined
                state.store.applyListing(listing, full: true)
                for room in prior.subtracting(state.store.joined) { clearHistoryRoom(room); roomEpochs[room] = UUID() }
                if state.supports("history") {
                    for room in state.store.joined.sorted() where state.store.rooms[room]?.string("parent_room_id") == nil {
                        try await recover(room, epoch: epoch)
                    }
                }
            } else if state.supports("history") { try await recover("", epoch: epoch) }
            if state.store.rooms.isEmpty && !state.supports("rooms") {
                state.store.rooms[""] = ["room_id": .string(""), "title": .string("Conversation")]
                state.store.joined.insert("")
            }
            guard epoch == generation else { throw ClientError.disconnected }
            for frame in buffered { applyLive(frame, notify: false) }
            buffered = []; bootstrap = false; attempts = 0
            state.phase = .ready; state.error = nil; publish()
        } catch {
            if epoch == generation {
                bootstrap = false; buffered = []; state.phase = .signIn; state.error = error.localizedDescription; publish()
            }
            throw error
        }
    }

    public func requestEmail(_ email: String) async throws {
        guard state.you.isEmpty, state.phase == .signIn else { throw ClientError.notReady }
        let epoch = generation
        _ = try await request("auth", params: ["scheme": .string("email"), "email": .string(email), "agent": .string("sidetable/0.1")])
        guard epoch == generation else { throw ClientError.disconnected }
    }

    public func loadRoom(_ room: String) async throws {
        let key = state.historyKey(room)
        guard state.phase == .ready, !state.recoveringRooms.contains(key), state.history[key]?.isLoading != true else { return }
        let epoch = generation, roomEpoch = roomEpochs[key]
        state.recoveringRooms.insert(key); publish()
        defer {
            if epoch == generation, roomEpoch == roomEpochs[key] {
                state.recoveringRooms.remove(key); publish()
            }
        }
        if state.supports("rooms") {
            let result = try await request("room_list", params: ["room_id": .string(room), "members": .bool(true)])
            try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch, requireHistory: false)
            state.store.applyListing(result)
            let threads = try await request("room_list", params: ["parent_room_id": .string(room)])
            try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch, requireHistory: false)
            state.store.applyListing(threads)
        }
        if state.supports("history") { try await recover(key, epoch: epoch) }
    }

    public func loadOlderHistory(_ room: String) async throws {
        let key = state.historyKey(room)
        guard state.phase == .ready, state.supports("history"),
              !state.recoveringRooms.contains(key), var history = state.history[key],
              !history.isLoading, let before = history.before else { return }
        let epoch = generation, roomEpoch = roomEpochs[key]
        history.isLoading = true; history.error = nil; state.history[key] = history; publish()
        defer {
            if epoch == generation, roomEpoch == roomEpochs[key] {
                state.history[key]?.isLoading = false
                state.history[key]?.completionID = UUID(); publish()
            }
        }
        do {
            if checkpoints[key] == nil {
                try await recover(key, epoch: epoch)
                return
            }
            var params: JSONObject = ["limit": .number(200), "before": .string(String(before))]
            if !key.isEmpty { params["room_id"] = .string(key) }
            let page = try await request("history", params: params)
            try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch)
            let bounds = try BackwardHistoryPage(page, before: before)
            if bounds.lowerBound > (historyBounds[key] ?? bounds.lowerBound) {
                // Retention may have removed a deletion/move needed by an older
                // snapshot. Rebuild a recent window before exposing more history.
                clearHistoryRoom(key)
                try await recover(key, epoch: epoch)
            } else {
                applyHistoryPage(page, room: key)
                state.history[key]?.before = bounds.nextBefore
            }
        } catch {
            if epoch == generation, roomEpoch == roomEpochs[key] {
                if state.history[key] == nil { state.history[key] = history }
                state.history[key]?.error = error.localizedDescription
            }
            throw error
        }
    }

    private func checkHistoryOperation(_ room: String, epoch: UUID, roomEpoch: UUID?, requireHistory: Bool = true) throws {
        guard (!requireHistory || state.supports("history")), epoch == generation, roomEpoch == roomEpochs[room] else { throw ClientError.disconnected }
    }

    private func clearHistoryRoom(_ room: String) {
        let rooms = room.isEmpty && !state.supports("rooms")
            ? Set(state.store.messages.values.compactMap { $0.string("room_id") }).union([room]) : [room]
        for id in rooms {
            let members = state.store.members[id], baseline = state.store.membershipBaselines[id]
            let objects = state.store.memberObjects.filter { $0.key.first == id }
            state.store.clearRoom(id)
            state.store.members[id] = members; state.store.membershipBaselines[id] = baseline
            state.store.memberObjects.merge(objects) { _, new in new }
        }
        checkpoints[room] = nil; historyBounds[room] = nil; state.history[room] = nil
        state.recoveringRooms.remove(room)
    }

    private func applyHistoryPage(_ page: JSONObject, room: String) {
        state.store.applyHistory(page)
        if !room.isEmpty {
            var record = state.store.rooms[room] ?? ["room_id": .string(room)]
            record["latest_log_id"] = page["latest_log_id"]; record["history_log_id"] = page["history_log_id"]
            state.store.rooms[room] = record
        } else {
            for id in Set(page.objects("messages").compactMap { $0.string("room_id") }) {
                state.store.joined.insert(id)
                if state.store.rooms[id] == nil { state.store.rooms[id] = ["room_id": .string(id), "title": .string(id)] }
            }
        }
    }

    private func recover(_ room: String, epoch: UUID) async throws {
        let roomEpoch = roomEpochs[room]
        state.recoveringRooms.insert(room); roomBuffers[room] = []; publish()
        defer {
            if epoch == generation, roomEpoch == roomEpochs[room] {
                // Even a failed history request must not discard live events.
                for frame in roomBuffers[room] ?? [] { applyLive(frame, notify: false) }
                state.recoveringRooms.remove(room); roomBuffers[room] = nil
            }
        }
        if checkpoints[room] == nil {
            try await loadRecentHistory(room, epoch: epoch, roomEpoch: roomEpoch)
            return
        }
        var cursor = RecoveryCursor(checkpoint: checkpoints[room])
        cursor.lowerBound = historyBounds[room] ?? 0
        while true {
            var params = cursor.params
            if !room.isEmpty { params["room_id"] = .string(room) }
            let page = try await request("history", params: params)
            try checkHistoryOperation(room, epoch: epoch, roomEpoch: roomEpoch)
            if try cursor.inspect(page) {
                clearHistoryRoom(room)
                state.recoveringRooms.insert(room)
                try await loadRecentHistory(room, epoch: epoch, roomEpoch: roomEpoch)
                return
            }
            applyHistoryPage(page, room: room)
            historyBounds[room] = cursor.lowerBound
            if try !cursor.advance(page) { break }
        }
        checkpoints[room] = cursor.head
        // An advancing retention bound can make the older cursor obsolete.
        if let before = state.history[room]?.before, before < cursor.lowerBound { state.history[room]?.before = nil }
    }

    private func loadRecentHistory(_ room: String, epoch: UUID, roomEpoch: UUID?) async throws {
        var params: JSONObject = ["limit": .number(200)]
        if !room.isEmpty { params["room_id"] = .string(room) }
        let page = try await request("history", params: params)
        try checkHistoryOperation(room, epoch: epoch, roomEpoch: roomEpoch)
        let bounds = try BackwardHistoryPage(page)
        applyHistoryPage(page, room: room)
        historyBounds[room] = bounds.lowerBound
        state.history[room] = RoomHistory(before: bounds.nextBefore)
        checkpoints[room] = bounds.head
    }

    public func perform(_ method: String, params: JSONObject, id: String = UUID().uuidString) async throws -> JSONObject {
        guard state.phase == .ready else { throw ClientError.notReady }
        let epoch = generation
        let result = try await request(method, params: params, id: id)
        guard epoch == generation else { throw ClientError.disconnected }
        if method == "me", !result.object("you").isEmpty {
            state.you = result.object("you"); state.store.mergeUser(state.you, complete: true, own: true); publish()
        }
        return result
    }
    public func activity(room: String, fields: JSONObject) async {
        guard state.phase == .ready, state.supports("activity") else { return }
        var params = fields; if !room.isEmpty { params["room_id"] = .string(room) }
        try? await transport?.send(WireFrame(method: "activity", params: params))
    }
    private func configureHeartbeat(_ seconds: Double?) {
        heartbeat?.cancel(); awaitingPong = false
        guard let seconds, seconds >= 1 else { return }
        let epoch = generation
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                await self?.ping(epoch)
            }
        }
    }
    private func ping(_ epoch: UUID) async {
        guard epoch == generation else { return }
        if awaitingPong { await lost(epoch: epoch); return }
        awaitingPong = true
        do { try await transport?.send(WireFrame(method: "ping")) } catch { await lost(epoch: epoch) }
    }
}
