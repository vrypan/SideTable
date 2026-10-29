import SwiftUI
import AppKit
import ApronCore
import UniformTypeIdentifiers

/// The message record as the client holds it, for inspecting what the
/// server sent.
struct MessageSourceView: View {
    let message: JSONObject
    @Environment(\.dismiss) private var dismiss
    static func text(_ message: JSONObject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(message)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    var body: some View {
        let source = Self.text(message)
        VStack(alignment: .leading, spacing: 12) {
            Text("Message Source").font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(source).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 480)
    }
}
