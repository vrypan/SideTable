import Foundation
import AppKit
import SwiftUI
import Testing
import ApronCore
@testable import Sidetable

/// Opt-in transcript rendering benchmark. Run with
/// `TEST_RUNNER_SIDETABLE_BENCHMARK=1`; see docs/testing.md for the optimized command.
/// It scrolls real message rows offscreen through a LazyVStack, which rebuilds rows
/// the reader returns to, and reports per-step timings and text views created.
private let benchmarkEnabled = ProcessInfo.processInfo.environment["SIDETABLE_BENCHMARK"] == "1"

enum BenchmarkCorpus: String, CaseIterable { case text, embeds, mixed }

/// Server-sent embeds that never touch the network: link cards whose images are
/// outside the media policy, and non-image uploads.
private func benchmarkEmbeds(_ index: Int) -> [JSONValue] {
    var embeds: [JSONValue] = [.object(["kind": .string("link"), "url": .string("https://news.example/story/\(index)"),
        "og": .object(["title": .string("Story \(index): a headline long enough to wrap onto a second line in the card"),
                       "description": .string("A description of the linked page that also spans more than one line of text."),
                       "site_name": .string("News Example"),
                       "image": .object(["url": .string("https://cdn.elsewhere.example/\(index).jpg"), "width": .number(1200), "height": .number(630)])])])]
    if index % 2 == 0 {
        embeds.append(.object(["kind": .string("upload"), "url": .string("https://chat.example/files/report-\(index).pdf"),
                               "title": .string("report-\(index).pdf")]))
    }
    return embeds
}

@MainActor private func benchmarkServer(count: Int, corpus: BenchmarkCorpus) -> ServerModel {
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    server.snapshot.phase = .ready
    server.snapshot.you = ["user_id": .string("ada")]
    server.snapshot.store.joined = ["general"]
    server.snapshot.store.installRoom(["room_id": .string("general"), "title": .string("General")])
    for user in ["ada", "ben", "cy"] {
        server.snapshot.store.mergeUser(["user_id": .string(user), "name": .string(user.capitalized + " Example")])
    }
    for index in 0..<count {
        let id = String(1_900_000_000_000 + index)
        var body: JSONObject
        switch corpus == .embeds ? 4 : index % 5 {
        case 0, 1:
            body = ["format": .string("markdown"), "text": .string("""
                ## Update \(index)

                Thanks @ben, the **build** is green. See [the notes](https://example.com/notes/\(index)) and `make check`.

                - first item with *emphasis*
                - second item linking https://example.com/issues/\(index)
                  1. nested step

                > quoted context from earlier

                ```swift
                let value = \(index)
                print(value)
                ```
                """)]
        case 2:
            body = ["format": .string("markdown"), "text": .string("Short **markdown** reply \(index) for @cy.")]
        case 3:
            body = ["text": .string("Plain message \(index) from @ada with a link https://example.com/page?item=\(index)&ref=bench and some more words to wrap across a couple of lines in a typical panel width.")]
        default:
            body = ["text": .string("ok \(index)")]
        }
        if corpus == .embeds || (corpus == .mixed && index % 3 == 0) { body["embeds"] = .array(benchmarkEmbeds(index)) }
        server.snapshot.store.installMessage(["message_id": .string(id), "log_id": .string(id), "room_id": .string("general"),
            "from": .object(["user_id": .string(["ada", "ben", "cy"][index % 3])]), "body": .object(body)])
    }
    return server
}

@MainActor private struct BenchmarkTranscript: View {
    let model: AppModel
    let server: ServerModel
    let messages: [JSONObject]
    var body: some View {
        // Mirrors the transcript: rows are created lazily and rebuilt after scrolling away.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages, id: \.messageIdentity) { MessageRow(model: model, server: server, message: $0) }
            }
        }.frame(width: 600, height: 800)
    }
}

private func scrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for child in view.subviews { if let found = scrollView(in: child) { return found } }
    return nil
}

/// Scrolls through the whole transcript in reader-sized steps, letting deferred updates run after each one.
/// Returns per-step durations (a step that exceeds a frame budget is a visible hitch).
@MainActor private func sweep(_ host: NSView, scroll: NSScrollView, downward: Bool, step: CGFloat = 300) -> [Double] {
    let clock = ContinuousClock()
    var durations: [Double] = []
    var y = downward ? 0 : scroll.documentView?.frame.height ?? 0
    while true {
        let start = clock.now
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<2 { RunLoop.main.run(mode: .default, before: Date()); host.layoutSubtreeIfNeeded() }
        durations.append(milliseconds(clock.now - start))
        let height = scroll.documentView?.frame.height ?? 0
        if downward { if y >= height - 800 { break }; y += step } else { if y <= 0 { break }; y -= step }
    }
    return durations
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@MainActor @Test(.enabled(if: benchmarkEnabled), arguments: BenchmarkCorpus.allCases)
func renderBenchmarkRebuildsLoadedRows(corpus: BenchmarkCorpus) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    let server = benchmarkServer(count: 150, corpus: corpus)
    let messages = server.snapshot.store.timeline("general")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let clock = ContinuousClock()
    let start = clock.now
    let host = NSHostingView(rootView: BenchmarkTranscript(model: model, server: server, messages: messages))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let open = milliseconds(clock.now - start)
    let scroll = try #require(scrollView(in: host))
    func summary(_ steps: [Double]) -> String {
        let sorted = steps.sorted()
        return String(format: "total=%.0fms median=%.1fms p90=%.1fms max=%.1fms steps=%d", steps.reduce(0, +),
                      sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last ?? 0, steps.count)
    }
    let passes = ProcessInfo.processInfo.environment["SIDETABLE_BENCHMARK_PASSES"].flatMap(Int.init) ?? 2
    let first = sweep(host, scroll: scroll, downward: true)
    var later: [Double] = []
    func inHierarchy(_ view: NSView) -> Int { (view is MessageTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + inHierarchy($1) } }
    print("BENCH \(corpus) text views created after first sweep: \(MessageTextViewPool.shared.created), in hierarchy: \(inHierarchy(host))")
    for _ in 0..<passes {
        later += sweep(host, scroll: scroll, downward: false); later += sweep(host, scroll: scroll, downward: true)
        print("BENCH \(corpus) text views created: \(MessageTextViewPool.shared.created), in hierarchy: \(inHierarchy(host))")
    }
    print(String(format: "BENCH %@ open=%.0fms", corpus.rawValue as NSString, open) + " | first sweep " + summary(first) + " | revisits " + summary(later))

    // Per-row body derivation, isolated from SwiftUI layout.
    var derivations: [Double] = []
    for _ in 0..<5 {
        let start = clock.now
        for message in messages {
            let text = message.object("body").string("text") ?? ""
            let markdown = message.object("body").string("format") == "markdown"
            let names = Dictionary(uniqueKeysWithValues: MessageMentions.userIDs(in: text).map { ($0, server.snapshot.store.displayName(["user_id": .string($0)])) })
            if markdown { _ = MessageMarkdown(text, endpoint: server.profile.address, mentionNames: names) }
            else { _ = MessageTextDisplay.attributed(text, names: names) }
            _ = GitHubPreviewCache.shared.missingEmbeds(in: text, existing: [], markdown: markdown)
            _ = ApronLinkDiscovery.shared.missingEmbeds(in: text, markdown: markdown, endpoint: server.profile.address, existing: [])
        }
        derivations.append(milliseconds(clock.now - start))
    }
    print(String(format: "BENCH %@ derivation rows=%d cold=%.1fms warm median=%.1fms",
                 corpus.rawValue as NSString, messages.count, derivations[0], derivations.dropFirst().sorted()[2]))
}
