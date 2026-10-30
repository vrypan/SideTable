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
    public var privateRoomCount: Int {
        store.joined.filter { store.rooms[$0]?.bool("private") == true && store.rooms[$0]?.string("parent_room_id") == nil }.count
    }
    public var privateRoomLimit: Int? {
        guard supports("ext:settings"), let limit = server.object("ext").object("settings")["private_rooms"]?.number,
              limit.isFinite, limit >= 0 else { return nil }
        return Int(exactly: limit)
    }
    public var privateRoomLimitReached: Bool {
        guard let privateRoomLimit else { return false }
        return privateRoomCount >= privateRoomLimit
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
