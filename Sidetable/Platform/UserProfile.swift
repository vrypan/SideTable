import Foundation
import ApronCore

/// A presentation-only merge: recorded identities must never update the current-user store.
struct UserProfile {
    let fields: JSONObject
    let recordedID: String
    let hasCurrentIdentity: Bool
    var id: String { fields.string("user_id") ?? "Unknown" }
    var name: String { fields.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? id }
    var avatar: String? { fields.string("avatar").flatMap { $0.isEmpty ? nil : $0 } }
    var roles: [String] { fields.strings("roles") }
    var status: String? { fields.string("status").flatMap { $0.isEmpty ? nil : $0 } }

    init(recorded: JSONObject, store: RecordStore) {
        recordedID = recorded.string("user_id") ?? "Unknown"
        var canonical = recordedID
        var seen: Set<String> = []
        while let next = store.aliases[canonical], seen.insert(canonical).inserted { canonical = next }
        let current = store.users[canonical]
        hasCurrentIdentity = current != nil
        var merged = recorded.merging(current ?? [:]) { _, new in new }
        // Presence is current information; a historical message must not imply someone is online.
        merged["status"] = current?["status"]
        merged["user_id"] = .string(canonical)
        fields = merged
    }
}
