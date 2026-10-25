import Foundation
import Testing
import ApronCore
@testable import Sidetable

private func editableMessage(_ embeds: [JSONObject], text: String = "Hello @ada") -> JSONObject {
    ["message_id": .string("100"), "log_id": .string("101"), "room_id": .string("room"),
     "from": .object(["user_id": .string("self")]), "reply_to": .object(["message_id": .string("99")]),
     "ext": .object(["custom": .string("kept")]),
     "body": .object(["text": .string(text), "format": .string("markdown"), "mentions": .array([.string("ada")]),
                      "custom": .bool(true), "embeds": .array(embeds.map(JSONValue.object))])]
}

@Test func messageEditPreservesSnapshotsAndDistinguishesSameURLAttachments() throws {
    let first: JSONObject = ["kind": .string("upload"), "embed_id": .string("first"), "title": .string("first.txt"),
        "url": .string("https://chat.example/file"), "og": .object(["title": .string("first.txt"), "description": .string("kept")])]
    let second: JSONObject = ["kind": .string("upload"), "embed_id": .string("second"), "title": .string("second.txt"),
        "url": .string("https://chat.example/file"), "og": .object(["title": .string("Server title")])]
    let link: JSONObject = ["kind": .string("link"), "url": .string("https://example.com"), "og": .object(["title": .string("Example")])]
    let original = editableMessage([first, second, link])
    var draft = MessageEdit(message: original)
    draft.attachments[0].title = "renamed.txt"
    draft.remove(1)
    let params = try draft.parameters(knownUserIDs: [])
    #expect(params.object("reply_to") == original.object("reply_to"))
    #expect(params.object("ext") == original.object("ext"))
    #expect(params["from"] == nil && params["log_id"] == nil)
    let body = params.object("body")
    #expect(body.string("format") == "markdown" && body.bool("custom"))
    #expect(body.strings("mentions") == ["ada"])
    let embeds = body.objects("embeds")
    #expect(embeds.count == 2 && embeds[0].string("embed_id") == "first" && embeds[1] == link)
    #expect(embeds[0].object("og").string("title") == "renamed.txt")
    #expect(embeds[0].object("og").string("description") == "kept")
    #expect(original.object("body").objects("embeds")[0] == first)
    draft.restore(1); draft.attachments[1].title = "other.txt"
    #expect(try draft.parameters(knownUserIDs: []).object("body").objects("embeds")[1].object("og").string("title") == "Server title")
}

@Test func messageEditDoesNotRemovePendingUploadsOrSaveEmptyMessages() throws {
    let pending: JSONObject = ["kind": .string("upload"), "embed_id": .string("pending"), "title": .string("photo.png")]
    var draft = MessageEdit(message: editableMessage([pending], text: ""))
    #expect(!draft.attachments[0].canRemove && !draft.attachments[0].canRename)
    draft.remove(0)
    #expect(draft.keptAttachments.count == 1 && !draft.changed && draft.canSave)
    draft = MessageEdit(message: editableMessage([["kind": .string("link"), "url": .string("https://example.com")]], text: ""))
    draft.remove(0)
    #expect(!draft.canSave)
    #expect(throws: MessageEdit.EditError.self) { try draft.parameters(knownUserIDs: []) }
    draft.restore(0)
    #expect(draft.canSave && !draft.changed)
}

@Test func messageEditRecomputesMentionsOnlyWhenTextChanges() throws {
    var draft = MessageEdit(message: editableMessage([]))
    draft.text = "Now @ben and @ada plus @unknown"
    #expect(try draft.parameters(knownUserIDs: ["ben"]).object("body").strings("mentions") == ["ada", "ben"])
    draft.text = "No mentions"
    #expect(try draft.parameters(knownUserIDs: ["ben"]).object("body").strings("mentions").isEmpty)
    #expect(draft.original.object("body").strings("mentions") == ["ada"])
}

@Test func messageEditRejectsOtherAccountsAndChangedMessages() throws {
    let original = editableMessage([])
    try MessageEdit.validate(original: original, current: original, account: "self")
    #expect(throws: MessageEdit.EditError.self) { try MessageEdit.validate(original: original, current: original, account: "other") }
    var updated = original; updated["log_id"] = .string("102")
    #expect(throws: MessageEdit.EditError.self) { try MessageEdit.validate(original: original, current: updated, account: "self") }
}

@MainActor @Test func hiddenGeneratedPreviewsStayLocalAndSurviveRelaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let preferences = LinkPreviewPreferences(storage: storage)
    let link = try #require(GitHubPreview("https://github.com/apron-chat/apron-web/pull/114"))
    let original = editableMessage([], text: link.url.absoluteString)
    var edit = MessageEdit(message: original, localPreviews: [link.embed])
    edit.remove(0)
    #expect(edit.changed && !edit.remoteChanged)
    #expect(try edit.parameters(knownUserIDs: []).object("body").objects("embeds").isEmpty)
    let server = UUID()
    try preferences.hide(edit.hiddenPreviewURLs, server: server, account: "self", message: "100")
    let reopened = LinkPreviewPreferences(storage: storage)
    #expect(reopened.hidden(server: server, account: "self", message: "100") == [link.url.absoluteString])
    #expect(reopened.hidden(server: server, account: "other", message: "100").isEmpty)
    #expect(reopened.hidden(server: UUID(), account: "self", message: "100").isEmpty)
    try reopened.clear(server: server)
    #expect(reopened.hidden(server: server, account: "self", message: "100").isEmpty)
}
