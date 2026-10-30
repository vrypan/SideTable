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
