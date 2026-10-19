import Foundation
import ApronCore

/// Compatible with apron-web's src/lib/ui/address.ts destination format.
enum MessageLink {
    static func url(endpoint: String, message: JSONObject, rooms: [String: JSONObject]) -> URL? {
        guard let server = try? ServerAddress.normalize(endpoint),
              let address = URLComponents(url: server, resolvingAgainstBaseURL: false),
              address.query == nil, // Never put endpoint query credentials in a shareable URL.
              let room = message.string("room_id"), !room.isEmpty,
              let id = message.string("message_id"), LogID(id) != nil else { return nil }
        let parent = rooms[room]?.string("parent_room_id")
        var link = URLComponents(string: "https://web.apron.chat/")!
        link.queryItems = [URLQueryItem(name: "server", value: server.absoluteString),
                           URLQueryItem(name: "room", value: parent ?? room)]
        if parent != nil { link.queryItems?.append(URLQueryItem(name: "thread", value: room)) }
        // URLSearchParams treats literal + as a space; encode it in opaque IDs.
        link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        link.fragment = "message=\(id)"
        return link.url
    }
}
