import Foundation
import CryptoKit
import ApronCore

/// A serial, bounded journal. Only explicitly selected metadata reaches disk.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog(directory: ProcessInfo.processInfo.environment["SIDETABLE_TESTING"] == "1" ? nil :
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sidetable/Diagnostics", isDirectory: true))

    private let queue = DispatchQueue(label: "chat.sidetable.diagnostics", qos: .utility)
    private let directory: URL?
    private let limit: Int
    private let salt = UUID().uuidString
    private var recent = Data()
    private var writeFailed = false

    init(directory: URL?, limit: Int = 256 * 1024) {
        self.directory = directory; self.limit = max(1024, limit)
    }

    private struct Entry: Encodable {
        var date = Date()
        var category: String
        var server: String
        var room: String?
        var event: String
        var scope: String?
        var method: String?
        var trigger: String?
        var request: UUID?
        var milliseconds: Double?
        var errorCode: Int?
        var retryAfter: Double?
        var offset: Double?
        var viewportHeight: Double?
        var documentHeight: Double?
        var visibleRows: Int?
        var renderer: String?
        var atEnd: Bool?
        var navigation: UUID?
        var durationMilliseconds: Double?
    }

    private func alias(_ value: String) -> String {
        SHA256.hash(data: Data((salt + value).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func record(_ diagnostic: SessionDiagnostic, server: UUID) {
        let serverAlias = alias(server.uuidString)
        let roomAlias = diagnostic.room.map { alias(server.uuidString + "/" + $0) }
        queue.async {
            var entry = Entry(date: diagnostic.date, category: "request", server: serverAlias,
                              room: roomAlias, event: diagnostic.event.rawValue)
            entry.scope = diagnostic.scope
            entry.method = diagnostic.method; entry.trigger = diagnostic.trigger.rawValue
            entry.request = diagnostic.request; entry.milliseconds = diagnostic.milliseconds
            entry.errorCode = diagnostic.errorCode
            entry.retryAfter = diagnostic.retryAfter.flatMap { $0.isFinite ? $0 : nil }
            self.append(entry)
        }
    }

    func transcript(server: UUID, room: String, offset: Double, viewportHeight: Double,
                    documentHeight: Double, visibleRows: Int, atEnd: Bool) {
        let serverAlias = alias(server.uuidString), roomAlias = alias(server.uuidString + "/" + room)
        queue.async {
            var entry = Entry(category: "transcript", server: serverAlias, room: roomAlias, event: "layout")
            entry.offset = offset; entry.viewportHeight = viewportHeight; entry.documentHeight = documentHeight
            entry.visibleRows = visibleRows; entry.atEnd = atEnd
            entry.renderer = "eager-batch"
            self.append(entry)
        }
    }

    func navigation(server: UUID, room: String, id: UUID, phase: NavigationTiming.Phase,
                    elapsed: Double, duration: Double? = nil) {
        let date = Date(), serverAlias = alias(server.uuidString), roomAlias = alias(server.uuidString + "/" + room)
        queue.async {
            var entry = Entry(date: date, category: "navigation", server: serverAlias, room: roomAlias, event: phase.rawValue)
            entry.navigation = id; entry.milliseconds = elapsed; entry.durationMilliseconds = duration
            self.append(entry)
        }
    }

    private func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(entry), line.count < limit else { return }
        line.append(10)
        recent.append(line)
        while recent.count > limit, let newline = recent.firstIndex(of: 10) { recent.removeSubrange(...newline) }
        guard let directory else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let current = directory.appendingPathComponent("current.jsonl")
            let previous = directory.appendingPathComponent("previous.jsonl")
            let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + line.count > limit {
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: current, to: previous)
            }
            if !manager.fileExists(atPath: current.path) {
                guard manager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    writeFailed = true; return
                }
            }
            let file = try FileHandle(forWritingTo: current)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: line)
        } catch { writeFailed = true }
    }

    func snapshot() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                var data = Data()
                if let directory = self.directory {
                    for name in ["previous.jsonl", "current.jsonl"] {
                        let url = directory.appendingPathComponent(name)
                        if let file = try? FileHandle(forReadingFrom: url) {
                            if let chunk = try? file.read(upToCount: self.limit) { data.append(chunk) }
                            try? file.close()
                        }
                    }
                }
                if data.isEmpty || self.writeFailed { data = self.recent }
                let header = "SideTable diagnostics v2\nAnonymous identifiers change on each launch. Times are UTC.\n"
                    + (self.writeFailed ? "Disk logging failed; showing recent in-memory events.\n" : "")
                continuation.resume(returning: header + (String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}

/// One navigation's milestones, using monotonic time and no observable UI state.
/// Layout milestones describe AppKit geometry, not pixels presented by the compositor.
@MainActor final class NavigationTiming {
    enum Phase: String, Sendable { case selected, selectionFinished, timeline, threadSummaries, viewAppeared, firstLayout, restoreFinished, scrollRequested, positionReported }
    private let log: DiagnosticLog
    private var server: UUID?
    private var room: String?
    private var id = UUID()
    private var start = ContinuousClock.now
    private(set) var milestones: [Phase: Double] = [:]
    private(set) var durations: [Phase: Double] = [:]

    init(log: DiagnosticLog = .shared) { self.log = log }

    func begin(server: UUID, room: String) {
        self.server = server; self.room = room; id = UUID(); start = .now; milestones = [:]; durations = [:]
        mark(.selected, server: server, room: room)
    }

    func mark(_ phase: Phase, server: UUID, room: String, duration: Double? = nil) {
        guard self.server == server, self.room == room, milestones[phase] == nil else { return }
        let elapsed = Self.milliseconds(start.duration(to: .now))
        milestones[phase] = elapsed
        durations[phase] = duration
        log.navigation(server: server, room: room, id: id, phase: phase, elapsed: elapsed, duration: duration)
    }

    func measure<T>(_ phase: Phase, server: UUID, room: String, operation: () -> T) -> T {
        guard self.server == server, self.room == room, milestones[phase] == nil else { return operation() }
        let start = ContinuousClock.now
        let result = operation()
        mark(phase, server: server, room: room, duration: Self.milliseconds(start.duration(to: .now)))
        return result
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// Opt-in aggregate profiling for the local rendering benchmark. Timings are
/// inclusive wall durations on the main actor; nested operations must not be summed.
@MainActor enum RenderProfile {
    static var enabled = false
    static var counts: [String: Int] = [:]
    static var milliseconds: [String: Double] = [:]
    static func reset() { counts = [:]; milliseconds = [:] }
    static func count(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
    }
    static func start() -> ContinuousClock.Instant? { enabled ? .now : nil }
    static func finish(_ name: String, _ start: ContinuousClock.Instant?) {
        guard let start else { return }
        count(name)
        let duration = start.duration(to: .now).components
        milliseconds[name, default: 0] += Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
    static var report: String {
        counts.keys.sorted().map {
            "\($0)=\(counts[$0]!)x/\(String(format: "%.2f", milliseconds[$0, default: 0]))ms"
        }.joined(separator: " ")
    }
}
