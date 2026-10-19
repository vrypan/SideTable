import Foundation

enum MediaPolicy {
    static func allows(_ url: URL, endpoint: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        let scheme = endpoint.scheme == "wss" ? "https" : "http"
        return url.scheme == scheme && url.host == endpoint.host && (url.port ?? (scheme == "https" ? 443 : 80)) == (endpoint.port ?? (scheme == "https" ? 443 : 80))
    }
    static func safeLink(_ url: URL) -> Bool { ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
