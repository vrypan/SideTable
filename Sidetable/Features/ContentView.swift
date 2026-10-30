import SwiftUI
import AppKit
import ApronCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            // A split view would not report or restore the members width, so the
            // column keeps its own width and divider, like conversation panels.
            HStack(spacing: 0) {
                discussions
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .ignoresSafeArea(.container, edges: visibility == .detailOnly ? [] : .top)
                Group {
                    if model.showMembers {
                        ResizeHandle(width: model.membersWidth, range: AppModel.membersWidthRange,
                                     defaultWidth: AppModel.defaultMembersWidth, leadingEdge: true,
                                     title: "members panel", identifier: "membersResizeHandle") { width in
                            model.membersWidth = width
                        } finished: {
                            model.saveMembersPanel()
                        }
                        membersColumn
                            .overlay(alignment: .topTrailing) {
                                membersToggle.padding(8)
                            }
                            .frame(width: model.membersWidth)
                    } else {
                        Rectangle().fill(.separator).frame(width: 1)
                        VStack(spacing: 0) {
                            membersToggle.padding(.top, 8)
                            if let panel = model.activePanel,
                               let server = model.servers.first(where: { $0.id == panel.serverID && $0.account == panel.account }) {
                                CollapsedMembersView(model: model, server: server, room: panel.room)
                                    .id(panel.key)
                            } else {
                                Spacer(minLength: 0)
                            }
                        }
                        .frame(width: 44)
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea(.container, edges: .top)
            }
            .ignoresSafeArea(.container, edges: visibility == .detailOnly ? [] : .top)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { model.ensureInitialPanel() }
        .sheet(isPresented: $model.showServerSignIn) {
            if let server = model.current { SignInView(model: model, server: server).frame(minWidth: 420, minHeight: 360) }
        }
        .onChange(of: model.current?.snapshot.phase) { if model.current?.snapshot.phase == .ready { model.showServerSignIn = false } }
        .sheet(isPresented: $model.showAddServer) { AddServerView(model: model) }
        .sheet(isPresented: $model.showOpenLink) { OpenLinkView(model: model) }
        .sheet(isPresented: Binding(get: { model.linkedUser != nil }, set: { if !$0 { model.linkedUser = nil } })) {
            if let server = model.current, let user = model.linkedUser {
                UserProfileView(model: model, server: server, recorded: ["user_id": .string(user)])
            }
        }
        .sheet(isPresented: $model.showJump) { JumpView(model: model) }
        .alert("SideTable", isPresented: Binding(get: { model.globalError != nil }, set: { if !$0 { model.globalError = nil } })) {
            Button("OK") { model.globalError = nil }
        } message: { Text(userText: model.globalError ?? "") }
    }

    private var discussions: some View {
        VStack(spacing: 0) {
            if model.preview {
                Text("Preview · Sample conversations · No server connection")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(6).background(.quaternary.opacity(0.3))
            }
            if let server = model.current {
                ServerNoticesView(model: model, server: server)
                if let until = server.snapshot.roomListingRetryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if until > context.date {
                            Label("Room and member refresh paused by the server. Try again in \(ceil(until.timeIntervalSince(context.date)).formatted(.number.precision(.fractionLength(0)))) seconds. Message history remains available.", systemImage: "clock")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let error = server.error ?? server.snapshot.error {
                    HStack {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(userText: error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { server.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss error")
                    }.padding(12).background(.orange.opacity(0.08))
                }
                if !model.panels.isEmpty {
                    ConversationPanelsView(model: model)
                } else if [.signIn, .authenticating].contains(server.snapshot.phase) {
                    SignInView(model: model, server: server)
                } else {
                    ContentUnavailableView {
                        Label("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Click a room to open it, or ⌘-click to add a panel.")
                    } actions: {
                        if server.snapshot.phase != .ready {
                            Button("Reconnect") { Task { await server.session?.reconnect() } }
                        }
                    }
                }
            } else {
                WelcomeView { model.showAddServer = true }
            }
        }
    }

    private var membersToggle: some View {
        Button { model.showMembers.toggle() } label: {
            Image(systemName: model.showMembers ? "person.2.fill" : "person.2")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.showMembers ? "Collapse members panel" : "Expand members panel")
        .accessibilityLabel(model.showMembers ? "Collapse members panel" : "Expand members panel")
        .accessibilityIdentifier("toggleMembers")
    }

    private var membersColumn: some View {
        Group {
            if let panel = model.activePanel,
               let server = model.servers.first(where: { $0.id == panel.serverID && $0.account == panel.account }) {
                MembersView(model: model, server: server, room: panel.room)
                    .id(panel.key)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("discussionMembers")
            } else {
                Text("Select a discussion to see its members.")
                    .foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
