import SwiftUI
import ApronCore

struct EmojiPicker: View {
    var store: CustomEmojiStore? = nil
    let choose: (String) -> Void
    @State private var query = ""
    @State private var recent = RecentEmojis().entries
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let matches = EmojiCatalog.matching(query)
        let custom = store?.offered.filter { $0.matches(query.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
        let categories = Dictionary(grouping: custom, by: \.category)
        VStack(spacing: 12) {
            HStack {
                TextField("Search emoji", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("emojiSearch")
                Button("Done") { dismiss() }
            }
            if !searching {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(recent) { entry in emojiButton(entry) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Recently used emoji")
                Divider()
            }
            if store?.loading == true { ProgressView("Loading server emoji…").controlSize(.small) }
            if store?.failed == true || store?.failedImages == true {
                HStack {
                    Text("Some server emoji could not be loaded.").font(.caption)
                    Button("Retry") { store?.retry() }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let store {
                        ForEach(categories.keys.sorted(), id: \.self) { category in
                            Text(userText: category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(categories[category] ?? []) { entry in
                                    Button { choose(entry.id); dismiss() } label: {
                                        CustomEmojiView(key: entry.id, store: store, size: 25, maximumWidth: 32)
                                            .frame(width: 36, height: 36).clipped().contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(UserText.isolated(entry.alt)).accessibilityLabel(UserText.clean(entry.alt))
                                }
                            }
                        }
                    }
                    if !custom.isEmpty { Text("Unicode emoji").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(matches) { entry in emojiButton(entry) }
                    }
                }
            }
            .id(searching)
            .overlay {
                if matches.isEmpty && custom.isEmpty && store?.loading != true {
                    Text("No emoji found").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(width: 360, height: 380)
            .task(id: store?.generation) { await store?.loadCatalog() }
    }

    private func emojiButton(_ entry: EmojiEntry) -> some View {
        Button {
            RecentEmojis().record(entry.emoji)
            choose(entry.emoji)
            dismiss()
        } label: {
            Text(userText: entry.emoji).font(.system(size: 25)).frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(entry.description).accessibilityLabel(entry.description)
    }
}
