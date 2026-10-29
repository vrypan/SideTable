import AppKit
import ApronCore
import SwiftUI

struct ServerDetailsView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AvatarView(name: server.displayTitle, size: 56, source: server.serverAvatar,
                    endpoint: URL(string: server.profile.address), cache: server.avatars)
                VStack(alignment: .leading, spacing: 5) {
                    Text(userText: server.displayTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(server.snapshot.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(userText: server.profile.address).font(.callout.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("serverDetailsAddress")
            ScrollView {
                if let description = server.serverDescription, !description.isEmpty {
                    MarkdownMessageView(source: description, size: 14, endpoint: server.profile.address,
                        reviewLink: { model.receiveLink($0, from: server) }, emojiStore: server.emojis)
                } else { Text("This server has not provided a description.").foregroundStyle(.secondary) }
            }.frame(maxHeight: 220)
            PrivateRoomQuotaView(snapshot: server.snapshot)
            HStack {
                Button(copied ? "Copied Address" : "Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.profile.address, forType: .string)
                    copied = true
                }
                if let link = ServerLink.url(endpoint: server.profile.address) {
                    ShareLink("Share Server…", item: link)
                    Button("Copy Server Link") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 500)
            .onChange(of: server.profile.address) { copied = false }
    }
}
