import Foundation
import Observation

@MainActor @Observable
final class ConversationPanel: Identifiable {
    let id: UUID
    let serverID: UUID
    let account: String
    let room: String
    let isThread: Bool
    var findText = ""
    var showFind = false
    var showMembers = false

    init(id: UUID = UUID(), server: ServerModel, room: String, isThread: Bool) {
        self.id = id; serverID = server.id; account = server.account
        self.room = room; self.isThread = isThread
    }
    static func isFullyVisible(frame: CGRect, viewport: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && !frame.intersection(viewport).isNull
            && frame.intersection(viewport).width >= frame.width - 1
    }
    var key: DraftKey { DraftKey(server: serverID, account: account, room: room) }
}
