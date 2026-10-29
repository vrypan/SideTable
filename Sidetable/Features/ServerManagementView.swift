import ApronCore
import SwiftUI

/// Management commands are sent without a room or Markdown interpretation.
enum ServerManagementCommand {
    static func parameters(_ command: String, files: [StagedFile]) -> JSONObject {
        var body: JSONObject = ["text": .string(command)]
        if !files.isEmpty {
            body["embeds"] = .array(files.map { .object(["kind": .string("upload"), "title": .string($0.name)]) })
        }
        return ["body": .object(body)]
    }
    static func setting(_ name: String, value: String) -> String {
        "/server \(name)" + (value.isEmpty ? "" : " " + value)
    }
}

struct ServerManagementView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var emojiKey = ""
    @State private var file: StagedFile?
    @State private var icon: StagedFile?
    @State private var picker: String?
    @State private var confirmation: String?
    @State private var latest: PendingMessage?
    @State private var error: String?

    private var operations: [PendingMessage] {
        server.pending.filter { $0.isManagement && $0.account == server.account }
    }
    private var busy: Bool {
        operations.contains { message in
            message.sending || (message.acknowledged && message.uploads.contains { [.waiting, .uploading].contains($0.phase) })
        }
    }
    private var unavailable: Bool {
        model.preview || server.cached || server.snapshot.phase != .ready || !server.snapshot.supports("command") || busy
    }
    private var existingEmoji: Bool { server.emojis.catalog[emojiKey] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Server").font(.title2.weight(.semibold))
            Text(userText: server.displayTitle).foregroundStyle(.secondary)
            Text("Available actions depend on your server permissions and supported commands.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Server details") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                            commandButton("Save Title", command: ServerManagementCommand.setting("title", value: title))
                            Text("Description").font(.caption)
                            TextEditor(text: $description).frame(height: 85).border(.quaternary)
                                .accessibilityLabel("Server description")
                            commandButton("Save Description", command: ServerManagementCommand.setting("description", value: description))
                            Text("Leave a field empty to clear it.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Choose Server Icon…") { picker = "avatar" }
                                    .disabled(unavailable || !server.snapshot.supports("embed:upload"))
                                Button("Remove Icon…", role: .destructive) { confirmation = "/server avatar" }
                                    .disabled(unavailable || server.serverAvatar == nil)
                            }
                            if let icon {
                                Text(userText: icon.name).font(.caption)
                                CooldownButton(snapshot: server.snapshot, method: "command", hasUploads: true,
                                    disabled: unavailable, action: { if send("/server avatar", files: [icon]) { self.icon = nil } }) {
                                        Text("Upload Server Icon")
                                    }
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if server.snapshot.supports("ext:emoji") {
                        GroupBox("Custom emoji") {
                            VStack(alignment: .leading, spacing: 10) {
                                if server.emojis.loading { ProgressView().controlSize(.small) }
                                if server.emojis.failed {
                                    Text("The emoji catalog could not be loaded.").foregroundStyle(.secondary)
                                }
                                if !server.emojis.catalog.isEmpty {
                                    Menu("Choose Existing Emoji") {
                                        ForEach(server.emojis.catalog.values.sorted { $0.id < $1.id }) { emoji in
                                            Button(emoji.id + (emoji.hidden ? " (hidden)" : "")) { emojiKey = emoji.id }
                                        }
                                    }
                                }
                                TextField(":emoji_name:", text: $emojiKey).textFieldStyle(.roundedBorder)
                                Text("Use letters, numbers, underscores, + or - between colons.")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Choose Image…") { picker = "emoji" }
                                        .disabled(unavailable || !server.snapshot.supports("embed:upload"))
                                    if let file { Text(userText: file.name).lineLimit(1) }
                                }
                                HStack {
                                    CooldownButton(snapshot: server.snapshot, method: "command", hasUploads: true,
                                        disabled: unavailable || !CustomEmoji.validKey(emojiKey) || file == nil,
                                        action: {
                                            confirmation = "/emoji add " + emojiKey
                                        }) { Text(existingEmoji ? "Replace Emoji…" : "Add Emoji…") }
                                    Button("Remove Emoji…", role: .destructive) { confirmation = "/emoji remove " + emojiKey }
                                        .disabled(unavailable || !CustomEmoji.validKey(emojiKey))
                                }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let error { Text(userText: error).foregroundStyle(.red) }
                    RequestCooldownView(snapshot: server.snapshot, method: "command", hasUploads: true)
                    if let latest, latest.account == server.account, latest.acknowledged, latest.uploads.isEmpty {
                        Label("Change accepted by the server.", systemImage: "checkmark.circle").font(.callout)
                    }
                    ForEach(operations) { operation in
                        DeliveryView(model: model, server: server, message: operation)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560, height: 650)
            .onAppear { title = server.snapshot.server.string("title") ?? ""; description = server.serverDescription ?? "" }
            .task(id: server.emojis.generation) { await server.emojis.loadCatalog() }
            .sheet(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
                if let category = picker {
                    AttachmentPickerView(snapshot: server.snapshot, category: category, multiple: false) { files in
                        if category == "avatar" { icon = files.first }
                        else { file = files.first }
                    }
                }
            }
            .confirmationDialog("Confirm Server Change", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                if let command = confirmation {
                    Button(command.hasPrefix("/emoji add") ? "Add or Replace Emoji" : "Remove", role: .destructive) {
                        let replacing = command.hasPrefix("/emoji add")
                        if send(command, files: replacing ? file.map { [$0] } ?? [] : []), replacing { file = nil }
                        confirmation = nil
                    }
                }
            } message: { Text(userText: confirmation ?? "") }
            .onChange(of: server.account) { file = nil; icon = nil; dismiss() }
    }
    private func commandButton(_ label: String, command: String) -> some View {
        CooldownButton(snapshot: server.snapshot, method: "command", disabled: unavailable,
            action: { send(command) }) { Text(label) }
    }
    @discardableResult
    private func send(_ command: String, files: [StagedFile] = []) -> Bool {
        guard !unavailable else { error = "Wait until the server is connected and the current operation finishes."; return false }
        guard server.snapshot.cooldown(for: "command", hasUploads: !files.isEmpty) == nil else {
            error = "Wait for the countdown before trying again."; return false
        }
        latest = model.manageServer(command, files: files, server: server)
        error = latest == nil ? server.error ?? "The command could not be sent." : nil
        return latest != nil
    }
}
