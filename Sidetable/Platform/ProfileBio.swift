import Foundation
import ApronCore

/// `ext:bio` is bounded plain text. Never interpret a bio as Markdown or HTML.
enum ProfileBio {
    static let maximumCharacters = 250

    static func isSupported(by snapshot: SessionSnapshot) -> Bool {
        snapshot.supports("ext:bio") || snapshot.supports("ext")
    }

    /// Cleaning does not truncate editing input: the editor must show an over-limit count.
    static func clean(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        let scalars = normalized.unicodeScalars.filter {
            $0.value == 10 || ($0.properties.generalCategory != .control
                && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value))
        }
        let stripped = String(String.UnicodeScalarView(scalars))
        let lines = stripped.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines {
            if line.isEmpty && result.last == "" { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func display(_ text: String) -> String {
        String(String.UnicodeScalarView(clean(text).unicodeScalars.prefix(maximumCharacters)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func characterCount(_ text: String) -> Int { clean(text).unicodeScalars.count }

    /// Link only explicit HTTP(S) URLs; Markdown, HTML, email, and Apron syntax stays literal.
    static func linkedText(_ text: String) -> AttributedString {
        let text = display(text)
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, MediaPolicy.safeLink(url),
                  let range = Range(match.range, in: text),
                  text[range].lowercased().hasPrefix("http://") || text[range].lowercased().hasPrefix("https://"),
                  let attributedRange = Range(range, in: result) else { continue }
            result[attributedRange].link = url
        }
        return result
    }
}
