import SwiftUI
import AppKit
import ApronCore

struct SidebarThread: Identifiable {
    let id: String
    let title: String
    let summary: String
    let activity: UInt64
    let unread: Int

    static func entries(store: RecordStore, parent: String, unread: [String: Int]) -> [Self] {
        store.rooms.values.compactMap { room -> Self? in
            guard room.string("parent_room_id") == parent, let id = room.string("room_id") else { return nil }
            let messages = store.timeline(id)
            let activity = max(room.logID("latest_log_id") ?? 0, room.logID("log_id") ?? 0,
                               messages.map { $0.logID("log_id") ?? 0 }.max() ?? 0)
            var summary = excerpt(room.string("description") ?? "")
            if summary.isEmpty, let message = messages.last(where: { !$0.bool("deleted") }) {
                let body = message.object("body")
                let text = excerpt(body.string("text") ?? "")
                let content = text.isEmpty && !body.objects("embeds").isEmpty ? "Attachment" : text
                if !content.isEmpty { summary = store.displayName(message.object("from")) + ": " + content }
            }
            return Self(id: id, title: room.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? id,
                        summary: summary, activity: activity, unread: unread[id] ?? 0)
        }.sorted { lhs, rhs in
            if lhs.activity != rhs.activity { return lhs.activity > rhs.activity }
            return lhs.id < rhs.id
        }
    }

    static func groups(_ entries: [Self], selected: String?) -> (recent: [Self], older: [Self]) {
        let visible = Set(entries.prefix(4).map(\.id))
        return (entries.filter { visible.contains($0.id) || $0.id == selected || $0.unread > 0 },
                entries.filter { !visible.contains($0.id) && $0.id != selected && $0.unread == 0 })
    }

    private static func excerpt(_ source: String) -> String {
        let bounded = String(source.prefix(1024))
        let parsed = try? AttributedString(markdown: bounded, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return String(parsed?.characters ?? AttributedString(bounded).characters)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct SidebarThreadsView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    let parent: String
    @State private var showOlder = false

    private var selected: String? {
        guard model.activePanel?.serverID == server.id, model.activePanel?.account == server.account else { return nil }
        return model.activePanel?.room
    }

    var body: some View {
        let entries = model.navigationTiming.measure(.threadSummaries, server: server.id, room: selected ?? parent) {
            SidebarThread.entries(store: server.snapshot.store, parent: parent, unread: server.unread)
        }
        let groups = SidebarThread.groups(entries, selected: selected)
        ForEach(groups.recent) { thread in row(thread) }
        if !groups.older.isEmpty {
            // A sidebar DisclosureGroup outdents its chevron to the list edge;
            // this toggle stays in the thread column with the rows it reveals.
            Button { withAnimation { showOlder.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showOlder ? 90 : 0))
                    Text(userText: "Other threads · \(groups.older.count)").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("olderThreads-" + parent)
            .accessibilityValue(showOlder ? "Expanded" : "Collapsed")
            if showOlder {
                ForEach(groups.older) { thread in row(thread) }
            }
        }
    }

    private func row(_ thread: SidebarThread) -> some View {
        Button {
            model.selectRoom(thread.id, server: server, asThread: true)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(userText: thread.title).font(.callout.weight(thread.unread > 0 || selected == thread.id ? .semibold : .regular))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if thread.unread > 0 {
                        Text(String(thread.unread)).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).background(.tint.opacity(0.13), in: Capsule())
                    }
                    if thread.activity > 0 {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let minutes = max(0, Int(context.date.timeIntervalSince1970 / 60 - Double(thread.activity) / 60_000))
                            Text(userText: minutes < 1 ? "now" : minutes < 60 ? "\(minutes)m" : minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d")
                                .font(.caption2).foregroundStyle(.tertiary).fixedSize()
                        }
                        .help("Latest known thread activity")
                    }
                    RoomMuteIndicator(snapshot: server.snapshot, room: thread.id, parent: parent)
                }
                if !thread.summary.isEmpty {
                    Text(userText: thread.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

            }
            .padding(.leading, 12).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebarThread-" + thread.id)
        .accessibilityValue("\(thread.unread) unread")
        .listRowBackground(selected == thread.id ? Color.accentColor.opacity(0.12) : Color.clear)
        .modifier(RoomContextMenu(model: model, server: server, room: thread.id, isThread: true))
    }
}
