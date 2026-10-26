import Foundation
import ApronCore

/// A presentation-only merge: recorded identities must never update the current-user store.
struct UserProfile {
    let fields: JSONObject
    let recordedID: String
    let hasCurrentIdentity: Bool
    let bio: String?
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
        // A bio is current profile data, never a fallback from historical message authors.
        let currentBio = current?.object("ext").string("bio").map(ProfileBio.display)
        bio = currentBio.flatMap { $0.isEmpty ? nil : $0 }
        var merged = recorded.merging(current ?? [:]) { _, new in new }
        // Presence is current information; a historical message must not imply someone is online.
        merged["status"] = current?["status"]
        merged["user_id"] = .string(canonical)
        fields = merged
    }
}

struct MemberListEntry: Identifiable {
    let id: String
    let profile: UserProfile
    let isActive: Bool
    let status: String

    var hoverText: String {
        var lines = [profile.name + " (@" + profile.id + ")", status]
        if !profile.roles.isEmpty { lines.append("Roles: " + profile.roles.joined(separator: ", ")) }
        if let bio = profile.bio { lines.append(bio) }
        lines.append("Click to view profile")
        return lines.joined(separator: "\n")
    }

    static func members(in room: String, store: RecordStore, presenceAvailable: Bool, query: String = "") -> [Self] {
        let members = (store.members[room] ?? []).map { id in
            let profile = UserProfile(recorded: ["user_id": .string(id)], store: store)
            let active = presenceAvailable && profile.status == "online"
            let status = !presenceAvailable ? "Presence unavailable" : active ? "Active" :
                profile.status == "dnd" ? "Do Not Disturb" : profile.status?.capitalized ?? "Presence unknown"
            return Self(id: id, profile: profile, isActive: active, status: status)
        }.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let order = lhs.profile.name.localizedStandardCompare(rhs.profile.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        return matching(members, query: query)
    }

    static func matching(_ members: [Self], query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return members }
        return members.filter { member in
            ([member.profile.name, member.profile.id, "@" + member.profile.id] + member.profile.roles)
                .contains { $0.localizedStandardContains(query) }
        }
    }
}
