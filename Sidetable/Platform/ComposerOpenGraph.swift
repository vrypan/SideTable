import Foundation
// libxml2 exposes its allocator as a C function-pointer variable; SideTable never changes it.
@preconcurrency import libxml2
import ApronCore

/// Link Presentation exposes image bytes, but no public original-image URL.
/// Read the page's own OG tags to supply a URL the chat server can proxy.
enum ComposerOpenGraph {
    static let maximumHTMLBytes = 1024 * 1024

    static func fetch(_ url: URL) async -> JSONObject {
        guard webURL(url.absoluteString, relativeTo: url) != nil else { return [:] }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: ComposerPreviewRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (data, response) = try await BoundedDownload.data(for: request, session: session, limit: maximumHTMLBytes) { response in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      ["text/html", "application/xhtml+xml"].contains(http.mimeType?.lowercased() ?? ""),
                      http.url != nil, http.expectedContentLength <= maximumHTMLBytes else { throw URLError(.badServerResponse) }
            }
            guard let finalURL = response.url else { return [:] }
            return parse(data, url: finalURL)
        } catch { return [:] }
    }

    static func webURL(_ value: String, relativeTo base: URL) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value, relativeTo: base)?.absoluteURL,
              MediaPolicy.safeLink(url), url.host?.isEmpty == false else { return nil }
        return url
    }

    static func parse(_ data: Data, url: URL) -> JSONObject {
        guard !data.isEmpty, data.count <= maximumHTMLBytes else { return [:] }
        let options = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NONET.rawValue |
            HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue)
        let document = data.withUnsafeBytes {
            htmlReadMemory($0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), url.absoluteString, nil, options)
        }
        guard let document else { return [:] }
        defer { xmlFreeDoc(document) }
        // The HTML parser handles quoted attributes, entities, casing, comments,
        // and malformed markup. Only real elements in the head supply metadata.
        guard let context = xmlXPathNewContext(document) else { return [:] }
        defer { xmlXPathFreeContext(context) }
        let query = "/html/head/*".utf8CString.withUnsafeBytes {
            xmlXPathEvalExpression($0.baseAddress?.assumingMemoryBound(to: xmlChar.self), context)
        }
        guard let query else { return [:] }
        defer { xmlXPathFreeObject(query) }
        guard let nodes = query.pointee.nodesetval else { return [:] }
        var base = url, hasBase = false
        var text: JSONObject = [:]
        var images: [[String: String]] = []
        for index in 0..<Int(nodes.pointee.nodeNr) {
            guard let node = nodes.pointee.nodeTab[index], let name = node.pointee.name else { continue }
            switch String(cString: name).lowercased() {
            case "base":
                if !hasBase, let href = attribute(node, "href"), let resolved = webURL(href, relativeTo: url) {
                    base = resolved; hasBase = true
                }
            case "meta":
                guard let key = (attribute(node, "property") ?? attribute(node, "name"))?.lowercased(),
                      let value = attribute(node, "content"), !value.isEmpty else { continue }
                if ["og:title", "og:site_name", "og:description"].contains(key) {
                    let field = String(key.dropFirst(3))
                    if text[field] == nil { text[field] = .string(String(value.prefix(4096))) }
                } else if key == "og:image" || key == "og:image:url" {
                    images.append(["url": value])
                } else if key.hasPrefix("og:image:"), !images.isEmpty {
                    let field = String(key.dropFirst(9))
                    if images[images.count - 1][field] == nil { images[images.count - 1][field] = value }
                }
            default: break
            }
        }
        for fields in images {
            let secure = fields["secure_url"].flatMap { webURL($0, relativeTo: base) }.flatMap { $0.scheme == "https" ? $0 : nil }
            guard let imageURL = secure ?? fields["url"].flatMap({ webURL($0, relativeTo: base) }) else { continue }
            var image: JSONObject = ["url": .string(imageURL.absoluteString)]
            for key in ["type", "alt"] {
                if let value = fields[key] { image[key] = .string(String(value.prefix(4096))) }
            }
            for key in ["width", "height"] {
                if let value = fields[key].flatMap(Int.init), value > 0, value < 1_000_000 { image[key] = .number(Double(value)) }
            }
            text["image"] = .object(image)
            break
        }
        return text
    }

    private static func attribute(_ node: xmlNodePtr, _ name: String) -> String? {
        let value = name.utf8CString.withUnsafeBytes {
            xmlGetProp(node, $0.baseAddress?.assumingMemoryBound(to: xmlChar.self))
        }
        guard let value else { return nil }
        defer { xmlFree(value) }
        return String(cString: value)
    }
}

private final class ComposerPreviewRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ComposerOpenGraph.webURL(url.absoluteString, relativeTo: url) != nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
