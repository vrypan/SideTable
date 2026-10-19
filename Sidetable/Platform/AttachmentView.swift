import SwiftUI
import AppKit
import QuickLook
import ApronCore

struct AttachmentView: View {
    let embed: JSONObject
    let endpoint: URL
    @State private var image: NSImage?
    @State private var previewURL: URL?
    @State private var busy = false
    @State private var error: String?
    private var url: URL? { embed.string("url").flatMap(URL.init(string:)) }
    private var title: String { embed.string("title") ?? "Attachment" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel(title)
            }
            HStack(spacing: 10) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium))
                    if let url, MediaPolicy.safeLink(url) {
                        HStack {
                            if MediaPolicy.allows(url, endpoint: endpoint) {
                                Button("Preview") { download(url, save: false) }
                                Button("Save…") { download(url, save: true) }
                            }
                            Link("Open ↗", destination: url)
                        }.font(.caption).disabled(busy)
                    } else {
                        Text(embed.string("kind") == "upload" ? "Upload pending…" : "Preview unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if busy { ProgressView().controlSize(.mini) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .quickLookPreview($previewURL)
            .task(id: embed) {
                let metadata = embed.object("og").object("image")
                guard let address = metadata.string("url"), let imageURL = URL(string: address), MediaPolicy.allows(imageURL, endpoint: endpoint) else { return }
                do { image = NSImage(data: try await fetch(imageURL, limit: 8 * 1024 * 1024)) }
                catch { /* A failed thumbnail must not obscure the file card. */ }
            }
    }
    private func download(_ url: URL, save: Bool) {
        guard !busy else { return }
        var destination: URL?
        if save {
            let panel = NSSavePanel(); panel.nameFieldStringValue = (title as NSString).lastPathComponent
            guard panel.runModal() == .OK else { return }; destination = panel.url
        }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await fetch(url, limit: 64 * 1024 * 1024)
                if let destination { try data.write(to: destination, options: .atomic) }
                else {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidetablePreviews").appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent((title as NSString).lastPathComponent.isEmpty ? "Attachment" : (title as NSString).lastPathComponent)
                    try data.write(to: file, options: .atomic); previewURL = file
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard MediaPolicy.allows(url, endpoint: endpoint) else { throw URLError(.unsupportedURL) }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
