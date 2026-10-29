import SwiftUI
import AppKit
import ApronCore

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
