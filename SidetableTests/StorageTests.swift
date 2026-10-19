import Foundation
import Testing
@testable import Sidetable

@MainActor @Test func draftsPreserveAccountAndEndpointIsolation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStorage(directory: root)
    let server = UUID()
    let a = DraftKey(server: server, account: "ada", room: "general")
    let b = DraftKey(server: server, account: "ben", room: "general")
    let drafts = [a: SavedDraft(text: "Private draft", replyTo: "100"), b: SavedDraft(text: "Different user")]
    try store.write(drafts, to: "drafts.json")
    #expect(store.read("drafts.json", as: [DraftKey: SavedDraft].self) == drafts)
}

@Test func mediaRequestsCannotCrossOrigins() {
    let server = URL(string: "wss://chat.example/ws")!
    #expect(MediaPolicy.allows(URL(string: "https://chat.example/files/a")!, endpoint: server))
    #expect(!MediaPolicy.allows(URL(string: "https://evil.example/files/a")!, endpoint: server))
    #expect(!MediaPolicy.allows(URL(string: "https://chat.example:444/files/a")!, endpoint: server))
    #expect(!MediaPolicy.safeLink(URL(string: "javascript:alert(1)")!))
}
