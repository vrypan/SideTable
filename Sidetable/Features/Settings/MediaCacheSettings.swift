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

struct TrustedMediaDomainsSettings: View {
    var preview = false
    @AppStorage(TrustedMediaDomains.defaultsKey) private var saved = ""
    @State private var domain = ""
    private var domains: [String] { TrustedMediaDomains.domains(in: saved) }
    private var validDomain: String? { TrustedMediaDomains.normalize(domain) }

    var body: some View {
        Section("Trusted media domains") {
            Text("Allow media from these domains to load automatically in all accounts. Applies to Markdown images and link-preview thumbnails; this does not enable autoplay. Subdomains must be added separately. Removing a domain stops future automatic loads; images already loaded stay visible.")
                .font(.caption).foregroundStyle(.secondary)
            if domains.isEmpty {
                Text("No trusted domains").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(domains, id: \.self) { host in
                            HStack {
                                Text(userText: host).textSelection(.enabled)
                                Spacer()
                                Button("Remove") { saved = TrustedMediaDomains.removing(host, from: saved) }
                                    .accessibilityLabel("Remove trusted media domain \(host)")
                            }
                        }
                    }
                }.frame(maxHeight: 140)
            }
            HStack {
                TextField("example.com", text: $domain)
                    .accessibilityLabel("Trusted image domain")
                    .onSubmit { add() }
                Button("Add") { add() }.disabled(validDomain == nil)
            }
            if !domain.isEmpty && validDomain == nil {
                Text("Enter a domain name without a URL, path, port, or wildcard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(preview)
    }

    private func add() {
        guard !preview, let validDomain else { return }
        saved = TrustedMediaDomains.adding(validDomain, to: saved)
        domain = ""
    }
}
