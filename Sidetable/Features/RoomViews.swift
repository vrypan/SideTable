import SwiftUI
import AppKit
import ApronCore

struct MembersView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let room: String
    @State private var userID = ""
    @State private var removing: String?
    @State private var search = ""
    private var presenceAvailable: Bool { !server.cached && server.snapshot.phase == .ready }
    var body: some View {
        let members = MemberListEntry.members(in: room, store: server.snapshot.store, presenceAvailable: presenceAvailable)
        let matchingMembers = MemberListEntry.matching(members, query: search)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Members").font(.headline)
                    Text(server.title(room)).font(.callout).lineLimit(1)
                        .accessibilityIdentifier("membersDiscussion")
                    Text(server.profile.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }.padding(18)
            HStack {
                TextField("Search members", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("memberSearch")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear member search")
                }
            }.padding(.horizontal, 12)
            Text(presenceAvailable ? "\(members.count) members · \(members.filter(\.isActive).count) active" : "\(members.count) members")
                .font(.caption).foregroundStyle(.secondary).padding(12)
            Divider()
            List(matchingMembers) { member in
                let profile = member.profile
                UserProfileButton(model: model, server: server, recorded: ["user_id": .string(member.id)], hoverText: member.hoverText) {
                    HStack(spacing: 10) {
                        AvatarView(name: profile.name, size: 28, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(profile.name).font(.callout).lineLimit(1)
                                if member.isActive {
                                    Circle().fill(.green).frame(width: 7, height: 7)
                                        .accessibilityLabel("Active").help("Active")
                                }
                            }
                            Text("@\(profile.id)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if !profile.roles.isEmpty {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 4) {
                                        ForEach(Array(Set(profile.roles)).sorted(), id: \.self) { role in
                                            Text(role).font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text(profile.roles.joined(separator: ", "))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 5)
                }
                .accessibilityLabel("\(profile.name), @\(profile.id), \(member.status), \(profile.roles.joined(separator: ", "))")
                .accessibilityIdentifier("memberRow-" + member.id)
                .contextMenu {
                    Button("Remove Member…", role: .destructive) { removing = member.id }
                }
            }.listStyle(.plain)
                .overlay {
                    if matchingMembers.isEmpty {
                        Text(search.isEmpty ? "No members to display" : "No matching members")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            if let count = server.snapshot.store.rooms[room]?["member_count"]?.number, Int(count) > (server.snapshot.store.members[room]?.count ?? 0) {
                Text("Showing recent members of \(Int(count)) total.").font(.caption).foregroundStyle(.secondary).padding(12)
            }
            if server.snapshot.supports("rooms") {
                HStack {
                    TextField("Add by user ID", text: $userID).textFieldStyle(.roundedBorder)
                    Button { model.perform("room_join", params: ["room_id": .string(room), "user_id": .string(userID)], server: server); userID = "" } label: { Image(systemName: "plus") }.disabled(userID.isEmpty)
                }.padding(12)
            }
        }
        .onChange(of: room) { search = "" }
        .onChange(of: server.id) { search = "" }
        .confirmationDialog("Remove this member?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Member", role: .destructive) {
                if let removing { model.perform("room_leave", params: ["room_id": .string(room), "user_id": .string(removing)], server: server) }
                removing = nil
            }
        }
    }
}

struct BrowseRoomsView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [JSONObject] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse rooms").font(.title2.weight(.semibold))
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            List(rooms, id: \.self) { room in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.string("title") ?? room.string("room_id") ?? "Room").fontWeight(.medium)
                        Text(room.string("description") ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Join") {
                        let id = room.string("room_id") ?? ""
                        model.perform("room_join", params: ["room_id": .string(id)], server: server) { _ in model.selectRoom(id, server: server); dismiss() }
                    }
                }.padding(.vertical, 5)
            }.overlay { if !loading && rooms.isEmpty { Text("No other rooms to join.").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 480, height: 400)
            .task {
                do { rooms = try await server.session?.perform("room_list", params: ["filter": .string("not_joined")]).objects("not_joined") ?? [] }
                catch { self.error = error.localizedDescription }
                loading = false
            }
    }
}

struct NewRoomView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let parent: String?
    var sourceMessage: JSONObject? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var isPrivate = false
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(parent == nil ? "New room" : "New thread").font(.title2.weight(.semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $description).textFieldStyle(.roundedBorder)
            Toggle("Private", isOn: $isPrivate)
            Text("The server decides who can create rooms and manage membership.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.buttonStyle(.borderedProminent).disabled(title.isEmpty || busy || model.preview || server.snapshot.readOnly)
            }
        }.padding(24).frame(width: 440)
            .onAppear {
                if let sourceMessage {
                    let text = sourceMessage.object("body").string("text") ?? ""
                    title = String((text.split(separator: "\n").first.map(String.init) ?? "New thread").prefix(80))
                    description = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                }
                if let parent, server.snapshot.store.rooms[parent]?.bool("private") == true { isPrivate = true }
            }
    }
    private func create() {
        guard let session = server.session, server.snapshot.phase == .ready else {
            error = "Wait until the server is connected."; return
        }
        let account = server.account
        busy = true
        Task {
            defer { busy = false }
            var params: JSONObject = ["title": .string(title), "description": .string(description)]
            if let parent { params["parent_room_id"] = .string(parent) }
            let requiresPrivacy = isPrivate || parent.flatMap { server.snapshot.store.rooms[$0] }?.bool("private") == true
            if requiresPrivacy { params["private"] = .bool(true) }
            do {
                let response = try await session.perform("room_set", params: params)
                guard let room = response.string("room_id") else { throw ClientError.invalidHistory }
                let latest = await session.snapshot()
                guard server.session === session, server.account == account else { return }
                if requiresPrivacy && latest.store.rooms[room]?.bool("private") != true {
                    error = "The server did not confirm privacy. This room has not been opened."; return
                }
                server.snapshot = latest
                if let id = sourceMessage?.string("message_id") {
                    var draft = model.draft(server, room: room); draft.replyTo = id
                    model.setDraft(draft, server: server, room: room)
                }
                // Selecting a thread also selects its parent room in the sidebar.
                model.selectRoom(room, server: server, asThread: parent != nil); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var updates: UpdateService?
    @State private var removing: ServerModel?
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--preview-storage") ? 1 : 0
    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("Appearance") {
                    Slider(value: $model.messageSize, in: 12...22, step: 1) { Text("Message text size") }
                    Text("Preview of conversation text").font(.system(size: model.messageSize))
                }
                if let updates { UpdateSettingsView(updates: updates) }
                Section("Notifications") {
                    Toggle("Notify me about mentions and replies", isOn: Binding(get: { model.notificationsEnabled }, set: { model.enableNotifications($0) }))
                    Text("Alerts are available while SideTable is running and connected. Quitting the app stops alerts. Notification previews do not include message content.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Session tokens are stored in Keychain. Drafts and recent conversations are stored on this Mac. Signing out clears that server’s local account data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            Form {
                Section("Saved conversations") {
                    LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: model.conversationCacheBytes, countStyle: .file))
                    Text("Recent conversations are saved so the next launch shows them right away and downloads only what changed. Clearing removes those copies until the next launch. Live conversations, drafts, read markers, and sign-in are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $model.savedMessagesPerRoom, in: AppModel.savedMessagesRange, step: 100) {
                        LabeledContent("Messages kept per conversation", value: String(model.savedMessagesPerRoom))
                    }.accessibilityIdentifier("savedMessagesPerRoom")
                    Stepper(value: $model.recoveryPageLimit, in: AppModel.recoveryPagesRange) {
                        LabeledContent("Catch-up limit", value: "\(model.recoveryPageLimit) × 200 updates")
                    }.accessibilityIdentifier("recoveryPageLimit")
                    Text("On launch and after reconnecting, each conversation downloads the edits, reactions, and messages it missed. Beyond the catch-up limit it starts again from the latest messages instead, so long absences do not delay connecting. Earlier messages load as you scroll back.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.servers) { server in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.profile.title)
                                Text(ByteCountFormatter.string(fromByteCount: model.cacheUsage[server.id] ?? 0, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear") { model.clearSavedConversations(server: server.id) }
                                .disabled(model.preview || model.cacheUsage[server.id] == nil)
                                .accessibilityLabel("Clear saved conversations for \(server.profile.title)")
                        }
                    }
                    Button("Clear All Saved Conversations") { model.clearSavedConversations() }
                        .disabled(model.preview || model.cacheUsage.isEmpty)
                    if let error = model.cacheError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
                MediaCacheSettings(preview: model.preview)
            }.formStyle(.grouped).tabItem { Label("Storage", systemImage: "internaldrive") }.tag(1)
                .onAppear { model.refreshCacheUsage() }
            VStack(alignment: .leading) {
                List(model.servers) { server in
                    HStack {
                        VStack(alignment: .leading) { Text(server.profile.title); Text(server.profile.address).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button("Remove…", role: .destructive) { removing = server }
                    }
                }
                Button("Add Server…") { model.showAddServer = true }
            }.padding().tabItem { Label("Servers", systemImage: "network") }.tag(2)
        }.padding(12).frame(width: 520, height: 400)
            .onChange(of: model.messageSize) { UserDefaults.standard.set(model.messageSize, forKey: "messageSize") }
            .confirmationDialog("Remove this server and its saved account data?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove Server", role: .destructive) { if let removing { model.remove(removing) }; removing = nil }
            }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateService
    var body: some View {
        Section("Updates") {
            if updates.enabled {
                Toggle("Automatically check for updates", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticallyChecks))
                Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
                Text("SideTable asks before downloading and installing updates.").font(.caption).foregroundStyle(.secondary)
                if let error = updates.error { Text(error).font(.caption).foregroundStyle(.red) }
            } else {
                Text("This development build does not check for updates.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}


/// Room edits replace client fields; preserve privacy and extensions when changing text.
enum RoomDetails {
    static func editParameters(_ original: JSONObject, title: String, description: String) -> JSONObject {
        var result: JSONObject = ["room_id": original["room_id"] ?? .null, "description": .string(description)]
        // An empty title is omitted, leaving the room untitled.
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result["title"] = .string(title) }
        for field in ["private", "ext"] { result[field] = original[field] }
        return result
    }

    /// Untitled private top-level rooms are shown by their participants; other
    /// rooms would fall back to a bare room ID, and servers title threads.
    static func titleIsOptional(_ room: JSONObject?) -> Bool {
        room?.bool("private") == true && room?.string("parent_room_id") == nil
    }

    static func memberSummary(room: JSONObject, members: Set<String>?) -> String {
        if let count = room["member_count"]?.number, count.isFinite, count >= 0,
           count >= Double(members?.count ?? 0) {
            return "\(count.formatted(.number.precision(.fractionLength(0)))) \(count == 1 ? "member" : "members")"
        }
        guard let members else { return "Members not loaded" }
        return "\(members.count) \(members.count == 1 ? "member" : "members")"
    }
}

struct EditRoomView: View {
    @Bindable var server: ServerModel
    let room: String
    @Environment(\.dismiss) private var dismiss
    @State private var original: JSONObject?
    @State private var title = ""
    @State private var description = ""
    @State private var error: String?
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?
    private var canSave: Bool {
        !saving && (RoomDetails.titleIsOptional(original) || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !server.cached && server.snapshot.phase == .ready && !server.snapshot.readOnly
            && original != nil && (title != (original?.string("title") ?? "") || description != (original?.string("description") ?? ""))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Room").font(.title2.weight(.semibold))
            TextField(RoomDetails.titleIsOptional(original) ? "Title (optional)" : "Title", text: $title)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("roomTitle")
            if RoomDetails.titleIsOptional(original) {
                Text("Leave empty to show the other members’ names.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $description).font(.body).frame(height: 120)
                .border(.quaternary).accessibilityLabel("Room description")
            Label(original?.bool("private") == true ? "Private · Visible only to members" : "Public room", systemImage: original?.bool("private") == true ? "lock" : "number")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }.padding(24).frame(width: 420)
            .onAppear {
                original = server.snapshot.store.rooms[room]
                title = original?.string("title") ?? ""
                description = original?.string("description") ?? ""
            }
            .onChange(of: server.account) { saveTask?.cancel(); dismiss() }
            .onChange(of: server.id) { saveTask?.cancel(); dismiss() }
            .onDisappear { saveTask?.cancel() }
    }
    private func save() {
        guard canSave, let original, let session = server.session else { return }
        guard server.snapshot.store.rooms[room]?.string("log_id") == original.string("log_id") else {
            error = "This room changed while you were editing. Close and reopen Edit Room to load its latest details."; return
        }
        let account = server.account
        let params = RoomDetails.editParameters(original, title: title, description: description)
        saving = true; error = nil
        saveTask = Task { @MainActor in
            defer { saving = false; saveTask = nil }
            do {
                _ = try await session.perform("room_set", params: params)
                guard !Task.isCancelled, server.session === session, server.account == account else { return }
                let latest = await session.snapshot()
                guard !Task.isCancelled, server.session === session, server.account == account else { return }
                server.snapshot = latest
                dismiss()
            } catch {
                guard !Task.isCancelled, server.session === session, server.account == account else { return }
                self.error = error.localizedDescription
            }
        }
    }
}


/// Shared by the conversation header and sidebar context menus.
struct RoomActionItems: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let room: String
    let isThread: Bool
    var copiedLink = false
    let copyLink: () -> Void
    let edit: () -> Void
    let newThread: () -> Void
    let leave: () -> Void
    private var canManage: Bool {
        server.snapshot.phase == .ready && !server.cached && !server.snapshot.readOnly && !model.preview
    }
    /// Opening a room that already has a panel only focuses that panel, so the
    /// action is offered only for rooms not yet open (never from their own header).
    private var isOpen: Bool {
        model.panels.contains { $0.serverID == server.id && $0.account == server.account && $0.room == room }
    }
    var body: some View {
        if !isOpen {
            Button("Open in New Panel", systemImage: "rectangle.split.2x1") {
                model.openInNewPanel(room, server: server, isThread: isThread)
            }
            Divider()
        }
        Button(copiedLink ? "Copied Room Link" : "Copy Link to Room", systemImage: "link", action: copyLink)
            .disabled(RoomLink.url(endpoint: server.profile.address, room: room) == nil)
        if server.snapshot.supports("status") {
            Menu("Mute Room", systemImage: "bell.slash") {
                Button("For One Hour") { mute(.number(3600)) }
                Button("For Eight Hours") { mute(.number(28800)) }
                Button("Until Resumed") { mute(.bool(true)) }
                Divider()
                Button("Unmute Room") { mute(.bool(false)) }
            }.disabled(server.snapshot.phase != .ready || server.cached || model.preview)
        }
        Divider()
        Button("Edit Room…", systemImage: "pencil", action: edit).disabled(!canManage)
        if !isThread {
            Button("New Thread…", systemImage: "arrow.turn.down.right", action: newThread).disabled(!canManage)
        }
        if server.snapshot.store.joined.contains(room) {
            Divider()
            Button("Leave Room…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: leave).disabled(!canManage)
        }
    }
    private func mute(_ value: JSONValue) {
        model.perform("status", params: ["room_id": .string(room), "mute": value], server: server)
    }
}

struct RoomContextMenu: ViewModifier {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let room: String
    let isThread: Bool
    @State private var editing = false
    @State private var creatingThread = false
    @State private var leaving = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if server.snapshot.supports("rooms") {
                    RoomActionItems(model: model, server: server, room: room, isThread: isThread,
                        copyLink: {
                            guard let url = RoomLink.url(endpoint: server.profile.address, room: room) else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }, edit: { editing = true }, newThread: { creatingThread = true }, leave: { leaving = true })
                }
            }
            .sheet(isPresented: $editing) { EditRoomView(server: server, room: room) }
            .sheet(isPresented: $creatingThread) { NewRoomView(model: model, server: server, parent: room) }
            .confirmationDialog("Leave \(server.title(room))?", isPresented: $leaving) {
                Button("Leave Room", role: .destructive) {
                    let account = server.account
                    model.perform("room_leave", params: ["room_id": .string(room)], server: server) { _ in
                        if server.account == account { model.closeThreadPanel(server: server, room: room) }
                    }
                }
            }
            .onChange(of: server.account) { editing = false; creatingThread = false; leaving = false }
            .onChange(of: room) { editing = false; creatingThread = false; leaving = false }
    }
}
