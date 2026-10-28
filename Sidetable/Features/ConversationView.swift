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
    @State private var unreadBoundary: ConversationUnreadBoundary?
    /// Opening positions the transcript programmatically; only the user's own
    /// scrolling or a jump to Latest may then clear the New divider.
    @State private var userNavigated = false
    @GestureState private var draggingHeader = false
    @State private var composerInsertion: ComposerInsertion?
    @State private var showingComposerEmoji = false
    @State private var composerLinkLoader = ComposerLinkPreviewLoader(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    @State private var attentionID = UUID()
    @State private var windowActive = false
    private func attentionState(latest: String? = nil) -> AttentionState {
        AttentionState(server: server.id, account: server.account, room: room,
            eligible: panelVisible && positionedLatest && windowActive && atBottom && historyAnchor == nil && history?.isLoading != true
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
    @State private var showRoomDetails = false
    @State private var newThread = false
    @State private var leave = false
    @State private var editRoom = false
    @State private var copiedRoomLink = false
    @State private var atBottom = false
    @State private var showFilePicker = false
    @State private var visibleCount = 150
    @State private var positionedLatest = false
    @State private var arrivals = ConversationArrivals()
    @State private var scrollRequest: UUID?
    @State private var scrollPosition: String?
    @State private var historyAnchor: String?
    private var history: RoomHistory? { server.snapshot.roomHistory(room) }
    var body: some View {
        // Derive the timeline once; all transcript rows, counts and observers share it.
        let messages = self.messages
        let attentionState = attentionState(latest: messages.last?.string("message_id"))
        VStack(spacing: 0) {
            header
            Divider()
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
        .background(WindowAttentionReader(changed: { active in
                // Messages that arrived while away stay marked as New until the
                // user navigates again, even when they fit in the viewport.
                if active { userNavigated = false }
                windowActive = active
            },
            deactivated: { model.attention.remove(attentionID) }).frame(width: 0, height: 0))
        .onChange(of: attentionState, initial: true) { _, state in
            captureUnreadBoundary()
            if state.eligible, userNavigated { unreadBoundary?.reachedLatest(state.latest) }
            model.updateAttention(attentionID, server: server, room: room, readingLatest: state.eligible)
        }
        .sheet(isPresented: $editRoom) { EditRoomView(server: server, room: room) }
        .sheet(isPresented: $newThread) { NewRoomView(model: model, server: server, parent: room) }
        .confirmationDialog("Leave \(server.title(room))?", isPresented: $leave) {
            Button("Leave Room", role: .destructive) {
                let account = server.account
                model.perform("room_leave", params: ["room_id": .string(room)], server: server) { _ in
                    if server.account == account { model.closeThreadPanel(server: server, room: room) }
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): server.files[room, default: []].append(contentsOf: urls.map { StagedFile(url: $0) })
            case .failure(let error): server.error = error.localizedDescription
            }
        }
        .onChange(of: room) { _, _ in atBottom = false; visibleCount = 150; historyAnchor = nil; scrollPosition = nil; positionedLatest = false; userNavigated = false; arrivals = ConversationArrivals() }
        .onChange(of: server.snapshot.phase) { if server.snapshot.phase != .ready { historyAnchor = nil } }
        .task(id: server.snapshot.phase) {
            if server.snapshot.phase == .ready { await model.loadConversation(room, server: server) }
        }
        .onAppear { markRead() }
        .onDisappear { model.attention.remove(attentionID) }
    }
    private var roomRecord: JSONObject { server.snapshot.store.rooms[room] ?? [:] }
    private var roomURL: URL? { RoomLink.url(endpoint: server.profile.address, room: room) }
    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if let participants = server.participants(room) {
                    ParticipantAvatars(participants: participants, size: 24, server: server)
                } else {
                    Image(systemName: roomRecord.bool("private") ? "lock" : (isThread ? "arrow.turn.down.right" : "number"))
                        .foregroundStyle(.secondary)
                }
            }.help(roomRecord.bool("private") ? "Private room" : (isThread ? "Thread" : "Room"))
            Button { showRoomDetails.toggle() } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.title(room)).font(.headline).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(server.profile.title) · \(RoomDetails.memberSummary(room: roomRecord, members: server.snapshot.store.members[room]))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Room details: \(server.title(room))")
            .accessibilityIdentifier("roomDetails")
            .popover(isPresented: $showRoomDetails) { roomDetails }
            if let panel {
                Button { model.focusPanel(panel.id); showingFind.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).help("Find in \(server.title(room))")
                    .accessibilityLabel("Find in \(server.title(room))")
            }
            if isThread {
                Button { Task { await model.loadConversation(room, server: server) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh thread replies").accessibilityLabel("Refresh thread replies")
                    .disabled(server.snapshot.phase != .ready || server.snapshot.recoveringRooms.contains(server.snapshot.historyKey(room)))
            }
            if server.snapshot.supports("rooms") {
                Menu {
                    RoomActionItems(model: model, server: server, room: room, isThread: isThread, copiedLink: copiedRoomLink,
                        copyLink: {
                            guard let url = roomURL else { return }
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            copiedRoomLink = true
                        }, edit: { editRoom = true }, newThread: { newThread = true }, leave: { leave = true })
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("Room actions")
                    .accessibilityLabel("Room actions").accessibilityIdentifier("roomActions")
            }
            if let panel {
                Button { model.closePanel(panel.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close \(server.title(room)) panel").accessibilityLabel("Close panel")
            } else if isThread {
                Button { model.closeThreadPanel(server: server, room: room) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close thread")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(panel?.id == model.activePanelID ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        // Dragging the header reorders panels; clicks still reach its buttons.
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(ConversationPanelsView.rowSpace))
            .updating($draggingHeader) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard let panel, model.panels.count > 1 else { return }
                model.panelDrag = PanelDrag(id: panel.id, offset: value.translation.width, pointer: value.location.x)
            }, including: panel == nil ? .subviews : .all)
        // Gesture state also resets when a drag is cancelled, which `onEnded` would miss.
        .onChange(of: draggingHeader) { _, dragging in
            if !dragging, let panel, model.panelDrag?.id == panel.id { model.panelDrag?.released = true }
        }
        .contextMenu {
            if let panel, let index = model.panels.firstIndex(where: { $0.id == panel.id }), model.panels.count > 1 {
                Button("Move Panel Left") { model.movePanel(panel.id, to: index - 1) }.disabled(index == 0)
                Button("Move Panel Right") { model.movePanel(panel.id, to: index + 1) }.disabled(index == model.panels.count - 1)
            }
        }
        .task(id: copiedRoomLink) {
            guard copiedRoomLink else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedRoomLink = false
        }
        .onChange(of: room) { copiedRoomLink = false; editRoom = false }
    }
    private var roomDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server.title(room)).font(.headline).textSelection(.enabled)
            Text(server.profile.title).font(.caption).foregroundStyle(.secondary)
            Text(RoomDetails.memberSummary(room: roomRecord, members: server.snapshot.store.members[room]))
                .font(.caption).foregroundStyle(.secondary)
            if roomRecord.bool("private") {
                HStack(spacing: -6) {
                    ForEach(Array((server.snapshot.store.members[room] ?? []).sorted().prefix(6)), id: \.self) { user in
                        let profile = UserProfile(recorded: ["user_id": .string(user)], store: server.snapshot.store)
                        AvatarView(name: profile.name, size: 28, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
                    }
                }
                Label("Only members and the server host can read messages here.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if (server.snapshot.mutedUntil[room] ?? .distantPast) > Date() {
                Label("Room notifications muted", systemImage: "bell.slash").font(.caption)
            }
            if let description = roomRecord.string("description"), !description.isEmpty {
                Divider()
                ScrollView {
                    MarkdownMessageView(source: description, size: model.messageSize, endpoint: server.profile.address, reviewLink: { model.receiveLink($0, from: server) })
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            }
        }
        .padding(16).frame(width: 340)
        .environment(\.openURL, OpenURLAction { url in MediaPolicy.safeLink(url) ? .systemAction : .discarded })
    }
    private var messages: [JSONObject] {
        let all = server.snapshot.store.timeline(room)
        return !searchText.isEmpty ? all.filter { $0.object("body").string("text")?.localizedCaseInsensitiveContains(searchText) == true } : all
    }
    private func transcript(messages: [JSONObject], attentionState: AttentionState) -> some View {
        let visibleMessages = Array(messages.suffix(visibleCount))
        let visibleIDs = Set(visibleMessages.compactMap { $0.string("message_id") })
        let firstUnread = searchText.isEmpty
            ? unreadBoundary?.firstUnread(in: messages, account: server.account) : nil
        let notices = TranscriptNotices(server.snapshot.store.notices, room: room, messages: visibleMessages)
        let initialHistoryReady = server.snapshot.phase == .ready && !server.cached
            && !server.snapshot.recoveringRooms.contains(server.snapshot.historyKey(room)) && !messages.isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: isThread ? "bubble.left" : "number").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                            Text(searchText.isEmpty ? (history?.hasOlder == true ? "No messages in this page" : "The start of \(server.title(room))") : "No matching loaded messages").font(.title2.weight(.semibold))
                            Text(searchText.isEmpty ? "Make yourself at home. Say something." : "Try another phrase.").foregroundStyle(.secondary)
                        }.padding(28)
                    }
                    if messages.count > visibleCount {
                        Button("Show earlier messages") {
                            let anchor = scrollPosition ?? messages.suffix(visibleCount).first?.string("message_id")
                            positionedLatest = true; atBottom = false; model.attention.remove(attentionID)
                            visibleCount += 150
                            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                        }.buttonStyle(.link).padding(20)
                    } else if server.snapshot.supports("history"), history?.hasOlder == true || history?.isLoading == true {
                        VStack(alignment: .leading, spacing: 6) {
                            if history?.isLoading == true {
                                HStack { ProgressView().controlSize(.small); Text("Loading earlier history…") }
                            } else {
                                Button(history?.error == nil ? "Load earlier messages" : "Retry loading earlier messages") {
                                    historyAnchor = scrollPosition ?? messages.first?.string("message_id")
                                    positionedLatest = true; atBottom = false; model.attention.remove(attentionID)
                                    Task { await model.loadOlderHistory(room, server: server) }
                                }.buttonStyle(.link).accessibilityIdentifier("loadEarlierMessages")
                                    .disabled(server.snapshot.phase != .ready || server.snapshot.recoveringRooms.contains(server.snapshot.historyKey(room)))
                            }
                            if let error = history?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        }.padding(20)
                    }
                    ForEach(notices.leading) { NoticeView(model: model, server: server, notice: $0) }
                    ForEach(visibleMessages, id: \.messageIdentity) { message in
                        VStack(alignment: .leading, spacing: 0) {
                            if message.string("message_id") == firstUnread { newMessagesDivider }
                            MessageRow(model: model, server: server, message: message)
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
                        delivery.room == room && !visibleIDs.contains(delivery.messageID ?? "")
                    }) { message in
                        DeliveryView(model: model, server: server, message: message)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.scrollTargetLayout().padding(.vertical, 14)
                    .background(TranscriptScrollObserver(request: scrollRequest, positionChanged: { scrollPosition = $0 },
                                                         userScrolled: { if !userNavigated { userNavigated = true } },
                                                         believedAtEnd: atBottom, holdsPosition: !windowActive) { reachedEnd in
                        atBottom = reachedEnd
                        if reachedEnd { markRead() }
                        else { model.attention.remove(attentionID) }
                    }.frame(width: 0, height: 0))
            }
            .defaultScrollAnchor(.top)
            .accessibilityIdentifier("transcript-" + room)
            .overlay(alignment: .bottomTrailing) {
                if !atBottom || arrivals.unread > 0 {
                    Button { requestLatest() } label: { Label(arrivals.label, systemImage: "arrow.down") }
                        .buttonStyle(.bordered).padding(12)
                }
            }
            .onChange(of: scrollPosition) { saveViewedPosition(latest: messages.last?.string("message_id")) }
            .onChange(of: windowActive) { if windowActive { saveViewedPosition(latest: messages.last?.string("message_id")) } }
            .onChange(of: server.liveMessageCounts[room] ?? 0, initial: true) { _, total in
                let following = positionedLatest && atBottom && windowActive && historyAnchor == nil
                    && history?.isLoading != true && searchText.isEmpty
                if arrivals.receive(total: total, followingLatest: following) { scrollRequest = UUID() }
            }
            .onChange(of: attentionState) { _, state in
                if state.eligible { arrivals.reachedLatest() }
            }
            // Command replies arrive as transient notices below the latest message.
            .onChange(of: notices.latest) {
                if positionedLatest && atBottom && historyAnchor == nil && searchText.isEmpty { scrollRequest = UUID() }
            }
            .task(id: model.linkedMessage) {
                guard let target = model.linkedMessage, target.server == server.id, target.room == room else { return }
                positionedLatest = true; atBottom = false; scrollRequest = nil
                visibleCount = max(visibleCount, messages.count)
                model.attention.remove(attentionID)
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(target.message, anchor: .center)
            }
            .task(id: scrollRequest) {
                guard scrollRequest != nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task(id: initialHistoryReady) {
                guard initialHistoryReady, !positionedLatest, historyAnchor == nil,
                      searchText.isEmpty else { return }
                let saved = await model.restoreViewedMessage(server: server, room: room)
                guard !Task.isCancelled, !positionedLatest, model.linkedMessage?.room != room else { return }
                if saved != nil {
                    // Restoration may have fetched pages since this render's snapshot.
                    visibleCount = max(visibleCount, server.snapshot.store.timeline(room).count)
                }
                // Install older rows before asking SwiftUI to position the viewport.
                await Task.yield()
                guard !Task.isCancelled, !positionedLatest else { return }
                positionedLatest = true
                if let saved {
                    atBottom = false
                    proxy.scrollTo(saved, anchor: .top)
                } else if model.preview && ProcessInfo.processInfo.arguments.contains("--preview-reading") {
                    proxy.scrollTo("1900000000030", anchor: .top)
                } else {
                    scrollRequest = UUID()
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                if let anchor = historyAnchor {
                    visibleCount += max(0, newCount - oldCount)
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            .onChange(of: history?.completionID) {
                // A completion ID survives coalesced loading snapshots, including
                // fast pages and retries that return the same error or row count.
                if let anchor = historyAnchor { proxy.scrollTo(anchor, anchor: .top) }
                historyAnchor = nil
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
        guard panelVisible, positionedLatest, windowActive, !server.cached, historyAnchor == nil,
              history?.isLoading != true, searchText.isEmpty,
              let position = scrollPosition else { return }
        let message = position == "bottom" ? latest : position
        if let message { model.saveViewedMessage(message, server: server, room: room) }
    }
    private func requestLatest() {
        userNavigated = true
        searchText = ""
        historyAnchor = nil; positionedLatest = true
        scrollRequest = UUID()
    }
    private func sendMessage() {
        if model.send(server: server, room: room, linkMetadata: composerLinkLoader.metadata(for: composerLinkRequest)) { requestLatest() }
    }
    private func captureUnreadBoundary() {
        guard unreadBoundary == nil else { return }
        let key = DraftKey(server: server.id, account: server.account, room: room)
        unreadBoundary = ConversationUnreadBoundary(readMarker: model.readMarkers[key],
            messages: server.snapshot.store.timeline(room), unreadCount: server.unread[room] ?? 0)
    }
    private func markRead() {
        captureUnreadBoundary()
        if attentionState().eligible, userNavigated {
            unreadBoundary?.reachedLatest(server.snapshot.store.timeline(room).last?.string("message_id"))
        }
        model.updateAttention(attentionID, server: server, room: room, readingLatest: attentionState().eligible)
    }
    private var composerSuggestions: [ComposerSuggestion] {
        let members = (server.snapshot.store.members[room] ?? []).sorted().map { id in
            let name = server.snapshot.store.displayName(["user_id": .string(id)])
            return ComposerSuggestion(insertion: "@" + id, label: name + " · @" + id, search: name + " " + id)
        }
        let rooms = server.snapshot.store.rooms.keys.sorted().map { id in
            ComposerSuggestion(insertion: "#" + id, label: "#" + server.title(id), search: server.title(id) + " " + id)
        }
        return members + rooms
    }
    private var composerLinkRequest: ComposerLinkPreviewLoader.Request {
        let draft = model.draft(server, room: room)
        let composed = ComposedText(draft.text, commands: server.snapshot.supports("command"))
        let links = composed.isCommand ? [] : ComposerLinkDiscovery.shared.links(in: composed.text)
            .filter { !draft.excludedPreviewURLs.contains($0.id) }
        return ComposerLinkPreviewLoader.Request(key: DraftKey(server: server.id, account: server.account, room: room), links: links)
    }
    private var composer: some View {
        let linkRequest = composerLinkRequest
        let draft = model.draft(server, room: room)
        return VStack(alignment: .leading, spacing: 8) {
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
            }), placeholder: server.snapshot.readOnly ? "Sign in to post in this room" : "Message \(server.title(room))…", enabled: server.snapshot.phase == .ready && !server.snapshot.readOnly && (!model.preview || ProcessInfo.processInfo.arguments.contains("--preview-composer")),
                candidates: composerSuggestions, insertion: composerInsertion,
                acceptsAttachments: server.snapshot.supports("embed:upload"),
                pasteFiles: { server.files[room, default: []].append(contentsOf: $0) },
                pasteError: { server.error = $0 },
                focused: { if let panel { model.focusPanel(panel.id) } }) {
                sendMessage()
            }.frame(minHeight: 46, maxHeight: 110).accessibilityIdentifier("messageComposer")
            ComposerLinkPreviewList(links: linkRequest.links, metadata: composerLinkLoader.metadata(for: linkRequest),
                images: composerLinkLoader.images(for: linkRequest),
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
                Button { showFilePicker = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain).help("Attach files").disabled(!server.snapshot.supports("embed:upload") || model.preview)
                Menu {
                    ForEach((server.snapshot.store.members[room] ?? []).sorted(), id: \.self) { id in
                        Button(server.snapshot.store.displayName(["user_id": .string(id)])) {
                            composerInsertion = ComposerInsertion(text: "@\(id) ")
                        }
                    }
                } label: { Image(systemName: "at") }.menuStyle(.borderlessButton).frame(width: 24).help("Mention a member")
                Button { showingComposerEmoji = true } label: { Image(systemName: "face.smiling") }
                    .buttonStyle(.plain).help("Insert emoji")
                    .popover(isPresented: $showingComposerEmoji) {
                        EmojiPicker { composerInsertion = ComposerInsertion(text: $0) }
                    }
                Spacer()
                Text("⇧ Return for a new line").font(.caption2).foregroundStyle(.tertiary)
                Button { sendMessage() } label: { Image(systemName: "arrow.up").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).help("Send message").accessibilityLabel("Send message")
                    .disabled(server.snapshot.phase != .ready || server.snapshot.readOnly || model.preview || (model.draft(server, room: room).text.isEmpty && (server.files[room] ?? []).isEmpty))
            }
        }.task(id: linkRequest) {
            guard !model.preview || ProcessInfo.processInfo.arguments.contains("--preview-links") else { return }
            await composerLinkLoader.refresh(linkRequest)
        }
            .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 6)
            .dropDestination(for: URL.self) { urls, _ in
                guard server.snapshot.supports("embed:upload"), !model.preview else { return false }
                server.files[room, default: []].append(contentsOf: urls.filter(\.isFileURL).map { StagedFile(url: $0) }); return true
            }
    }
}

/// A room's transient notices placed where they arrived: after the latest message
/// known at that moment, or before the shown messages when they arrived earlier.
/// Notices without a room appear once per server instead (`ServerNoticesView`).
struct TranscriptNotices {
    var leading: [Notice] = []
    var after: [String: [Notice]] = [:]
    var latest: UUID?

    init(_ notices: [Notice], room: String, messages: [JSONObject]) {
        let ids = messages.compactMap { message in message.logID("message_id").map { ($0, message.string("message_id")!) } }
        for notice in notices where notice.record.string("room_id") == room {
            latest = notice.id
            // The last shown message at or before the notice's arrival.
            if let anchor = notice.after, let index = ids.lastIndex(where: { $0.0 <= anchor }) {
                after[ids[index].1, default: []].append(notice)
            } else { leading.append(notice) }
        }
    }
}

/// Server notices such as `~private` command replies. They are visible only on this
/// connection and are never part of history.
struct NoticeView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let notice: Notice
    var dismiss: (() -> Void)? = nil
    var body: some View {
        let body = notice.record.object("body")
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if let name = notice.record.object("from").string("name"), !name.isEmpty {
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Dismiss notice").accessibilityLabel("Dismiss notice")
                }
            }
            if body.string("format") == "markdown", let text = body.string("text") {
                MarkdownMessageView(source: text, size: model.messageSize, endpoint: server.profile.address,
                                    reviewLink: { model.receiveLink($0, from: server) })
            } else {
                Text(body.string("text") ?? "Server notice")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notice")
    }
}

/// Notices without a room, such as a server welcome, shown once beneath the
/// conversations rather than in each one. Dismissing one also hides the identical
/// notice a server sends again on reconnect, for the rest of the app session.
struct ServerNoticesView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    var body: some View {
        let notices = server.snapshot.store.notices.filter {
            $0.record.string("room_id") == nil && !server.dismissedNotices.contains(ServerModel.noticeKey($0))
        }
        if !notices.isEmpty {
            // Bounded, so accumulated notices cannot push the conversations off screen.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(notices) { notice in
                        NoticeView(model: model, server: server, notice: notice) {
                            server.dismissedNotices.insert(ServerModel.noticeKey(notice))
                        }
                    }
                }.padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 180).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 34
    var source: String?
    var endpoint: URL?
    let cache: AvatarCache
    @State private var entry: AvatarEntry?
    private var hue: Double { Double(name.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) } % 360) / 360 }
    private var requestID: String { "\(endpoint?.absoluteString ?? "")|\(source ?? "")|\(cache.generation)" }
    var body: some View {
        ZStack {
            if entry?.source == source, let image = entry?.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                    .font(.system(size: size * 0.33, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hue: hue, saturation: 0.45, brightness: 0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hue: hue, saturation: 0.25, brightness: 0.8).opacity(0.18))
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
            .task(id: requestID) {
                entry = nil
                guard let source, let endpoint else { return }
                entry = cache.entry(source: source, endpoint: endpoint)
            }
    }
}

/// Stands in for an untitled private room's title, ahead of the participant names.
struct ParticipantAvatars: View {
    let participants: [UserProfile]
    var size: CGFloat = 18
    let server: ServerModel
    var body: some View {
        HStack(spacing: -size * 0.25) {
            ForEach(participants.prefix(3), id: \.id) { profile in
                AvatarView(name: profile.name, size: size, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
            }
        }
    }
}

struct MessageRow: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let message: JSONObject
    @State private var startingThread = false
    @State private var selectedUserProfile: String?
    @State private var showingProfile = false
    @State private var deleting = false
    @State private var showingReactionPicker = false
    @State private var menuHighlight = MessageMenuHighlight()
    @State private var isHovered = false
    @State private var showHoverActions = false
    @State private var editing = false
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
        HStack(alignment: .top, spacing: 12) {
            UserProfileButton(model: model, server: server, recorded: sender) {
                AvatarView(name: profile.name, source: profile.avatar, endpoint: URL(string: server.profile.address), cache: server.avatars)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UserProfileButton(model: model, server: server, recorded: sender) {
                        Text(profile.name).font(.callout.weight(.semibold))
                    }
                    ForEach(profile.roles, id: \.self) { role in
                        Text(role).font(.caption2).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
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
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help("Show original message")
                    .accessibilityIdentifier("replyContext-" + id)
                }
                if message.bool("deleted") { Text("Message deleted").italic().foregroundStyle(.tertiary) }
                else {
                    if message.object("body").string("format") == "markdown" {
                        MarkdownMessageView(source: text, size: model.messageSize, mentionNames: mentionNames, endpoint: server.profile.address, reviewLink: { model.receiveLink($0, from: server) }, showMention: { selectedUserProfile = $0 })
                            .id(server.account + "/" + id)
                    } else { NativeMessageText(text: MessageTextDisplay.attributed(text, names: mentionNames), size: model.messageSize) }
                    ForEach(displayEmbeds, id: \.self) { embed in
                        if embed.string("kind") != "upload", let address = embed.string("url"),
                           let preview = ApronLinkPreview(address: address, endpoint: server.profile.address,
                                                         store: server.snapshot.store, serverTitle: server.profile.title) {
                            ApronLinkPreviewCard(preview: preview, serverTitle: server.profile.title) {
                                model.receiveLink(preview.url, from: server)
                            }
                        } else {
                            AttachmentView(embed: embed, endpoint: URL(string: server.profile.address)!, serverID: server.id, account: server.account, mediaOrigins: server.snapshot.server.object("ext").object("media").strings("origins"))
                        }
                    }
                    let reactions = server.snapshot.store.reactionSummary(id)
                    if !reactions.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(reactions.keys.sorted(), id: \.self) { emoji in
                                Button {
                                    if canWrite && server.snapshot.supports("reactions") { model.react(emoji, message: message, server: server) }
                                } label: {
                                    Text("\(emoji) \(reactions[emoji]!.count)").font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(reactions[emoji]!.contains(server.account) ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: Capsule())
                                }.buttonStyle(.plain)
                                    .help("Right-click to see accounts that reacted")
                                    .contextMenu {
                                        Text("\(emoji) · Accounts")
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
            .sheet(isPresented: Binding(get: { selectedUserProfile != nil }, set: { if !$0 { selectedUserProfile = nil } })) {
                if let selectedUserProfile { UserProfileView(model: model, server: server, recorded: reactionIdentity(selectedUserProfile)) }
            }
            .onChange(of: server.account) { showingProfile = false; selectedUserProfile = nil }
            .confirmationDialog("Delete this message?", isPresented: $deleting) {
                Button("Delete Message", role: .destructive) { model.saveMessage(message, deleted: true, server: server) }
            }
            .sheet(isPresented: $showingReactionPicker) {
                EmojiPicker { emoji in
                    if canWrite && server.snapshot.supports("reactions") { model.react(emoji, message: message, server: server) }
                }
            }
            .sheet(isPresented: $editing) {
                MessageEditorView(message: message, localPreviews: localPreviews,
                    knownUserIDs: Set(server.snapshot.store.users.keys).union(server.snapshot.store.members[message.string("room_id") ?? ""] ?? []),
                    protocolVersion: server.snapshot.server["apron"]?.number ?? 9,
                    contextID: server.id.uuidString + "/" + server.account) { edit, params in
                        try await model.applyMessageEdit(edit, params: params, server: server)
                    }
            }
    }
    private var messageActions: [MessageAction] {
        var actions = [
            MessageAction(title: "Copy Link", enabled: link != nil, perform: copyLink),
            MessageAction(title: "View Profile", perform: { showingProfile = true }),
            MessageAction(title: "Copy Text", perform: {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            })
        ]
        if !message.bool("deleted") {
            actions.append(MessageAction(title: "Reply", enabled: canWrite, perform: reply))
            actions.append(MessageAction(title: "Start Thread…", enabled: canStartThread, perform: { startingThread = true }))
            if server.snapshot.supports("reactions") {
                actions.append(MessageAction(title: "React…", enabled: canWrite, perform: { showingReactionPicker = true }))
            }
            if server.snapshot.supports("edit") {
                actions.append(MessageAction(title: "Edit…", enabled: canWrite, perform: { editing = true }))
                actions.append(MessageAction(title: "Move to…", children: server.rooms.map { room in
                    MessageAction(title: server.title(room.string("room_id") ?? ""), perform: {
                        model.saveMessage(message, destination: room.string("room_id"), server: server)
                    })
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
