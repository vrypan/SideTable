import Foundation
import ApronCore

struct ApronLink: Equatable {
    let server: URL
    let room: String?
    let message: String?
    let user: String?
    let token: String?

    enum Invalid: LocalizedError {
        case link, server, destination
        var errorDescription: String? {
            switch self {
            case .link: "Enter an https://link.apron.chat/#… or apron:?… link."
            case .server: "The link needs a secure WebSocket server address (ws is allowed only on loopback)."
            case .destination: "The link contains an invalid destination. Messages need a room."
            }
        }
    }

    init(_ text: String, relativeTo endpoint: String? = nil) throws {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.user == nil, parts.password == nil else { throw Invalid.link }
        let encoded: String
        if parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "link.apron.chat",
           parts.port == nil, parts.path == "/" || parts.path.isEmpty, parts.query == nil {
            encoded = parts.percentEncodedFragment ?? ""
        } else if parts.scheme?.lowercased() == "apron", parts.host == nil, parts.path.isEmpty, parts.fragment == nil {
            encoded = parts.percentEncodedQuery ?? ""
        } else { throw Invalid.link }
        var fields: [String: String] = [:]
        for pair in encoded.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ value: Substring) throws -> String {
                guard let result = String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw Invalid.link }
                return result
            }
            let key = try decode(pieces.first ?? "")
            let value = try decode(pieces.count > 1 ? pieces[1] : "")
            if fields[key] == nil { fields[key] = value }
        }
        guard let address = fields["server"] ?? endpoint,
              let scheme = URLComponents(string: address)?.scheme?.lowercased(), ["wss", "ws"].contains(scheme),
              let url = try? ServerAddress.normalize(address) else { throw Invalid.server }
        server = url; room = fields["room"]; message = fields["message"]; user = fields["user"]; token = fields["token"]
        for id in [room, user].compactMap({ $0 }) {
            guard !id.isEmpty, !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw Invalid.destination }
        }
        if let message, room == nil || LogID(message) == nil { throw Invalid.destination }
        if token != nil && (token!.isEmpty || parts.scheme?.lowercased() == "apron") { throw Invalid.link }
    }

    static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._:/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
    }
}

enum MessageLink {
    static func url(endpoint: String, message: JSONObject, rooms: [String: JSONObject]) -> URL? {
        guard let server = try? ServerAddress.normalize(endpoint),
              let address = URLComponents(url: server, resolvingAgainstBaseURL: false), address.query == nil,
              let room = message.string("room_id"), !room.isEmpty,
              let id = message.string("message_id"), LogID(id) != nil else { return nil }
        let text = "https://link.apron.chat/#server=\(ApronLink.encode(server.absoluteString))&room=\(ApronLink.encode(room))&message=\(ApronLink.encode(id))"
        guard (try? ApronLink(text)) != nil else { return nil }
        return URL(string: text)
    }
}
