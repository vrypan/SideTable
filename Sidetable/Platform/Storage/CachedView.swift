import Foundation
import ApronCore

struct CachedView: Codable, Sendable {
    let account: String
    let date: Date
    let rooms: [JSONObject]
    let messages: [JSONObject]
    let users: [JSONObject]
    let joined: [String]
    /// Contiguous history the next session continues from; `messages` is then empty.
    var history: HistorySeed?
}
