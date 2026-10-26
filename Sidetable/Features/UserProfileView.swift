import SwiftUI
import AppKit
import ApronCore

struct UserProfileButton<Label: View>: View {
    @Bindable var server: ServerModel
    let recorded: JSONObject
    var hoverText: String = "View profile"
    @ViewBuilder var label: () -> Label
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { label() }
            .buttonStyle(.plain)
            .help(hoverText)
            .accessibilityLabel("View profile for \(UserProfile(recorded: recorded, store: server.snapshot.store).name)")
            .sheet(isPresented: $showing) { UserProfileView(server: server, recorded: recorded) }
            .onChange(of: server.account) { showing = false }
            .onChange(of: server.id) { showing = false }
    }
}

struct UserProfileView: View {
    @Bindable var server: ServerModel
    let recorded: JSONObject
    @Environment(\.dismiss) private var dismiss
    @State private var editingBio = false
    @State private var bioDraft = ""
    @State private var savingBio = false
    @State private var bioError: String?
    @State private var bioOperation = UUID()
    @State private var bioTask: Task<Void, Never>?
    private var profile: UserProfile { UserProfile(recorded: recorded, store: server.snapshot.store) }
    private var endpoint: URL { URL(string: server.profile.address)! }
    private var supportsBio: Bool { ProfileBio.isSupported(by: server.snapshot) }
    private var canEditBio: Bool {
        supportsBio && profile.id == server.account && !server.cached && server.snapshot.phase == .ready && server.session != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                AvatarView(name: profile.name, size: 80, source: profile.avatar, endpoint: endpoint, cache: server.avatars)
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("@" + profile.id).foregroundStyle(.secondary).textSelection(.enabled)
                    if server.cached {
                        Text("Saved profile").font(.caption).foregroundStyle(.secondary)
                    } else if let status = profile.status {
                        Label(status == "dnd" ? "Do Not Disturb" : status.capitalized, systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(status == "online" ? .green : .secondary)
                        if let seen = profile.lastSeen {
                            Text("Last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if supportsBio {
                if editingBio { bioEditor }
                else {
                    if let bio = profile.bio {
                        Text(ProfileBio.linkedText(bio)).font(.callout).textSelection(.enabled).accessibilityIdentifier("profileBio")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if canEditBio {
                        Button(profile.bio == nil ? "Add Bio…" : "Edit Bio…") {
                            bioDraft = profile.bio ?? ""; bioError = nil; editingBio = true
                        }.font(.callout)
                    }
                }
            }
            if !profile.roles.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Roles").font(.caption).foregroundStyle(.secondary)
                    Text(profile.roles.joined(separator: ", ")).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Server").font(.caption).foregroundStyle(.secondary)
                Text(server.profile.title).textSelection(.enabled)
            }
            if !profile.hasCurrentIdentity {
                Text("Showing the identity recorded with this message. Current profile details are not available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy User ID") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(profile.id, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 360)
            .onChange(of: server.account) { cancelBioSave(); dismiss() }
            .onChange(of: server.id) { cancelBioSave(); dismiss() }
            .onDisappear { cancelBioSave() }
    }

    private var bioEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bio").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $bioDraft).font(.callout).frame(height: 88)
                .border(.quaternary).disabled(savingBio).accessibilityLabel("Bio")
            let count = ProfileBio.characterCount(bioDraft)
            Text("\(count) / \(ProfileBio.maximumCharacters)").font(.caption)
                .foregroundStyle(count > ProfileBio.maximumCharacters ? .red : .secondary)
            if let bioError { Text(bioError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { cancelBioSave(); editingBio = false }.disabled(savingBio)
                Spacer()
                if savingBio { ProgressView().controlSize(.small) }
                Button("Save Bio") { saveBio() }
                    .disabled(savingBio || !canEditBio || count > ProfileBio.maximumCharacters
                        || ProfileBio.clean(bioDraft) == (profile.bio ?? ""))
            }
        }
    }

    private func cancelBioSave() {
        bioOperation = UUID(); bioTask?.cancel(); bioTask = nil; savingBio = false
    }

    private func saveBio() {
        let bio = ProfileBio.clean(bioDraft)
        guard canEditBio, !savingBio, bio.unicodeScalars.count <= ProfileBio.maximumCharacters,
              let session = server.session else { return }
        let account = server.account, serverID = server.id, operation = UUID()
        bioOperation = operation; savingBio = true; bioError = nil
        bioTask = Task { @MainActor in
            defer {
                if bioOperation == operation { savingBio = false; bioTask = nil }
            }
            do {
                // `me` patches ext keys; sending only bio preserves other extensions. ApronSession
                // applies the authoritative `you` result and publishes the updated current profile.
                _ = try await session.perform("me", params: ["ext": .object(["bio": .string(bio)])])
                guard !Task.isCancelled, bioOperation == operation, server.id == serverID,
                      server.account == account, server.session === session else { return }
                savingBio = false; editingBio = false; bioTask = nil
            } catch {
                guard !Task.isCancelled, bioOperation == operation, server.id == serverID,
                      server.account == account, server.session === session else { return }
                savingBio = false; bioTask = nil; bioError = error.localizedDescription
            }
        }
    }
}
