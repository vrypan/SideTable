import SwiftUI
import ApronCore

/// Settings > Servers: add, remove, reorder, and edit the servers SideTable connects to.
struct ServerListSettings: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?
    @State private var adding = false
    @State private var removing: ServerModel?
    private var selected: ServerModel? { model.servers.first { $0.id == selection } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.servers) { server in
                        ServerListRow(server: server).tag(server.id)
                    }.onMove { model.moveServers(from: $0, to: $1) }
                }.listStyle(.bordered(alternatesRowBackgrounds: false)).accessibilityIdentifier("serverList")
                HStack(spacing: 0) {
                    Button { adding = true } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                        .help("Add Server").accessibilityLabel("Add Server")
                    Button { removing = selected } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                        .help("Remove Server").accessibilityLabel("Remove Server").disabled(selected == nil)
                    Spacer()
                }.buttonStyle(.borderless).padding(.top, 4)
                Text("Drag to reorder. ⌥⌘1–9 switch to the first nine.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.frame(width: 210)
            if let server = selected {
                ServerListDetail(model: model, server: server) { removing = server }.id(server.id)
            } else {
                ContentUnavailableView("No Server Selected", systemImage: "network",
                    description: Text(model.servers.isEmpty ? "Add a server to get started." : "Select a server to edit it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = model.selectedServer ?? model.servers.first?.id } }
        .onChange(of: model.servers.map(\.id)) { _, ids in
            // Select a newly added server; keep a valid selection after removal.
            if let id = model.selectedServer, ids.contains(id), adding || selection == nil || !ids.contains(selection!) { selection = id }
            else if let selection, !ids.contains(selection) { self.selection = ids.first }
        }
        .sheet(isPresented: $adding) { AddServerView(model: model) }
        .confirmationDialog("Remove \(removing?.displayTitle ?? "this server")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Server", role: .destructive) { if let removing { model.remove(removing) }; removing = nil }
        } message: {
            Text("Its drafts, saved conversations, downloaded media, and saved sign-ins on this Mac are deleted.")
        }
    }
}

private struct ServerListRow: View {
    @Bindable var server: ServerModel
    var body: some View {
        HStack(spacing: 8) {
            AvatarView(name: server.displayTitle, size: 24, source: server.serverAvatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
            VStack(alignment: .leading, spacing: 2) {
                Text(userText: server.displayTitle).lineLimit(1)
                Text(userText: server.profile.address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Circle().fill(server.snapshot.phase == .ready ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                .help(server.snapshot.phase.rawValue)
        }.padding(.vertical, 2)
    }
}

private struct ServerListDetail: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let remove: () -> Void
    @State private var address = ""
    @State private var addressError: String?
    @State private var addressNotice: String?
    @State private var signingOut = false
    private var account: String? { server.snapshot.you.string("user_id") }
    private var addressChanged: Bool {
        (try? ServerAddress.normalize(address)) != (try? ServerAddress.normalize(server.profile.address))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    AvatarView(name: server.displayTitle, size: 36, source: server.serverAvatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(userText: server.displayTitle).font(.headline)
                        Text(userText: server.snapshot.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Address") {
                    TextField("Address", text: $address).labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit(applyAddress).accessibilityIdentifier("serverAddressEditor")
                }
                if addressChanged {
                    HStack {
                        Text("Another path on the same host keeps your sign-in. A different host signs you out.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revert") { address = server.profile.address; addressError = nil }
                        Button("Apply", action: applyAddress).buttonStyle(.borderedProminent)
                    }
                }
                if let addressError { Text(userText: addressError).font(.caption).foregroundStyle(.red) }
                if let addressNotice { Text(userText: addressNotice).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Account") {
                LabeledContent("Signed in as", value: account.map { "@" + $0 } ?? "Not signed in")
                HStack {
                    Button("Reconnect") { Task { await server.session?.reconnect() } }.disabled(model.preview)
                    Button("Sign Out…") { signingOut = true }.disabled(account == nil || model.preview)
                }
                let saved = model.savedAccounts(server)
                if !saved.isEmpty {
                    ForEach(saved, id: \.self) { saved in
                        LabeledContent("Saved: @" + saved) {
                            Button("Forget") { model.forgetSavedAccount(saved, server: server) }
                        }
                    }
                }
            }
            Section {
                Button("Remove Server…", role: .destructive, action: remove)
            }
        }
        .formStyle(.grouped)
        .onAppear { address = server.profile.address }
        .confirmationDialog("Sign out of @\(account ?? "")?", isPresented: $signingOut) {
            Button("Sign Out", role: .destructive) { model.signOut(server) }
        } message: { Text("This account’s drafts and saved conversations on this Mac are removed. Its sign-in stays saved, so you can continue as this account later.") }
    }

    private func applyAddress() {
        guard addressChanged else { return }
        addressError = nil; addressNotice = nil
        do {
            let keptSignIn = try model.changeAddress(server, to: address)
            address = server.profile.address
            addressNotice = keptSignIn ? nil : "The host changed, so you were signed out. Sign in to the new server."
        } catch { addressError = error.localizedDescription }
    }
}
