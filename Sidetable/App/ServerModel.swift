import ApronCore
import AppKit
import Observation

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
    let connection = ServerConnection()
    var busy: Bool { connection.busy }
    var cached = false
    @ObservationIgnored var connectedAccount: String?
    var session: ApronSession? {
        get { connection.session }
        set { connection.session = newValue }
    }
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
    /// Lists every visible row and composer reads. Each snapshot replaces them, so
    /// they are derived once per snapshot and account rather than once per view.
    @ObservationIgnored private var derived = Derived()
    private struct Derived {
        var revision: UUID?
        var account: String?
        var rooms: [JSONObject]?
        var referenceNames: [String: String]?
        var titles: [String: String] = [:]
        var suggestions: [String: [ComposerSuggestion]] = [:]
    }
    /// Callers still observe the snapshot, so they update when it changes.
    private func currentDerived() -> Derived {
        let account = account
        if derived.revision != cacheRevision || derived.account != account {
            derived = Derived(revision: cacheRevision, account: account)
        }
        return derived
    }
    var rooms: [JSONObject] {
        if let rooms = currentDerived().rooms { return rooms }
        let rooms = snapshot.store.rooms.values.filter { snapshot.store.joined.contains($0.string("room_id") ?? "") || $0.string("parent_room_id") != nil }
            .map { (title($0.string("room_id") ?? ""), $0) }
            .sorted { lhs, rhs in
                // Dictionary order varies by launch; equal titles fall back to the room ID.
                let order = lhs.0.localizedStandardCompare(rhs.0)
                return order == .orderedSame ? (lhs.1.string("room_id") ?? "") < (rhs.1.string("room_id") ?? "") : order == .orderedAscending
            }
            .map(\.1)
        derived.rooms = rooms
        return rooms
    }
    var composerReferenceNames: [String: String] {
        if let names = currentDerived().referenceNames { return names }
        var names = Dictionary(uniqueKeysWithValues: Set(snapshot.store.users.keys).union(snapshot.store.aliases.keys).map {
            ("@" + $0, snapshot.store.displayName(["user_id": .string($0)]))
        })
        if snapshot.supports("rooms") {
            for id in snapshot.store.rooms.keys { names["#" + id] = title(id) }
        }
        derived.referenceNames = names
        return names
    }
    /// Member and room completions for a conversation's composer.
    func composerSuggestions(room: String) -> [ComposerSuggestion] {
        if let suggestions = currentDerived().suggestions[room] { return suggestions }
        let members = (snapshot.store.members[room] ?? []).sorted().map { id in
            let name = snapshot.store.displayName(["user_id": .string(id)])
            return ComposerSuggestion(insertion: "@" + id, label: name + " · @" + id, search: name + " " + id)
        }
        let rooms = snapshot.store.rooms.keys.sorted().map { id in
            let title = title(id)
            return ComposerSuggestion(insertion: "#" + id, label: "#" + title, search: title + " " + id)
        }
        derived.suggestions[room] = members + rooms
        return members + rooms
    }
    func roomReferenceNames(in text: String) -> [String: String] {
        guard snapshot.supports("rooms") else { return [:] }
        return Dictionary(uniqueKeysWithValues: RoomReferenceDisplay.ids(in: text).compactMap { id in
            snapshot.store.rooms[id] == nil ? nil : (id, title(id))
        })
    }
    func title(_ room: String) -> String {
        if let title = currentDerived().titles[room] { return title }
        let title: String
        if let name = snapshot.store.rooms[room]?.string("title"), !name.isEmpty { title = name }
        else if let participants = participants(room) { title = participants.map(\.name).joined(separator: ", ") }
        else { title = room.isEmpty ? "Conversation" : room }
        derived.titles[room] = title
        return title
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
