import Foundation
import ApronCore

/// A local edit draft. Merely changing or cancelling it never mutates the received message.
struct MessageEdit {
    struct Attachment: Identifiable {
        let id: Int
        let original: JSONObject
        var localOnly = false
        var title: String
        var removed = false

        var pending: Bool { original.string("kind") == "upload" && original.string("url") == nil }
        var canRename: Bool { original.string("kind") == "upload" && !pending }
        var canRemove: Bool { !pending }
        var removesContent: Bool { ["upload", "stream"].contains(original.string("kind") ?? "") }
        var originalTitle: String { Self.displayTitle(original) }
        var value: JSONObject {
            guard canRename, title != originalTitle else { return original }
            var value = original
            value["title"] = .string(title)
            var og = value.object("og")
            if og.string("title") == originalTitle {
                og["title"] = .string(title)
                value["og"] = .object(og)
            }
            return value
        }
        private static func displayTitle(_ embed: JSONObject) -> String {
            embed.string("title") ?? embed.object("og").string("title") ?? embed.string("url") ?? "Attachment"
        }
        init(id: Int, original: JSONObject) {
            self.id = id; self.original = original; title = Self.displayTitle(original)
        }
    }

    let original: JSONObject
    var text: String
    var attachments: [Attachment]

    init(message: JSONObject, localPreviews: [JSONObject] = []) {
        original = message
        text = message.object("body").string("text") ?? ""
        attachments = message.object("body").objects("embeds").enumerated().map { Attachment(id: $0.offset, original: $0.element) }
        for preview in localPreviews {
            var entry = Attachment(id: attachments.count, original: preview)
            entry.localOnly = true; attachments.append(entry)
        }
    }

    var keptAttachments: [Attachment] { attachments.filter { !$0.removed } }
    var changed: Bool {
        text != (original.object("body").string("text") ?? "") ||
        attachments.contains { $0.removed || $0.value != $0.original }
    }
    var remoteChanged: Bool {
        text != (original.object("body").string("text") ?? "") ||
        attachments.contains { !$0.localOnly && ($0.removed || $0.value != $0.original) }
    }
    var hiddenPreviewURLs: Set<String> {
        Set(attachments.filter(\.removed).compactMap { attachment in
            guard attachment.original.string("kind") != "upload", let address = attachment.original.string("url") else { return nil }
            return GitHubPreview(address)?.url.absoluteString
        })
    }
    var canSave: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keptAttachments.contains { !$0.localOnly }) &&
        keptAttachments.allSatisfy { !$0.canRename || !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    mutating func remove(_ id: Int) {
        guard let index = attachments.firstIndex(where: { $0.id == id }), attachments[index].canRemove else { return }
        attachments[index].removed = true
    }
    mutating func restore(_ id: Int) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].removed = false
    }

    func parameters(knownUserIDs: Set<String>, protocolVersion: Double = 9) throws -> JSONObject {
        guard canSave, original.string("message_id") != nil else { throw EditError.emptyMessage }
        var result = original.filter { ["message_id", "room_id", "body", "reply_to", "ext"].contains($0.key) }
        var body = original.object("body")
        if text != (body.string("text") ?? "") {
            body["text"] = .string(text)
            // A previously mentioned identity remains known even if it is not in the current member listing.
            let known = knownUserIDs.union(body.strings("mentions"))
            body["mentions"] = .array(MessageMentions.userIDs(in: text, version: protocolVersion)
                .intersection(known).sorted().map(JSONValue.string))
        }
        if attachments.contains(where: { !$0.localOnly && ($0.removed || $0.value != $0.original) }) {
            body["embeds"] = .array(keptAttachments.filter { !$0.localOnly }.map { .object($0.value) })
        }
        result["body"] = .object(body)
        return result
    }

    static func validate(original: JSONObject, current: JSONObject?, account: String) throws {
        guard original.object("from").string("user_id") == account else { throw EditError.unavailable }
        guard let current, !current.bool("deleted"), current == original else { throw EditError.changed }
    }

    enum EditError: LocalizedError {
        case emptyMessage, unavailable, changed
        var errorDescription: String? {
            switch self {
            case .emptyMessage: "Keep some text or an attachment. To remove everything, delete the message instead."
            case .unavailable: "This message cannot be edited on the current connection."
            case .changed: "This message changed while you were editing it. Cancel and reopen the editor to use the latest version."
            }
        }
    }
}
