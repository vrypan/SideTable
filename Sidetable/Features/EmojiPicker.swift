import SwiftUI

struct EmojiPicker: View {
    let choose: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search emoji", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("emojiSearch")
                Button("Done") { dismiss() }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                    ForEach(EmojiCatalog.matching(query)) { entry in
                        Button { choose(entry.emoji); dismiss() } label: {
                            Text(entry.emoji).font(.system(size: 25)).frame(width: 36, height: 36)
                        }.buttonStyle(.plain).help(entry.description).accessibilityLabel(entry.description)
                    }
                }
            }
        }.padding(16).frame(width: 360, height: 320)
    }
}
