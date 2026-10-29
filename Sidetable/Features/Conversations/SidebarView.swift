import SwiftUI
import AppKit
import ApronCore

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var browse = false
    @State private var create = false
    @State private var signingOut = false
    @State private var detailsServer: ServerModel?
    @State private var removingServer: ServerModel?
    @Environment(\.openSettings) private var openSettings
    /// Right-click on the server header: switch servers and manage the current one.
    @ViewBuilder private var serverHeaderMenu: some View {
        ForEach(model.servers) { server in
            Toggle(isOn: Binding(get: { model.selectedServer == server.id }, set: { if $0 { model.selectedServer = server.id } })) {
                let unread = server.unread.values.reduce(0, +)
                Text(userText: server.displayTitle + (unread > 0 ? " · \(unread) unread" : ""))
            }
        }
        Divider()
        if let server = model.current {
            Button("Server Details…") { detailsServer = server }
            Button("Manage Server…") { openWindow(id: "server-management", value: server.id) }
                .disabled(!server.snapshot.supports("command"))
        }
        Button("Add Server…") { model.showAddServer = true }
        Button("Edit Server List…") { model.settingsTab = 2; openSettings() }
        if let server = model.current {
            Divider()
            Button("Remove “\(server.displayTitle)”…", role: .destructive) { removingServer = server }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                if let server = model.current {
                    Button { detailsServer = server } label: {
                        AvatarView(name: server.displayTitle, size: 28, source: server.serverAvatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                    }.buttonStyle(.plain).help("Server details").accessibilityLabel("Server details")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(userText: model.current?.displayTitle ?? "SideTable").font(.headline).lineLimit(1)
                    if let server = model.current {
                        Text(userText: server.profile.address).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Label(server.snapshot.phase.rawValue, systemImage: server.snapshot.phase == .ready ? "circle.fill" : "circle.dotted")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { model.showAddServer = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add Server")
            }.padding(16)
            .contentShape(Rectangle())
            .contextMenu { serverHeaderMenu }
            .confirmationDialog("Remove \(removingServer?.displayTitle ?? "this server")?", isPresented: Binding(get: { removingServer != nil }, set: { if !$0 { removingServer = nil } })) {
                Button("Remove Server", role: .destructive) { if let removingServer { model.remove(removingServer) }; removingServer = nil }
            } message: {
                Text("Its drafts, saved conversations, downloaded media, and saved sign-ins on this Mac are deleted.")
            }
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
                .confirmationDialog("Sign out and remove this account’s saved drafts? Its sign-in stays saved, so you can continue as this account later.", isPresented: $signingOut) {
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
