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
    public var requestCooldowns: [RequestCooldown] = []
    public func cooldown(for method: String, hasUploads: Bool = false, now: Date = Date()) -> RequestCooldown? {
        requestCooldowns.filter { $0.retryAt > now && $0.matches(method: method, hasUploads: hasUploads) }.max { $0.retryAt < $1.retryAt }
    }
    public var roomListingRetryAt: Date?
    public var pendingSignIn: String?
    public var recoveringRooms: Set<String> = []
    public var history: [String: RoomHistory] = [:]
    public func historyKey(_ room: String) -> String { supports("rooms") ? room : "" }
    public func roomHistory(_ room: String) -> RoomHistory? { history[historyKey(room)] }
    public var isGuest = false
    public var mutedUntil: [String: Date] = [:]
    public init() {}
    public func supports(_ feature: String) -> Bool { server.strings("capabilities").contains(feature) }
    public func canAddMembers(to room: String) -> Bool {
        !readOnly && (supports("ext:permissions") && you.object("ext").object("permissions")["add_members"] == .bool(true)
            || store.joined.contains(room) && store.rooms[room]?.bool("private") == true)
    }
    public func canMove(_ message: JSONObject) -> Bool {
        !readOnly && ((you.string("user_id") != nil && message.object("from").string("user_id") == you.string("user_id"))
            || supports("ext:permissions") && you.object("ext").object("permissions")["move_any"] == .bool(true))
    }
    public var privateRoomLimitReached: Bool {
        guard supports("ext:settings"), let limit = server.object("ext").object("settings")["private_rooms"]?.number,
              limit.isFinite, limit >= 0 else { return false }
        return Double(store.joined.filter { store.rooms[$0]?.bool("private") == true && store.rooms[$0]?.string("parent_room_id") == nil }.count) >= limit
    }
    public var mediaOrigins: [String] { supports("ext:media") ? server.object("ext").object("media").strings("origins") : [] }
    public var readOnly: Bool {
        if supports("ext:permissions") { return you.object("ext").object("permissions")["write"] == .bool(false) }
        // Keep compatibility with older v8/v9 servers predating ext:permissions.
        return supports("ext:settings") && server.object("ext").object("settings")["guest_posting"] == .bool(false) && isGuest
    }
}

public enum SessionEvent: Sendable {
    case snapshot(SessionSnapshot)
    case token(String, String)
    case incoming(JSONObject)
    case avatarChanged(String)
}

/// Lossless discrete events with replaceable steady-state snapshots. Keep the
/// first snapshot of each phase/account boundary: consumers use it to reconcile
/// unread counts and account state before processing subsequent incoming events.
/// Thereafter only the latest queued snapshot in that phase is retained. Moving
/// it to the queue tail keeps discrete events ordered before their resulting state.
final class SessionEventBuffer: @unchecked Sendable {
    private final class Node {
        let event: SessionEvent
        var next: Node?
        weak var previous: Node?
        init(_ event: SessionEvent) { self.event = event }
    }
    private struct Context: Equatable {
        let phase: ConnectionPhase
        let account: String?
    }
    private let lock = NSLock()
    private var head: Node?
    private var tail: Node?
    private var replaceable: Node?
    private var context: Context?
    private var waiter: CheckedContinuation<SessionEvent?, Never>?
    private var cancelled = false

    deinit { cancel() }

    func yield(_ event: SessionEvent) {
        lock.withLock {
            guard !cancelled else { return }
            let node = Node(event)
            if case .snapshot(let snapshot) = event {
                let nextContext = Context(phase: snapshot.phase, account: snapshot.you.string("user_id"))
                if context == nextContext {
                    if let replaceable { remove(replaceable) }
                    replaceable = node
                } else {
                    // Freeze the transition snapshot, even if no consumer is ready.
                    context = nextContext
                    replaceable = nil
                }
            }
            node.previous = tail
            if let tail { tail.next = node } else { head = node }
            tail = node
            if let waiter, let head {
                self.waiter = nil
                remove(head)
                waiter.resume(returning: head.event)
            }
        }
    }

    func next() async -> SessionEvent? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let head {
                    remove(head)
                    continuation.resume(returning: head.event)
                } else if cancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            while let head { remove(head) }
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    private func remove(_ node: Node) {
        if let previous = node.previous { previous.next = node.next } else { head = node.next }
        if let next = node.next { next.previous = node.previous } else { tail = node.previous }
        if replaceable === node { replaceable = nil }
        node.next = nil; node.previous = nil
    }
}

public actor ApronSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    private let output: SessionEventBuffer
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
    private var requestLimits = RequestLimits()
    private var timers: [String: Task<Void, Never>] = [:]
    /// Rooms of in-flight commands, oldest first. A command's reply may omit `room_id`.
    private var commandRooms: [(id: String, room: String)] = []
    private var token: String?
    private var guestName: String?
    private var attempts = 0
    private var awaitingPong = false
    private var checkpoints: [String: UInt64] = [:]
    private var roomEpochs: [String: UUID] = [:]
    private var historyBounds: [String: UInt64] = [:]
    /// The account a restored seed belongs to, until the first sign-in confirms or discards it.
    private var seededAccount: String?
    /// Forward recovery pages per stream before falling back to a recent window; nil is unlimited.
    private var recoveryPageLimit: Int?
    private struct HistoryLoad {
        let id: UUID
        let older: Bool
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }
    private var historyLoads: [String: HistoryLoad] = [:]
    private var buffered: [WireFrame] = []
    private var bootstrap = false
    /// Retained account/history can outlive the socket that authenticated them.
    private var authenticatedConnection = false
    private var roomBuffers: [String: [WireFrame]] = [:]
    private var roomListingResume: Task<Void, any Error>?
    private var memberListingDates: [String: Date] = [:]
    private var threadListingDates: [String: Date] = [:]
    private var roomListingCooldowns: [String: Date] = [:]
    private struct RoomListingLoad {
        let id: UUID
        let task: Task<JSONObject, any Error>
    }
    private var roomListingLoads: [JSONObject: RoomListingLoad] = [:]
    private var retryNotBefore = Date.distantPast
    private let requestTimeout: Duration

    public init(url: URL, token: String? = nil, requestTimeout: Duration = .seconds(20)) {
        let output = SessionEventBuffer()
        self.output = output
        events = AsyncStream(unfolding: { await output.next() }, onCancel: { output.cancel() })
        self.token = token; self.requestTimeout = requestTimeout
        factory = { WebSocketTransport(url: url) }
    }

    public init(transportFactory: @escaping @Sendable () async -> any ChatTransport, requestTimeout: Duration = .seconds(20)) {
        let output = SessionEventBuffer()
        self.output = output
        events = AsyncStream(unfolding: { await output.next() }, onCancel: { output.cancel() })
        factory = transportFactory; self.requestTimeout = requestTimeout
    }

    public func snapshot() -> SessionSnapshot {
        var snapshot = state
        snapshot.requestCooldowns = requestLimits.current(account: state.you.string("user_id") ?? "")
        return snapshot
    }

    public func setRecoveryPageLimit(_ limit: Int?) { recoveryPageLimit = limit.map { max(1, $0) } }

    /// Install saved history before the session first starts. Recovery then continues each
    /// stream from its checkpoint; signing in as a different account discards the seed.
    public func restore(_ seed: HistorySeed) {
        guard stopped, state.you.isEmpty, checkpoints.isEmpty, !seed.account.isEmpty else { return }
        var store = RecordStore()
        for room in seed.rooms { store.installRoom(room) }
        for user in seed.users { store.mergeUser(user, complete: true) }
        for message in seed.messages { store.installMessage(message) }
        for reaction in seed.reactions { store.reactions[RecordKey(reaction.message, reaction.user)] = reaction.record }
        store.joined = Set(seed.joined)
        state.store = store
        for (key, stream) in seed.streams {
            checkpoints[key] = stream.checkpoint
            historyBounds[key] = stream.lowerBound
            state.history[key] = RoomHistory(before: stream.before)
        }
        seededAccount = seed.account
    }

    /// Contiguous history worth saving, keeping at most `maxMessages` per stream. Trimming
    /// drops the oldest log positions and moves the older-page cursor to them, so a later
    /// session can page back to whatever was not saved.
    public func exportHistory(maxMessages: Int) -> HistorySeed? {
        guard state.phase == .ready, let account = state.you.string("user_id"), maxMessages > 0 else { return nil }
        var streams: [String: HistorySeed.Stream] = [:]
        var messages: [JSONObject] = []
        for (key, checkpoint) in checkpoints where !state.recoveringRooms.contains(key) && historyLoads[key] == nil {
            var stream = HistorySeed.Stream(checkpoint: checkpoint, lowerBound: historyBounds[key] ?? 0, before: state.history[key]?.before)
            var held = state.store.messages.values.filter { key.isEmpty || $0.string("room_id") == key }
            if held.count > maxMessages {
                held.sort { ($0.logID("log_id") ?? 0) > ($1.logID("log_id") ?? 0) }
                let cutoff = held[maxMessages].logID("log_id") ?? 0
                held = Array(held.prefix(maxMessages))
                let before = max(stream.before ?? 0, cutoff)
                stream.before = before >= stream.lowerBound ? before : nil
            }
            streams[key] = stream
            messages += held
        }
        guard !streams.isEmpty else { return nil }
        let kept = Set(messages.compactMap { $0.string("message_id") })
        // Dropped reaction sets can be newer than their message snapshots. Include
        // those log positions in older pagination, including empty sets (removals).
        // Without this, the saved checkpoint would skip records not actually saved.
        for (key, reaction) in state.store.reactions where !kept.contains(key.first) {
            guard let version = reaction.logID("log_id") else { continue }
            let room = reaction.string("room_id") ?? state.store.messages[key.first]?.string("room_id")
            for streamKey in Array(streams.keys) where streamKey.isEmpty || room == nil || streamKey == room {
                guard var stream = streams[streamKey], version >= stream.lowerBound else { continue }
                stream.before = max(stream.before ?? 0, version)
                streams[streamKey] = stream
            }
        }
        let reactions = state.store.reactions.filter { kept.contains($0.key.first) }
            .map { HistorySeed.Reaction(message: $0.key.first, user: $0.key.second, record: $0.value) }
        return HistorySeed(account: account, streams: streams, rooms: Array(state.store.rooms.values),
                           joined: Array(state.store.joined), users: Array(state.store.users.values),
                           messages: messages, reactions: reactions)
    }
    private func publish() {
        state.requestCooldowns = requestLimits.current(account: state.you.string("user_id") ?? "")
        output.yield(.snapshot(state))
    }

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
        authenticatedConnection = false
        generation = UUID()
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        announcement?.cancel(); announcement = nil
        reconnectTask?.cancel(); reconnectTask = nil
        let old = transport; transport = nil
        failPending(ClientError.disconnected)
        for load in roomListingLoads.values { load.task.cancel() }
        roomListingResume?.cancel(); roomListingResume = nil
        roomListingLoads = [:]; memberListingDates = [:]; threadListingDates = [:]
        state.roomListingRetryAt = nil
        let loads = historyLoads; historyLoads = [:]
        for load in loads.values {
            for waiter in load.waiters.values { waiter.resume(throwing: ClientError.disconnected) }
        }
        buffered = []; roomBuffers = [:]; bootstrap = false
        for room in state.history.keys { state.history[room]?.isLoading = false }
        state.recoveringRooms = []; awaitingPong = false
        state.pendingSignIn = nil
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
        // Unlogged notices belong to this connection, unlike recovered chat history.
        // Servers resend their welcome on reconnect; do not accumulate old copies.
        state.store.notices = []
        commandRooms = []
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
        let account = state.you.string("user_id") ?? ""
        try requestLimits.check(method: method, params: params, account: account)
        if state.readOnly && RequestLimits.writes.contains(method) {
            throw RPCError(code: -32001, message: "This account does not have permission to write on this server.")
        }
        let epoch = generation
        do { return try await uncheckedRequest(method, params: params, id: id) }
        catch let error as RPCError {
            if epoch == generation {
                requestLimits.record(error, method: method, params: params, account: account, extended: state.supports("ext:limits"))
                publish()
            }
            throw error
        }
    }
    private func uncheckedRequest(_ method: String, params: JSONObject, id: String) async throws -> JSONObject {
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
        var frame = frame
        // Effects arrive before a command's result (§4.1), and results in request order, so
        // a private notice without a room belongs to the oldest command still in flight.
        if frame.method == "message", var params = frame.params, params["room_id"] == nil, params["message_id"] == nil,
           params.object("from").string("user_id") == "~private", let room = commandRooms.first?.room {
            params["room_id"] = .string(room); frame.params = params
        }
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
            guard ApronProtocol.supports(params["apron"]) else {
                stopped = true
                let old = invalidateConnection()
                state.phase = .disconnected; state.error = ClientError.unsupportedVersion.localizedDescription; publish()
                await old?.close(); return
            }
            announcement?.cancel(); announcement = nil
            let first = state.server.isEmpty
            state.server = params; configureHeartbeat(params["ping"]?.number); publish()
            if let avatar = params.string("avatar"), !avatar.isEmpty { output.yield(.avatarChanged(avatar)) }
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
        // No UI currently consumes inbound typing/read activity. Do not retain
        // expired presence or publish unchanged snapshots for these notifications.
        // Outgoing activity remains available to other clients.
        if frame.method == "activity" { return }
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
            authenticatedConnection = true
            if user != (state.you.string("user_id") ?? seededAccount) {
                state.store = RecordStore(); checkpoints = [:]; historyBounds = [:]; state.history = [:]; roomEpochs = [:]
            }
            seededAccount = nil
            state.pendingSignIn = nil
            state.mutedUntil = [:]
            for id in state.store.users.keys {
                state.store.users[id]?.removeValue(forKey: "status")
                state.store.users[id]?.removeValue(forKey: "seen")
            }
            state.you = response.object("you")
            memberListingDates = [:]; threadListingDates = [:]
            state.roomListingRetryAt = roomListingCooldowns[user]
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
                // Reconnect must neither bypass an account cooldown nor leave an authenticated
                // socket at the sign-in screen merely because its initial listing is paused.
                if let until = roomListingCooldowns[user], until > Date() {
                    let wait = Task {
                        while until > Date() {
                            try await Task.sleep(for: .seconds(min(60, until.timeIntervalSinceNow)))
                        }
                    }
                    roomListingResume = wait
                    try await wait.value
                    guard epoch == generation else { throw ClientError.disconnected }
                    roomListingResume = nil
                }
                let listing = try await roomListing(params: ["filter": .string("joined"), "members": .bool(true)])
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
                if authenticatedConnection {
                    // Authentication succeeded, but bootstrap failed. Start a new socket
                    // instead of offering another auth request on an authenticated one.
                    await lost(epoch: epoch, reason: error.localizedDescription)
                } else {
                    bootstrap = false; buffered = []; state.phase = .signIn; state.error = error.localizedDescription; publish()
                }
            }
            throw error
        }
    }

    public func requestEmail(_ email: String) async throws {
        _ = try await proposeSignIn(scheme: "email", fields: ["email": .string(email)])
    }

    public func requestExternalSignIn() async throws -> URL {
        let result = try await proposeSignIn(scheme: "external", fields: [:])
        return try ExternalSignIn.url(result.string("url") ?? "")
    }

    private func proposeSignIn(scheme: String, fields: JSONObject) async throws -> JSONObject {
        guard !stopped, connectionAvailable, !authenticatedConnection, state.phase == .signIn,
              state.server.strings("auth").contains(scheme) || state.server.strings("signup").contains(scheme),
              scheme != "external" || state.server["apron"] == .number(9) else { throw ClientError.notReady }
        let epoch = generation
        state.phase = .authenticating; state.pendingSignIn = nil; publish()
        var params = fields
        params["scheme"] = .string(scheme); params["agent"] = .string("sidetable/0.1")
        // No return_url: use the code on the proposing connection, without a callback handler.
        do {
            let result = try await request("auth", params: params)
            guard epoch == generation else { throw ClientError.disconnected }
            if scheme == "external" { _ = try ExternalSignIn.url(result.string("url") ?? "") }
            state.pendingSignIn = scheme; state.phase = .signIn; publish()
            return result
        } catch {
            if epoch == generation { state.phase = .signIn; publish() }
            throw error
        }
    }

    public func loadRoom(_ room: String) async throws {
        try await loadHistory(room, older: false)
    }

    public func loadOlderHistory(_ room: String) async throws {
        try await loadHistory(room, older: true)
    }

    /// Coalesce identical loads and serialize different loads for the same history stream.
    /// A cancelled joiner leaves the original request and its other callers untouched.
    private func loadHistory(_ room: String, older: Bool) async throws {
        try Task.checkCancellation()
        guard state.phase == .ready else { throw ClientError.notReady }
        let key = state.historyKey(room), epoch = generation, roomEpoch = roomEpochs[state.historyKey(room)]
        while let load = historyLoads[key] {
            try await waitForHistoryLoad(key, id: load.id)
            try Task.checkCancellation()
            try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch, requireHistory: false)
            if load.older == older { return }
        }
        let id = UUID()
        historyLoads[key] = HistoryLoad(id: id, older: older)
        do {
            if older { try await loadOlderHistoryPage(room) }
            else { try await loadRoomContents(room) }
            try Task.checkCancellation()
            try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch, requireHistory: false)
            finishHistoryLoad(key, id: id, result: .success(()))
        } catch {
            finishHistoryLoad(key, id: id, result: .failure(error))
            throw error
        }
    }

    private func waitForHistoryLoad(_ key: String, id: UUID) async throws {
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard historyLoads[key]?.id == id else { continuation.resume(); return }
                historyLoads[key]?.waiters[waiter] = continuation
            }
        } onCancel: {
            Task { await self.cancelHistoryWaiter(key, id: id, waiter: waiter) }
        }
    }

    private func cancelHistoryWaiter(_ key: String, id: UUID, waiter: UUID) {
        guard historyLoads[key]?.id == id else { return }
        historyLoads[key]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }

    private func finishHistoryLoad(_ key: String, id: UUID, result: Result<Void, any Error>) {
        guard historyLoads[key]?.id == id, let load = historyLoads.removeValue(forKey: key) else { return }
        for waiter in load.waiters.values { waiter.resume(with: result) }
    }

    private func loadRoomContents(_ room: String) async throws {
        let key = state.historyKey(room)
        guard state.phase == .ready else { throw ClientError.notReady }
        let epoch = generation, roomEpoch = roomEpochs[key]
        state.recoveringRooms.insert(key); publish()
        defer {
            if epoch == generation, roomEpoch == roomEpochs[key] {
                state.recoveringRooms.remove(key); publish()
            }
        }
        // Replies must not depend on optional member/child listings. Public
        // servers may rate-limit those separately from readable history.
        if state.supports("history") { try await recover(key, epoch: epoch) }
        if state.supports("rooms"), state.store.rooms[room]?.string("parent_room_id") == nil {
            do {
                if !recentListing(memberListingDates[room]) {
                    _ = try await roomListing(params: ["room_id": .string(room), "members": .bool(true)])
                    try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch, requireHistory: false)
                }
                if !recentListing(threadListingDates[room]) {
                    _ = try await roomListing(params: ["parent_room_id": .string(room)])
                    try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch, requireHistory: false)
                }
            } catch is RoomListingLimited {
                // History above is usable. A rejected metadata refresh must not fail opening chat.
                try checkHistoryOperation(key, epoch: epoch, roomEpoch: roomEpoch, requireHistory: false)
            }
        }
    }

    private func loadOlderHistoryPage(_ room: String) async throws {
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
        var pages = 0
        while true {
            if let limit = recoveryPageLimit, pages >= limit {
                // A long gap would hold sign-in for many pages; start again from a recent window.
                clearHistoryRoom(room)
                state.recoveringRooms.insert(room)
                try await loadRecentHistory(room, epoch: epoch, roomEpoch: roomEpoch)
                return
            }
            pages += 1
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

    private func recentListing(_ date: Date?) -> Bool {
        date.map { Date().timeIntervalSince($0) < 30 } ?? false
    }

    private func roomListing(params: JSONObject, id: String = UUID().uuidString) async throws -> JSONObject {
        try Task.checkCancellation()
        let account = state.you.string("user_id") ?? ""
        if let until = roomListingCooldowns[account], until > Date() {
            throw RoomListingLimited(retryAt: until)
        }
        let load: RoomListingLoad
        if let existing = roomListingLoads[params] { load = existing }
        else {
            let epoch = generation
            load = RoomListingLoad(id: UUID(), task: Task {
                do {
                    let result = try await self.request("room_list", params: params, id: id)
                    guard epoch == self.generation else { throw ClientError.disconnected }
                    if params.bool("members") && params["user_id"] == nil {
                        for room in result.objects("joined") + result.objects("not_joined") {
                            if let roomID = room.string("room_id"), room["members"] != nil {
                                self.memberListingDates[roomID] = Date()
                            }
                        }
                    }
                    if let parent = params.string("parent_room_id") { self.threadListingDates[parent] = Date() }
                    if self.state.phase == .ready {
                        self.state.store.applyListing(result)
                        self.publish()
                    }
                    return result
                } catch let error as RPCError where error.code == -32002 {
                    guard epoch == self.generation else { throw ClientError.disconnected }
                    let delay = error.retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 30
                    let until = Date().addingTimeInterval(delay)
                    self.roomListingCooldowns[account] = max(self.roomListingCooldowns[account] ?? .distantPast, until)
                    self.state.roomListingRetryAt = self.roomListingCooldowns[account]
                    self.publish()
                    throw RoomListingLimited(retryAt: self.roomListingCooldowns[account]!)
                }
            })
            roomListingLoads[params] = load
        }
        defer { if roomListingLoads[params]?.id == load.id { roomListingLoads[params] = nil } }
        let result = try await load.task.value
        try Task.checkCancellation()
        return result
    }

    public func perform(_ method: String, params: JSONObject, id: String = UUID().uuidString) async throws -> JSONObject {
        guard state.phase == .ready else { throw ClientError.notReady }
        if method == "room_join", let room = params.string("room_id") {
            if params.string("user_id") != nil, !state.canAddMembers(to: room) {
                throw RPCError(code: -32001, message: "This account cannot add members to that room.")
            }
            if params.string("user_id") == nil, !state.store.joined.contains(room),
               state.store.rooms[room]?.bool("private") == true,
               state.store.rooms[room]?.string("parent_room_id") == nil, state.privateRoomLimitReached {
                throw RPCError(code: -32001, message: "You have reached this server’s private room limit.")
            }
        }
        if method == "room_set", params.string("room_id") == nil, params.bool("private"),
           params.string("parent_room_id") == nil, state.privateRoomLimitReached {
            throw RPCError(code: -32001, message: "You have reached this server’s private room limit.")
        }
        let epoch = generation
        if method == "command", let room = params.string("room_id") { commandRooms.append((id, room)) }
        defer { commandRooms.removeAll { $0.id == id } }
        let result = try await method == "room_list" ? roomListing(params: params, id: id) : request(method, params: params, id: id)
        guard epoch == generation else { throw ClientError.disconnected }
        if method == "me", !result.object("you").isEmpty {
            state.you = result.object("you"); state.store.mergeUser(state.you, complete: true, own: true); publish()
        }
        return result
    }
    public func activity(room: String, fields: JSONObject) async {
        guard state.phase == .ready, state.supports("activity") else { return }
        var params = fields
        if state.supports("ext:settings"), state.server.object("ext").object("settings")["read_cursors"] == .bool(false) {
            params.removeValue(forKey: "read_message_id")
        }
        guard !params.isEmpty else { return }
        if !room.isEmpty { params["room_id"] = .string(room) }
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
