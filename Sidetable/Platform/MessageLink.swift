import Foundation
import SwiftUI
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
            case .link: "Enter an https://link.apron.chat/#…, apron:?…, or sidetable://open?… link."
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
        } else if parts.scheme?.lowercased() == "sidetable", parts.host?.lowercased() == "open",
                  parts.port == nil, parts.path.isEmpty || parts.path == "/", parts.fragment == nil {
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
        if token != nil && (token!.isEmpty || parts.scheme?.lowercased() != "https") { throw Invalid.link }
    }

    static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._:/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
    }
}

enum ServerLink {
    static func url(endpoint: String) -> URL? {
        // Match room/message sharing: endpoint query strings can contain credentials.
        guard let server = try? ServerAddress.normalize(endpoint),
              URLComponents(url: server, resolvingAgainstBaseURL: false)?.query == nil else { return nil }
        return URL(string: "https://link.apron.chat/#server=" + ApronLink.encode(server.absoluteString))
    }
}

enum RoomLink {
    static func url(endpoint: String, room: String) -> URL? {
        guard !room.isEmpty, let server = try? ServerAddress.normalize(endpoint),
              let address = URLComponents(url: server, resolvingAgainstBaseURL: false), address.query == nil else { return nil }
        let text = "https://link.apron.chat/#server=\(ApronLink.encode(server.absoluteString))&room=\(ApronLink.encode(room))"
        guard (try? ApronLink(text)) != nil else { return nil }
        return URL(string: text)
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

/// Navigation allows reviewed Apron destinations without widening media/download policy.
enum MessageNavigation {
    enum Destination: Equatable { case review, web, blocked }

    static func destination(_ url: URL, relativeTo endpoint: String? = nil) -> Destination {
        let scheme = url.scheme?.lowercased()
        if scheme == "apron" || scheme == "sidetable" ||
            (scheme == "https" && url.host?.lowercased() == "link.apron.chat") {
            return (try? ApronLink(url.absoluteString, relativeTo: endpoint)) == nil ? .blocked : .review
        }
        return MediaPolicy.safeLink(url) ? .web : .blocked
    }

    /// Freeze the source server before destination review can change the selected server.
    static func resolvedLink(_ url: URL, relativeTo endpoint: String?) -> URL? {
        if (try? ApronLink(url.absoluteString)) != nil { return url }
        guard let link = try? ApronLink(url.absoluteString, relativeTo: endpoint),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let server = "server=" + ApronLink.encode(link.server.absoluteString)
        if parts.scheme?.lowercased() == "https" {
            parts.percentEncodedFragment = (parts.percentEncodedFragment.map { $0 + "&" } ?? "") + server
        } else {
            parts.percentEncodedQuery = (parts.percentEncodedQuery.map { $0 + "&" } ?? "") + server
        }
        return parts.url
    }

    @MainActor
    static func open(_ url: URL, relativeTo endpoint: String? = nil, review: ((URL) -> Void)?) -> OpenURLAction.Result {
        switch destination(url, relativeTo: endpoint) {
        case .review:
            guard let review else { return .discarded }
            guard let resolved = resolvedLink(url, relativeTo: endpoint) else { return .discarded }
            review(resolved)
            return .handled
        case .web: return .systemAction
        case .blocked: return .discarded
        }
    }
}
