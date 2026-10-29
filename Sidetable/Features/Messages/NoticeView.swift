import SwiftUI
import AppKit
import ApronCore
import UniformTypeIdentifiers

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
                    Text(userText: name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Dismiss notice").accessibilityLabel("Dismiss notice")
                }
            }
            if body.string("format") == "markdown", let text = body.string("text") {
                MarkdownMessageView(source: text, size: model.messageSize, roomNames: server.roomReferenceNames(in: text), endpoint: server.profile.address,
                                    reviewLink: { model.receiveLink($0, from: server) }, emojiStore: server.emojis)
            } else {
                EmojiMessageText(text: MessageTextDisplay.attributed(body.string("text") ?? "Server notice", roomNames: server.roomReferenceNames(in: body.string("text") ?? "")), size: model.messageSize, store: server.emojis)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notice")
        .environment(\.openURL, OpenURLAction { url in
            MessageNavigation.open(url, relativeTo: server.profile.address, review: { model.receiveLink($0, from: server) })
        })
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
