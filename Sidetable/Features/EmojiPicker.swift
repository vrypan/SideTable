import SwiftUI

struct EmojiPicker: View {
    let choose: (String) -> Void
    @State private var query = ""
    @State private var recent = RecentEmojis().entries
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let matches = EmojiCatalog.matching(query)
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(matches) { entry in emojiButton(entry) }
                }
            }
            .id(searching)
            .overlay {
                if matches.isEmpty {
                    Text("No emoji found").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(width: 360, height: 320)
    }

    private func emojiButton(_ entry: EmojiEntry) -> some View {
        Button {
            RecentEmojis().record(entry.emoji)
            choose(entry.emoji)
            dismiss()
        } label: {
            Text(entry.emoji).font(.system(size: 25)).frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(entry.description).accessibilityLabel(entry.description)
    }
}
