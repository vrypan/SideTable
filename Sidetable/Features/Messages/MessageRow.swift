import SwiftUI
import AppKit
import ApronCore
import UniformTypeIdentifiers

struct MessageRow: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let message: JSONObject
    var editMessage: ((JSONObject, [JSONObject]) -> Void)? = nil
    var focusComposer: () -> Void = {}
    @State private var startingThread = false
    @State private var selectedUserProfile: String?
    @State private var showingProfile = false
    @State private var showingSource = false
    @State private var deleting = false
    @State private var showingReactionPicker = false
    @State private var menuHighlight = MessageMenuHighlight()
    @State private var isHovered = false
    @State private var showHoverActions = false
    private var id: String { message.string("message_id") ?? "" }
    private var sender: JSONObject { message.object("from") }
    private var text: String { message.object("body").string("text") ?? "" }
    private var displayEmbeds: [JSONObject] {
        let existing = message.object("body").objects("embeds")
        return existing + localPreviews
    }
    private var localPreviews: [JSONObject] {
        let hidden = model.linkPreviews.hidden(server: server.id, account: server.account, message: id)
        let existing = message.object("body").objects("embeds")
        let markdown = message.object("body").string("format") == "markdown"
        let github = GitHubPreviewCache.shared.missingEmbeds(in: text, existing: existing, markdown: markdown)
        let apron = ApronLinkDiscovery.shared.missingEmbeds(in: text, markdown: markdown,
                                                          endpoint: server.profile.address, existing: existing)
        return (github + apron).filter { !hidden.contains($0.string("url") ?? "") }
    }
    private var profile: UserProfile { UserProfile(recorded: sender, store: server.snapshot.store) }
    private var mentionNames: [String: String] {
        let store = server.snapshot.store
        return Dictionary(uniqueKeysWithValues: MessageMentions.userIDs(in: text).compactMap { id in
            guard store.users[id] != nil || store.aliases[id] != nil else { return nil }
            return (id, store.displayName(["user_id": .string(id)]))
        })
    }
    private var canWrite: Bool { server.snapshot.phase == .ready && !server.cached && !server.snapshot.readOnly && !message.bool("deleted") }
    private var canStartThread: Bool {
        canWrite && server.snapshot.supports("rooms") && message.string("room_id").flatMap { server.snapshot.store.rooms[$0] }.map { $0.string("parent_room_id") == nil } == true
    }
    private var link: URL? { MessageLink.url(endpoint: server.profile.address, message: message, rooms: server.snapshot.store.rooms) }
    var body: some View {
        let _ = RenderProfile.count("rowBody")
        HStack(alignment: .top, spacing: 12) {
            UserProfileButton(model: model, server: server, recorded: sender) {
                AvatarView(name: profile.name, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UserProfileButton(model: model, server: server, recorded: sender) {
                        Text(userText: profile.name).font(.callout.weight(.semibold))
                    }
                    ForEach(profile.roles, id: \.self) { role in
                        Text(userText: role).font(.caption2).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                    }
                    if let time = message.logID("message_id") {
                        Text(Date(timeIntervalSince1970: Double(time) / 1000), style: .time).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !message.bool("deleted") {
                        HStack(spacing: 4) {
                            Button(action: reply) {
                                Image(systemName: "arrowshape.turn.up.left")
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .help("Reply to message")
                            .accessibilityLabel("Reply to message")
                            .accessibilityIdentifier("replyToMessage-" + id)
                            if server.snapshot.supports("reactions") {
                                Button { showingReactionPicker = true } label: {
                                    Image(systemName: "face.smiling")
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .help("React to message")
                                .accessibilityLabel("React to message")
                                .accessibilityIdentifier("reactToMessage-" + id)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(!canWrite)
                        .opacity(showHoverActions || showingReactionPicker ? 1 : 0)
                        .allowsHitTesting(showHoverActions || showingReactionPicker)
                        .accessibilityHidden(!showHoverActions && !showingReactionPicker)
                    }
                    if message.string("log_id") != message.string("message_id") { Text("edited").font(.caption2).foregroundStyle(.tertiary) }
                }
                if let reply = message.object("reply_to").string("message_id") {
                    let original = server.snapshot.store.messages[reply]
                    Button { showOriginal(reply) } label: {
                        Label(original?.object("body").string("text") ?? "Earlier message", systemImage: "arrowshape.turn.up.left")
                            .lineLimit(1).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).font(.system(size: model.messageSize)).foregroundStyle(.secondary.opacity(0.8))
                    .help("Show original message")
                    .accessibilityIdentifier("replyContext-" + id)
                }
                if message.bool("deleted") { Text("Message deleted").italic().foregroundStyle(.tertiary) }
                else {
                    if message.object("body").string("format") == "markdown" {
                        MarkdownMessageView(source: text, size: model.messageSize, mentionNames: mentionNames, roomNames: server.roomReferenceNames(in: text), endpoint: server.profile.address, reviewLink: { model.receiveLink($0, from: server) }, showMention: { selectedUserProfile = $0 }, emojiStore: server.emojis)
                            .id(server.account + "/" + id)
                    } else { EmojiMessageText(text: MessageTextDisplay.attributed(text, names: mentionNames, roomNames: server.roomReferenceNames(in: text)), size: model.messageSize, store: server.emojis) }
                    ForEach(displayEmbeds, id: \.self) { embed in
                        if embed.string("kind") != "upload", let address = embed.string("url"),
                           let preview = ApronLinkPreview(address: address, endpoint: server.profile.address,
                                                         store: server.snapshot.store, serverTitle: server.displayTitle) {
                            ApronLinkPreviewCard(preview: preview, serverTitle: server.displayTitle) {
                                model.receiveLink(preview.url, from: server)
                            }
                        } else {
                            AttachmentView(embed: embed, endpoint: URL(string: server.profile.address)!, serverID: server.id, account: server.account, mediaOrigins: server.snapshot.mediaOrigins)
                        }
                    }
                    let reactions = server.snapshot.store.reactionSummary(id)
                    if !reactions.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(reactions.keys.sorted(), id: \.self) { emoji in
                                Button {
                                    if canWrite && server.snapshot.supports("reactions") { model.react(emoji, message: message, server: server) }
                                } label: {
                                    HStack(spacing: 4) {
                                        CustomEmojiView(key: emoji, store: server.emojis, size: 16)
                                        Text(String(reactions[emoji]!.count)).font(.caption)
                                    }.padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(reactions[emoji]!.contains(server.account) ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: Capsule())
                                }.buttonStyle(.plain)
                                    .help(ReactionEntry.isEmoji(emoji) ? "Right-click to see accounts that reacted" : UserText.isolated(server.emojis.catalog[emoji]?.alt ?? emoji))
                                    .contextMenu {
                                        Text(userText: "\(emoji) · Accounts")
                                        ForEach(reactions[emoji] ?? [], id: \.self) { userID in
                                            let person = UserProfile(recorded: reactionIdentity(userID), store: server.snapshot.store)
                                            Button(person.name == userID ? "@\(userID)" : "\(person.name) (@\(userID))") {
                                                selectedUserProfile = userID
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .background(MessageMenuHighlightView(highlight: menuHighlight, actions: messageActions).accessibilityHidden(true))
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("messageRow-" + id)
            .onHover { hovering in
                isHovered = hovering
                if !hovering { showHoverActions = false }
            }
            .task(id: isHovered) {
                guard isHovered else { return }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                guard !Task.isCancelled else { return }
                showHoverActions = true
            }
            .environment(\.openURL, OpenURLAction { url in
                if let user = MentionDisplay.userID(url, names: mentionNames) {
                    selectedUserProfile = user
                    return .handled
                }
                return MessageNavigation.open(url, relativeTo: server.profile.address, review: { model.receiveLink($0, from: server) })
            })
            .environment(\.messageActions, messageActions)
            .environment(\.messageMenuVisibility, menuHighlight.setVisible)
            .sheet(isPresented: $startingThread) {
                NewRoomView(model: model, server: server, parent: message.string("room_id"), sourceMessage: message)
            }
            .sheet(isPresented: $showingProfile) { UserProfileView(model: model, server: server, recorded: sender) }
            .sheet(isPresented: $showingSource) { MessageSourceView(message: message) }
            .sheet(isPresented: Binding(get: { selectedUserProfile != nil }, set: { if !$0 { selectedUserProfile = nil } })) {
                if let selectedUserProfile { UserProfileView(model: model, server: server, recorded: reactionIdentity(selectedUserProfile)) }
            }
            .onChange(of: server.account) { showingProfile = false; selectedUserProfile = nil }
            .confirmationDialog("Delete this message?", isPresented: $deleting) {
                Button("Delete Message", role: .destructive) { model.saveMessage(message, deleted: true, server: server) }
            }
            .sheet(isPresented: $showingReactionPicker) {
                EmojiPicker(store: server.emojis, favoriteScope: server.id.uuidString + "/" + server.account) { emoji, _ in
                    if canWrite && server.snapshot.supports("reactions") { model.react(emoji, message: message, server: server) }
                }
            }

    }
    private var messageActions: [MessageAction] {
        var actions = [
            MessageAction(title: "Copy Link", enabled: link != nil, perform: copyLink),
            MessageAction(title: "View Profile", perform: { showingProfile = true }),
            MessageAction(title: "Copy Text", perform: {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }),
            MessageAction(title: "View Source", perform: { showingSource = true })
        ]
        if !message.bool("deleted") {
            actions.append(MessageAction(title: "Reply", enabled: canWrite, perform: reply))
            actions.append(MessageAction(title: "Start Thread…", enabled: canStartThread, perform: { startingThread = true }))
            if server.snapshot.supports("reactions") {
                actions.append(MessageAction(title: "React…", enabled: canWrite, perform: { showingReactionPicker = true }))
            }
            if server.snapshot.supports("edit") {
                actions.append(MessageAction(title: "Edit…", enabled: canWrite && editMessage != nil, perform: { editMessage?(message, localPreviews) }))
                actions.append(MessageAction(title: "Move to…", enabled: canWrite && server.snapshot.canMove(message), children: {
                    server.rooms.map { room in
                        MessageAction(title: server.title(room.string("room_id") ?? ""), perform: {
                            model.saveMessage(message, destination: room.string("room_id"), server: server)
                        })
                    }
                }))
                actions.append(MessageAction(title: "Delete…", destructive: true, perform: { deleting = true }))
            }
        }
        return actions
    }

    private func reactionIdentity(_ userID: String) -> JSONObject {
        server.snapshot.store.reactions[RecordKey(id, userID)]?.object("from") ?? ["user_id": .string(userID)]
    }
    private func reply() {
        guard canWrite else { return }
        let room = message.string("room_id") ?? ""
        var draft = model.draft(server, room: room); draft.replyTo = id
        model.setDraft(draft, server: server, room: room)
        focusComposer()
    }
    /// Same-server message links scroll to and highlight the original, loading older history as needed.
    private func showOriginal(_ reply: String) {
        // A moved original lives in its recorded room; otherwise replies share the reply's room.
        let room = server.snapshot.store.messages[reply]?.string("room_id") ?? message.string("room_id") ?? ""
        let target: JSONObject = ["room_id": .string(room), "message_id": .string(reply)]
        guard let url = MessageLink.url(endpoint: server.profile.address, message: target, rooms: server.snapshot.store.rooms) else { return }
        model.receiveLink(url, from: server)
    }
    private func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

}
