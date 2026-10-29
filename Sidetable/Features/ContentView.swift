import SwiftUI
import AppKit
import ApronCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            // A split view would not report or restore the members width, so the
            // column keeps its own width and divider, like conversation panels.
            HStack(spacing: 0) {
                discussions
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .ignoresSafeArea(.container, edges: visibility == .detailOnly ? [] : .top)
                Group {
                    if model.showMembers {
                        ResizeHandle(width: model.membersWidth, range: AppModel.membersWidthRange,
                                     defaultWidth: AppModel.defaultMembersWidth, leadingEdge: true,
                                     title: "members panel", identifier: "membersResizeHandle") { width in
                            model.membersWidth = width
                        } finished: {
                            model.saveMembersPanel()
                        }
                        membersColumn
                            .overlay(alignment: .topTrailing) {
                                membersToggle.padding(8)
                            }
                            .frame(width: model.membersWidth)
                    } else {
                        Rectangle().fill(.separator).frame(width: 1)
                        VStack(spacing: 0) {
                            membersToggle.padding(.top, 8)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 44)
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea(.container, edges: .top)
            }
            .ignoresSafeArea(.container, edges: visibility == .detailOnly ? [] : .top)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { model.ensureInitialPanel() }
        .sheet(isPresented: $model.showServerSignIn) {
            if let server = model.current { SignInView(model: model, server: server).frame(minWidth: 420, minHeight: 360) }
        }
        .onChange(of: model.current?.snapshot.phase) { if model.current?.snapshot.phase == .ready { model.showServerSignIn = false } }
        .sheet(isPresented: $model.showAddServer) { AddServerView(model: model) }
        .sheet(isPresented: $model.showOpenLink) { OpenLinkView(model: model) }
        .sheet(isPresented: Binding(get: { model.linkedUser != nil }, set: { if !$0 { model.linkedUser = nil } })) {
            if let server = model.current, let user = model.linkedUser {
                UserProfileView(model: model, server: server, recorded: ["user_id": .string(user)])
            }
        }
        .sheet(isPresented: $model.showJump) { JumpView(model: model) }
        .alert("SideTable", isPresented: Binding(get: { model.globalError != nil }, set: { if !$0 { model.globalError = nil } })) {
            Button("OK") { model.globalError = nil }
        } message: { Text(userText: model.globalError ?? "") }
    }

    private var discussions: some View {
        VStack(spacing: 0) {
            if model.preview {
                Text("Preview · Sample conversations · No server connection")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(6).background(.quaternary.opacity(0.3))
            }
            if let server = model.current {
                if !model.panels.isEmpty {
                    ConversationPanelsView(model: model)
                } else if [.signIn, .authenticating].contains(server.snapshot.phase) {
                    SignInView(model: model, server: server)
                } else {
                    ContentUnavailableView {
                        Label("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Click a room to open it, or ⌘-click to add a panel.")
                    } actions: {
                        if server.snapshot.phase != .ready {
                            Button("Reconnect") { Task { await server.session?.reconnect() } }
                        }
                    }
                }
                ServerNoticesView(model: model, server: server)
                if let until = server.snapshot.roomListingRetryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if until > context.date {
                            Label("Room and member refresh paused by the server. Try again in \(ceil(until.timeIntervalSince(context.date)).formatted(.number.precision(.fractionLength(0)))) seconds. Message history remains available.", systemImage: "clock")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let error = server.error ?? server.snapshot.error {
                    HStack {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(userText: error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { server.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss error")
                    }.padding(12).background(.orange.opacity(0.08))
                }
            } else {
                WelcomeView { model.showAddServer = true }
            }
        }
    }

    private var membersToggle: some View {
        Button { model.showMembers.toggle() } label: {
            Image(systemName: model.showMembers ? "person.2.fill" : "person.2")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.showMembers ? "Collapse members panel" : "Expand members panel")
        .accessibilityLabel(model.showMembers ? "Collapse members panel" : "Expand members panel")
        .accessibilityIdentifier("toggleMembers")
    }

    private var membersColumn: some View {
        Group {
            if let panel = model.activePanel,
               let server = model.servers.first(where: { $0.id == panel.serverID && $0.account == panel.account }) {
                MembersView(model: model, server: server, room: panel.room)
                    .id(panel.key)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("discussionMembers")
            } else {
                Text("Select a discussion to see its members.")
                    .foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
    @Environment(\.openWindow) private var openWindow
    @State private var browse = false
    @State private var create = false
    @State private var signingOut = false
    @State private var detailsServer: ServerModel?
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                if let server = model.current {
                    Button { detailsServer = server } label: {
                        AvatarView(name: server.displayTitle, size: 28, source: server.serverAvatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                    }.buttonStyle(.plain).help("Server details").accessibilityLabel("Server details")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Menu {
                        ForEach(model.servers) { server in
                            Button { model.selectedServer = server.id } label: {
                                Text(userText: "\(server.displayTitle) — \(server.profile.address) · \(server.unread.values.reduce(0, +)) unread")
                            }
                        }
                        Divider()
                        if let server = model.current {
                            Button("Server Details…") { detailsServer = server }
                            Button("Manage Server…") { openWindow(id: "server-management", value: server.id) }
                                .disabled(!server.snapshot.supports("command"))
                        }
                        Button("Add Server…") { model.showAddServer = true }
                    } label: {
                        Text(userText: model.current?.displayTitle ?? "SideTable").font(.headline)
                    }.menuStyle(.borderlessButton)
                    if let server = model.current {
                        Text(userText: server.profile.address).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Label(server.snapshot.phase.rawValue, systemImage: server.snapshot.phase == .ready ? "circle.fill" : "circle.dotted")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { model.showAddServer = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add Server")
            }.padding(16)
            Divider()
            if let server = model.current {
                if [.signIn, .authenticating].contains(server.snapshot.phase), !model.panels.isEmpty {
                    Button("Sign In…") { model.showServerSignIn = true }.padding(8)
                }
                List {
                    Button { model.showJump = true } label: {
                        Label("Jump to conversation…", systemImage: "magnifyingglass")
                    }.buttonStyle(.plain).help("Jump to conversation (⌘K)")
                    let topLevel = server.rooms.filter { $0.string("parent_room_id") == nil }
                    let privateRooms = topLevel.filter { $0.bool("private") }.compactMap { $0.string("room_id") }
                    Section("Rooms") {
                        ForEach(topLevel.filter { !$0.bool("private") }.compactMap { $0.string("room_id") }, id: \.self) { id in
                            sidebarRoom(id, server: server)
                        }
                    }
                    if !privateRooms.isEmpty {
                        Section("Private Rooms") {
                            ForEach(privateRooms, id: \.self) { id in sidebarRoom(id, server: server) }
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
                    let profile = UserProfile(recorded: server.snapshot.you, store: server.snapshot.store)
                    UserProfileButton(model: model, server: server, recorded: server.snapshot.you) {
                        HStack(spacing: 10) {
                            AvatarView(name: profile.name, size: 30, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(userText: server.snapshot.you.string("user_id") == nil ? "Not signed in" : profile.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(userText: profile.status?.capitalized ?? "Account").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(server.snapshot.you.string("user_id") == nil)
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
                    } label: { Image(systemName: "ellipsis").accessibilityLabel("Account options") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("Account options")
                }.padding(14)
                .confirmationDialog("Sign out and remove this account’s saved drafts?", isPresented: $signingOut) {
                    Button("Sign Out", role: .destructive) { model.signOut(server) }
                }
                .sheet(item: $detailsServer) { server in ServerDetailsView(model: model, server: server) }
        .sheet(isPresented: $browse) { BrowseRoomsView(model: model, server: server) }
                .sheet(isPresented: $create) { NewRoomView(model: model, server: server, parent: nil) }
            } else { Spacer() }
        }
    }
    @ViewBuilder private func sidebarRoom(_ id: String, server: ServerModel) -> some View {
        let room = server.snapshot.store.rooms[id] ?? [:]
        Button {
            if NSEvent.modifierFlags.contains(.command) { model.openInNewPanel(id, server: server) }
            else { model.selectRoom(id, server: server) }
        } label: { roomRow(room, server: server).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityIdentifier("sidebarRoom-" + id)
            .accessibilityValue("\(server.unread[id] ?? 0) unread")
            .listRowBackground(model.activePanel?.serverID == server.id && model.activePanel?.room == id ? Color.accentColor.opacity(0.12) : Color.clear)
            .modifier(RoomContextMenu(model: model, server: server, room: id, isThread: false))
        if server.selectedRoom == id {
            SidebarThreadsView(model: model, server: server, parent: id)
                .id(server.id.uuidString + "/" + server.account + "/" + id)
        }
    }
    private func roomRow(_ room: JSONObject, server: ServerModel) -> some View {
        let id = room.string("room_id") ?? ""
        return HStack {
            Image(systemName: room.bool("private") ? "lock" : "number").foregroundStyle(.secondary).frame(width: 18)
            if let participants = server.participants(id) {
                ParticipantAvatars(participants: participants, server: server)
            }
            Text(userText: server.title(id)).lineLimit(1)
            Spacer()
            if let count = server.unread[id], count > 0 {
                Text(String(count)).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.13), in: Capsule()).accessibilityIdentifier("unreadBadge-" + id)
            }
            RoomMuteIndicator(snapshot: server.snapshot, room: id)
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
            if let error { Text(userText: error).foregroundStyle(.red).font(.callout) }
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
    @State private var externalCode = ""
    @State private var tokenExpanded: Bool?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AvatarView(name: server.displayTitle, size: 56, source: server.serverAvatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                Text(userText: server.displayTitle).font(.title.weight(.semibold))
                Text(userText: server.profile.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let description = server.serverDescription { MarkdownMessageView(source: description, size: 13, endpoint: server.profile.address, emojiStore: server.emojis) }
                if let welcome = server.snapshot.server.string("welcome") { MarkdownMessageView(source: welcome, size: 13, endpoint: server.profile.address, emojiStore: server.emojis) }
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
                            Button(server.snapshot.pendingSignIn == "email" ? "Send a New Code" : "Send Code") { code = ""; model.requestEmail(email, server: server) }.disabled(email.isEmpty)
                            if server.snapshot.pendingSignIn == "email" {
                                TextField("Code from your email", text: $code).textFieldStyle(.roundedBorder)
                                Button("Verify Code") { model.signIn(server, scheme: "email", fields: ["token": .string(code)]) }.disabled(code.isEmpty)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("external"), server.snapshot.server["apron"] == .number(9) {
                    GroupBox("Sign in with your browser") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sign in or create an account on the server’s website, then enter the code it shows here.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Sign-in Page") {
                                externalCode = ""; model.requestExternalSignIn(server: server)
                            }
                            if server.snapshot.pendingSignIn == "external" {
                                SecureField("Code from the website", text: $externalCode).textFieldStyle(.roundedBorder)
                                Button("Verify Code") {
                                    model.signIn(server, scheme: "external", fields: ["token": .string(externalCode.trimmingCharacters(in: .whitespacesAndNewlines))])
                                    externalCode = ""
                                }.disabled(externalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Text("Use only a code from the page you opened here. If the connection is lost, open a new sign-in page.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("token") {
                    // Expand when a token is the only way to get a full account.
                    let tokenOnly = !schemes.contains("email") && !(schemes.contains("external") && server.snapshot.server["apron"] == .number(9))
                    DisclosureGroup("Sign in with a token", isExpanded: Binding(get: { tokenExpanded ?? tokenOnly }, set: { tokenExpanded = $0 })) {
                        VStack(alignment: .leading, spacing: 10) {
                            if SignInToken.isPublicServer(server.profile.address) {
                                Text("To get a token for Apron’s public server:").font(.caption).foregroundStyle(.secondary)
                                Text("1. Open web.apron.chat and sign in, or create an account with a passkey.\n2. In any room, send `/invite-device mac` (any name works).\n3. Paste the token or the sign-in link from the reply here.")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Link("Open web.apron.chat", destination: URL(string: "https://web.apron.chat/")!)
                            } else {
                                Text("Your server provides tokens. On many Apron servers, sign in on the server’s website and send `/invite-device <name>`; the reply contains a token and a sign-in link.")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            SecureField("Token or sign-in link", text: $token).textFieldStyle(.roundedBorder).onSubmit(signInWithToken)
                            Button("Sign In", action: signInWithToken).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if schemes.contains("webauthn") {
                    Label("Native passkeys are not available in this build. Browser sign-in can use a website passkey when the server offers it.", systemImage: "key")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if schemes.isDisjoint(with: ["guest", "email", "token"]) && !(schemes.contains("external") && server.snapshot.server["apron"] == .number(9)) {
                    Text("This server does not offer a sign-in method supported by this build.").foregroundStyle(.orange)
                }
                if server.busy { ProgressView().controlSize(.small) }
            }.disabled(server.busy).padding(36).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
    }
    private func signInWithToken() {
        do {
            let value = try SignInToken.parse(token, endpoint: server.profile.address)
            guard !value.isEmpty else { return }
            model.signIn(server, scheme: "token", fields: ["token": .string(value)])
        } catch { server.error = error.localizedDescription }
        token = ""
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

struct OpenLinkView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var text: String { model.openLinkText }
    @State private var error: String?
    @State private var reviewed: ApronLink?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Apron Link").font(.title2.weight(.semibold))
            TextField("https://link.apron.chat/#server=…", text: $model.openLinkText)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("apronLink")
                .onChange(of: text) { reviewed = nil; error = nil }
                .onSubmit(open)
            if let link = reviewed {
                Text(userText: link.server.absoluteString).textSelection(.enabled).font(.callout)
                if !model.servers.contains(where: { (try? ServerAddress.normalize($0.profile.address)) == link.server }) {
                    Text("Connect to this new server?").fontWeight(.medium)
                }
                if link.token != nil {
                    Text("This link signs you in to an account chosen by its sender. Continue only if you trust the source.")
                } else {
                    Text("Open this destination. If sign-in is needed, you can choose how to sign in next.")
                }
            } else { Text("Paste a link to an Apron server, room, message, user, or invite.").foregroundStyle(.secondary) }
            if let error { Text(userText: error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(reviewed == nil ? "Continue" : (reviewed?.token == nil ? "Open" : "Sign In"), action: open)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480).onAppear {
            // URLs delivered by macOS have already been filled in and validated.
            // Manual entry still starts with the editable, empty URL field.
            if !text.isEmpty { reviewed = try? ApronLink(text) }
            focused = reviewed == nil
        }
    }
    private func open() {
        do {
            if let reviewed { try model.openLink(reviewed); dismiss() }
            else { reviewed = try ApronLink(text) }
        } catch { self.error = error.localizedDescription }
    }
}
