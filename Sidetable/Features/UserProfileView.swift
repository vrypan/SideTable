import SwiftUI
import AppKit
import ApronCore

struct UserProfileButton<Label: View>: View {
    @Bindable var server: ServerModel
    let recorded: JSONObject
    @ViewBuilder var label: () -> Label
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { label() }
            .buttonStyle(.plain)
            .help("View profile")
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
    private var profile: UserProfile { UserProfile(recorded: recorded, store: server.snapshot.store) }
    private var endpoint: URL { URL(string: server.profile.address)! }
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
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
            .onChange(of: server.account) { dismiss() }
    }
}
