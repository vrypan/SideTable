import Foundation

/// A dedicated native return address, separate from reviewed Apron navigation links.
/// Servers must explicitly allow this callback; state never comes from the server.
enum BrowserSignIn {
    static let returnURL = URL(string: "sidetable://signin")!
    static let lifetime: TimeInterval = 10 * 60

    struct Attempt {
        let state = UUID().uuidString + UUID().uuidString
        let expiresAt: Date
        init(now: Date = Date()) { expiresAt = now.addingTimeInterval(BrowserSignIn.lifetime) }
        func matches(_ callback: Callback, now: Date = Date()) -> Bool {
            now < expiresAt && callback.state == state
        }
    }

    struct Callback {
        let state: String
        let token: String
    }

    static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "sidetable" && url.host?.lowercased() == "signin"
    }

    static func parse(_ url: URL) -> Callback? {
        guard isCallback(url), url.absoluteString.utf8.count <= 16 * 1024,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.query == nil, let fragment = parts.percentEncodedFragment else { return nil }
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = decode(String(components[0])) else { return nil }
            guard key == "state" || key == "token" else { continue }
            guard components.count == 2, values[key] == nil, let value = decode(String(components[1])) else { return nil }
            values[key] = value
        }
        guard let state = values["state"], !state.isEmpty, state.utf8.count <= 256,
              let token = values["token"], !token.isEmpty,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        // A matching state selects the original connection. Never route via `server`.
        return Callback(state: state, token: token)
    }

    private static func decode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
