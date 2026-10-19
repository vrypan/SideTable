import Foundation

public enum ConnectionPhase: String, Sendable {
    case disconnected = "Disconnected", connecting = "Connecting…", signIn = "Sign in", authenticating = "Signing in…"
    case recovering = "Checking for new messages…", ready = "Connected", reconnecting = "Reconnecting…"
}

public struct SessionSnapshot: Sendable {
    public var phase: ConnectionPhase = .disconnected
    public var server: JSONObject = [:]
    public var you: JSONObject = [:]
    public var store = RecordStore()
    public var error: String?
    public var recoveringRooms: Set<String> = []
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
}

public actor ApronSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    private let output: AsyncStream<SessionEvent>.Continuation
    private let factory: @Sendable () async -> any ChatTransport
    private var transport: (any ChatTransport)?
    private var reader: Task<Void, Never>?
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
        await connect()
    }
    public func stop() async {
        stopped = true; generation = UUID()
        reader?.cancel(); heartbeat?.cancel(); reconnectTask?.cancel()
        await transport?.close(); transport = nil
        failPending(ClientError.disconnected)
        state.phase = .disconnected; publish()
    }
    public func reconnect() async {
        guard Date() >= retryNotBefore else { return }
        await stop(); await start()
    }
    private func connect() async {
        guard !stopped else { return }
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
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
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
        generation = UUID(); reader?.cancel(); heartbeat?.cancel()
        await transport?.close(); transport = nil
        failPending(ClientError.disconnected)
        state.phase = .reconnecting; state.error = reason; publish()
        let backoff = min(60.0, 0.5 * pow(2, Double(min(attempts, 7)))) * Double.random(in: 0.8...1.2)
        let delay = max(backoff, retryNotBefore.timeIntervalSinceNow)
        attempts += 1
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.connect()
        }
    }

    public func request(_ method: String, params: JSONObject = [:], id: String = UUID().uuidString) async throws -> JSONObject {
        guard let transport, !stopped else { throw ClientError.disconnected }
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
                    do { try await transport.send(WireFrame(method: method, id: id, params: params)) }
                    catch { await self?.failRequest(id, epoch: epoch, error: error) }
                }
            }
        } onCancel: { Task { await self.failRequest(id, epoch: epoch, error: CancellationError()) } }
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
                await stop(); state.phase = .signIn; state.error = error.message; publish()
            } else { await lost(epoch: epoch) }
            return
        }
        let params = frame.params ?? [:]
        if frame.method == "server" {
            guard params["apron"]?.number == 8 else {
                await stop(); state.error = ClientError.unsupportedVersion.localizedDescription; publish(); return
            }
            let first = state.server.isEmpty
            state.server = params; configureHeartbeat(params["ping"]?.number); publish()
            if first {
                if let token, params.strings("auth").contains("token") {
                    Task { await self.automaticSignIn(scheme: "token", params: ["token": .string(token)]) }
                } else if let guestName, params.strings("auth").contains("guest") {
                    Task { await self.automaticSignIn(scheme: "guest", params: ["name": .string(guestName)]) }
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
        if let room = params.string("room_id"), roomBuffers[room] != nil {
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

    private func automaticSignIn(scheme: String, params: JSONObject) async {
        do { try await authenticate(scheme: scheme, fields: params) }
        catch { state.phase = .signIn; state.error = error.localizedDescription; publish() }
    }

    public func authenticate(scheme: String, fields: JSONObject) async throws {
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
                state.store = RecordStore(); checkpoints = [:]; historyBounds = [:]
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
                for room in prior.subtracting(state.store.joined) { state.store.clearRoom(room); checkpoints[room] = nil }
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
        guard state.you.isEmpty else { throw ClientError.notReady }
        _ = try await request("auth", params: ["scheme": .string("email"), "email": .string(email), "agent": .string("sidetable/0.1")])
    }

    public func loadRoom(_ room: String) async throws {
        guard state.phase == .ready, !state.recoveringRooms.contains(room) else { return }
        let epoch = generation
        if state.supports("rooms") {
            let result = try await request("room_list", params: ["room_id": .string(room), "members": .bool(true)])
            guard epoch == generation else { throw ClientError.disconnected }
            state.store.applyListing(result)
            let threads = try await request("room_list", params: ["parent_room_id": .string(room)])
            guard epoch == generation else { throw ClientError.disconnected }
            state.store.applyListing(threads)
        }
        if state.supports("history") { try await recover(room, epoch: epoch) }
        publish()
    }

    private func recover(_ room: String, epoch: UUID) async throws {
        state.recoveringRooms.insert(room); roomBuffers[room] = []; publish()
        defer { state.recoveringRooms.remove(room); roomBuffers[room] = nil }
        var cursor = RecoveryCursor(checkpoint: checkpoints[room])
        cursor.lowerBound = historyBounds[room] ?? 0
        // Without a checkpoint the first request must page forwards from the start.
        if cursor.next == nil { cursor.next = 1 }
        var restarts = 0
        while true {
            var params = cursor.params
            if !room.isEmpty { params["room_id"] = .string(room) }
            let page = try await request("history", params: params)
            guard epoch == generation else { throw ClientError.disconnected }
            if try cursor.inspect(page) {
                let members = state.store.members[room]
                let baseline = state.store.membershipBaselines[room]
                let objects = state.store.memberObjects.filter { $0.key.first == room }
                state.store.clearRoom(room); checkpoints[room] = nil
                state.store.members[room] = members; state.store.membershipBaselines[room] = baseline
                state.store.memberObjects.merge(objects) { _, new in new }
                historyBounds[room] = cursor.lowerBound
                restarts += 1; guard restarts <= 8 else { throw ClientError.invalidHistory }
                continue
            }
            state.store.applyHistory(page)
            historyBounds[room] = cursor.lowerBound
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
            if try !cursor.advance(page) { break }
        }
        checkpoints[room] = cursor.head
        for frame in roomBuffers[room] ?? [] { applyLive(frame, notify: false) }
    }

    public func perform(_ method: String, params: JSONObject, id: String = UUID().uuidString) async throws -> JSONObject {
        guard state.phase == .ready else { throw ClientError.notReady }
        let result = try await request(method, params: params, id: id)
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
