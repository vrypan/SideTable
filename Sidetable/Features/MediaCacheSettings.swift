import SwiftUI

struct MediaCacheSettings: View {
    var preview = false
    @State private var bytes: Int64 = 0
    @State private var clearing = false
    @State private var error: String?

    var body: some View {
        Section("Downloaded media") {
            LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            Text("Images, link thumbnails, and opened attachments are kept on this Mac for reuse. The cache keeps up to 256 MiB, removing the least recently used files when full.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear Downloaded Media") {
                clearing = true; error = nil
                AttachmentRenderCache.shared.clear()
                NotificationCenter.default.post(name: .mediaCacheCleared, object: nil)
                Task {
                    do { try await MediaCache.shared.clear() }
                    catch { self.error = error.localizedDescription }
                    bytes = await MediaCache.shared.usage(); clearing = false
                }
            }.disabled(preview || clearing)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task { if !preview { bytes = await MediaCache.shared.usage() } }
    }
}
