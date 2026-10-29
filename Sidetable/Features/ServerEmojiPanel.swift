import AppKit
import ApronCore
import SwiftUI

struct ServerEmojiPanel: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let close: () -> Void
    @State private var search = ""
    @State private var selected: String?
    @State private var name = ""
    @State private var image: StagedFile?
    @State private var choosing = false
    @State private var discardAll = false
    private var edits: EmojiEditQueue { server.emojiEdits }
    private var keys: [String] {
        Set(server.emojis.catalog.keys).union(edits.changes.map(\.key)).sorted().filter {
            search.isEmpty || $0.localizedCaseInsensitiveContains(search) || server.emojis.catalog[$0]?.matches(search) == true
        }
    }
    private var active: EmojiEditQueue.Change? { edits.changes.first { $0.key == selected } }
    private var canSave: Bool {
        !model.preview && !server.cached && server.snapshot.phase == .ready && server.snapshot.supports("command")
            && !edits.saving && !edits.changes.isEmpty
    }
    private var canonicalName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(":") ? trimmed : ":" + trimmed + ":"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Server Emoji").font(.title2.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "sidebar.right") }.help("Hide emoji panel")
            }
            Text("Add or remove emoji below, then Save to apply your changes.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search server emoji", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                    ForEach(keys, id: \.self) { key in
                        let change = edits.changes.first { $0.key == key }
                        Button { selected = key; name = key; image = nil } label: {
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    Group {
                                        if let file = change?.file { StagedEmojiImage(file: file) }
                                        else { CustomEmojiView(key: key, store: server.emojis, size: 26, maximumWidth: 40) }
                                    }.frame(width: 48, height: 36).opacity(change != nil && change?.file == nil ? 0.35 : 1)
                                    if let change {
                                        Image(systemName: change.file == nil ? "minus.circle.fill" : "plus.circle.fill")
                                            .font(.caption).foregroundStyle(change.file == nil ? .red : .green)
                                    }
                                }
                                Text(userText: String(key.dropFirst().dropLast())).font(.system(size: 9)).lineLimit(1)
                            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(selected == key ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(edits.saving)
                            .help(UserText.isolated(key + (server.emojis.catalog[key]?.hidden == true ? " · Hidden from picker" : "")))
                            .accessibilityLabel(UserText.clean(key))
                            .contextMenu {
                                Button("Remove on Save", role: .destructive) { stageRemoval(key) }.disabled(edits.saving)
                                if change != nil { Button("Undo Pending Change") { edits.discard(key) }.disabled(edits.saving) }
                            }
                    }
                }
            }.frame(maxHeight: .infinity)
                .overlay {
                    if keys.isEmpty {
                        if server.emojis.loading { ProgressView().controlSize(.small) }
                        else { Text("No server emoji found").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            if server.emojis.failed {
                HStack {
                    Text("Could not load the catalog.").font(.caption)
                    Button("Retry") { server.emojis.retry() }
                }
            }
            if let selected {
                HStack {
                    Text(userText: selected).font(.caption).lineLimit(1)
                    Spacer()
                    if active != nil {
                        Button("Undo Change") { edits.discard(selected) }.disabled(edits.saving)
                    }
                    Button("Remove", role: .destructive) { stageRemoval(selected) }
                        .disabled(edits.saving || (active != nil && active?.file == nil))
                }
                if let error = active?.error { Text(userText: error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            Divider()
            HStack {
                TextField(":emoji_name:", text: $name).textFieldStyle(.roundedBorder)
                Button("Choose Image…") { choosing = true }.disabled(edits.saving || !server.snapshot.supports("embed:upload"))
            }
            HStack {
                if let image { StagedEmojiImage(file: image).frame(width: 24, height: 24); Text(userText: image.name).font(.caption).lineLimit(1) }
                Spacer()
                Button(server.emojis.catalog[canonicalName] == nil ? "Add to Changes" : "Stage Replacement") {
                    if let image { edits.add(canonicalName, file: image); selected = canonicalName; self.image = nil; name = "" }
                }.disabled(edits.saving || !CustomEmoji.validKey(canonicalName) || image == nil)
            }
            RequestCooldownView(snapshot: server.snapshot, method: "command", hasUploads: edits.changes.contains { $0.file != nil })
            if let status = edits.status { Text(userText: status).font(.caption).foregroundStyle(.secondary) }
            if let failed = edits.changes.first(where: { $0.error != nil }), failed.key != selected {
                Button("Review failed change: \(failed.key)") { selected = failed.key; name = failed.key; image = nil }.font(.caption)
            }
            HStack {
                if edits.saving { ProgressView().controlSize(.small) }
                Text("\(edits.changes.count) pending").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Discard…") { discardAll = true }.disabled(edits.saving || edits.changes.isEmpty)
                CooldownButton(snapshot: server.snapshot, method: "command", hasUploads: edits.changes.contains { $0.file != nil },
                    disabled: !canSave, action: { model.saveEmojiChanges(server: server) }) { Text("Save") }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(16).background(.background)
            .sheet(isPresented: $choosing) {
                AttachmentPickerView(snapshot: server.snapshot, category: "emoji", multiple: false) { image = $0.first }
            }
            .confirmationDialog("Discard pending emoji changes?", isPresented: $discardAll) {
                Button("Discard Changes", role: .destructive) { edits.reset(); image = nil }
            } message: { Text("Changes already accepted by the server will remain.") }
            .task(id: server.emojis.generation) { await server.emojis.loadCatalog() }
    }
    private func stageRemoval(_ key: String) {
        edits.remove(key, exists: server.emojis.catalog[key] != nil)
    }
}

private struct StagedEmojiImage: View {
    let file: StagedFile
    @State private var bitmap: CustomEmojiBitmap?
    var body: some View {
        Group {
            if let frame = bitmap?.frames.first {
                Image(nsImage: NSImage(cgImage: frame, size: .zero)).resizable().scaledToFit()
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: file.id) {
            bitmap = await Task.detached {
                guard let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= AvatarLoader.maximumBytes,
                      let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { return nil as CustomEmojiBitmap? }
                return try? CustomEmojiLoader.bitmap(data)
            }.value
        }
    }
}
