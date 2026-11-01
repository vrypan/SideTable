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

/// Exact host names shared by all accounts. Subdomains must be trusted separately.
enum TrustedMediaDomains {
    static let defaultsKey = "trustedMediaDomains"

    static func normalize(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
              !value.contains(where: { "/:@?#%\\*".contains($0) }),
              let url = URL(string: "https://" + value), let host = url.host?.lowercased(),
              host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }

    static func domains(in saved: String) -> [String] {
        Set(saved.components(separatedBy: "\n").compactMap(normalize)).sorted()
    }

    static func adding(_ domain: String, to saved: String) -> String {
        guard let domain = normalize(domain) else { return saved }
        return Set(domains(in: saved) + [domain]).sorted().joined(separator: "\n")
    }

    static func removing(_ domain: String, from saved: String) -> String {
        domains(in: saved).filter { $0 != normalize(domain) }.joined(separator: "\n")
    }

    static func allows(_ url: URL, saved: String) -> Bool {
        guard MediaPolicy.safeLink(url), let host = url.host.flatMap(normalize) else { return false }
        return domains(in: saved).contains(host)
    }
}
