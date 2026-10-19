import SwiftUI
import ApronCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if model.preview {
                    Text("Preview · Sample conversations · No server connection")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(6).background(.quaternary.opacity(0.3))
                }
                if let server = model.current {
                    if [.signIn, .authenticating].contains(server.snapshot.phase) {
                        SignInView(model: model, server: server)
                    } else if let room = server.selectedRoom {
                        HSplitView {
                            ConversationView(model: model, server: server, room: room, isThread: false)
                                .frame(minWidth: 340)
                            if let thread = model.thread {
                                ConversationView(model: model, server: server, room: thread, isThread: true)
                                    .frame(minWidth: 280, idealWidth: 350, maxWidth: 500)
                            } else if model.showMembers {
                                MembersView(model: model, server: server, room: room)
                                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                            }
                        }
                    } else {
                        ContentUnavailableView {
                            Label(server.snapshot.phase == .ready ? "Choose a conversation" : server.snapshot.phase.rawValue, systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text(server.snapshot.error ?? "Your rooms will appear in the sidebar.")
                        } actions: {
                            Button("Reconnect") { Task { await server.session?.reconnect() } }
                        }
                    }
                    if let error = server.error ?? server.snapshot.error {
                        HStack {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(error).font(.callout).textSelection(.enabled)
                            Spacer()
                            Button { server.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss error")
                        }.padding(12).background(.orange.opacity(0.08))
                    }
                } else {
                    WelcomeView { model.showAddServer = true }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.showJump = true } label: { Label("Jump to Conversation", systemImage: "magnifyingglass") }
                        .disabled(model.current == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.thread = nil; model.showMembers.toggle() } label: { Label("Members", systemImage: "sidebar.right") }
                        .disabled(model.current?.selectedRoom == nil).accessibilityIdentifier("toggleMembers")
                }
            }
        }
        .sheet(isPresented: $model.showAddServer) { AddServerView(model: model) }
        .sheet(isPresented: $model.showJump) { JumpView(model: model) }
        .alert("Sidetable", isPresented: Binding(get: { model.globalError != nil }, set: { if !$0 { model.globalError = nil } })) {
            Button("OK") { model.globalError = nil }
        } message: { Text(model.globalError ?? "") }
        .onChange(of: model.selectedServer) { model.thread = nil; model.findText = "" }
    }
}

struct WelcomeView: View {
    var connect: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48, weight: .light)).foregroundStyle(.tint).padding(24)
                .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 28))
            VStack(spacing: 9) {
                Text("A little space to talk.").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Your communities. Your servers. At home on your Mac.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Button("Add an Apron Server…", action: connect).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
            Text("Connect to any compatible Apron server.").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var browse = false
    @State private var create = false
    @State private var signingOut = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Menu {
                        ForEach(model.servers) { server in
                            Button { model.selectedServer = server.id } label: {
                                Text("\(server.profile.title) · \(server.unread.values.reduce(0, +)) unread")
                            }
                        }
                        Divider()
                        Button("Add Server…") { model.showAddServer = true }
                    } label: {
                        Text(model.current?.profile.title ?? "Sidetable").font(.headline)
                    }.menuStyle(.borderlessButton)
                    if let server = model.current {
                        Label(server.snapshot.phase.rawValue, systemImage: server.snapshot.phase == .ready ? "circle.fill" : "circle.dotted")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { model.showAddServer = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add Server")
            }.padding(16)
            Divider()
            if let server = model.current {
                List(selection: Binding(get: { server.selectedRoom }, set: { if let room = $0 { model.selectRoom(room, server: server) } })) {
                    Section("Rooms") {
                        ForEach(server.rooms.filter { $0.string("parent_room_id") == nil }, id: \.self) { room in
                            let id = room.string("room_id") ?? ""
                            roomRow(room, server: server).tag(id)
                            if server.selectedRoom == id {
                                ForEach(server.rooms.filter { $0.string("parent_room_id") == id }, id: \.self) { thread in
                                    Button { model.selectRoom(thread.string("room_id") ?? "", server: server, asThread: true) } label: {
                                        Label(thread.string("title") ?? "Thread", systemImage: "arrow.turn.down.right")
                                            .font(.callout).foregroundStyle(.secondary).padding(.leading, 12)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if server.snapshot.supports("rooms") {
                        Section {
                            Button { browse = true } label: { Label("Browse rooms…", systemImage: "square.grid.2x2") }
                            Button { create = true } label: { Label("New room…", systemImage: "plus.bubble") }
                        }.foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack(spacing: 10) {
                    AvatarView(name: server.snapshot.store.displayName(server.snapshot.you), size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.snapshot.you.string("name") ?? server.snapshot.you.string("user_id") ?? "Not signed in").font(.callout.weight(.medium)).lineLimit(1)
                        Text(server.snapshot.you.string("status")?.capitalized ?? "Account").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                    if server.snapshot.supports("status") {
                        Button("Online") { model.perform("me", params: ["status": .string("online")], server: server) }
                        ForEach(server.snapshot.server.strings("status"), id: \.self) { value in
                            Button(value == "dnd" ? "Do Not Disturb" : value.capitalized) { model.perform("me", params: ["status": .string(value)], server: server) }
                        }
                        Menu("Pause Notifications") {
                            Button("For One Hour") { model.perform("status", params: ["mute": .number(3600)], server: server) }
                            Button("Until Resumed") { model.perform("status", params: ["mute": .bool(true)], server: server) }
                            Button("Resume") { model.perform("status", params: ["mute": .bool(false)], server: server) }
                        }
                        Divider()
                    }
                    Button("Reconnect") { Task { await server.session?.reconnect() } }
                    Button("Sign Out…", role: .destructive) { signingOut = true }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Account options") }
                        .menuStyle(.borderlessButton).frame(width: 26)
                }.padding(14)
                .confirmationDialog("Sign out and remove this account’s saved drafts?", isPresented: $signingOut) {
                    Button("Sign Out", role: .destructive) { model.signOut(server) }
                }
                .sheet(isPresented: $browse) { BrowseRoomsView(model: model, server: server) }
                .sheet(isPresented: $create) { NewRoomView(model: model, server: server, parent: nil) }
            } else { Spacer() }
        }
    }
    private func roomRow(_ room: JSONObject, server: ServerModel) -> some View {
        let id = room.string("room_id") ?? ""
        return HStack {
            Image(systemName: room.bool("private") ? "lock" : "number").foregroundStyle(.secondary).frame(width: 18)
            Text(server.title(id)).lineLimit(1)
            Spacer()
            if let count = server.unread[id], count > 0 {
                Text(String(count)).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.13), in: Capsule())
            }
        }.padding(.vertical, 3)
    }
}

struct AddServerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Add a server", systemImage: "network").font(.title2.weight(.semibold))
            Text("Enter the address of your Apron community.").foregroundStyle(.secondary)
            TextField("server.apron.chat", text: $address).textFieldStyle(.roundedBorder).accessibilityIdentifier("serverAddress")
                .onSubmit(connect)
            Text("Use the full URL when your server requires a path, such as wss://chat.example/ws.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Try Apron’s public server") { address = "wss://server.apron.chat/" }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect", action: connect).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(address.isEmpty)
            }
        }.padding(28).frame(width: 480)
    }
    private func connect() {
        do { try model.addServer(address); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct SignInView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    @State private var name = ""
    @State private var token = ""
    @State private var email = ""
    @State private var code = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.tint)
                Text("Welcome to \(server.profile.title)").font(.title.weight(.semibold))
                if let welcome = server.snapshot.server.string("welcome") { Text(welcome).foregroundStyle(.secondary).textSelection(.enabled) }
                let schemes = Set(server.snapshot.server.strings("auth") + server.snapshot.server.strings("signup"))
                if schemes.contains("guest") {
                    GroupBox("Join as a guest") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
                            Text("Guest identities may change after reconnecting.").font(.caption).foregroundStyle(.secondary)
                            Button("Continue as Guest") { model.signIn(server, scheme: "guest", fields: ["name": .string(name)]) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("guestSignIn")
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("email") {
                    GroupBox("Sign in with email") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Email address", text: $email).textFieldStyle(.roundedBorder)
                            Button(server.emailPending ? "Send a New Code" : "Send Code") { model.requestEmail(email, server: server) }.disabled(email.isEmpty)
                            if server.emailPending {
                                TextField("Code from your email", text: $code).textFieldStyle(.roundedBorder)
                                Button("Verify Code") { model.signIn(server, scheme: "email", fields: ["token": .string(code)]) }.disabled(code.isEmpty)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("token") {
                    DisclosureGroup("Sign in with a token") {
                        SecureField("Access token", text: $token).textFieldStyle(.roundedBorder).padding(.top, 8)
                        Button("Sign In") { model.signIn(server, scheme: "token", fields: ["token": .string(token)]); token = "" }.disabled(token.isEmpty)
                    }
                }
                if schemes.contains("webauthn") {
                    Label("Native passkeys are not available in this build. Use another sign-in method offered by this server.", systemImage: "key")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if schemes.isDisjoint(with: ["guest", "email", "token"]) {
                    Text("This server does not offer a sign-in method supported by this build.").foregroundStyle(.orange)
                }
                if server.busy { ProgressView().controlSize(.small) }
            }.disabled(server.busy).padding(36).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
    }
}

struct JumpView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Jump to a conversation…", text: $query).textFieldStyle(.roundedBorder)
            if let server = model.current {
                List(server.rooms.filter { query.isEmpty || server.title($0.string("room_id") ?? "").localizedCaseInsensitiveContains(query) }, id: \.self) { room in
                    Button {
                        model.selectRoom(room.string("room_id") ?? "", server: server, asThread: room.string("parent_room_id") != nil); dismiss()
                    } label: { Label(server.title(room.string("room_id") ?? ""), systemImage: room.string("parent_room_id") != nil ? "arrow.turn.down.right" : "number") }
                    .buttonStyle(.plain)
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 420, height: 340)
    }
}
