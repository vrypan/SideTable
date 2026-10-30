import SwiftUI
import AppKit
import ApronCore
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let room: String
    let isThread: Bool
    var panel: ConversationPanel? = nil
    var panelVisible = true
    private var searchText: String {
        get { panel?.findText ?? model.findText }
        nonmutating set { if let panel { panel.findText = newValue } else { model.findText = newValue } }
    }
    private var showingFind: Bool {
        get { panel?.showFind ?? model.showFind }
        nonmutating set { if let panel { panel.showFind = newValue } else { model.showFind = newValue } }
    }
    @State private var transcriptState = ConversationTranscriptState()
    @State private var composerState = ConversationComposerState()
    private func attentionState(latest: String? = nil) -> AttentionState {
        AttentionState(server: server.id, account: server.account, room: room,
            eligible: panelVisible && transcriptState.positionedLatest && transcriptState.windowActive && transcriptState.atBottom && transcriptState.historyAnchor == nil && history?.isLoading != true
                && searchText.isEmpty && !server.cached && server.snapshot.phase == .ready,
            latest: latest)
    }
    private struct AttentionState: Equatable {
        let server: UUID
        let account: String
        let room: String
        let eligible: Bool
        let latest: String?
    }
    private var history: RoomHistory? { server.snapshot.roomHistory(room) }
    var body: some View {
        // Derive the timeline once; all transcript rows, counts and observers share it.
        let messages = self.messages
        let attentionState = attentionState(latest: messages.last?.string("message_id"))
        VStack(spacing: 0) {
            if showingFind {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in loaded messages", text: Binding(get: { searchText }, set: { searchText = $0 })).textFieldStyle(.plain)
                    Button { showingFind = false; searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }.padding(12)
                Divider()
            }
            transcript(messages: messages, attentionState: attentionState)
            if server.snapshot.phase != .ready || server.snapshot.recoveringRooms.contains(room) || server.cached {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(userText: server.cached ? "Saved view · Checking for updates…" : server.snapshot.phase.rawValue)
                }.font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if !server.snapshot.supports("history") && !model.preview {
                Text("Live conversation · This server does not provide message history.")
                    .font(.caption2).foregroundStyle(.secondary).padding(5)
            }
            if let edit = composerState.editingMessage, edit.account == server.account {
                MessageEditorView(message: edit.message, localPreviews: edit.previews,
                    knownUserIDs: Set(server.snapshot.store.users.keys).union(server.snapshot.store.members[room] ?? []),
                    protocolVersion: server.snapshot.server["apron"]?.number ?? 9, referenceNames: server.composerReferenceNames,
                    contextID: server.id.uuidString + "/" + server.account + "/" + room,
                    enabled: !model.preview && server.snapshot.phase == .ready && !server.cached && !server.snapshot.readOnly && server.snapshot.supports("edit"),
                    keyboardShortcuts: panel == nil || model.activePanelID == panel?.id,
                    onClose: { composerState.finishEditing(edit.id) }) { draft, params in
                        guard server.account == edit.account else { throw MessageEdit.EditError.unavailable }
                        try await model.applyMessageEdit(draft, params: params, server: server)
                    }
                    .id(edit.id)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5)))
                    .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 6)
            } else { composer }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(WindowAttentionReader(changed: { active in
                // Messages that arrived while away stay marked as New until the
                // user navigates again, even when they fit in the viewport.
                transcriptState.setWindowActive(active)
            },
            deactivated: { model.attention.remove(transcriptState.attentionID) }).frame(width: 0, height: 0))
        .onChange(of: attentionState, initial: true) { _, state in
            captureUnreadBoundary()
            transcriptState.reachedLatest(state.latest, eligible: state.eligible)
            model.updateAttention(transcriptState.attentionID, server: server, room: room, readingLatest: state.eligible)
        }
        // Open the system chooser directly; chosen files are checked against the
        // server's limits when staged and again when sent.
        .fileImporter(isPresented: $composerState.showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { stageFiles(try result.get().map { StagedFile(url: $0) }) }
            catch { server.error = error.localizedDescription }
        }
        // The whole panel accepts dropped files and images; the composer's text
        // view handles drops onto itself the same way it handles paste.
        .onDrop(of: DroppedAttachments.types, isTargeted: $composerState.dropTargeted) { providers in
            guard canAttach else { return false }
            composerState.stageDrop(server: server, room: room, category: attachmentCategory) {
                try await DroppedAttachments.files(from: providers)
            }
            return true
        }
        .overlay {
            if composerState.dropTargeted && canAttach {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                    Label("Drop to attach to \(server.title(room))", systemImage: "paperclip")
                        .font(.headline).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }.padding(4).allowsHitTesting(false)
            }
        }
        .onChange(of: server.account) { composerState.cancelEditing() }
        .onChange(of: server.id) { composerState.cancelEditing() }
        .onChange(of: room) { _, _ in composerState.changeRoom(); transcriptState.changeRoom() }
        .onChange(of: server.snapshot.phase) { if server.snapshot.phase != .ready { transcriptState.historyAnchor = nil } }
        .task(id: server.snapshot.phase) {
            if server.snapshot.phase == .ready { await model.loadConversation(room, server: server) }
        }
        .onAppear {
            markRead()
            if ProcessInfo.processInfo.arguments.contains("--preview-inline-edit"), composerState.editingMessage == nil,
               let message = messages.first(where: { $0.object("from").string("user_id") == server.account }) {
                composerState.beginEditing(message, previews: [], account: server.account)
            }
        }
        .onDisappear { model.attention.remove(transcriptState.attentionID) }
    }
    private var attachmentCategory: String {
        UploadMediaPolicy.category(text: model.draft(server, room: room).text, commands: server.snapshot.supports("command"))
    }
    private var canAttach: Bool { server.snapshot.supports("embed:upload") && !model.preview }
    private func stageFiles(_ files: [StagedFile]) {
        do {
            try UploadMediaPolicy.validate(files, snapshot: server.snapshot, category: attachmentCategory)
            server.files[room, default: []].append(contentsOf: files)
        } catch { server.error = error.localizedDescription }
    }
    private var messages: [JSONObject] {
        let all = server.snapshot.store.timeline(room)
        return !searchText.isEmpty ? all.filter { $0.object("body").string("text")?.localizedCaseInsensitiveContains(searchText) == true } : all
    }
    private func transcript(messages: [JSONObject], attentionState: AttentionState) -> some View {
        let visibleMessages = Array(messages.suffix(transcriptState.visibleCount))
        let visibleIDs = Set(visibleMessages.compactMap { $0.string("message_id") })
        let firstUnread = searchText.isEmpty
            ? transcriptState.unreadBoundary?.firstUnread(in: messages, account: server.account) : nil
        let notices = TranscriptNotices(server.snapshot.store.notices, room: room, messages: visibleMessages)
        let initialHistoryReady = server.snapshot.phase == .ready && !server.cached
            && !server.snapshot.recoveringRooms.contains(server.snapshot.historyKey(room)) && !messages.isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                // The displayed batch is initially capped at 150 messages. Realize
                // its rows before positioning: LazyVStack can retain an estimated
                // document height with no rows at the restored scroll destination.
                VStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: isThread ? "bubble.left" : "number").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                            Text(userText: searchText.isEmpty ? (history?.hasOlder == true ? "No messages in this page" : "The start of \(server.title(room))") : "No matching loaded messages").font(.title2.weight(.semibold))
                            Text(userText: searchText.isEmpty ? "Make yourself at home. Say something." : "Try another phrase.").foregroundStyle(.secondary)
                        }.padding(28)
                    }
                    if messages.count > transcriptState.visibleCount {
                        Button("Show earlier messages") {
                            let anchor = transcriptState.revealEarlier(messages: messages)
                            model.attention.remove(transcriptState.attentionID)
                            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                        }.buttonStyle(.link).padding(20)
                    } else if server.snapshot.supports("history"), history?.hasOlder == true || history?.isLoading == true {
                        VStack(alignment: .leading, spacing: 6) {
                            if history?.isLoading == true {
                                HStack { ProgressView().controlSize(.small); Text("Loading earlier history…") }
                            } else {
                                CooldownButton(snapshot: server.snapshot, method: "history",
                                    disabled: server.snapshot.phase != .ready || server.snapshot.recoveringRooms.contains(server.snapshot.historyKey(room)), action: {
                                        transcriptState.beginHistory(messages: messages)
                                        model.attention.remove(transcriptState.attentionID)
                                        Task { await model.loadOlderHistory(room, server: server) }
                                    }) { Text(history?.error == nil ? "Load earlier messages" : "Retry loading earlier messages") }
                                    .buttonStyle(.link).accessibilityIdentifier("loadEarlierMessages")
                            }
                            if let error = history?.error { Text(userText: error).font(.caption).foregroundStyle(.secondary) }
                            RequestCooldownView(snapshot: server.snapshot, method: "history")
                        }.padding(20)
                    }
                    ForEach(notices.leading) { NoticeView(model: model, server: server, notice: $0) }
                    ForEach(visibleMessages, id: \.messageIdentity) { message in
                        VStack(alignment: .leading, spacing: 0) {
                            if message.string("message_id") == firstUnread { newMessagesDivider }
                            MessageRow(model: model, server: server, message: message, editMessage: composerState.editingMessage == nil ? { message, previews in
                                if let panel { model.focusPanel(panel.id) }
                                composerState.beginEditing(message, previews: previews, account: server.account)
                            } : nil)
                                .background(composerState.editingMessage?.message.string("message_id") == message.string("message_id") ? Color.accentColor.opacity(0.08) : Color.clear)
                                .background(model.linkedMessage?.server == server.id && model.linkedMessage?.room == room && model.linkedMessage?.message == message.string("message_id") ? Color.accentColor.opacity(0.12) : Color.clear)
                            ForEach(server.pending.filter { $0.messageID == message.string("message_id") && $0.acknowledged }) { delivery in
                                DeliveryView(model: model, server: server, message: delivery)
                                    .padding(.leading, 70).padding(.trailing, 24).padding(.bottom, 10)
                            }
                            ForEach(notices.after[message.string("message_id") ?? ""] ?? []) {
                                NoticeView(model: model, server: server, notice: $0)
                            }
                        }
                        .background(TranscriptMessageAnchor(messageID: message.string("message_id") ?? ""))
                        .id(message.string("message_id") ?? "")
                    }
                    ForEach(server.pending.filter { delivery in
                        !delivery.isManagement && delivery.room == room && !visibleIDs.contains(delivery.messageID ?? "")
                    }) { message in
                        DeliveryView(model: model, server: server, message: message)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                    }
                    // Include the trailing inset in the target so SwiftUI reaches
                    // the document's actual end without a native offset correction.
                    Color.clear.frame(height: 15).id("bottom")
                }.scrollTargetLayout().padding(.top, 14)
                    .background(TranscriptScrollObserver(request: transcriptState.scrollRequest, scrollToLatest: { proxy.scrollTo("bottom", anchor: .bottom) }, diagnosticServer: server.id, diagnosticRoom: room, positionChanged: { transcriptState.scrollPosition = $0 },
                                                         userScrolled: { transcriptState.userScrolled() },
                                                         believedAtEnd: transcriptState.atBottom, holdsPosition: !transcriptState.windowActive) { reachedEnd in
                        transcriptState.atBottom = reachedEnd
                        if reachedEnd { markRead() }
                        else { model.attention.remove(transcriptState.attentionID) }
                    }.frame(width: 0, height: 0))
            }
            .defaultScrollAnchor(.top)
            .accessibilityIdentifier("transcript-" + room)
            .overlay(alignment: .bottomTrailing) {
                if !transcriptState.atBottom || transcriptState.arrivals.unread > 0 {
                    Button { requestLatest() } label: { Label(transcriptState.arrivals.label, systemImage: "arrow.down") }
                        .buttonStyle(.bordered).padding(12)
                }
            }
            .onChange(of: transcriptState.scrollPosition) { saveViewedPosition(latest: messages.last?.string("message_id")) }
            .onChange(of: transcriptState.windowActive) { if transcriptState.windowActive { saveViewedPosition(latest: messages.last?.string("message_id")) } }
            .onChange(of: server.liveMessageCounts[room] ?? 0, initial: true) { _, total in
                transcriptState.receiveArrivals(total: total, loadingHistory: history?.isLoading == true, searching: !searchText.isEmpty)
            }
            .onChange(of: attentionState) { _, state in
                if state.eligible { transcriptState.clearArrivals() }
            }
            // Command replies arrive as transient notices below the latest message.
            .onChange(of: notices.latest) {
                if transcriptState.positionedLatest && transcriptState.atBottom && transcriptState.historyAnchor == nil && searchText.isEmpty { transcriptState.scrollRequest = UUID() }
            }
            .task(id: model.linkedMessage) {
                guard let target = model.linkedMessage, target.server == server.id, target.room == room else { return }
                transcriptState.revealLinkedMessage(messageCount: messages.count)
                model.attention.remove(transcriptState.attentionID)
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(target.message, anchor: .center)
            }
            .task(id: transcriptState.scrollRequest) {
                guard transcriptState.scrollRequest != nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task(id: initialHistoryReady) {
                guard initialHistoryReady, !transcriptState.positionedLatest, transcriptState.historyAnchor == nil,
                      searchText.isEmpty else { return }
                let saved = await model.restoreViewedMessage(server: server, room: room)
                guard !Task.isCancelled, !transcriptState.positionedLatest, model.linkedMessage?.room != room else { return }
                if let saved {
                    // Restoration may have fetched pages since this render's snapshot.
                    transcriptState.revealSavedMessage(saved, messages: server.snapshot.store.timeline(room))
                }
                // Install older rows before asking SwiftUI to position the viewport.
                await Task.yield()
                guard !Task.isCancelled, !transcriptState.positionedLatest else { return }
                transcriptState.positionedLatest = true
                if let saved {
                    transcriptState.atBottom = false
                    proxy.scrollTo(saved, anchor: .top)
                } else if model.preview && ProcessInfo.processInfo.arguments.contains("--preview-reading") {
                    proxy.scrollTo("1900000000030", anchor: .top)
                } else {
                    transcriptState.scrollRequest = UUID()
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                if let anchor = transcriptState.historyAnchor {
                    transcriptState.visibleCount += max(0, newCount - oldCount)
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            .onChange(of: history?.completionID) {
                // A completion ID survives coalesced loading snapshots, including
                // fast pages and retries that return the same error or row count.
                if let anchor = transcriptState.historyAnchor { proxy.scrollTo(anchor, anchor: .top) }
                transcriptState.historyAnchor = nil
            }

        }
    }
    private var newMessagesDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.accentColor.opacity(0.65)).frame(height: 1)
            Text("New").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.65)).frame(height: 1)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages start here")
        .accessibilityIdentifier("newMessagesDivider")
    }

    private func saveViewedPosition(latest: String?) {
        guard panelVisible, transcriptState.positionedLatest, transcriptState.windowActive, !server.cached, transcriptState.historyAnchor == nil,
              history?.isLoading != true, searchText.isEmpty,
              let position = transcriptState.scrollPosition else { return }
        let message = position == "bottom" ? latest : position
        if let message { model.saveViewedMessage(message, server: server, room: room) }
    }
    private func requestLatest() {
        searchText = ""
        transcriptState.requestLatest()
    }
    private func sendMessage() {
        if model.send(server: server, room: room, linkMetadata: composerState.linkLoader.metadata(for: composerLinkRequest)) { requestLatest() }
    }
    private func captureUnreadBoundary() {
        guard transcriptState.unreadBoundary == nil else { return }
        let key = DraftKey(server: server.id, account: server.account, room: room)
        transcriptState.captureUnreadBoundary(readMarker: model.readMarkers[key],
            messages: server.snapshot.store.timeline(room), unreadCount: server.unread[room] ?? 0)
    }
    private func markRead() {
        captureUnreadBoundary()
        transcriptState.reachedLatest(server.snapshot.store.timeline(room).last?.string("message_id"), eligible: attentionState().eligible)
        model.updateAttention(transcriptState.attentionID, server: server, room: room, readingLatest: attentionState().eligible)
    }
    private var composerSuggestions: [ComposerSuggestion] {
        let emojis = server.emojis.offered.map { entry in
            ComposerSuggestion(insertion: entry.id, label: entry.id + "  " + entry.alt,
                search: ([entry.id, entry.alt, entry.category] + entry.tags).joined(separator: " "))
        }
        return server.composerSuggestions(room: room) + emojis
    }
    private var composerLinkRequest: ComposerLinkPreviewLoader.Request {
        composerState.linkRequest(draft: model.draft(server, room: room),
            key: DraftKey(server: server.id, account: server.account, room: room),
            commands: server.snapshot.supports("command"))
    }

    private struct ComposerEmojiDemand: Hashable { let generation: UUID; let hasKey: Bool }
    private var composer: some View {
        let linkRequest = composerLinkRequest
        let draft = model.draft(server, room: room)
        let method = ComposedText(draft.text, commands: server.snapshot.supports("command")).isCommand ? "command" : "message"
        let hasUploads = !(server.files[room] ?? []).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            RequestCooldownView(snapshot: server.snapshot, method: method, hasUploads: hasUploads)
            if let reply = model.draft(server, room: room).replyTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text(userText: "Replying to \(server.snapshot.store.messages[reply]?.object("body").string("text") ?? "message")").lineLimit(1)
                    Spacer()
                    Button { var d = model.draft(server, room: room); d.replyTo = nil; model.setDraft(d, server: server, room: room) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !(server.files[room] ?? []).isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(server.files[room] ?? []) { file in
                            HStack { Image(systemName: "doc"); Text(userText: file.name); Button { server.files[room]?.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                                .font(.caption).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            NativeComposer(text: Binding(get: { model.draft(server, room: room).text }, set: { value in
                var draft = model.draft(server, room: room); draft.text = value; model.setDraft(draft, server: server, room: room)
            }), placeholder: server.snapshot.readOnly ? (server.snapshot.supports("command") ? "Enter a /command…" : "This account cannot post in this room") : "Message \(server.title(room))…", enabled: server.snapshot.phase == .ready && (!server.snapshot.readOnly || server.snapshot.supports("command")) && (!model.preview || ProcessInfo.processInfo.arguments.contains("--preview-composer")),
                candidates: composerSuggestions, insertion: composerState.insertion, referenceNames: server.composerReferenceNames, contextID: server.id.uuidString + "/" + server.account + "/" + room, autofocus: composerState.restoreFocus,
                acceptsAttachments: server.snapshot.supports("embed:upload"),
                pasteFiles: { stageFiles($0) },
                pasteError: { server.error = $0 },
                focused: { if let panel { model.focusPanel(panel.id) } }) {
                sendMessage()
            }.frame(minHeight: 46, maxHeight: 110).accessibilityIdentifier("messageComposer")
            ComposerLinkPreviewList(links: linkRequest.links, metadata: composerState.linkLoader.metadata(for: linkRequest),
                images: composerState.linkLoader.images(for: linkRequest),
                hasExcludedLinks: !draft.excludedPreviewURLs.isEmpty,
                remove: { link in
                    var updated = model.draft(server, room: room)
                    updated.excludedPreviewURLs.insert(link.id)
                    model.setDraft(updated, server: server, room: room)
                }, restore: {
                    var updated = model.draft(server, room: room)
                    updated.excludedPreviewURLs = []
                    model.setDraft(updated, server: server, room: room)
                })
            HStack {
                Button { composerState.showFilePicker = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain)
                    .help((["Attach files"] + UploadMediaPolicy.guidance(snapshot: server.snapshot, category: attachmentCategory)).joined(separator: "\n"))
                    .accessibilityLabel("Attach files").disabled(!server.snapshot.supports("embed:upload") || model.preview)
                Menu {
                    ForEach((server.snapshot.store.members[room] ?? []).sorted(), id: \.self) { id in
                        Button(server.snapshot.store.displayName(["user_id": .string(id)])) {
                            composerState.insertion = ComposerInsertion(text: "@\(id) ")
                        }
                    }
                } label: { Image(systemName: "at") }.menuStyle(.borderlessButton).frame(width: 24).help("Mention a member")
                Button { composerState.showingEmoji = true } label: { Image(systemName: "face.smiling") }
                    .buttonStyle(.plain).help("Insert emoji")
                    .popover(isPresented: $composerState.showingEmoji) {
                        EmojiPicker(store: server.emojis, favoriteScope: server.id.uuidString + "/" + server.account) { emoji, keepOpen in
                            composerState.insertion = ComposerInsertion(text: emoji, focus: !keepOpen)
                        }
                    }
                Spacer()
                Text("⇧ Return for a new line").font(.caption2).foregroundStyle(.tertiary)
                CooldownButton(snapshot: server.snapshot, method: method, hasUploads: hasUploads,
                    disabled: server.snapshot.phase != .ready || (server.snapshot.readOnly && method != "command") || model.preview || (draft.text.isEmpty && !hasUploads),
                    action: sendMessage) { Image(systemName: "arrow.up").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).help("Send message").accessibilityLabel("Send message")
            }
        }.task(id: ComposerEmojiDemand(generation: server.emojis.generation, hasKey: draft.text.contains(":"))) {
            if draft.text.contains(":") { await server.emojis.loadCatalog() }
        }.task(id: linkRequest) {
            guard !model.preview || ProcessInfo.processInfo.arguments.contains("--preview-links") else { return }
            await composerState.linkLoader.refresh(linkRequest)
        }
            .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 6)
    }
}
