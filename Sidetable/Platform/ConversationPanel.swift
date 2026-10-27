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
    /// The panel's own width; panels never share space, so resizing one scrolls the others.
    var width: CGFloat

    static let defaultWidth: CGFloat = 430
    static let minimumWidth: CGFloat = 340

    init(id: UUID = UUID(), server: ServerModel, room: String, isThread: Bool, width: CGFloat = ConversationPanel.defaultWidth) {
        self.id = id; serverID = server.id; account = server.account
        self.room = room; self.isThread = isThread
        self.width = max(Self.minimumWidth, width)
    }
    /// The last panel fills any space the others leave, without changing its saved width.
    static func displayedWidths(_ widths: [CGFloat], viewport: CGFloat) -> [CGFloat] {
        guard let last = widths.last else { return [] }
        return widths.dropLast() + [max(last, viewport - widths.dropLast().reduce(0, +))]
    }
    static func isFullyVisible(frame: CGRect, viewport: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && !frame.intersection(viewport).isNull
            && frame.intersection(viewport).width >= frame.width - 1
    }
    var key: DraftKey { DraftKey(server: serverID, account: account, room: room) }
}
