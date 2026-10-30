import Foundation
import Testing
import ApronCore
@testable import Sidetable

@MainActor @Test func completingAnOldEditDoesNotCloseTheCurrentEditor() throws {
    let state = ConversationComposerState(preview: true)
    state.beginEditing(["message_id": .string("100")], previews: [], account: "ada")
    let old = try #require(state.editingMessage)
    state.beginEditing(["message_id": .string("200")], previews: [], account: "ada")
    state.finishEditing(old.id)
    #expect(state.editingMessage?.message.string("message_id") == "200")
    #expect(!state.restoreFocus)
    state.finishEditing(try #require(state.editingMessage).id)
    #expect(state.editingMessage == nil && state.restoreFocus)
    state.changeRoom()
    #expect(!state.restoreFocus)
}

@MainActor @Test func composerPreviewRequestsRespectCommandsExclusionsAndConversationIdentity() {
    let state = ConversationComposerState(preview: true)
    let key = DraftKey(server: UUID(), account: "ada", room: "general")
    var draft = SavedDraft(text: "https://first.example/ https://second.example/")
    draft.excludedPreviewURLs = ["https://first.example/"]
    let request = state.linkRequest(draft: draft, key: key, commands: true)
    #expect(request.key == key)
    #expect(request.links.map(\.id) == ["https://second.example/"])
    draft.text = "/topic https://second.example/"
    #expect(state.linkRequest(draft: draft, key: key, commands: true).links.isEmpty)
    #expect(state.linkRequest(draft: draft, key: key, commands: false).links.count == 1)
    state.beginEditing(["message_id": .string("100")], previews: [], account: "ada")
    state.cancelEditing()
    #expect(state.linkRequest(draft: draft, key: key, commands: false).links.count == 1)
}
