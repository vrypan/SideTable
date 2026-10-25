import Foundation

enum MediaPolicy {
    static func allows(_ url: URL, endpoint: URL, mediaOrigins: [String] = []) -> Bool {
        if safeLink(url), mediaOrigins.contains(where: { value in
            guard let origin = URL(string: value), safeLink(origin),
                  origin.path.isEmpty, origin.query == nil, origin.fragment == nil,
                  origin.scheme == "https" || (origin.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(origin.host ?? "")) else { return false }
            return url.scheme == origin.scheme && url.host == origin.host && effectivePort(url) == effectivePort(origin)
        }) { return true }
        guard url.user == nil, url.password == nil else { return false }
        let scheme = endpoint.scheme == "wss" ? "https" : "http"
        return url.scheme == scheme && url.host == endpoint.host && (url.port ?? (scheme == "https" ? 443 : 80)) == (endpoint.port ?? (scheme == "https" ? 443 : 80))
    }
    private static func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
    static func safeLink(_ url: URL) -> Bool { ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
