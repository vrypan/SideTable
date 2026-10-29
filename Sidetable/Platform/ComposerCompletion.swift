import Foundation

struct ComposerSuggestion: Identifiable, Equatable {
    let insertion: String
    let label: String
    let search: String
    var id: String { insertion }
}

struct ComposerInsertion: Equatable {
    let id = UUID()
    let text: String
    var focus = true
}

struct EmojiEntry: Decodable, Identifiable, Sendable {
    let emoji: String
    let description: String
    let aliases: [String]
    let tags: [String]
    var id: String { emoji }
    let search: String

    private enum CodingKeys: String, CodingKey { case emoji, description, aliases, tags }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try values.decode(String.self, forKey: .emoji)
        description = try values.decode(String.self, forKey: .description)
        aliases = try values.decode([String].self, forKey: .aliases)
        tags = try values.decode([String].self, forKey: .tags)
        search = ([description] + aliases + tags).joined(separator: " ")
    }
}

enum EmojiCatalog {
    static let entries: [EmojiEntry] = {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([EmojiEntry].self, from: data) else { return [] }
        var seen = Set<String>()
        return entries.filter { !$0.emoji.isEmpty && seen.insert($0.emoji).inserted }
    }()
    /// Entries are unique by emoji, as filtered above.
    static let byEmoji = Dictionary(uniqueKeysWithValues: entries.map { ($0.emoji, $0) })
    static func matching(_ query: String) -> [EmojiEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.search.localizedCaseInsensitiveContains(query) || $0.emoji == query }
    }
}

struct RecentEmojis {
    var defaults: UserDefaults = .standard
    private let key = "recentEmojis"
    private let fallback = ["👍", "❤️", "🎉", "👀", "✨", "😀", "🚀"]

    var entries: [EmojiEntry] {
        let catalog = EmojiCatalog.byEmoji
        var seen = Set<String>()
        return Array(((defaults.stringArray(forKey: key) ?? []) + fallback)
            .filter { seen.insert($0).inserted }
            .compactMap { catalog[$0] }.prefix(7))
    }

    func record(_ emoji: String) {
        guard EmojiCatalog.byEmoji[emoji] != nil else { return }
        let previous = defaults.stringArray(forKey: key) ?? []
        defaults.set(Array(([emoji] + previous.filter { $0 != emoji }).prefix(7)), forKey: key)
    }
}

enum ComposerCompletion {
    struct Query: Equatable { let range: NSRange; let marker: String; let text: String }
    private static let trigger = try! NSRegularExpression(pattern: #"(?:^|[\s(])([@#:])([^\s]*?)$"#)
    static func query(in text: String, selection: NSRange) -> Query? {
        let ns = text as NSString
        guard selection.length == 0, selection.location != NSNotFound, selection.location <= ns.length else { return nil }
        let prefix = ns.substring(to: selection.location)
        // Do not complete code fences or inline code, URLs, or email addresses.
        let fences = prefix.components(separatedBy: "```").count - 1
        let line = prefix.components(separatedBy: .newlines).last ?? ""
        guard fences.isMultiple(of: 2), line.filter({ $0 == "`" }).count.isMultiple(of: 2),
              let match = trigger.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
        let marker = (prefix as NSString).substring(with: match.range(at: 1))
        let query = (prefix as NSString).substring(with: match.range(at: 2))
        guard !query.contains("/"), marker != ":" || !query.contains(":") else { return nil }
        return Query(range: NSRange(location: match.range(at: 1).location, length: selection.location - match.range(at: 1).location), marker: marker, text: query)
    }
    static func suggestions(for query: Query, candidates: [ComposerSuggestion]) -> [ComposerSuggestion] {
        if query.marker == ":" {
            let custom = candidates.filter { $0.insertion.hasPrefix(":") && (query.text.isEmpty || $0.search.localizedCaseInsensitiveContains(query.text)) }
            let unicode = EmojiCatalog.matching(query.text).prefix(8).map {
                ComposerSuggestion(insertion: $0.emoji, label: $0.emoji + "  " + $0.description, search: $0.search)
            }
            return Array((custom + unicode).prefix(8))
        }
        return Array(candidates.filter {
            $0.insertion.hasPrefix(query.marker) && (query.text.isEmpty || $0.search.localizedCaseInsensitiveContains(query.text))
        }.prefix(8))
    }
}

/// Store keys only: custom favorites belong to one server/account, never to a catalog URL.
struct EmojiFavorites {
    var defaults: UserDefaults = .standard
    var scope: String?
    private let unicodeKey = "favoriteUnicodeEmojis"
    private var customKey: String? { scope.map { "favoriteCustomEmojis." + $0 } }
    var keys: Set<String> {
        Set(defaults.stringArray(forKey: unicodeKey) ?? []).union(customKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
    }
    func toggle(_ emoji: String, custom: Bool) {
        let key: String
        if custom {
            guard CustomEmoji.validKey(emoji), let customKey else { return }
            key = customKey
        } else {
            guard EmojiCatalog.byEmoji[emoji] != nil else { return }
            key = unicodeKey
        }
        var saved = defaults.stringArray(forKey: key) ?? []
        if saved.contains(emoji) { saved.removeAll { $0 == emoji } }
        else { saved.append(emoji) }
        defaults.set(Array(saved.suffix(256)), forKey: key)
    }
}
