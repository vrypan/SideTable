import SwiftUI
import ApronCore

struct ComposerLinkPreviewList: View {
    let links: [ComposerLink]
    let metadata: [String: JSONObject]
    let hasExcludedLinks: Bool
    let remove: (ComposerLink) -> Void
    let restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !links.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(links) { link in
                            let og = metadata[link.id] ?? [:]
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top) {
                                    Label(og.string("site_name") ?? link.url.host ?? "Link", systemImage: "link")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Button { remove(link) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).help("Remove link preview")
                                        .accessibilityLabel("Remove preview for \(link.id)")
                                        .accessibilityIdentifier("removeLinkPreview-" + link.id)
                                }
                                Text(og.string("title") ?? link.id).font(.callout).lineLimit(2)
                                if let description = og.string("description"), !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(9).frame(width: 230, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("composerLinkPreview-" + link.id)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            if hasExcludedLinks {
                Button("Restore link previews", action: restore)
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("restoreLinkPreviews")
            }
        }
    }
}
