import SwiftUI
import ApronCore

struct MembersView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let room: String
    @State private var userID = ""
    @State private var removing: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Members").font(.headline)
                Spacer()
                Button { model.showMembers = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close members")
            }.padding(18)
            Divider()
            List((server.snapshot.store.members[room] ?? []).sorted(), id: \.self) { id in
                let user = server.snapshot.store.users[id] ?? ["user_id": .string(id)]
                let profile = UserProfile(recorded: user, store: server.snapshot.store)
                UserProfileButton(server: server, recorded: user) {
                    HStack(spacing: 10) {
                        AvatarView(name: profile.name, size: 28, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.callout)
                            Text(profile.status?.capitalized ?? "@\(id)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 5)
                }.contextMenu {
                    Button("Remove Member…", role: .destructive) { removing = id }
                }
            }.listStyle(.plain)
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
    }
    private func create() {
        busy = true
        Task {
            defer { busy = false }
            var params: JSONObject = ["title": .string(title), "description": .string(description)]
            if let parent { params["parent_room_id"] = .string(parent) }
            if isPrivate { params["private"] = .bool(true) }
            do {
                let response = try await server.session?.perform("room_set", params: params) ?? [:]
                guard let room = response.string("room_id") else { throw ClientError.invalidHistory }
                let latest = await server.session?.snapshot()
                if isPrivate && latest?.store.rooms[room]?.bool("private") != true {
                    error = "The server did not confirm privacy. This room has not been opened."; return
                }
                if let latest { server.snapshot = latest }
                model.selectRoom(room, server: server, asThread: parent != nil); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var removing: ServerModel?
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--preview-storage") ? 1 : 0
    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("Appearance") {
                    Slider(value: $model.messageSize, in: 12...22, step: 1) { Text("Message text size") }
                    Text("Preview of conversation text").font(.system(size: model.messageSize))
                }
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
                    Text("Recent conversations are saved for offline launch views. Clearing removes those copies until the next launch. Live conversations, drafts, read markers, and sign-in are kept.")
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
