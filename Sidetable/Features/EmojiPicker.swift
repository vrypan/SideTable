import AppKit
import SwiftUI
import ApronCore

struct EmojiPicker: View {
    var store: CustomEmojiStore? = nil
    var favoriteScope: String? = nil
    let choose: (String, Bool) -> Void
    @State private var favorites: Set<String> = []
    @State private var query = ""
    @State private var recent = RecentEmojis().entries
    @State private var source = Source.all
    @State private var hovered: String?
    @State private var selected: String?
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    private enum Source: String, CaseIterable { case favorites = "Favorites", all = "All", server = "Server", unicode = "Unicode", recent = "Recent" }
    private struct Item: Identifiable {
        let id: String
        let name: String
        let details: String
        let custom: Bool
        let shortcode: String?
    }
    // Ten 32-point targets, with nine 4-point gaps, in each direction.
    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 4), count: 10)
    private var items: [Item] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = (store?.offered ?? []).filter { $0.matches(search) }.map {
            Item(id: $0.id, name: $0.alt, details: ([$0.id, $0.category] + $0.tags).joined(separator: " · "), custom: true, shortcode: $0.id)
        }
        let unicode = (source == .recent ? recent.filter { search.isEmpty || $0.search.localizedCaseInsensitiveContains(search) || $0.emoji == search } : EmojiCatalog.matching(search)).map {
            Item(id: $0.emoji, name: $0.description,
                details: ($0.aliases.map { ":" + $0 + ":" } + $0.tags).joined(separator: " · "), custom: false, shortcode: $0.aliases.first.map { ":" + $0 + ":" })
        }
        switch source {
        case .favorites: return (custom + unicode).filter { favorites.contains($0.id) }
        case .all: return (custom + unicode).filter { favorites.contains($0.id) } + (custom + unicode).filter { !favorites.contains($0.id) }
        case .server: return custom
        case .unicode, .recent: return unicode
        }
    }

    var body: some View {
        let entries = items
        let detail = entries.first { $0.id == (hovered ?? selected) }
        VStack(spacing: 10) {
            HStack {
                TextField("Search emoji", text: $query).textFieldStyle(.roundedBorder)
                    .focused($searching).accessibilityIdentifier("emojiSearch")
                    .onSubmit { if let item = entries.first(where: { $0.id == selected }) ?? entries.first { pick(item) } }
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                        guard !entries.isEmpty else { return .ignored }
                        if selected == nil && (press.key == .leftArrow || press.key == .rightArrow) { return .ignored }
                        let current = entries.firstIndex { $0.id == selected }
                        let step = press.key == .downArrow ? 10 : press.key == .upArrow ? -10 : press.key == .rightArrow ? 1 : -1
                        let index = current.map { min(entries.count - 1, max(0, $0 + step)) } ?? 0
                        selected = entries[index].id; hovered = nil
                        return .handled
                    }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Emoji source", selection: $source) {
                ForEach(Source.allCases, id: \.self) { source in
                    if source == .favorites {
                        Image(systemName: "star.fill").tag(source).help("Favorites").accessibilityLabel("Favorites")
                    } else if source != .server || store?.enabled == true { Text(source.rawValue).tag(source) }
                }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(entries) { item in
                            Button { pick(item) } label: {
                                Group {
                                    if item.custom, let store {
                                        CustomEmojiView(key: item.id, store: store, size: 20, maximumWidth: 25.6)
                                    } else { Text(userText: item.id).font(.system(size: 20)) }
                                }.frame(width: 32, height: 32)
                                    .background(hovered == item.id || selected == item.id ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help(UserText.isolated(item.name + "\n" + item.details))
                                .accessibilityLabel(UserText.clean(item.name))
                                .accessibilityHint(UserText.clean(item.details))
                                .onHover { inside in
                                    if inside { hovered = item.id }
                                    else if hovered == item.id { hovered = nil }
                                }
                                .contextMenu {
                                    Button(favorites.contains(item.id) ? "Unpin Favorite" : "Pin Favorite", systemImage: favorites.contains(item.id) ? "star.slash" : "star") { toggleFavorite(item) }
                                        .disabled(item.custom && favoriteScope == nil)
                                    Button("Copy Shortcode", systemImage: "doc.on.doc") {
                                        if let shortcode = item.shortcode {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(shortcode, forType: .string)
                                        }
                                    }.disabled(item.shortcode == nil)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if favorites.contains(item.id) {
                                        Image(systemName: "star.fill").font(.system(size: 6)).foregroundStyle(.secondary)
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                                }
                                .id(item.id)
                        }
                    }
                }.frame(width: 356, height: 356).scrollIndicators(.hidden)
                    .onChange(of: selected) { if let selected { proxy.scrollTo(selected) } }
                    .onChange(of: query) { resetSelection(); if let first = entries.first { proxy.scrollTo(first.id, anchor: .top) } }
                    .onChange(of: source) { resetSelection(); if let first = entries.first { proxy.scrollTo(first.id, anchor: .top) } }
                    .overlay {
                        if entries.isEmpty {
                            if store?.loading == true && source != .unicode && source != .recent {
                                ProgressView("Loading server emoji…").controlSize(.small)
                            } else { Text(source == .favorites ? "Right-click an emoji to pin a favorite" : "No emoji found").font(.callout).foregroundStyle(.secondary) }
                        }
                    }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(userText: detail?.name ?? "Hover over an emoji for details")
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text(userText: detail?.details ?? "↓ to browse · Return to choose · Esc to close\nShift-click to keep open · Right-click for options")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(width: 356, height: 52, alignment: .topLeading)
            if store?.failed == true || store?.failedImages == true {
                HStack {
                    Text("Some server emoji could not be loaded.").font(.caption)
                    Button("Retry") { store?.retry() }
                }
            }
        }.padding(16).frame(width: 388)
            .onAppear { searching = true; loadFavorites() }
            .onChange(of: favoriteScope) { loadFavorites(); resetSelection() }
            .task(id: store?.generation) { await store?.loadCatalog() }
    }
    private func loadFavorites() { favorites = EmojiFavorites(scope: favoriteScope).keys }
    private func toggleFavorite(_ item: Item) {
        EmojiFavorites(scope: favoriteScope).toggle(item.id, custom: item.custom)
        loadFavorites()
    }
    private func resetSelection() { selected = nil; hovered = nil }
    private func pick(_ item: Item) {
        if !item.custom { RecentEmojis().record(item.id) }
        let keepOpen = NSEvent.modifierFlags.contains(.shift)
        choose(item.id, keepOpen)
        if keepOpen { searching = true } else { dismiss() }
    }
}
