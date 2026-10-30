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
    /// Preferred width; display is capped to the available conversation viewport.
    var width: CGFloat

    static let defaultWidth: CGFloat = 430
    static let minimumWidth: CGFloat = 340

    init(id: UUID = UUID(), server: ServerModel, room: String, isThread: Bool, width: CGFloat = ConversationPanel.defaultWidth) {
        self.id = id; serverID = server.id; account = server.account
        self.room = room; self.isThread = isThread
        self.width = max(Self.minimumWidth, width)
    }
    /// Keep each panel and its handle within the viewport. The last panel fills
    /// leftover space; window resizing never overwrites the preferred widths.
    static func displayedWidths(_ widths: [CGFloat], viewport: CGFloat, handleWidth: CGFloat = 0) -> [CGFloat] {
        guard !widths.isEmpty else { return [] }
        let maximum = max(0, viewport - handleWidth)
        var displayed = widths.map { min(max(0, $0), maximum) }
        let available = max(0, viewport - CGFloat(widths.count) * handleWidth)
        let last = displayed.count - 1
        displayed[last] = min(maximum, max(displayed[last], available - displayed.dropLast().reduce(0, +)))
        return displayed
    }
    static func isFullyVisible(frame: CGRect, viewport: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && !frame.intersection(viewport).isNull
            && frame.intersection(viewport).width >= frame.width - 1
    }
    var key: DraftKey { DraftKey(server: serverID, account: account, room: room) }

    /// Where a dragged panel lands: the slot under the pointer, measured along the
    /// unshifted row. Beyond either end it lands first or last. `widths` include each
    /// panel's resize handle.
    static func dropIndex(widths: [CGFloat], pointer: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        var end: CGFloat = 0
        for (index, width) in widths.enumerated() {
            end += width
            if pointer < end { return index }
        }
        return widths.count - 1
    }
}

/// A panel being dragged by its header; transient and never saved.
struct PanelDrag: Equatable {
    let id: UUID
    var offset: CGFloat
    /// Pointer position along the panel row.
    var pointer: CGFloat
    /// The gesture ended or was cancelled; the panels view drops the panel.
    var released = false
}
