import SwiftUI
import AppKit
import ApronCore
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let room: String
    let isThread: Bool
    @State private var newThread = false
    @State private var leave = false
    @State private var atBottom = true
    @State private var showFilePicker = false
    @State private var visibleCount = 150
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.showFind && !isThread {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in loaded messages", text: $model.findText).textFieldStyle(.plain)
                    Button { model.showFind = false; model.findText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }.padding(12)
                Divider()
            }
            transcript
            if server.snapshot.phase != .ready || server.snapshot.recoveringRooms.contains(room) || server.cached {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(server.cached ? "Saved view · Checking for updates…" : server.snapshot.phase.rawValue)
                }.font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if !server.snapshot.supports("history") && !model.preview {
                Text("Live conversation · This server does not provide message history.")
                    .font(.caption2).foregroundStyle(.secondary).padding(5)
            }
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $newThread) { NewRoomView(model: model, server: server, parent: room) }
        .confirmationDialog("Leave \(server.title(room))?", isPresented: $leave) {
            Button("Leave Room", role: .destructive) { model.perform("room_leave", params: ["room_id": .string(room)], server: server) }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): server.files[room, default: []].append(contentsOf: urls.map { StagedFile(url: $0) })
            case .failure(let error): server.error = error.localizedDescription
            }
        }
        .onChange(of: room) { old, _ in server.attendedRooms.remove(old); atBottom = true; visibleCount = 150 }
        .onDisappear { server.attendedRooms.remove(room) }
    }
    private var header: some View {
        HStack(spacing: 12) {
            if isThread { Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 4) {
                Text(server.title(room)).font(.headline).accessibilityAddTraits(.isHeader)
                if let description = server.snapshot.store.rooms[room]?.string("description"), !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isThread {
                Button { model.thread = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close thread")
            } else if server.snapshot.supports("rooms") {
                Menu {
                    Button("New Thread…") { newThread = true }
                    Button("Leave Room…", role: .destructive) { leave = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            }
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
    private var messages: [JSONObject] {
        let all = server.snapshot.store.timeline(room)
        return !isThread && !model.findText.isEmpty ? all.filter { $0.object("body").string("text")?.localizedCaseInsensitiveContains(model.findText) == true } : all
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: isThread ? "bubble.left" : "number").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                            Text(model.findText.isEmpty ? "The start of \(server.title(room))" : "No matching loaded messages").font(.title2.weight(.semibold))
                            Text(model.findText.isEmpty ? "Make yourself at home. Say something." : "Try another phrase.").foregroundStyle(.secondary)
                        }.padding(28)
                    }
                    if messages.count > visibleCount {
                        Button("Show earlier messages") { visibleCount += 150 }.buttonStyle(.link).padding(20)
                    }
                    ForEach(Array(messages.suffix(visibleCount)), id: \.messageIdentity) { message in
                        MessageRow(model: model, server: server, message: message)
                            .id(message.string("message_id") ?? "")
                    }
                    if !isThread {
                        ForEach(server.rooms.filter { $0.string("parent_room_id") == room }, id: \.self) { thread in
                            Button { model.selectRoom(thread.string("room_id") ?? "", server: server, asThread: true) } label: {
                                HStack {
                                    Image(systemName: "arrow.turn.down.right")
                                    Text(thread.string("title") ?? "Thread").fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 5)
                        }
                    }
                    ForEach(Array(server.snapshot.store.notices.enumerated()), id: \.offset) { _, notice in
                        if notice.string("room_id") == nil || notice.string("room_id") == room {
                            Text(notice.object("body").string("text") ?? "Server notice")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 24)
                        }
                    }
                    ForEach(server.pending.filter { $0.room == room }) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.text).foregroundStyle(.secondary).textSelection(.enabled)
                            if message.sending { Label("Sending…", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
                            else {
                                Text(message.error ?? "Delivery uncertain").font(.caption).foregroundStyle(.orange)
                                HStack {
                                    Button("Retry Same Operation") { model.retry(message, server: server) }
                                        .disabled(message.params.object("body")["embeds"] != nil)
                                    Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                                    Button("Dismiss") { server.pending.removeAll { $0.id == message.id } }
                                }.font(.caption)
                            }
                        }.padding(.horizontal, 24).padding(.vertical, 10)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true; server.attendedRooms.insert(room); markRead() }
                        .onDisappear { atBottom = false; server.attendedRooms.remove(room) }
                }.padding(.vertical, 14)
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { proxy.scrollTo("bottom", anchor: .bottom) } label: { Label("Latest", systemImage: "arrow.down") }
                        .buttonStyle(.bordered).padding(12)
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: messages.count) {
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom); markRead() }
            }
            .onChange(of: room) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private func markRead() {
        guard !server.cached, server.snapshot.phase == .ready, NSApp.isActive,
              let id = messages.last?.string("message_id") else { return }
        server.unread[room] = 0
        model.markRead(id, server: server, room: room)
        let settings = server.snapshot.server.object("ext").object("settings")
        if server.snapshot.supports("ext:settings"), settings["read_cursors"] == .bool(false) { return }
        Task { await server.session?.activity(room: room, fields: ["read_message_id": .string(id)]) }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reply = model.draft(server, room: room).replyTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text("Replying to \(server.snapshot.store.messages[reply]?.object("body").string("text") ?? "message")").lineLimit(1)
                    Spacer()
                    Button { var d = model.draft(server, room: room); d.replyTo = nil; model.setDraft(d, server: server, room: room) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !(server.files[room] ?? []).isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(server.files[room] ?? []) { file in
                            HStack { Image(systemName: "doc"); Text(file.name); Button { server.files[room]?.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                                .font(.caption).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            NativeComposer(text: Binding(get: { model.draft(server, room: room).text }, set: { value in
                var draft = model.draft(server, room: room); draft.text = value; model.setDraft(draft, server: server, room: room)
            }), placeholder: server.snapshot.readOnly ? "Sign in to post in this room" : "Message \(server.title(room))…", enabled: server.snapshot.phase == .ready && !server.snapshot.readOnly && !model.preview) {
                model.send(server: server, room: room)
            }.frame(minHeight: 46, maxHeight: 110).accessibilityIdentifier("messageComposer")
            HStack {
                Button { showFilePicker = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain).help("Attach files").disabled(!server.snapshot.supports("embed:upload") || model.preview)
                Menu {
                    ForEach((server.snapshot.store.members[room] ?? []).sorted(), id: \.self) { id in
                        Button(server.snapshot.store.displayName(["user_id": .string(id)])) {
                            var draft = model.draft(server, room: room); draft.text += "@\(id) "; model.setDraft(draft, server: server, room: room)
                        }
                    }
                } label: { Image(systemName: "at") }.menuStyle(.borderlessButton).frame(width: 24).help("Mention a member")
                Spacer()
                Text("⇧ Return for a new line").font(.caption2).foregroundStyle(.tertiary)
                Button { model.send(server: server, room: room) } label: { Image(systemName: "arrow.up").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).help("Send message").accessibilityLabel("Send message")
                    .disabled(server.snapshot.phase != .ready || server.snapshot.readOnly || model.preview || (model.draft(server, room: room).text.isEmpty && (server.files[room] ?? []).isEmpty))
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 6)
            .dropDestination(for: URL.self) { urls, _ in
                guard server.snapshot.supports("embed:upload"), !model.preview else { return false }
                server.files[room, default: []].append(contentsOf: urls.filter(\.isFileURL).map { StagedFile(url: $0) }); return true
            }
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 34
    private var hue: Double { Double(name.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) } % 360) / 360 }
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.system(size: size * 0.33, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(hue: hue, saturation: 0.45, brightness: 0.7))
            .frame(width: size, height: size).background(Color(hue: hue, saturation: 0.25, brightness: 0.8).opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

struct MessageRow: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let message: JSONObject
    @State private var deleting = false
    @State private var editing = false
    @State private var editText = ""
    private var id: String { message.string("message_id") ?? "" }
    private var sender: JSONObject { message.object("from") }
    private var text: String { message.object("body").string("text") ?? "" }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: server.snapshot.store.displayName(sender))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(server.snapshot.store.displayName(sender)).font(.callout.weight(.semibold))
                    Text("@" + (sender.string("user_id") ?? "unknown")).font(.caption2).foregroundStyle(.tertiary)
                    ForEach((server.snapshot.store.users[sender.string("user_id") ?? ""] ?? sender).strings("roles"), id: \.self) { role in
                        Text(role).font(.caption2).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                    }
                    if let time = message.logID("message_id") {
                        Text(Date(timeIntervalSince1970: Double(time) / 1000), style: .time).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if message.string("log_id") != message.string("message_id") { Text("edited").font(.caption2).foregroundStyle(.tertiary) }
                }
                if let reply = message.object("reply_to").string("message_id") {
                    Label(server.snapshot.store.messages[reply]?.object("body").string("text") ?? "Earlier message", systemImage: "arrowshape.turn.up.left")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if message.bool("deleted") { Text("Message deleted").italic().foregroundStyle(.tertiary) }
                else {
                    if message.object("body").string("format") == "markdown" {
                        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                            .font(.system(size: model.messageSize)).textSelection(.enabled).lineSpacing(3)
                    } else { Text(text).font(.system(size: model.messageSize)).textSelection(.enabled).lineSpacing(3) }
                    ForEach(message.object("body").objects("embeds"), id: \.self) { embed in
                        AttachmentView(embed: embed, endpoint: URL(string: server.profile.address)!)
                    }
                    let reactions = server.snapshot.store.reactionSummary(id)
                    if !reactions.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(reactions.keys.sorted(), id: \.self) { emoji in
                                Button { model.react(emoji, message: message, server: server) } label: {
                                    Text("\(emoji) \(reactions[emoji]!.count)").font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(reactions[emoji]!.contains(server.account) ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: Capsule())
                                }.buttonStyle(.plain).disabled(!server.snapshot.supports("reactions"))
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .environment(\.openURL, OpenURLAction { url in MediaPolicy.safeLink(url) ? .systemAction : .discarded })
            .contextMenu {
                Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                if !message.bool("deleted") {
                    Button("Reply") {
                        let room = message.string("room_id") ?? ""
                        var draft = model.draft(server, room: room); draft.replyTo = id; model.setDraft(draft, server: server, room: room)
                    }
                    if server.snapshot.supports("reactions") {
                        Menu("React") { ForEach(["👍", "❤️", "🎉", "👀", "✨"], id: \.self) { emoji in Button(emoji) { model.react(emoji, message: message, server: server) } } }
                    }
                    if server.snapshot.supports("edit") {
                        Button("Edit…") { editText = text; editing = true }
                        Menu("Move to…") {
                            ForEach(server.rooms, id: \.self) { room in
                                Button(server.title(room.string("room_id") ?? "")) { model.saveMessage(message, destination: room.string("room_id"), server: server) }
                            }
                        }
                        Button("Delete…", role: .destructive) { deleting = true }
                    }
                }
            }
            .confirmationDialog("Delete this message?", isPresented: $deleting) {
                Button("Delete Message", role: .destructive) { model.saveMessage(message, deleted: true, server: server) }
            }
            .sheet(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Edit message").font(.title2.weight(.semibold))
                    TextEditor(text: $editText).font(.body).frame(height: 160).border(.quaternary)
                    HStack { Spacer(); Button("Cancel") { editing = false }; Button("Save") { model.saveMessage(message, text: editText, server: server); editing = false }.buttonStyle(.borderedProminent) }
                }.padding(24).frame(width: 480)
            }
    }
}

struct EmbedView: View {
    let embed: JSONObject
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: embed.string("kind") == "upload" ? "doc" : "link").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(embed.string("title") ?? embed.string("kind") ?? "Attachment").font(.callout.weight(.medium))
                if let address = embed.string("url"), let url = URL(string: address), MediaPolicy.safeLink(url) {
                    Link("Open attachment ↗", destination: url).font(.caption)
                } else {
                    Text(embed.string("kind") == "upload" ? "Upload pending…" : "Preview unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
